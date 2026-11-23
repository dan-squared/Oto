//
//  ShortcutDispatchDualTests.swift
//  OtoTests
//
//  Dual live slots through the real dispatch + coordinator (no hardware):
//  slot routing, cross-mode no-ops, the save gate (.blocked keeps the old
//  trigger), per-slot clears (clearing one slot never kills the other),
//  and the fresh-capture re-enable pin. Backend events are
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
            microphoneAccessOverride: { true }
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

    @Test func combinationCancelsALongHoldWithoutInserting() async {
        // ⌘ held well past the 1 s "fresh micro-session" window, then ⌘1.
        // The monitor marks combination use and swallows the release, so the
        // hold can only end through the routed combination event. It must
        // discard (never insert) and leave the coordinator terminal.
        let (coordinator, inserter) = makeCoordinator()
        let dispatch = ShortcutDispatch(coordinator: coordinator, configuration: .default())

        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .hold)
        await waitFor(coordinator) { if case .recording = $0 { true } else { false } }
        try? await Task.sleep(for: .milliseconds(1100))
        dispatch.receiveForTests(.combinationBegan, from: .hold)
        await waitFor(coordinator) { if case .cancelled = $0 { true } else { false } }

        #expect(await coordinator.state.isTerminal)
        #expect(await inserter.calls.isEmpty)
        // The next hold still begins: no stuck pressed state.
        try? await Task.sleep(for: .milliseconds(60))
        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .hold)
        await waitFor(coordinator) { if case .recording = $0 { true } else { false } }
        dispatch.receiveForTests(.keyUp, from: .hold)
        await waitFor(coordinator) { if case .completed = $0 { true } else { false } }
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
        // hands-free with a combo from a DIFFERENT family than the hold
        // (Rule B refuses same-family pairs), then refuse it in hold.
        // (Factory hold is Right Option ⇒ stage a Command combo here.)
        let mods = CarbonModifiers.command
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

    // MARK: - Per-slot enable (clear kills only its slot)

    @Test func clearDisablesOnlyItsSlotAndFreshCaptureReEnables() {
        let (coordinator, _) = makeCoordinator()
        let dispatch = ShortcutDispatch(coordinator: coordinator, configuration: .default())
        defer { cleanDualKey() }

        // Clearing hands-free must never kill push-to-talk (the old
        // global boolean did exactly that).
        dispatch.setSlotEnabled(false, for: .handsFree)
        #expect(dispatch.configuration.handsFreeEnabled == false)
        #expect(dispatch.configuration.holdEnabled == true)
        #expect(dispatch.slotEnabled(.hold) == true)
        #expect(dispatch.slotEnabled(.handsFree) == false)
        // Off slot reads as off, never as broken; the live slot keeps
        // whatever live value the machine has (never notSet).
        #expect(dispatch.calibrationHandsFree == .notSet)
        #expect(dispatch.calibrationHold != .notSet)

        // A fresh explicit assignment re-enables its own slot only.
        let mods = CarbonModifiers.command | CarbonModifiers.control
        let free = ShortcutTrigger(kind: combo(kVK_ANSI_H, modifiers: mods), interaction: .handsFree)
        #expect(dispatch.updateHandsFreeTrigger(free) == .applied)
        #expect(dispatch.configuration.handsFreeEnabled == true)
        #expect(dispatch.configuration.holdEnabled == true)
        #expect(dispatch.configuration.handsFree.kind == free.kind)

        // Mirror: hold off leaves hands-free alone, and a fresh hold
        // capture re-enables hold.
        dispatch.setSlotEnabled(false, for: .hold)
        #expect(dispatch.configuration.holdEnabled == false)
        #expect(dispatch.configuration.handsFreeEnabled == true)
        #expect(dispatch.calibrationHold == .notSet)
        let hold = ShortcutTrigger(kind: combo(kVK_ANSI_G, modifiers: mods), interaction: .holdToTalk)
        #expect(dispatch.updateHoldTrigger(hold) == .applied)
        #expect(dispatch.configuration.holdEnabled == true)
        #expect(dispatch.configuration.hold.kind == hold.kind)
    }

    /// The recorder's Remove/⌫ must empty the keys themselves, not only the
    /// enable flag: an off slot that still stores its old kind kept drawing
    /// keycaps that could no longer fire. Clearing one slot must leave the
    /// other exactly as it was.
    @Test func clearSlotEmptiesKeysAndOnlyItsSlot() {
        let mods = CarbonModifiers.command | CarbonModifiers.control
        var config = DualShortcutConfiguration.default()
        config.handsFree = ShortcutTrigger(
            kind: combo(kVK_ANSI_J, modifiers: mods), interaction: .handsFree
        )
        let (coordinator, _) = makeCoordinator()
        let dispatch = ShortcutDispatch(coordinator: coordinator, configuration: config)
        defer { cleanDualKey() }

        dispatch.clearSlot(.hold)
        #expect(dispatch.configuration.hold.kind == .unassigned)
        #expect(dispatch.configuration.holdEnabled == false)
        #expect(dispatch.configuration.handsFree == config.handsFree)
        #expect(dispatch.configuration.handsFreeEnabled == true)
        #expect(dispatch.calibrationHold == .notSet)

        // A fresh capture after Remove re-enables the slot (no one-way door).
        let hold = ShortcutTrigger(
            kind: combo(kVK_ANSI_K, modifiers: mods), interaction: .holdToTalk
        )
        #expect(dispatch.updateHoldTrigger(hold) == .applied)
        #expect(dispatch.configuration.holdEnabled == true)
        #expect(dispatch.configuration.hold.kind == hold.kind)

        // Mirror: clearing hands-free never touches the live hold slot.
        dispatch.clearSlot(.handsFree)
        #expect(dispatch.configuration.handsFree == .unassignedHandsFree())
        #expect(dispatch.configuration.handsFreeEnabled == false)
        #expect(dispatch.configuration.hold == hold)
        #expect(dispatch.configuration.holdEnabled == true)
    }

    @Test func disabledSlotReadsNotSetWhileOtherSlotStaysLive() {        // Gating level (no modal): hold off with an assigned hands-free
        // on — hold reports notSet, hands-free never reads as off.
        // Distinctive J/K combos avoid the G/H users elsewhere in this file.
        let mods = CarbonModifiers.command | CarbonModifiers.control
        var config = DualShortcutConfiguration.default()
        config.handsFree = ShortcutTrigger(
            kind: combo(kVK_ANSI_J, modifiers: mods), interaction: .handsFree
        )
        config.holdEnabled = false
        let (coordinator, _) = makeCoordinator()
        let dispatch = ShortcutDispatch(coordinator: coordinator, configuration: config)
        defer { cleanDualKey() }
        dispatch.start()
        #expect(dispatch.slotEnabled(.hold) == false)
        #expect(dispatch.slotEnabled(.handsFree) == true)
        #expect(dispatch.calibrationHold == .notSet)
        #expect(dispatch.calibrationHandsFree != .notSet)

        // Mirror flip: hands-free off, hold live.
        dispatch.setSlotEnabled(true, for: .hold)
        dispatch.setSlotEnabled(false, for: .handsFree)
        #expect(dispatch.calibrationHandsFree == .notSet)
        #expect(dispatch.calibrationHold != .notSet)
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

    @Test func swapExchangesTriggersAndPreservesFlags() {
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
        #expect(dispatch.configuration.holdEnabled == true)
        #expect(dispatch.configuration.handsFreeEnabled == true)

        // Swap twice round-trips.
        dispatch.swapHoldAndHandsFree()
        #expect(dispatch.configuration.hold == holdCombo)
        #expect(dispatch.configuration.handsFree == freeCombo)
    }

    @Test func swapPreservesDisabledSlot() {
        // Swapping keys must never silently turn a way to talk on or off:
        // flags stay with their slots, only triggers exchange.
        let (coordinator, _) = makeCoordinator()
        let dispatch = ShortcutDispatch(coordinator: coordinator, configuration: .default())
        defer { cleanDualKey() }

        dispatch.setSlotEnabled(false, for: .handsFree)
        #expect(dispatch.configuration.handsFreeEnabled == false)
        dispatch.swapHoldAndHandsFree()
        #expect(dispatch.configuration.holdEnabled == true)
        #expect(dispatch.configuration.handsFreeEnabled == false)
        #expect(dispatch.configuration.hold == .unassignedHandsFree().withInteraction(.holdToTalk))
        #expect(dispatch.configuration.handsFree == .defaultHoldToTalk().withInteraction(.handsFree))
    }

    @Test func resetRestoresFactoryTriggersWithBothSlotsOn() {
        let (coordinator, _) = makeCoordinator()
        let mods = CarbonModifiers.command | CarbonModifiers.control
        var config = DualShortcutConfiguration.default()
        config.hold = ShortcutTrigger(kind: combo(kVK_ANSI_G, modifiers: mods), interaction: .holdToTalk)
        config.holdEnabled = false
        let dispatch = ShortcutDispatch(coordinator: coordinator, configuration: config)
        defer { cleanDualKey() }

        dispatch.resetToDefaults()
        #expect(dispatch.configuration == .default())
        #expect(dispatch.configuration.holdEnabled == true)
        #expect(dispatch.configuration.handsFreeEnabled == true)
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
            microphoneAccessOverride: { true }
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
            holdEnabled: true,
            handsFreeEnabled: true
        )
    }

    @Test func fnPressBeginsImmediatelyLikeOtherModifiers() async {
        // Bare fn behaves identically to every other hold key (0 ms start, no
        // 200 ms confirmation lag) so it feels snappy and consistent.
        let (coordinator, inserter) = makeCoordinator()
        let dispatch = ShortcutDispatch(
            coordinator: coordinator,
            configuration: fnHoldConfig(),
            systemFnUsageProvider: { .emoji }
        )
        let t0 = ContinuousClock().now

        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .hold, at: t0)
        await waitFor(coordinator) { if case .recording = $0 { true } else { false } }
        dispatch.receiveForTests(.keyUp, from: .hold, at: t0 + .milliseconds(100))
        await waitFor(coordinator) { $0.isTerminal && $0 != .idle }

        guard case .completed(let context) = await coordinator.state else {
            Issue.record("expected completed, got \(await coordinator.state)")
            return
        }
        #expect(context.interaction == .holdToTalk)
        #expect(await inserter.calls.count == 1)
        #expect(dispatch.calibrationHold == .ready)
    }

    @Test func fnSustainedHoldRecordsNormally() async {
        let (coordinator, inserter) = makeCoordinator()
        let dispatch = ShortcutDispatch(
            coordinator: coordinator,
            configuration: fnHoldConfig(),
            systemFnUsageProvider: { .emoji }
        )
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

    @Test func fnDoubleTapConvertsToHandsFree() async {
        // Bare fn shares the exact same instant hold + double-tap-to-hands-free
        // UX as every other hold modifier key.
        let (coordinator, _) = makeCoordinator()
        let dispatch = ShortcutDispatch(
            coordinator: coordinator,
            configuration: fnHoldConfig(),
            systemFnUsageProvider: { .emoji }
        )
        let t0 = ContinuousClock().now

        tap(dispatch, from: t0, downMs: 0, upMs: 100)
        tap(dispatch, from: t0, downMs: 250, upMs: 330)
        // Wait for the double-tap conversion (cancel + handsFree begin) to settle.
        for _ in 0..<40 {
            if case .recording(let ctx) = await coordinator.state, ctx.interaction == .handsFree {
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard case .recording(let context) = await coordinator.state else {
            Issue.record("expected hands-free recording, got \(await coordinator.state)")
            return
        }
        #expect(context.interaction == .handsFree)

        // Single click (tap) of fn stops hands-free cleanly without requiring a hold,
        // and any duplicate echo pulse within 400ms is absorbed without restarting hands-free.
        tap(dispatch, from: t0, downMs: 800, upMs: 830)
        tap(dispatch, from: t0, downMs: 860, upMs: 890)
        await waitFor(coordinator) { $0.isTerminal && $0 != .idle }
        guard case .completed(let doneCtx) = await coordinator.state else {
            Issue.record("expected completed after single click of fn, got \(await coordinator.state)")
            return
        }
        #expect(doneCtx.interaction == .handsFree)
    }

    @Test func reconfigCancelsActiveFnSession() async {
        let (coordinator, _) = makeCoordinator()
        let dispatch = ShortcutDispatch(
            coordinator: coordinator,
            configuration: fnHoldConfig(),
            systemFnUsageProvider: { .emoji }
        )
        defer { cleanDualKey() }
        let t0 = ContinuousClock().now

        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .hold, at: t0)
        await waitFor(coordinator) { if case .recording = $0 { true } else { false } }
        _ = dispatch.updateHoldTrigger(.defaultHoldToTalk())
        await waitFor(coordinator) { if case .cancelled = $0 { true } else { false } }
        guard case .cancelled = await coordinator.state else {
            Issue.record("reconfig left fn session running: \(await coordinator.state)")
            return
        }
    }

    @Test func fnCombinationAfterConfirmCancelsActiveSessionAndResetsState() async {
        let (coordinator, inserter) = makeCoordinator()
        let dispatch = ShortcutDispatch(
            coordinator: coordinator,
            configuration: fnHoldConfig(),
            systemFnUsageProvider: { .emoji }
        )
        let t0 = ContinuousClock().now

        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .hold, at: t0)
        await waitFor(coordinator) { if case .recording = $0 { true } else { false } }
        // User presses fn+Arrow after confirmation: cancels cleanly and resets fnHold.
        dispatch.receiveForTests(.combinationBegan, from: .hold)
        await waitFor(coordinator) { if case .cancelled = $0 { true } else { false } }
        #expect(await inserter.calls.isEmpty)

        // Next fn hold confirms and records cleanly (no stranded fnHold.isDown).
        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .hold, at: ContinuousClock().now)
        await waitFor(coordinator) { if case .recording = $0 { true } else { false } }
        dispatch.receiveForTests(.keyUp, from: .hold)
        await waitFor(coordinator) { if case .completed = $0 { true } else { false } }
        #expect(await inserter.calls.count == 1)
    }

    @Test func fnWithSystemUsageNoneIsInstantAndSupportsDoubleTapAndHandsFree() async {
        defer { cleanDualKey() }
        let (coordinator, inserter, _) = makeGatedCoordinator()
        let dispatch = ShortcutDispatch(
            coordinator: coordinator,
            configuration: fnHoldConfig(),
            systemFnUsageProvider: { .none }
        )
        let t0 = ContinuousClock().now

        // Instant hold (zero 200ms confirmation wait): quick tap starts & inserts.
        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .hold, at: t0)
        await waitFor(coordinator) { if case .recording = $0 { true } else { false } }
        dispatch.receiveForTests(.keyUp, from: .hold, at: t0 + .milliseconds(80))
        await waitFor(coordinator) { $0.isTerminal && $0 != .idle }
        #expect(await inserter.calls.count == 1)

        // Double-tap converts to hands-free when macOS is set to "Do Nothing".
        tap(dispatch, from: t0, downMs: 220, upMs: 300)
        _ = await waitForHandsFree(coordinator)
        guard case .recording(let ctx) = await coordinator.state, ctx.interaction == .handsFree else {
            Issue.record("expected hands-free recording for fn with usage .none")
            return
        }
        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .handsFree)
        await waitFor(coordinator) { $0.isTerminal && $0 != .idle }

        // Swap into hands-free is allowed when macOS does not own fn taps.
        dispatch.swapHoldAndHandsFree()
        #expect(dispatch.configuration.handsFree.kind == .modifierHold(keyCode: UInt16(kVK_Function)))
    }

    @Test func fnHandsFreeAndSwapBlockedWhenSystemOwnsFnTaps() {
        defer { cleanDualKey() }
        let (coordinator, _) = makeCoordinator()
        let dispatch = ShortcutDispatch(
            coordinator: coordinator,
            configuration: .default(),
            systemFnUsageProvider: { .emoji }
        )
        let fnHandsFree = ShortcutTrigger(
            kind: .modifierHold(keyCode: UInt16(kVK_Function)),
            interaction: .handsFree
        )
        #expect(dispatch.updateHandsFreeTrigger(fnHandsFree) == .blocked)
        #expect(dispatch.configuration.handsFree == .unassignedHandsFree())

        // Put fn in hold, then attempt to swap it into hands-free: refused.
        let fnHold = ShortcutTrigger(
            kind: .modifierHold(keyCode: UInt16(kVK_Function)),
            interaction: .holdToTalk
        )
        #expect(dispatch.updateHoldTrigger(fnHold) == .applied)
        dispatch.swapHoldAndHandsFree()
        #expect(dispatch.configuration.hold.kind == .modifierHold(keyCode: UInt16(kVK_Function)))
        #expect(dispatch.configuration.handsFree == .unassignedHandsFree())
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

    // MARK: - Press cue (feedback sounds)

    @Test func pressPlaysTheListeningTone() async {
        defer { cleanDualKey() }
        let (coordinator, _, _) = makeGatedCoordinator()
        let sounds = SpyFeedbackSounds()
        let dispatch = ShortcutDispatch(
            coordinator: coordinator, configuration: .default(), sounds: sounds
        )

        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .hold)
        #expect(sounds.cues == [.listening])

        // Release is silent: the done tone belongs to the moment the words
        // land, which the coordinator owns.
        dispatch.receiveForTests(.keyUp, from: .hold)
        #expect(sounds.cues == [.listening])
    }

    @Test func handsFreeStopPressIsSilent() async {
        defer { cleanDualKey() }
        let (coordinator, _, _) = makeGatedCoordinator()
        let sounds = SpyFeedbackSounds()
        let dispatch = ShortcutDispatch(
            coordinator: coordinator, configuration: .default(), sounds: sounds
        )

        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .handsFree)
        await waitFor(coordinator) { if case .recording = $0 { true } else { false } }
        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .handsFree)
        #expect(sounds.cues == [.listening])
    }

    @Test func combinationAfterAPressAddsNoSecondTone() async {
        defer { cleanDualKey() }
        let (coordinator, _, _) = makeGatedCoordinator()
        let sounds = SpyFeedbackSounds()
        let dispatch = ShortcutDispatch(
            coordinator: coordinator, configuration: .default(), sounds: sounds
        )

        // A modifier used as a chord: the press already sounded (it cannot be
        // unplayed without delaying every press to classify it), and the
        // cancel adds nothing.
        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .hold)
        dispatch.receiveForTests(.combinationBegan, from: .hold)
        #expect(sounds.cues == [.listening])
    }

    // MARK: - Serialization, hands-free stateless toggle, repeat guard & AX flag

    @Test func immediateQuickTapFinishesWithoutDroppingAndImmediateEscapeCancels() async {
        // Rapid down+up with zero sleep between them: FIFO action queue ensures
        // finish waits for begin's activeSessionID instead of dropping it.
        let (coordinator, inserter) = makeCoordinator()
        let dispatch = ShortcutDispatch(coordinator: coordinator, configuration: .default())
        let t0 = ContinuousClock().now

        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .hold, at: t0)
        dispatch.receiveForTests(.keyUp, from: .hold, at: t0 + .milliseconds(40))
        await waitFor(coordinator) { $0.isTerminal && $0 != .idle }
        guard case .completed = await coordinator.state else {
            Issue.record("expected completed after immediate down+up, got \(await coordinator.state)")
            return
        }
        #expect(await inserter.calls.count == 1)

        // Rapid down + Escape before begin settles: cancel still wins.
        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .hold, at: t0 + .milliseconds(2000))
        dispatch.receiveEscapeForTests()
        await waitFor(coordinator) { if case .cancelled = $0 { true } else { false } }
        guard case .cancelled = await coordinator.state else {
            Issue.record("expected cancelled after immediate down+Escape, got \(await coordinator.state)")
            return
        }
        #expect(await inserter.calls.count == 1)
    }

    @Test func handsFreeStatelessToggleNeverDesyncsAfterDoubleTapStop() async {
        let (coordinator, inserter, _) = makeGatedCoordinator()
        let sounds = SpyFeedbackSounds()
        let dispatch = ShortcutDispatch(
            coordinator: coordinator, configuration: .default(), sounds: sounds
        )
        let t0 = ContinuousClock().now

        // Start hands-free via double-tap (not the hands-free key).
        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .hold, at: t0)
        await waitFor(coordinator) { if case .recording = $0 { true } else { false } }
        dispatch.receiveForTests(.keyUp, from: .hold, at: t0 + .milliseconds(80))
        await waitFor(coordinator) { $0.isTerminal && $0 != .idle }
        tap(dispatch, from: t0, downMs: 200, upMs: 280)
        _ = await waitForHandsFree(coordinator)
        let cuesBeforeStop = sounds.cues.count

        // Stop via hands-free press: stops cleanly WITHOUT playing a listening cue.
        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .handsFree)
        await waitFor(coordinator) { $0.isTerminal && $0 != .idle }
        #expect(sounds.cues.count == cuesBeforeStop)
        #expect(await inserter.calls.count == 2)

        // Next hands-free press immediately starts a new session (no desync!).
        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .handsFree)
        _ = await waitForHandsFree(coordinator)
        #expect(sounds.cues.count == cuesBeforeStop + 1)
    }

    @Test func autoRepeatKeyDownDoesNotTriggerFalseDoubleTap() async {
        let (coordinator, inserter, _) = makeGatedCoordinator()
        let dispatch = ShortcutDispatch(coordinator: coordinator, configuration: .default())
        let t0 = ContinuousClock().now

        // Tap 1 (short), then held key with auto-repeat events, then release:
        // repeats must not overwrite holdTap.downAt and manufacture a fake tap.
        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .hold, at: t0)
        await waitFor(coordinator) { if case .recording = $0 { true } else { false } }
        dispatch.receiveForTests(.keyUp, from: .hold, at: t0 + .milliseconds(80))
        await waitFor(coordinator) { $0.isTerminal && $0 != .idle }

        dispatch.receiveForTests(.keyDown(isRepeat: false), from: .hold, at: t0 + .milliseconds(200))
        await waitFor(coordinator) { if case .recording = $0 { true } else { false } }
        dispatch.receiveForTests(.keyDown(isRepeat: true), from: .hold, at: t0 + .milliseconds(500))
        dispatch.receiveForTests(.keyUp, from: .hold, at: t0 + .milliseconds(550))
        await waitFor(coordinator) { $0.isTerminal && $0 != .idle }

        guard case .completed(let ctx) = await coordinator.state else {
            Issue.record("expected completed hold, got \(await coordinator.state)")
            return
        }
        #expect(ctx.interaction == .holdToTalk)
        #expect(await inserter.calls.count == 2)
    }

    @Test func requiresAccessibilityReflectsEnabledSlotKinds() {
        let (coordinator, _) = makeCoordinator()
        // Default: Right Option hold → requires Accessibility.
        let dispatch = ShortcutDispatch(coordinator: coordinator, configuration: .default())
        #expect(dispatch.requiresAccessibility == true)

        // Combo-only configuration → does not require Accessibility.
        let comboConfig = DualShortcutConfiguration(
            hold: ShortcutTrigger(
                kind: combo(kVK_ANSI_D, modifiers: CarbonModifiers.control | CarbonModifiers.shift),
                interaction: .holdToTalk
            ),
            handsFree: .unassignedHandsFree(),
            holdEnabled: true,
            handsFreeEnabled: true
        )
        let comboDispatch = ShortcutDispatch(coordinator: coordinator, configuration: comboConfig)
        #expect(comboDispatch.requiresAccessibility == false)

        // Disabled hold + unassigned hands-free → does not require Accessibility.
        var disabledConfig = DualShortcutConfiguration.default()
        disabledConfig.holdEnabled = false
        let disabledDispatch = ShortcutDispatch(coordinator: coordinator, configuration: disabledConfig)
        #expect(disabledDispatch.requiresAccessibility == false)
    }
}
