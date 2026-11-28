//
//  CoordinatorProductivityTests.swift
//  OtoTests
//
//  Wave 2 integration tests: per-app Auto Cleanup overrides, dictionary +
//  snippet coexistence, voice-triggered snippet expansion bypassing Auto
//  Cleanup, non-voice/mid-sentence snippet non-expansion, and in-memory
//  lastTranscript tracking across success/failure/empty/cancel paths.
//

import Foundation
import Testing
@testable import Oto

@MainActor
struct CoordinatorProductivityTests {
    private func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suite = "test.oto.coord.prod.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func makeHistory(enabled: Bool = false) -> HistoryStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let (defaults, _) = makeDefaults()
        let store = HistoryStore(persistence: LocalPersistence(directory: dir), defaults: defaults)
        store.setEnabled(enabled)
        return store
    }

    private func waitFor(
        _ coordinator: DictationCoordinator,
        _ predicate: @Sendable (DictationState) -> Bool
    ) async -> DictationState {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while clock.now < deadline {
            let state = await coordinator.state
            if predicate(state) { return state }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for coordinator state")
        return await coordinator.state
    }

    private func runSession(_ coordinator: DictationCoordinator) async {
        guard let id = await coordinator.beginHold() else {
            Issue.record("beginHold refused")
            return
        }
        _ = await waitFor(coordinator, { if case .recording = $0 { return true }; return false })
        await coordinator.finish(id)
        _ = await waitFor(coordinator, { $0.isTerminal && $0 != .idle })
    }

    private func makeCleanupCoordinator(
        bundleID: String?,
        finalText: String = "raw dictation text",
        suiteName: String,
        polishChunks: [String] = ["Polished dictation text."]
    ) -> (DictationCoordinator, FakePolishService, FakeTextInsertion) {
        let audio = FakeAudioCapture(stubPeak: 1.0)
        let speech = FakeSpeechService(finalText: finalText)
        let target = FakeTargetCapture(stubTarget: TargetApplication(
            bundleIdentifier: bundleID,
            processIdentifier: 1234,
            windowIdentifier: nil
        ))
        let inserter = FakeTextInsertion(result: .inserted)
        let polish = FakePolishService()
        polish.availabilityResult = .available
        polish.chunks = polishChunks
        let coordinator = DictationCoordinator(
            audio: audio,
            speech: speech,
            targetService: target,
            inserter: inserter,
            history: nil,
            microphoneAccessOverride: { true },
            polish: polish,
            cleanupProvider: { appID in
                EffectiveCleanup.resolve(for: appID, defaults: UserDefaults(suiteName: suiteName)!)
            }
        )
        return (coordinator, polish, inserter)
    }

    // MARK: - Per-app Auto Cleanup overrides

    @Test func perAppCleanupOverridesRouteThroughCoordinator() async {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: CleanupSettings.enabledKey)
        defaults.set(CleanupLevel.light.rawValue, forKey: CleanupSettings.levelKey)

        CleanupAppOverrides.upsert(
            AppCleanupOverride(bundleID: "com.apple.Terminal", mode: .off),
            defaults: defaults
        )
        CleanupAppOverrides.upsert(
            AppCleanupOverride(bundleID: "com.apple.mail", mode: .medium),
            defaults: defaults
        )
        CleanupAppOverrides.upsert(
            AppCleanupOverride(bundleID: "com.tinyspeck.slackmacgap", mode: .custom, customPrompt: "Keep it casual"),
            defaults: defaults
        )

        // .off skips FakePolishService completely.
        let (offCoord, offPolish, offInserter) = makeCleanupCoordinator(
            bundleID: "com.apple.Terminal",
            suiteName: suiteName
        )
        await runSession(offCoord)
        #expect(offPolish.prompts.isEmpty)
        #expect(offPolish.jobs.isEmpty)
        #expect(offPolish.prewarms == 0)
        #expect(await offInserter.calls.first?.text == "raw dictation text")

        // .medium invokes .cleanup(.medium).
        let (medCoord, medPolish, medInserter) = makeCleanupCoordinator(
            bundleID: "com.apple.mail",
            suiteName: suiteName
        )
        await runSession(medCoord)
        #expect(medPolish.prompts == ["raw dictation text"])
        #expect(medPolish.jobs == [.cleanup(.medium)])
        #expect(medPolish.prewarms == 1)
        #expect(await medInserter.calls.first?.text == "Polished dictation text.")

        // .custom invokes .customCleanup(instruction:).
        let (customCoord, customPolish, customInserter) = makeCleanupCoordinator(
            bundleID: "com.tinyspeck.slackmacgap",
            suiteName: suiteName
        )
        await runSession(customCoord)
        #expect(customPolish.prompts == ["raw dictation text"])
        #expect(customPolish.jobs == [.customCleanup(instruction: "Keep it casual")])
        #expect(await customInserter.calls.first?.text == "Polished dictation text.")
    }

    // MARK: - Dictionary + Snippets coexistence & voice expansion

    @Test func setDictionaryRulesAndSetSnippetsDoNotClobberEachOther() async {
        let audio = FakeAudioCapture(stubPeak: 1.0)
        let speech = FakeSpeechService(finalText: "fix teh typo")
        let target = FakeTargetCapture(stubTarget: TargetApplication(
            bundleIdentifier: "com.apple.Notes",
            processIdentifier: 1234,
            windowIdentifier: nil
        ))
        let inserter = FakeTextInsertion(result: .inserted)
        let coordinator = DictationCoordinator(
            audio: audio,
            speech: speech,
            targetService: target,
            inserter: inserter,
            history: nil,
            microphoneAccessOverride: { true }
        )

        let snippet = Snippet(
            name: "calendar link",
            expansion: "https://cal.example/alex",
            voiceTriggerEnabled: true
        )
        let rule = DictionaryRule(spoken: "teh", replacement: "the")

        // Set snippets first, then dictionary rules — snippets must survive.
        await coordinator.setSnippets([snippet])
        await coordinator.setDictionaryRules([rule])

        await runSession(coordinator)
        #expect(await inserter.calls.last?.text == "fix the typo")

        await speech.setFinalText("calendar link")
        await runSession(coordinator)
        #expect(await inserter.calls.last?.text == "https://cal.example/alex")

        // Now update snippets again — dictionary rules must survive.
        let updatedSnippet = Snippet(
            name: "my email",
            expansion: "alex@example.com",
            voiceTriggerEnabled: true
        )
        await coordinator.setSnippets([updatedSnippet])

        await speech.setFinalText("fix teh other typo")
        await runSession(coordinator)
        #expect(await inserter.calls.last?.text == "fix the other typo")

        await speech.setFinalText("my email")
        await runSession(coordinator)
        #expect(await inserter.calls.last?.text == "alex@example.com")
    }

    @Test func voiceTriggeredSnippetExpandsVerbatimSkipsPolishAndRecordsHistory() async {
        let history = makeHistory(enabled: true)
        let audio = FakeAudioCapture(stubPeak: 1.0)
        let speech = FakeSpeechService(finalText: "  Calendar Link. ")
        let target = FakeTargetCapture(stubTarget: TargetApplication(
            bundleIdentifier: "com.apple.Notes",
            processIdentifier: 1234,
            windowIdentifier: nil
        ))
        let inserter = FakeTextInsertion(result: .inserted)
        let polish = FakePolishService()
        polish.availabilityResult = .available
        polish.chunks = ["Should never be used"]

        let coordinator = DictationCoordinator(
            audio: audio,
            speech: speech,
            targetService: target,
            inserter: inserter,
            history: history,
            microphoneAccessOverride: { true },
            polish: polish,
            cleanupProvider: { _ in EffectiveCleanup(enabled: true, job: .cleanup(.medium)) }
        )
        await coordinator.setSnippets([
            Snippet(
                name: "calendar link",
                expansion: "https://cal.example/alex?slot=30m",
                voiceTriggerEnabled: true
            ),
        ])

        await runSession(coordinator)

        #expect(polish.prompts.isEmpty)
        #expect(polish.jobs.isEmpty)
        #expect(await inserter.calls.first?.text == "https://cal.example/alex?slot=30m")
        #expect(history.entries.count == 1)
        #expect(history.entries[0].finalText == "https://cal.example/alex?slot=30m")
        #expect(history.entries[0].wasCleaned == false)
        #expect(history.entries[0].rawText == nil)
    }

    @Test func nonVoiceAndMidSentenceSnippetsDoNotExpandAndStillFlowThroughDictionaryAndPolish() async {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: CleanupSettings.enabledKey)
        defaults.set(CleanupLevel.light.rawValue, forKey: CleanupSettings.levelKey)

        // 1) Non-voice snippet: exact name still goes through dictionary + polish.
        let (coord1, polish1, inserter1) = makeCleanupCoordinator(
            bundleID: "com.apple.Notes",
            finalText: "calendar link teh",
            suiteName: suiteName,
            polishChunks: ["Calendar link the."]
        )
        await coord1.setDictionaryRules([DictionaryRule(spoken: "teh", replacement: "the")])
        await coord1.setSnippets([
            Snippet(
                name: "calendar link teh",
                expansion: "https://cal.example/alex",
                voiceTriggerEnabled: false
            ),
        ])
        await runSession(coord1)
        #expect(polish1.prompts == ["calendar link the"])
        #expect(await inserter1.calls.first?.text == "Calendar link the.")

        // 2) Voice-enabled snippet mentioned mid-sentence does not expand; dictionary + polish run.
        let (coord2, polish2, inserter2) = makeCleanupCoordinator(
            bundleID: "com.apple.Notes",
            finalText: "send teh calendar link please",
            suiteName: suiteName,
            polishChunks: ["Send the calendar link, please."]
        )
        await coord2.setDictionaryRules([DictionaryRule(spoken: "teh", replacement: "the")])
        await coord2.setSnippets([
            Snippet(
                name: "calendar link",
                expansion: "https://cal.example/alex",
                voiceTriggerEnabled: true
            ),
        ])
        await runSession(coord2)
        #expect(polish2.prompts == ["send the calendar link please"])
        #expect(await inserter2.calls.first?.text == "Send the calendar link, please.")
    }

    // MARK: - In-memory lastTranscriptText()

    @Test func lastTranscriptUpdatesOnSuccessAndFailureEvenWithHistoryOffAndIgnoresEmptyOrCancelled() async {
        let history = makeHistory(enabled: false)
        let audio = FakeAudioCapture(stubPeak: 1.0)
        let speech = FakeSpeechService(finalText: "first dictation")
        let target = FakeTargetCapture(stubTarget: TargetApplication(
            bundleIdentifier: "com.apple.Notes",
            processIdentifier: 1234,
            windowIdentifier: nil
        ))
        let inserter = FakeTextInsertion(result: .inserted)

        let coordinator = DictationCoordinator(
            audio: audio,
            speech: speech,
            targetService: target,
            inserter: inserter,
            history: history,
            microphoneAccessOverride: { true }
        )

        #expect(await coordinator.lastTranscriptText() == nil)

        // Completed insertion updates lastTranscript even when History is OFF.
        await runSession(coordinator)
        #expect(await coordinator.lastTranscriptText() == "first dictation")
        #expect(history.entries.isEmpty)

        // Empty session leaves previous lastTranscript untouched.
        await speech.setFinalText("   \n ")
        await runSession(coordinator)
        #expect(await coordinator.lastTranscriptText() == "first dictation")

        // Cancelled session (while finalizing) leaves previous lastTranscript untouched.
        await speech.setFinalText("should be cancelled")
        await speech.closeFinishGate()
        guard let cancelID = await coordinator.beginHold() else {
            Issue.record("beginHold refused")
            return
        }
        _ = await waitFor(coordinator, { if case .recording = $0 { return true }; return false })
        let finishTask = Task { await coordinator.finish(cancelID) }
        _ = await waitFor(coordinator, { if case .finalizing = $0 { return true }; return false })
        await coordinator.cancel(cancelID)
        await speech.openFinishGate()
        await finishTask.value
        #expect(await coordinator.lastTranscriptText() == "first dictation")

        // Insertion failure still updates lastTranscript.
        await speech.setFinalText("kept on insertion failure")
        await inserter.setResult(.recoverableFailure(reason: "paste failed"))
        await runSession(coordinator)
        #expect(await coordinator.lastTranscriptText() == "kept on insertion failure")

        // No editable field still updates lastTranscript.
        await speech.setFinalText("kept on no text field")
        await inserter.setResult(.noEditableField)
        await runSession(coordinator)
        #expect(await coordinator.lastTranscriptText() == "kept on no text field")

        // Target gone still updates lastTranscript.
        await speech.setFinalText("kept on target gone")
        await target.setCapturedTargetAlive(false)
        await runSession(coordinator)
        #expect(await coordinator.lastTranscriptText() == "kept on target gone")
    }
}
