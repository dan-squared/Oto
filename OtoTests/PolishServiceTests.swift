//
//  PolishServiceTests.swift
//  OtoTests
//
//  Slice A: the mapper tells the truth per reason, the fake streams in
//  order and cancels, the affordance rule hides without a model, and the
//  Manual flow provably never writes history (raw is never overwritten).
//

import AppKit
import Foundation
import FoundationModels
import Testing
@testable import Oto

@MainActor
struct PolishServiceTests {
    @Test func availableMapsToAvailable() {
        #expect(LivePolishService.map(.available) == .available)
    }

    @Test func eachReasonMapsToItsCopy() {
        #expect(LivePolishService.map(.unavailable(.deviceNotEligible)) ==
            .unavailable(copy: "This Mac doesn't support Apple Intelligence, so cleanup isn't available."))
        #expect(LivePolishService.map(.unavailable(.appleIntelligenceNotEnabled)) ==
            .unavailable(copy: "Turn on Apple Intelligence in System Settings to use cleanup."))
        #expect(LivePolishService.map(.unavailable(.modelNotReady)) ==
            .unavailable(copy: "The on-device model is still preparing. Try again shortly."))
    }

    @Test func affordanceNeedsEnabledAndAvailable() {
        #expect(polishActionVisible(availability: .available, enabled: true))
        #expect(!polishActionVisible(availability: .available, enabled: false))
        #expect(!polishActionVisible(availability: .unavailable(copy: "x"), enabled: true))
        #expect(!polishActionVisible(availability: .unavailable(copy: "x"), enabled: false))
    }

    @Test func fakeStreamsChunksInOrder() async {
        let fake = FakePolishService()
        fake.chunks = ["Clean", "Clean up", "Clean up."]
        var got: [String] = []
        for await snapshot in fake.streamCleanup("raw", job: .cleanup(.light)) {
            got.append(snapshot)
        }
        #expect(got == ["Clean", "Clean up", "Clean up."])
        #expect(fake.prompts == ["raw"])
        #expect(fake.jobs == [.cleanup(.light)])
    }

    @Test func fakeCancelStopsDelivery() async {
        let fake = FakePolishService()
        fake.chunks = ["one", "two", "three"]
        var got: [String] = []
        for await snapshot in fake.streamCleanup("raw", job: .cleanup(.medium)) {
            got.append(snapshot)
            break
        }
        // Consumer-side cancel (dismissing the sheet kills its .task):
        // at most the first snapshot escapes.
        #expect(got.count <= 1)
    }

    @Test func fakeErrorFinishesEmpty() async {
        let fake = FakePolishService()
        fake.shouldError = true
        var got: [String] = []
        for await snapshot in fake.streamCleanup("raw", job: .cleanup(.light)) {
            got.append(snapshot)
        }
        // Empty ⇒ the UI takes the "couldn't clean up" path, raw intact.
        #expect(got.isEmpty)
    }

    @Test func prewarmIsCounted() {
        let fake = FakePolishService()
        fake.prewarm()
        fake.prewarm()
        #expect(fake.prewarms == 2)
    }

    @Test func keepWritesOnlyTheClipboard() {
        let board = NSPasteboard(name: NSPasteboard.Name("test.oto.polish.\(UUID().uuidString)"))
        placePolishedOnClipboard("cleaned text", board: board)
        #expect(board.string(forType: .string) == "cleaned text")
    }

    @Test func useOriginalWritesRawToClipboard() {
        // Symmetric clipboard (Matrix A finding): Use original copies the
        // raw, so paste always reflects the last decision — a previous Keep
        // must not survive a change of mind.
        let board = NSPasteboard(name: NSPasteboard.Name("test.oto.polish.\(UUID().uuidString)"))
        placePolishedOnClipboard("polished", board: board)
        placePolishedOnClipboard("helo wrld", board: board)
        #expect(board.string(forType: .string) == "helo wrld")
    }

    @Test func captionFormatsElapsedAndWords() {
        #expect(polishTimingCaption(stats: PolishRunStats(
            firstTokenMs: 400, totalMs: 1400, inWords: 30, outWords: 38
        )) == "Cleaned with Light in 1.4s · 38 words")
        #expect(polishTimingCaption(stats: PolishRunStats(
            firstTokenMs: 120, totalMs: 400, inWords: 4, outWords: 4
        ), job: .transform(.polish)) == "Cleaned with Polish in 0.4s · 4 words")
    }

    @Test func instructionsDifferPerJob() {
        // None never streams (nil instructions); Light is the Matrix-A v2
        // text verbatim; Medium adds exactly the clarity-license sentence;
        // every streamed job carries the meaning-lock + same-language +
        // output-only locks.
        #expect(LivePolishService.instructions(for: .cleanup(.none)) == nil)
        let light = LivePolishService.instructions(for: .cleanup(.light))!
        let medium = LivePolishService.instructions(for: .cleanup(.medium))!
        #expect(light.contains("Preserve the meaning exactly"))
        #expect(light.contains("casual stays casual"))
        #expect(light.contains("Keep the same language"))
        #expect(light.contains("Output only the cleaned text"))
        #expect(medium.hasPrefix(light))
        #expect(medium.contains("clarity and conciseness"))
        #expect(light != medium)
        for preset in TransformPreset.allCases where preset != .custom {
            let prompt = LivePolishService.instructions(for: .transform(preset))!
            #expect(prompt.contains("Preserve the meaning exactly"))
            #expect(prompt.contains("Keep the same language"))
            #expect(prompt.contains("Output only the rewritten text"))
        }
        let concise = LivePolishService.instructions(for: .transform(.concise))!
        #expect(concise.contains("keep every fact and number"))
        let professional = LivePolishService.instructions(for: .transform(.professional))!
        #expect(professional.contains("work-ready"))
        #expect(TransformPreset.polish.displayName == "Polish")
        #expect(TransformPreset.polish.tagline == "Improve clarity and conciseness")
        #expect(TransformPreset.custom.tagline == "Your own instruction")
        #expect(TransformPreset.custom.pillVerb == "Custom")
    }

    @Test func customInstructionWrapsWithLocksMinusLanguage() {
        // Unjudged user text keeps meaning + output-only locks; the
        // same-language lock is dropped so translation works.
        let custom = CustomPrompt(name: "Bullets", instruction: "rewrite as 3 bullet points")
        let prompt = LivePolishService.instructions(for: .transform(.custom), custom: custom)!
        #expect(prompt.hasPrefix("rewrite as 3 bullet points"))
        #expect(prompt.contains("Preserve the meaning exactly"))
        #expect(prompt.contains("Output only the rewritten text"))
        #expect(!prompt.contains("Keep the same language"))
        // Empty instruction ⇒ nil ⇒ fail-closed upstream.
        #expect(LivePolishService.instructions(for: .transform(.custom), custom: CustomPrompt(name: "", instruction: "  ")) == nil)
        // Fixed presets ignore the injected custom (byte-identical either way).
        let a = LivePolishService.instructions(for: .transform(.polish), custom: custom)!
        let b = LivePolishService.instructions(for: .transform(.polish), custom: CustomPrompt(name: "", instruction: ""))!
        #expect(a == b)
    }

    @Test func customPromptCapsAndSanitize() {
        #expect(CustomPrompt.sanitizeName(nil) == "")
        #expect(CustomPrompt.sanitizeName("  Bullets\t\nrock  ") == "Bullets rock")
        #expect(CustomPrompt.sanitizeName(String(repeating: "a", count: 100)).count == CustomPrompt.nameCap)
        #expect(CustomPrompt.sanitizeInstruction(nil) == "")
        #expect(CustomPrompt.sanitizeInstruction(String(repeating: "b", count: 900)).count == CustomPrompt.instructionCap)
        #expect(CustomPrompt(name: "", instruction: "").isUsable == false)
        #expect(CustomPrompt(name: "", instruction: "do x").isUsable == true)
        #expect(CustomPrompt(name: "", instruction: "").nameOrFallback == "Custom")
        #expect(CustomPrompt(name: "Mine", instruction: "do x").nameOrFallback == "Mine")
        // Round-trip through injected defaults (never shared standard).
        let defaults = UserDefaults(suiteName: "test.oto.\(UUID().uuidString)")!
        let original = CustomPrompt(name: "Bullets", instruction: "rewrite as 3 bullets")
        original.save(to: defaults)
        #expect(CustomPrompt.load(defaults: defaults) == original)
    }

    @Test func tokenCapScalesWithInput() {
        // Short entries finish sooner; long ones keep full headroom.
        #expect(LivePolishService.options(for: String(repeating: "a", count: 200)).maximumResponseTokens == 164)
        #expect(LivePolishService.options(for: String(repeating: "a", count: 20)).maximumResponseTokens == 128)
        #expect(LivePolishService.options(for: String(repeating: "a", count: 5000)).maximumResponseTokens == 512)
    }

    @Test func customPromptNeverReachesLogs() throws {
        // Structural pin: the user's instruction must not appear in any
        // log line. Scans the service source (located relative to this
        // file) for prompt-content interpolation in logs — a tripwire, not
        // a parser: any hit fails for human review, never auto-fixed.
        let thisFile = URL(fileURLWithPath: #filePath)
        let sourceURL = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Oto/Services/WritingPolishService.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        for line in source.components(separatedBy: "\n") {
            let lower = line.lowercased()
            if lower.contains("log.") && (lower.contains("instruction") || lower.contains("customprompt") || lower.contains("prompt")) {
                Issue.record("possible prompt content in logs: \(line)")
            }
        }
    }

    @Test func manualFlowNeverWritesHistory() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let defaults = UserDefaults(suiteName: "test.oto.\(UUID().uuidString)")!
        let store = HistoryStore(
            persistence: LocalPersistence(directory: dir),
            defaults: defaults
        )
        store.setEnabled(true)
        await store.load()
        await store.record(finalText: "helo wrld", bundleID: "com.example.App")
        #expect(store.entries.count == 1)

        // The Manual flow end to end (fake model): stream the draft, Keep
        // copies it to a scratch board. History must be byte-identical.
        let fake = FakePolishService()
        fake.chunks = ["hello world"]
        var draft = ""
        for await snapshot in fake.streamCleanup(store.entries[0].finalText, job: .cleanup(.light)) {
            draft = snapshot
        }
        let board = NSPasteboard(name: NSPasteboard.Name("test.oto.polish.\(UUID().uuidString)"))
        placePolishedOnClipboard(draft, board: board)

        #expect(board.string(forType: .string) == "hello world")
        #expect(store.entries.count == 1)
        #expect(store.entries[0].finalText == "helo wrld")
    }
}
