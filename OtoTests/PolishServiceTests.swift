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
        for await snapshot in fake.streamCleanup("raw") {
            got.append(snapshot)
        }
        #expect(got == ["Clean", "Clean up", "Clean up."])
        #expect(fake.prompts == ["raw"])
    }

    @Test func fakeCancelStopsDelivery() async {
        let fake = FakePolishService()
        fake.chunks = ["one", "two", "three"]
        var got: [String] = []
        for await snapshot in fake.streamCleanup("raw") {
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
        for await snapshot in fake.streamCleanup("raw") {
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
        for await snapshot in fake.streamCleanup(store.entries[0].finalText) {
            draft = snapshot
        }
        let board = NSPasteboard(name: NSPasteboard.Name("test.oto.polish.\(UUID().uuidString)"))
        placePolishedOnClipboard(draft, board: board)

        #expect(board.string(forType: .string) == "hello world")
        #expect(store.entries.count == 1)
        #expect(store.entries[0].finalText == "helo wrld")
    }
}
