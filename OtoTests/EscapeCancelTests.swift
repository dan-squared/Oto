//
//  EscapeCancelTests.swift
//  OtoTests
//
//  Escape→cancel through the real dispatch + coordinator (no hardware):
//  seeding mirrors what route(.begin) stores on a key-down, then the
//  production receiveEscape path cancels. Both interaction modes.
//

import Foundation
import Testing
@testable import Oto

@MainActor
struct EscapeCancelTests {
    private func makeCoordinator() -> DictationCoordinator {
        DictationCoordinator(
            audio: FakeAudioCapture(),
            speech: FakeSpeechService(finalText: "kept words"),
            targetService: FakeTargetCapture(stubTarget: TargetApplication(
                bundleIdentifier: "com.example.FakeTarget",
                processIdentifier: 1234
            )),
            inserter: FakeTextInsertion(result: .inserted),
            history: nil,
            micDeniedOverride: { false }
        )
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

    @Test func escapeCancelsHoldSession() async {
        let coordinator = makeCoordinator()
        let dispatch = ShortcutDispatch(coordinator: coordinator)
        let id = await coordinator.beginHold()
        await waitFor(coordinator) { if case .recording = $0 { true } else { false } }
        dispatch.seedActiveSessionForTests(id!)
        dispatch.receiveEscapeForTests()
        await waitFor(coordinator) { if case .cancelled = $0 { true } else { false } }
        if case .cancelled = await coordinator.state {
        } else {
            Issue.record("expected cancelled after Escape")
        }
    }

    @Test func escapeCancelsHandsFreeSession() async {
        let coordinator = makeCoordinator()
        let dispatch = ShortcutDispatch(coordinator: coordinator)
        let id = await coordinator.toggleHandsFree()
        await waitFor(coordinator) { if case .recording = $0 { true } else { false } }
        dispatch.seedActiveSessionForTests(id!)
        dispatch.receiveEscapeForTests()
        await waitFor(coordinator) { if case .cancelled = $0 { true } else { false } }
        if case .cancelled = await coordinator.state {
        } else {
            Issue.record("expected cancelled after Escape")
        }
    }
}
