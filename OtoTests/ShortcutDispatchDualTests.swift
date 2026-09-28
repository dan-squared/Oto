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

    /// Waits for a hands-free recording specifically. The generic waitFor
    /// matches ANY recording — vacuous right after a tap that is about to
    /// convert (it matches the micro's recording, then the guard races
    /// the cancel). This polls in the test body (MainActor) so the
    /// interaction check is legal.
    private func waitForHandsFree(
        _ coordinator: DictationCoordinator,
        timeout: Duration = .seconds(5)
    ) async -> DictationState {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            let state = await coordinator.state
            if case .recording(let context) = state, context.interaction == .handsFree {
                return state
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for hands-free recording")
        return await coordinator.state
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
        #expect(dispatch.updateHandsFreeTrigger(.unassignedHandsFree()) == .unchanged)
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
        #expect(dispatch.configuration.handsFree == .unassignedHandsFree())

        // Same shortcut in both slots, staged explicitly: occupy
        // hands-free with a combo, then refuse it in hold.
        let mods = CarbonModifiers.command | CarbonModifiers.control
        let staged = ShortcutTrigger(
            kind: combo(kVK_ANSI_G, modifiers: mods),
            interaction: .handsFree
        )
        #expect(dispatch.updateHandsFreeTrigger(staged) == .applied)
        let preset = ShortcutTrigger(
            kind: combo(kVK_ANSI_G, modifiers: mods),
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
        #expect(dispatch.calibrationHandsFree == .notSet)

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
        #expect(dispatch.configuration.hold == .unassignedHandsFree().withInteraction(.holdToTalk))
        #expect(dispatch.configuration.handsFree == .defaultHoldToTalk().withInteraction(.handsFree))
    }

    // MARK: - Unassigned slot

    @Test func unassignedSlotStaysNotSetAndNeverWins() {
        let (coordinator, _) = makeCoordinator()
        let dispatch = ShortcutDispatch(coordinator: coordinator, configuration: .default())
        defer { cleanDualKey() }
        #expect(dispatch.configuration.handsFree.kind == .unassigned)

        dispatch.refreshAvailability()
        #expect(dispatch.calibrationHandsFree == .notSet)
        // Combined value follows the live hold slot, never the empty one.
        #expect(dispatch.calibration == dispatch.calibrationHold)
        #expect(dispatch.calibration != .notSet)
    }

    @Test func doubleTapConvertsWithEmptyToggleSlot() async {
        // The toggle trigger is unnecessary for conversion: the coordinator
        // owns hands-free sessions, the slot only owns its key.
        let (coordinator, inserter, _) = makeGatedCoordinator()
        let dispatch = ShortcutDispatch(coordinator: coordinator, configuration: .default())
        #expect(dispatch.configuration.handsFree.kind == .unassigned)
        let t0 = ContinuousClock().now

        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .hold, at: t0)
        await waitFor(coordinator) { if case .recording = $0 { true } else { false } }
        dispatch.receiveForTests(.keyUp, from: .hold, at: t0 + .milliseconds(100))
        await waitFor(coordinator) { $0.isTerminal && $0 != .idle }
        #expect(await inserter.calls.count == 1)

        tap(dispatch, from: t0, downMs: 250, upMs: 330)
        _ = await waitForHandsFree(coordinator)
        guard case .recording(let converted) = await coordinator.state,
              converted.interaction == .handsFree
        else {
            Issue.record("expected hands-free recording, got \(await coordinator.state)")
            return
        }
        // Micro two was cancelled before it could insert.
        #expect(await inserter.calls.count == 1)

        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .handsFree)
        await waitFor(coordinator) { $0.isTerminal && $0 != .idle }
        #expect(await inserter.calls.count == 2)
    }

    // MARK: - Double-tap to hands-free

    private func makeGatedCoordinator(
        finalText: String = "hello oto",
        finishGateOpen: Bool = true
    ) -> (coordinator: DictationCoordinator, inserter: FakeTextInsertion, speech: FakeSpeechService) {
        let inserter = FakeTextInsertion(result: .inserted)
        let speech = FakeSpeechService(finalText: finalText, finishGateOpen: finishGateOpen)
        let coordinator = DictationCoordinator(
            audio: FakeAudioCapture(),
            speech: speech,
            targetService: FakeTargetCapture(stubTarget: Self.stubTarget),
            inserter: inserter,
            history: nil,
            micDeniedOverride: { false }
        )
        return (coordinator, inserter, speech)
    }

    private func tap(
        _ dispatch: ShortcutDispatch,
        from base: ContinuousClock.Instant,
        downMs: Int,
        upMs: Int
    ) {
        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .hold, at: base + .milliseconds(downMs))
        dispatch.receiveForTests(.keyUp, from: .hold, at: base + .milliseconds(upMs))
    }

    @Test func doubleTapCancelsMicroAndBeginsHandsFree() async {
        // Finish gate closed: the first tap's micro-session is stuck
        // finalizing at confirm time, so cancel wins deterministically.
        let (coordinator, inserter, speech) = makeGatedCoordinator(finishGateOpen: false)
        let dispatch = ShortcutDispatch(coordinator: coordinator, configuration: .default())
        let t0 = ContinuousClock().now

        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .hold, at: t0)
        await waitFor(coordinator) { if case .recording = $0 { true } else { false } }
        dispatch.receiveForTests(.keyUp, from: .hold, at: t0 + .milliseconds(100))
        // Micro-session stuck finalizing (finish gate closed): the confirm
        // below cancels it deterministically via cancel-wins.
        tap(dispatch, from: t0, downMs: 250, upMs: 330)
        // Confirm path: micro cancelled, hands-free begins.
        _ = await waitForHandsFree(coordinator)
        #expect(await inserter.calls.count == 0)
        guard case .recording(let context) = await coordinator.state else {
            Issue.record("expected hands-free recording, got \(await coordinator.state)")
            return
        }
        #expect(context.interaction == .handsFree)

        // Tidy: open the gate and stop via the hands-free press.
        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .handsFree)
        await speech.openFinishGate()
        await waitFor(coordinator) { $0.isTerminal && $0 != .idle }
        #expect(await inserter.calls.count == 1)
    }

    @Test func doubleTapConvergesWhenMicroAlreadyTerminal() async {
        // Gates open: the first tap finalizes instantly (short session takes
        // the full path and inserts). Conversion still lands hands-free.
        let (coordinator, inserter, _) = makeGatedCoordinator()
        let dispatch = ShortcutDispatch(coordinator: coordinator, configuration: .default())
        let t0 = ContinuousClock().now

        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .hold, at: t0)
        await waitFor(coordinator) { if case .recording = $0 { true } else { false } }
        dispatch.receiveForTests(.keyUp, from: .hold, at: t0 + .milliseconds(100))
        await waitFor(coordinator) { $0.isTerminal && $0 != .idle }
        #expect(await inserter.calls.count == 1)

        tap(dispatch, from: t0, downMs: 250, upMs: 330)
        _ = await waitForHandsFree(coordinator)
        // Micro two was cancelled before it could insert.
        #expect(await inserter.calls.count == 1)
        guard case .recording(let converted) = await coordinator.state,
              converted.interaction == .handsFree
        else {
            Issue.record("expected hands-free recording, got \(await coordinator.state)")
            return
        }

        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .handsFree)
        await waitFor(coordinator) { $0.isTerminal && $0 != .idle }
        #expect(await inserter.calls.count == 2)
    }

    @Test func slowPatternStaysTwoOrdinaryHolds() async {
        let (coordinator, inserter, _) = makeGatedCoordinator()
        let dispatch = ShortcutDispatch(coordinator: coordinator, configuration: .default())
        let t0 = ContinuousClock().now

        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .hold, at: t0)
        await waitFor(coordinator) { if case .recording = $0 { true } else { false } }
        dispatch.receiveForTests(.keyUp, from: .hold, at: t0 + .milliseconds(100))
        await waitFor(coordinator) { $0.isTerminal && $0 != .idle }

        // Far outside the tap window: injected future instants script a
        // genuinely slow pattern with zero wall-clock sleep (the tracker
        // reasons purely over injected time; routing never reads it).
        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .hold, at: t0 + .milliseconds(2000))
        await waitFor(coordinator) { if case .recording = $0 { true } else { false } }
        dispatch.receiveForTests(.keyUp, from: .hold, at: t0 + .milliseconds(2100))
        await waitFor(coordinator) { $0.isTerminal && $0 != .idle }

        guard case .completed(let context) = await coordinator.state else {
            Issue.record("expected completed, got \(await coordinator.state)")
            return
        }
        #expect(context.interaction == .holdToTalk)
        #expect(await inserter.calls.count == 2)
    }

    // MARK: - Bare-fn hold confirmation

    private func fnHoldConfig() -> DualShortcutConfiguration {
        DualShortcutConfiguration(
            hold: ShortcutTrigger(
                kind: .modifierHold(keyCode: UInt16(kVK_Function)),
                interaction: .holdToTalk
            ),
            handsFree: .dictationKeyHandsFree(),
            enabled: true
        )
    }

    @Test func fnTapCreatesNothing() async {
        // Sub-threshold tap: the system's (emoji or nothing). No session,
        // no insert, no calibration trace — and nothing late either.
        let (coordinator, inserter) = makeCoordinator()
        let dispatch = ShortcutDispatch(coordinator: coordinator, configuration: fnHoldConfig())
        let t0 = ContinuousClock().now

        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .hold, at: t0)
        dispatch.receiveForTests(.keyUp, from: .hold, at: t0 + .milliseconds(100))
        // Past the confirmation threshold: a late begin would land here.
        try? await Task.sleep(for: .milliseconds(400))
        guard case .idle = await coordinator.state else {
            Issue.record("fn tap created a session: \(await coordinator.state)")
            return
        }
        #expect(await inserter.calls.count == 0)
        #expect(dispatch.calibrationHold == .untested)
    }

    @Test func fnSustainedHoldRecordsNormally() async {
        let (coordinator, inserter) = makeCoordinator()
        let dispatch = ShortcutDispatch(coordinator: coordinator, configuration: fnHoldConfig())
        let t0 = ContinuousClock().now

        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .hold, at: t0)
        await waitFor(coordinator) { if case .recording = $0 { true } else { false } }
        dispatch.receiveForTests(.keyUp, from: .hold)
        await waitFor(coordinator) { $0.isTerminal && $0 != .idle }

        guard case .completed(let context) = await coordinator.state else {
            Issue.record("expected completed, got \(await coordinator.state)")
            return
        }
        #expect(context.interaction == .holdToTalk)
        #expect(await inserter.calls.count == 1)
        #expect(dispatch.calibrationHold == .ready)
    }

    @Test func fnDoubleTapNeverConverts() async {
        // fn taps belong to macOS (emoji/dictation): converting them would
        // double-fire against the system.
        let (coordinator, inserter) = makeCoordinator()
        let dispatch = ShortcutDispatch(coordinator: coordinator, configuration: fnHoldConfig())
        let t0 = ContinuousClock().now

        tap(dispatch, from: t0, downMs: 0, upMs: 100)
        tap(dispatch, from: t0, downMs: 250, upMs: 330)
        // Past every window: neither a convert nor a late begin may land.
        try? await Task.sleep(for: .milliseconds(500))
        guard case .idle = await coordinator.state else {
            Issue.record("fn double-tap converted: \(await coordinator.state)")
            return
        }
        #expect(await inserter.calls.count == 0)
    }

    @Test func reconfigDropsFnPending() async {
        let (coordinator, _) = makeCoordinator()
        let dispatch = ShortcutDispatch(coordinator: coordinator, configuration: fnHoldConfig())
        defer { cleanDualKey() }
        let t0 = ContinuousClock().now

        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .hold, at: t0)
        _ = dispatch.updateHoldTrigger(.defaultHoldToTalk())
        // The armed press belonged to the old trigger: nothing may begin.
        try? await Task.sleep(for: .milliseconds(400))
        guard case .idle = await coordinator.state else {
            Issue.record("reconfig leaked a session: \(await coordinator.state)")
            return
        }
    }

    @Test func tapsDuringHandsFreeKeepTranscriptAndConvert() async {
        let (coordinator, inserter, _) = makeGatedCoordinator()
        let dispatch = ShortcutDispatch(coordinator: coordinator, configuration: .default())

        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .handsFree)
        await waitFor(coordinator) { if case .recording = $0 { true } else { false } }

        // Two quick hold taps: the first tap's release finalizes the live
        // hands-free session (transcript KEPT via finalize, never cancel),
        // the pair then converts into a fresh hands-free session.
        let t0 = ContinuousClock().now
        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .hold, at: t0)
        dispatch.receiveForTests(.keyUp, from: .hold, at: t0 + .milliseconds(100))
        await waitFor(coordinator) { $0.isTerminal && $0 != .idle }
        #expect(await inserter.calls.count == 1)

        tap(dispatch, from: t0, downMs: 250, upMs: 330)
        _ = await waitForHandsFree(coordinator)
        #expect(await inserter.calls.count == 1)
        guard case .recording(let converted) = await coordinator.state,
              converted.interaction == .handsFree
        else {
            Issue.record("expected fresh hands-free recording, got \(await coordinator.state)")
            return
        }
    }
}
