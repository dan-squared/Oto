//
//  CoordinatorHistoryTests.swift
//  OtoTests
//
//  Phase 6A: history recording through finalize — non-empty finals record
//  (inserted AND kept-on-failure), empty/cancelled never record, OFF never
//  records. Uses the Phase 1 fakes; no audio, speech, or paste.
//

import Foundation
import Testing
@testable import Oto

@MainActor
struct CoordinatorHistoryTests {
    private static let stubTarget = TargetApplication(
        bundleIdentifier: "com.example.FakeTarget",
        processIdentifier: 1234,
        windowIdentifier: nil
    )

    private func makeHistory() -> HistoryStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let defaults = UserDefaults(suiteName: "test.oto.\(UUID().uuidString)")!
        return HistoryStore(persistence: LocalPersistence(directory: dir), defaults: defaults)
    }

    private func makeSUT(
        history: HistoryStore,
        finalText: String = "hello oto",
        insertionResult: InsertionResult = .inserted
    ) -> (DictationCoordinator, FakeSpeechService, FakeTextInsertion) {
        let audio = FakeAudioCapture()
        let speech = FakeSpeechService(finalText: finalText)
        let target = FakeTargetCapture(stubTarget: Self.stubTarget)
        let inserter = FakeTextInsertion(result: insertionResult)
        let coordinator = DictationCoordinator(
            audio: audio,
            speech: speech,
            targetService: target,
            inserter: inserter,
            history: history,
            micDeniedOverride: { false }
        )
        return (coordinator, speech, inserter)
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
        let id = await coordinator.beginHold()
        #expect(id != nil)
        _ = await waitFor(coordinator, { if case .recording = $0 { return true }; return false })
        await coordinator.finish(id!)
        _ = await waitFor(coordinator, { $0.isTerminal && $0 != .idle })
    }

    @Test func insertedFinalRecords() async {
        let history = makeHistory()
        history.setEnabled(true)
        let (coordinator, _, _) = makeSUT(history: history)
        await runSession(coordinator)
        #expect(history.entries.count == 1)
        #expect(history.entries[0].finalText == "hello oto")
        #expect(history.entries[0].bundleIdentifier == "com.example.FakeTarget")
    }

    @Test func keptOnFailureRecords() async {
        let history = makeHistory()
        history.setEnabled(true)
        let (coordinator, _, _) = makeSUT(history: history, insertionResult: .recoverableFailure(reason: "no route"))
        await runSession(coordinator)
        #expect(history.entries.count == 1)
    }

    @Test func offRecordsNothing() async {
        let history = makeHistory()
        // Never enabled: the coordinator call must no-op inside the store.
        let (coordinator, _, _) = makeSUT(history: history)
        await runSession(coordinator)
        #expect(history.entries.isEmpty)
    }

    @Test func emptyFinalNeverRecords() async {
        let history = makeHistory()
        history.setEnabled(true)
        let (coordinator, _, _) = makeSUT(history: history, finalText: "   ")
        await runSession(coordinator)
        #expect(history.entries.isEmpty)
    }

    @Test func dictionaryRulesFlowThroughFinalize() async {
        let history = makeHistory()
        history.setEnabled(true)
        let (coordinator, _, inserter) = makeSUT(history: history, finalText: "fix teh now")
        await coordinator.setDictionaryRules([
            DictionaryRule(spoken: "teh", replacement: "the"),
        ])
        await runSession(coordinator)
        let calls = await inserter.calls
        #expect(calls.first?.text == "fix the now")
        #expect(history.entries.first?.finalText == "fix the now")
    }
}
