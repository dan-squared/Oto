//
//  ShortcutDispatchDualTests.swift
//  OtoTests
//
//  Dual live slots through the real dispatch + coordinator (no hardware):
//  slot routing, cross-mode no-ops, the save gate (.blocked keeps the old
//  trigger), Delete→global-off, and the F1 re-enable pin. Backend events are
//  driven via the `receiveForTests` hook; real registration inside
//  `updateSlot` runs the production path (distinctive test-only combos,
//  RAII-unregistered on deinit).
//

import Carbon.HIToolbox
import Foundation
import Testing
@testable import Oto

@MainActor
struct ShortcutDispatchDualTests {
    private static let stubTarget = TargetApplication(
        bundleIdentifier: "com.example.FakeTarget",
        processIdentifier: 1234,
        windowIdentifier: nil
    )

    private func makeCoordinator(finalText: String = "hello oto") -> (
        coordinator: DictationCoordinator,
        inserter: FakeTextInsertion
    ) {
        let inserter = FakeTextInsertion(result: .inserted)
        let coordinator = DictationCoordinator(
            audio: FakeAudioCapture(),
            speech: FakeSpeechService(finalText: finalText),
            targetService: FakeTargetCapture(stubTarget: Self.stubTarget),
            inserter: inserter,
            history: nil,
            micDeniedOverride: { false }
        )
        return (coordinator, inserter)
    }

    /// Dual-key prefs cleanup: saves inside `updateSlot` target .standard.
    private func cleanDualKey() {
        UserDefaults.standard.removeObject(forKey: DualShortcutConfiguration.defaultsKey)
    }

    private func waitFor(
        _ coordinator: DictationCoordinator,
        timeout: Duration = .seconds(5),
        _ predicate: @Sendable (DictationState) -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if predicate(await coordinator.state) { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func combo(_ keyCode: Int, modifiers: Int) -> ShortcutTrigger.Kind {
        .combo(modifiers: UInt32(modifiers), keyCode: UInt32(keyCode))
    }

    // MARK: - Slot routing

    @Test func holdDownUpBeginsAndFinishes() async {
        let (coordinator, inserter) = makeCoordinator()
        let dispatch = ShortcutDispatch(coordinator: coordinator, configuration: .default())

        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .hold)
        await waitFor(coordinator) { if case .recording = $0 { true } else { false } }
        dispatch.receiveForTests(.keyUp, from: .hold)
        await waitFor(coordinator) { $0.isTerminal && $0 != .idle }

        guard case .completed = await coordinator.state else {
            Issue.record("expected completed, got \(await coordinator.state)")
            return
        }
        #expect(await inserter.calls.count == 1)
    }

    @Test func handsFreeDownDownTogglesBeginAndFinish() async {
        let (coordinator, inserter) = makeCoordinator()
        let dispatch = ShortcutDispatch(coordinator: coordinator, configuration: .default())

        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .handsFree)
        await waitFor(coordinator) { if case .recording = $0 { true } else { false } }
        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .handsFree)
        await waitFor(coordinator) { $0.isTerminal && $0 != .idle }

        guard case .completed(let context) = await coordinator.state else {
            Issue.record("expected completed, got \(await coordinator.state)")
            return
        }
        #expect(context.interaction == .handsFree)
        #expect(await inserter.calls.count == 1)
    }

    // MARK: - Cross-mode arbitration (first begin wins)

    @Test func handsFreePressDuringHoldSessionIsNoOp() async {
        let (coordinator, inserter) = makeCoordinator()
        let dispatch = ShortcutDispatch(coordinator: coordinator, configuration: .default())

        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .hold)
        await waitFor(coordinator) { if case .recording = $0 { true } else { false } }
        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .handsFree)
        // The second begin must not disturb the hold session.
        try? await Task.sleep(for: .milliseconds(200))
        guard case .recording = await coordinator.state else {
            Issue.record("hold session disturbed, got \(await coordinator.state)")
            return
        }
        #expect(await inserter.calls.count == 0)
        // And the hold session still finishes normally.
        dispatch.receiveForTests(.keyUp, from: .hold)
        await waitFor(coordinator) { $0.isTerminal && $0 != .idle }
        #expect(await inserter.calls.count == 1)
    }

    @Test func holdDownDuringHandsFreeSessionIsNoOp() async {
        let (coordinator, inserter) = makeCoordinator()
        let dispatch = ShortcutDispatch(coordinator: coordinator, configuration: .default())

        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .handsFree)
        await waitFor(coordinator) { if case .recording = $0 { true } else { false } }
        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .hold)
        try? await Task.sleep(for: .milliseconds(200))
        guard case .recording = await coordinator.state else {
            Issue.record("hands-free session disturbed, got \(await coordinator.state)")
            return
        }
        #expect(await inserter.calls.count == 0)
        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .handsFree)
        await waitFor(coordinator) { $0.isTerminal && $0 != .idle }
        #expect(await inserter.calls.count == 1)
    }

    // MARK: - Save gate

    @Test func sameSlotEqualityIsUnchanged() {
        let (coordinator, _) = makeCoordinator()
        let dispatch = ShortcutDispatch(coordinator: coordinator, configuration: .default())
        defer { cleanDualKey() }

        #expect(dispatch.updateHoldTrigger(.defaultHoldToTalk()) == .unchanged)
        #expect(dispatch.updateHandsFreeTrigger(.dictationKeyHandsFree()) == .unchanged)
    }

    @Test func triggerMatchingOtherSlotIsBlockedAndOldKept() {
        let (coordinator, _) = makeCoordinator()
        let dispatch = ShortcutDispatch(coordinator: coordinator, configuration: .default())
        defer { cleanDualKey() }

        // Hands-free takes the hold slot's kind: refused, old kept.
        let attempt = ShortcutTrigger(
            kind: DualShortcutConfiguration.default().hold.kind,
            interaction: .handsFree
        )
        #expect(dispatch.updateHandsFreeTrigger(attempt) == .blocked)
        #expect(dispatch.configuration.handsFree == .dictationKeyHandsFree())

        // Preset equal to the other slot's live trigger: same refusal.
        let preset = ShortcutTrigger(
            kind: DualShortcutConfiguration.default().handsFree.kind,
            interaction: .holdToTalk
        )
        #expect(dispatch.updateHoldTrigger(preset) == .blocked)
        #expect(dispatch.configuration.hold == .defaultHoldToTalk())
    }

    // MARK: - Delete globally off, fresh capture re-enables (F1)

    @Test func deleteDisablesGloballyAndFreshCaptureReEnables() {
        let (coordinator, _) = makeCoordinator()
        let dispatch = ShortcutDispatch(coordinator: coordinator, configuration: .default())
        defer { cleanDualKey() }

        dispatch.setEnabled(false)
        #expect(dispatch.configuration.enabled == false)
        #expect(dispatch.calibrationHold == .untested)
        #expect(dispatch.calibrationHandsFree == .untested)

        // A fresh explicit assignment is intent to have shortcuts on.
        let mods = CarbonModifiers.command | CarbonModifiers.control
        let first = ShortcutTrigger(kind: combo(kVK_ANSI_G, modifiers: mods), interaction: .holdToTalk)
        #expect(dispatch.updateHoldTrigger(first) == .applied)
        #expect(dispatch.configuration.enabled == true)
        #expect(dispatch.configuration.hold.kind == first.kind)

        let second = ShortcutTrigger(kind: combo(kVK_ANSI_H, modifiers: mods), interaction: .handsFree)
        #expect(dispatch.updateHandsFreeTrigger(second) == .applied)
        #expect(dispatch.configuration.enabled == true)
        #expect(dispatch.configuration.handsFree.kind == second.kind)
    }

    // MARK: - Suspend

    @Test func suspendCancelsSessionAndStopsBoth() async {
        let (coordinator, _) = makeCoordinator()
        let dispatch = ShortcutDispatch(coordinator: coordinator, configuration: .default())

        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .hold)
        await waitFor(coordinator) { if case .recording = $0 { true } else { false } }
        dispatch.setSuspended(true)
        await waitFor(coordinator) { if case .cancelled = $0 { true } else { false } }
        guard case .cancelled = await coordinator.state else {
            Issue.record("expected cancelled, got \(await coordinator.state)")
            return
        }
        #expect(dispatch.isSuspended == true)
        dispatch.setSuspended(false)
        #expect(dispatch.isSuspended == false)
    }

    // MARK: - Swap

    @Test func swapExchangesSlotsAndEnables() {
        let (coordinator, _) = makeCoordinator()
        let mods = CarbonModifiers.command | CarbonModifiers.control
        let holdCombo = ShortcutTrigger(kind: combo(kVK_ANSI_G, modifiers: mods), interaction: .holdToTalk)
        let freeCombo = ShortcutTrigger(kind: combo(kVK_ANSI_H, modifiers: mods), interaction: .handsFree)
        var config = DualShortcutConfiguration.default()
        config.hold = holdCombo
        config.handsFree = freeCombo
        let dispatch = ShortcutDispatch(coordinator: coordinator, configuration: config)
        defer { cleanDualKey() }

        dispatch.swapHoldAndHandsFree()
        #expect(dispatch.configuration.hold.kind == freeCombo.kind)
        #expect(dispatch.configuration.hold.interaction == .holdToTalk)
        #expect(dispatch.configuration.handsFree.kind == holdCombo.kind)
        #expect(dispatch.configuration.handsFree.interaction == .handsFree)
        #expect(dispatch.configuration.enabled == true)

        // Swap twice round-trips.
        dispatch.swapHoldAndHandsFree()
        #expect(dispatch.configuration.hold == holdCombo)
        #expect(dispatch.configuration.handsFree == freeCombo)
    }

    @Test func swapReEnablesFromDisabled() {
        let (coordinator, _) = makeCoordinator()
        let dispatch = ShortcutDispatch(coordinator: coordinator, configuration: .default())
        defer { cleanDualKey() }

        dispatch.setEnabled(false)
        #expect(dispatch.configuration.enabled == false)
        dispatch.swapHoldAndHandsFree()
        #expect(dispatch.configuration.enabled == true)
        #expect(dispatch.configuration.hold == .dictationKeyHandsFree().withInteraction(.holdToTalk))
        #expect(dispatch.configuration.handsFree == .defaultHoldToTalk().withInteraction(.handsFree))
    }
}
