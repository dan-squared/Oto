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
        pasteboard: NSPasteboard? = nil,
        micDenied: Bool = false,
        finalText: String = "kept words"
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
            speech: FakeSpeechService(finalText: finalText),
            targetService: FakeTargetCapture(stubTarget: TargetApplication(
                bundleIdentifier: "com.example.FakeTarget",
                processIdentifier: 1234
            )),
            inserter: FakeTextInsertion(result: insertionResult),
            history: nil,
            micDeniedOverride: { false }
        )
        let box = SpectrumFeedBox()
        let permission = PermissionModalController()
        let controller = FlowBarController(
            coordinator: coordinator,
            analyzer: AudioSpectrumAnalyzer(),
            box: box,
            modal: NoTargetModalController(),
            permission: permission,
            pasteboard: board,
            isMicDenied: { micDenied }
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

            // Second poll: no double-write path, clipboard holds.
            await sut.controller.pollOnce()
            #expect(sut.board.string(forType: .string) == "kept words")
            // No notice pixels, ever: the melt completes and the pill is
            // gone (clipboard + menu own recovery now).
            try? await Task.sleep(for: .milliseconds(250))
            await sut.controller.pollOnce()
            #expect(!sut.controller.isPillVisible)
        }
    }

    @Test func overLimitFailureShowsCopiedPillThenHides() async throws {
        // >100 words with the catcher on: no modal — auto-copy plus a
        // transient message pill at current size, gone after its deadline.
        // Data stays whole on the clipboard throughout.
        let longText = Array(repeating: "word", count: 101).joined(separator: " ")
        let sut = makeSUT(insertionResult: .recoverableFailure(reason: "nope"), finalText: longText)
        try await withModalSetting(true) {
            let id = await sut.coordinator.beginHold()
            await waitFor(sut.coordinator) { if case .recording = $0 { true } else { false } }
            await sut.coordinator.finish(id!)
            await waitFor(sut.coordinator) { if case .failed = $0 { true } else { false } }

            await sut.controller.pollOnce()
            #expect(sut.controller.isPillVisible)
            #expect(sut.board.string(forType: .string) == longText)

            try? await Task.sleep(for: .milliseconds(2700))
            await sut.controller.pollOnce()
            try? await Task.sleep(for: .milliseconds(250))
            await sut.controller.pollOnce()
            #expect(!sut.controller.isPillVisible)
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
            history: nil,
            micDeniedOverride: { false }
        )
        let controller = FlowBarController(
            coordinator: denied,
            analyzer: AudioSpectrumAnalyzer(),
            box: SpectrumFeedBox(),
            modal: NoTargetModalController(),
            permission: PermissionModalController(),
            pasteboard: scratchBoard(),
            isMicDenied: { false }
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
            history: nil,
            micDeniedOverride: { false }
        )
        let controller = FlowBarController(
            coordinator: denied,
            analyzer: AudioSpectrumAnalyzer(),
            box: SpectrumFeedBox(),
            modal: NoTargetModalController(),
            permission: PermissionModalController(),
            pasteboard: scratchBoard(),
            isMicDenied: { false }
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

    @Test func micGateSuppressesPillEntirelyWhenDenied() async throws {
        // No-flash workstream: with mic denied the pill never renders —
        // not during starting, not during recording. (Fakes don't gate on
        // mic, so recording is reachable here and still pill-free.)
        let sut = makeSUT(micDenied: true)
        let id = await sut.coordinator.beginHold()
        #expect(id != nil)
        await sut.controller.pollOnce()
        #expect(!sut.controller.isPillVisible)
        await waitFor(sut.coordinator) { if case .recording = $0 { true } else { false } }
        await sut.controller.pollOnce()
        await sut.controller.pollOnce()
        #expect(!sut.controller.isPillVisible)
        #expect(!sut.controller.isLiveValues)
        // The gate is view-layer only: state truth still projects.
        #expect(sut.controller.model.projection.state == .recording)
        await sut.coordinator.finish(id!)
        await waitFor(sut.coordinator) { if case .completed = $0 { true } else { false } }
    }

    @Test func liveValuesLinkRunsWhileBarsAreLive() async throws {
        // Fluid-waves workstream: the vsync link owns bar transforms while
        // bars show, and dies with the vanish path.
        let sut = makeSUT()
        let id = await sut.coordinator.beginHold()
        await waitFor(sut.coordinator) { if case .recording = $0 { true } else { false } }
        await sut.controller.pollOnce()
        #expect(sut.controller.isPillVisible)
        #expect(sut.controller.isLiveValues)
        await sut.coordinator.finish(id!)
        await waitFor(sut.coordinator) { if case .completed = $0 { true } else { false } }
        await sut.controller.pollOnce()
        // Past the adoption park (400 ms): the parked hide melts as usual.
        try? await Task.sleep(for: .milliseconds(550))
        await sut.controller.pollOnce()
        #expect(!sut.controller.isLiveValues)
        #expect(!sut.controller.isPillVisible)
    }

    @Test func cancelParkAdoptsNextSessionWithoutDip() async throws {
        // Double-tap shape: cancel parks the hide; the next session inside
        // the window adopts the live panel — visible at every poll, no
        // hideNow between (a dip would need hideNow, the only hider).
        let sut = makeSUT()
        let id = await sut.coordinator.beginHold()
        await waitFor(sut.coordinator) { if case .recording = $0 { true } else { false } }
        await sut.controller.pollOnce()
        #expect(sut.controller.isPillVisible)
        await sut.coordinator.cancel(id!)
        await waitFor(sut.coordinator) { if case .cancelled = $0 { true } else { false } }
        await sut.controller.pollOnce()
        #expect(sut.controller.isPillVisible)
        let id2 = await sut.coordinator.beginHold()
        await waitFor(sut.coordinator) { if case .recording = $0 { true } else { false } }
        await sut.controller.pollOnce()
        #expect(sut.controller.isPillVisible)
        await sut.coordinator.finish(id2!)
        await waitFor(sut.coordinator) { $0.isTerminal && $0 != .idle }
    }

    @Test func parkedHideExpiresWithoutNewSession() async throws {
        let sut = makeSUT()
        let id = await sut.coordinator.beginHold()
        await waitFor(sut.coordinator) { if case .recording = $0 { true } else { false } }
        await sut.controller.pollOnce()
        #expect(sut.controller.isPillVisible)
        await sut.coordinator.cancel(id!)
        await waitFor(sut.coordinator) { if case .cancelled = $0 { true } else { false } }
        await sut.controller.pollOnce()
        #expect(sut.controller.isPillVisible)
        try? await Task.sleep(for: .milliseconds(550))
        await sut.controller.pollOnce()
        #expect(!sut.controller.isPillVisible)
    }
}
