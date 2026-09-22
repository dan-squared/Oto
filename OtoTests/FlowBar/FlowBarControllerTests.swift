//
//  FlowBarControllerTests.swift
//  OtoTests
//
//  Slice 6B/6C1: controller transitions through a REAL fake coordinator
//  (no mocks of the state machine — fakes only at the hardware boundary).
//  Recording arms the analyzer path; failed insertion routes to auto-copy
//  (setting OFF, scratch pasteboard — never the user's) or the catcher
//  modal (setting ON); analyzer stop guarantees silence.
//
//  Display note: routing assertions create real NSPanels, so these run
//  where a window server exists (same requirement class as OtoUITests).
//

import AppKit
import Foundation
import Testing
@testable import Oto

// Serialized: two tests flip the global modal kill-switch; parallel runs
// would race UserDefaults.standard between them.
@Suite(.serialized)
@MainActor
struct FlowBarControllerTests {
    private func scratchBoard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("oto-flowbar-\(UUID().uuidString)"))
    }

    private func makeSUT(
        insertionResult: InsertionResult = .inserted,
        pasteboard: NSPasteboard? = nil
    ) -> (
        controller: FlowBarController,
        coordinator: DictationCoordinator,
        box: SpectrumFeedBox,
        board: NSPasteboard,
        permission: PermissionModalController
    ) {
        let board = pasteboard ?? scratchBoard()
        let coordinator = DictationCoordinator(
            audio: FakeAudioCapture(),
            speech: FakeSpeechService(finalText: "kept words"),
            targetService: FakeTargetCapture(stubTarget: TargetApplication(
                bundleIdentifier: "com.example.FakeTarget",
                processIdentifier: 1234
            )),
            inserter: FakeTextInsertion(result: insertionResult),
            history: nil
        )
        let box = SpectrumFeedBox()
        let permission = PermissionModalController()
        let controller = FlowBarController(
            coordinator: coordinator,
            analyzer: AudioSpectrumAnalyzer(),
            box: box,
            modal: NoTargetModalController(),
            permission: permission,
            pasteboard: board
        )
        return (controller, coordinator, box, board, permission)
    }

    private func waitFor(
        _ coordinator: DictationCoordinator,
        _ predicate: @Sendable (DictationState) -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while clock.now < deadline {
            if predicate(await coordinator.state) { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func withModalSetting(_ enabled: Bool, _ body: () async throws -> Void) async throws {
        let key = NoTargetModalSettings.key
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(enabled, forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try await body()
    }

    @Test func recordingProjectsAndAnalyzerStopsSilent() async throws {
        let sut = makeSUT()
        await sut.controller.pollOnce()
        #expect(sut.controller.model.projection.state == .hidden)

        let id = await sut.coordinator.beginHold()
        #expect(id != nil)
        await waitFor(sut.coordinator) { if case .recording = $0 { true } else { false } }
        await sut.controller.pollOnce()
        #expect(sut.controller.model.projection.state == .recording)

        // Feed real synthetic audio through the box while recording, then
        // finish: stop() must leave the model silent (the guarantee).
        sut.box.setArmed(true)
        sut.box.offer(sineBuffer())
        try await withModalSetting(true) {
            await sut.coordinator.finish(id!)
        }
        await waitFor(sut.coordinator) { if case .completed = $0 { true } else { false } }
        await sut.controller.pollOnce()
        // v6: completion renders no pixels — the loader melts straight out.
        #expect(sut.controller.model.projection.state == .hidden)
        // Leaving recording stops the analyzer → silence, awaited.
        #expect(sut.controller.model.sample == .silence)
    }

    @Test func failedInsertionAutoCopiesWhenModalOff() async throws {
        let sut = makeSUT(insertionResult: .recoverableFailure(reason: "nope"))
        try await withModalSetting(false) {
            let id = await sut.coordinator.beginHold()
            await waitFor(sut.coordinator) { if case .recording = $0 { true } else { false } }
            await sut.coordinator.finish(id!)
            await waitFor(sut.coordinator) { if case .failed = $0 { true } else { false } }

            await sut.controller.pollOnce()
            #expect(sut.board.string(forType: .string) == "kept words")
            #expect(sut.controller.model.notice == "Copied — paste with ⌘V.")

            // Second poll: no double-write path, notice holds, no crash.
            await sut.controller.pollOnce()
            #expect(sut.board.string(forType: .string) == "kept words")
        }
    }

    @Test func failedInsertionShowsModalWhenModalOn() async throws {
        let sut = makeSUT(insertionResult: .recoverableFailure(reason: "nope"))
        defer { Task { @MainActor in sut.controller.modal.hide() } }
        try await withModalSetting(true) {
            let id = await sut.coordinator.beginHold()
            await waitFor(sut.coordinator) { if case .recording = $0 { true } else { false } }
            await sut.coordinator.finish(id!)
            await waitFor(sut.coordinator) { if case .failed = $0 { true } else { false } }

            await sut.controller.pollOnce()
            #expect(sut.controller.modal.isVisible)
            // Pill stays out of recovery's way.
            #expect(sut.controller.model.projection.state == .hidden)
            // Scratch board untouched — modal owns the text, nothing auto-wrote.
            #expect(sut.board.string(forType: .string) == nil)
        }
    }

    @Test func failureLeavesThePillToTheMenu() async throws {
        // v7: errors never reach the pill — no panel, no hold, no buttons.
        // The concise home is menu status (`lastSessionSummary`), pinned
        // here so the copy has a test. Microphone-denied fails fast
        // (prepare throws on open gate).
        let denied = DictationCoordinator(
            audio: FakeAudioCapture(),
            speech: FakeSpeechService(finalText: "x", prepareError: SpeechReadiness.microphoneDenied),
            targetService: FakeTargetCapture(stubTarget: TargetApplication(
                bundleIdentifier: "com.example.FakeTarget",
                processIdentifier: 1234
            )),
            inserter: FakeTextInsertion(result: .inserted),
            history: nil
        )
        let controller = FlowBarController(
            coordinator: denied,
            analyzer: AudioSpectrumAnalyzer(),
            box: SpectrumFeedBox(),
            modal: NoTargetModalController(),
            permission: PermissionModalController(),
            pasteboard: scratchBoard()
        )
        _ = await denied.beginHold()
        await waitFor(denied) { if case .failed = $0 { true } else { false } }
        await controller.pollOnce()
        #expect(controller.model.projection.state == .hidden)

        // Still hidden two polls later: nothing held, nothing rendered.
        await controller.pollOnce()
        await controller.pollOnce()
        #expect(controller.model.projection.state == .hidden)

        // …while the menu names it concisely (the v7 contract).
        #expect(await denied.lastSessionSummary().contains("microphone denied"))

        // Recovery itself is untouched (menu + modal): a new session still
        // starts from terminal failure — and fails pill-free again, fast.
        let second = await denied.beginHold()
        #expect(second != nil)
        await waitFor(denied) { if case .failed = $0 { true } else { false } }
        await controller.pollOnce()
        #expect(controller.model.projection.state == .hidden)
    }

    @Test func micDeniedShowsPermissionModalAtSlot() async throws {
        // Mic-denied owns a card, never the pill: the permission modal
        // renders at the slot while the projection stays hidden.
        let denied = DictationCoordinator(
            audio: FakeAudioCapture(),
            speech: FakeSpeechService(finalText: "x", prepareError: SpeechReadiness.microphoneDenied),
            targetService: FakeTargetCapture(stubTarget: TargetApplication(
                bundleIdentifier: "com.example.FakeTarget",
                processIdentifier: 1234
            )),
            inserter: FakeTextInsertion(result: .inserted),
            history: nil
        )
        let controller = FlowBarController(
            coordinator: denied,
            analyzer: AudioSpectrumAnalyzer(),
            box: SpectrumFeedBox(),
            modal: NoTargetModalController(),
            permission: PermissionModalController(),
            pasteboard: scratchBoard()
        )
        defer { Task { @MainActor in controller.permission.hide() } }
        _ = await denied.beginHold()
        await waitFor(denied) { if case .failed = $0 { true } else { false } }
        await controller.pollOnce()
        #expect(controller.permission.isVisible)
        #expect(controller.model.projection.state == .hidden)
        // Second poll: once per transition — no reshow, no duplicate.
        await controller.pollOnce()
        #expect(controller.permission.isVisible)
    }
}
