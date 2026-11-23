//
//  ShortcutDispatch.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import os

/// Calibration state for the test-shortcut row. Set ONLY by observed real
/// global events — never by the recorder (12 limit).
enum ShortcutCalibration: Equatable, Sendable {
    case untested
    case ready
    case notReceivedGlobally
    case conflicts
    case requiresAccessibility
    /// No shortcut assigned (opt-in slot). Deliberate-empty needs no
    /// attention: ranked with ready so the combined value follows live slots.
    case notSet
}

/// Outcome of a per-slot trigger save. `.blocked` keeps the old trigger
/// (the UI shows "Same as your <other> shortcut — pick a different one").
enum TriggerUpdateResult: Equatable, Sendable {
    case applied
    case unchanged
    case blocked
}

/// MainActor owner of the shortcut layer. Holds the monitors, the dual
/// config, and one transition machine per slot; translates transitions into
/// serialized FIFO intents to the coordinator. Backends emit values; this
/// decides nothing about sessions beyond routing intents.
///
/// Two slots live at once with fixed modes (hold = hold-to-talk,
/// hands-free = hands-free toggle). The coordinator's single-session guard
/// arbitrates simultaneous presses: the first begin wins, the second is a
/// proven no-op.
@MainActor
final class ShortcutDispatch {
    private let coordinator: DictationCoordinator
    /// Press cue (feedback sounds). Nil in tests and when unwired — the
    /// transition machines stay pure, and a dispatch without a player is a
    /// silent one, never a slower one.
    private let sounds: (any FeedbackSounding)?
    /// Live macOS `AppleFnUsageType` reader (injectable in tests so fn-mode
    /// behavior is tested deterministically independent of host settings).
    private let systemFnUsageProvider: () -> SystemFnUsage
    private let log = Logger(subsystem: "app.Oto", category: "shortcut")

    private let holdComboMonitor = ModifierHotkeyMonitor()
    private let handsFreeComboMonitor = ModifierHotkeyMonitor()
    private let hidMonitor = HIDEventMonitor()

    private var holdTransition = HotkeyTransitionState()
    private var handsFreeTransition = HotkeyTransitionState()
    /// Double-tap-to-hands-free tracker for the hold slot (any kind).
    /// Timing only — routing decisions stay in the transition machines
    /// and the coordinator guards.
    private var holdTap = DoubleTapTracker()
    /// Pending/confirmed bare-fn press when macOS owns fn taps.
    /// Timing rules live in the pure core; the Task below is a thin timer.
    private var fnHold = FnHoldConfirm()
    private var fnConfirmTask: Task<Void, Never>?

    /// True when the hold slot is bare fn (derived from model policy).
    private var isFnHold: Bool {
        trigger(for: .hold).kind.isSystemTapSensitive
    }

    /// Bare fn now runs through the exact same instant hold-to-talk + double-tap
    /// path as every other modifier hold key (matching Hex: 0 ms start, no
    /// 200 ms confirmation lag, instant close on release). Retained as a hook
    /// so `FnHoldConfirm` remains unit-tested and opt-in if ever needed.
    private var isFnTapProtected: Bool {
        false
    }

    /// Single serialized FIFO task chain for all coordinator-bound intents
    /// (`begin`, `finish`, `cancel`, `escape`, `doubleTap`, `toggle`,
    /// `cancelActiveSession`). Every intent awaits the prior intent before
    /// reading `activeSessionID` or talking to the coordinator — eliminating
    /// spin-loops and begin/finish/Escape races.
    private var pendingAction: Task<Void, Never>?

    /// Latest session ID returned by the coordinator. Never cleared
    /// eagerly: cancel/finish are idempotent, so a stale ID is a harmless
    /// no-op — but clearing it would strand an Escape-during-starting
    /// cancel. Overwritten by each new begin.
    private var activeSessionID: UUID?
    private(set) var configuration: DualShortcutConfiguration {
        didSet { configuration.save() }
    }

    /// Last real global down/up observed per slot (for calibration).
    private var observedDownHold = false
    private var observedUpAfterDownHold = false
    private var observedDownHandsFree = false
    private var observedUpAfterDownHandsFree = false
    private(set) var calibrationHold: ShortcutCalibration = .untested
    private(set) var calibrationHandsFree: ShortcutCalibration = .untested

    /// Derived single-value calibration (worst-of) for callers that need one
    /// value. Menu-compat: preserved as a derived value, never stored.
    var calibration: ShortcutCalibration {
        Self.worst(of: calibrationHold, and: calibrationHandsFree)
    }

    /// True when either enabled slot uses `.modifierHold` or `.functionKey`
    /// and therefore needs Accessibility trust for the HID event tap.
    var requiresAccessibility: Bool {
        ShortcutSlot.allCases.contains { slotEnabled($0) && slotRequiresAccessibility($0) }
    }

    /// While true, global registration is suspended (recorder listening).
    private(set) var isSuspended = false

    init(
        coordinator: DictationCoordinator,
        configuration: DualShortcutConfiguration = .load(),
        sounds: (any FeedbackSounding)? = nil,
        systemFnUsageProvider: @escaping () -> SystemFnUsage = { SystemFnUsage.read() }
    ) {
        self.coordinator = coordinator
        self.configuration = configuration
        self.sounds = sounds
        self.systemFnUsageProvider = systemFnUsageProvider

        holdComboMonitor.onEvent = { [weak self] in self?.receive($0, from: .hold) }
        handsFreeComboMonitor.onEvent = { [weak self] in self?.receive($0, from: .handsFree) }
        hidMonitor.onSlotEvent = { [weak self] in self?.receive($0, from: $1) }
        hidMonitor.onEscape = { [weak self] in self?.receiveEscape() }
    }

    // MARK: - Lifecycle

    /// Per-slot liveness: a cleared slot is off for that slot only —
    /// clearing hands-free must never kill push-to-talk (the old global
    /// boolean did exactly that).
    func slotEnabled(_ slot: ShortcutSlot) -> Bool {
        slot == .hold ? configuration.holdEnabled : configuration.handsFreeEnabled
    }

    /// (Re)register backends for the current configuration. Unregisters
    /// first: re-registering can never leave a stale callback behind
    /// (10_NEXT_STEP §1 acceptance).
    func start() {
        stop()
        guard configuration.holdEnabled || configuration.handsFreeEnabled, !isSuspended else {
            updateCalibrationForAvailability()
            return
        }
        var holdSlots: [UInt16: ShortcutSlot] = [:]
        var functionSlots: [Int64: ShortcutSlot] = [:]
        if slotEnabled(.hold) {
            configureSlot(trigger: configuration.hold, slot: .hold, holdSlots: &holdSlots, functionSlots: &functionSlots)
        }
        if slotEnabled(.handsFree) {
            configureSlot(
                trigger: configuration.handsFree, slot: .handsFree,
                holdSlots: &holdSlots, functionSlots: &functionSlots
            )
        }
        // One shared HID tap for both slots + one shared Escape observation.
        hidMonitor.configure(holdSlots: holdSlots, functionSlots: functionSlots, escapeObserved: true)
        // HID-kind slots need a live tap; combo slots already reported above.
        for slot in ShortcutSlot.allCases where slotEnabled(slot) && slotUsesHIDTap(slot) && !hidMonitor.isLive {
            setCalibration(.requiresAccessibility, for: slot)
            log.error("HID tap unavailable (accessibility?)")
        }
        // Escape observation rides the HID tap (zero NSEvent monitors in
        // the trigger path); combo triggers need no Escape backend change.
        holdTransition = HotkeyTransitionState()
        handsFreeTransition = HotkeyTransitionState()
        updateCalibrationForAvailability()
        log.info("shortcut dispatch started")
    }

    /// Register one slot's Carbon combo (if any) and collect its HID codes.
    /// A failed Carbon registration surfaces per slot (the other slot keeps
    /// working — no shared failure mode).
    private func configureSlot(
        trigger: ShortcutTrigger,
        slot: ShortcutSlot,
        holdSlots: inout [UInt16: ShortcutSlot],
        functionSlots: inout [Int64: ShortcutSlot]
    ) {
        switch trigger.kind {
        case .unassigned:
            // Opt-in slot with nothing assigned: registers nothing, fires
            // nothing. Double-tap of the hold key needs no trigger.
            break
        case .modifierHold(let keyCode):
            // HID tap path (NSEvent monitors are banned: proven to wedge
            // MenuBarExtra tracking). Requires Accessibility trust.
            holdSlots[keyCode] = slot
        case .combo(let modifiers, let keyCode):
            comboMonitor(for: slot).configure(comboModifiers: modifiers, keyCode: keyCode)
            if !comboMonitor(for: slot).isLive {
                setCalibration(.conflicts, for: slot)
                log.error("combo registration failed (conflict)")
            }
        case .functionKey(let codes):
            for code in codes { functionSlots[code] = slot }
        }
    }

    func stop() {
        holdComboMonitor.stop()
        handsFreeComboMonitor.stop()
        hidMonitor.stop()
        holdTransition = HotkeyTransitionState()
        handsFreeTransition = HotkeyTransitionState()
        holdTap.reset()
        isHandsFreeSessionActive = false
        fnHandsFreeStoppedAt = nil
        dropFnPending()
    }

    /// Suspend global registration while the recorder listens, resume after.
    /// A release during suspension belongs to the recorder, never to us —
    /// so an in-flight session is cancelled first rather than stranded
    /// recording with its release path torn down.
    func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else { return }
        isSuspended = suspended
        holdTransition = HotkeyTransitionState()
        handsFreeTransition = HotkeyTransitionState()
        if suspended {
            cancelActiveSession()
            stop()
        } else {
            start()
        }
    }

    /// Re-check Accessibility-derived availability without tearing down a
    /// healthy live tap. Only restarts backends when a required combo monitor
    /// or the HID tap is actually dead (`verifyLive() == false`).
    func refreshAvailability() {
        guard !isSuspended else { return }
        let trusted = isAccessibilityTrusted()
        if !trusted {
            let holdGated = slotEnabled(.hold) && slotRequiresAccessibility(.hold)
            let freeGated = slotEnabled(.handsFree) && slotRequiresAccessibility(.handsFree)
            if holdGated { setCalibration(.requiresAccessibility, for: .hold) }
            if freeGated { setCalibration(.requiresAccessibility, for: .handsFree) }
            if holdGated && freeGated { return }
        }
        guard !holdTransition.isDown, !handsFreeTransition.isDown, !fnHold.isDown else { return }

        guard configuration.holdEnabled || configuration.handsFreeEnabled else {
            updateCalibrationForAvailability()
            return
        }

        let hidHealthy = !HIDEventMonitor.liveTapsEnabled || hidMonitor.verifyLive()
        let comboHealthy = ShortcutSlot.allCases.allSatisfy { slot in
            guard slotEnabled(slot) else { return true }
            if case .combo = trigger(for: slot).kind {
                return comboMonitor(for: slot).isLive
            }
            return true
        }
        let needsHidHeal = !hidHealthy && trusted
        if !needsHidHeal && comboHealthy {
            updateCalibrationForAvailability()
            return
        }
        // Heal a timed-out tap or failed combo registration.
        start()
    }

    // MARK: - Configuration changes

    func updateHoldTrigger(_ trigger: ShortcutTrigger) -> TriggerUpdateResult {
        updateSlot(trigger, slot: .hold)
    }

    func updateHandsFreeTrigger(_ trigger: ShortcutTrigger) -> TriggerUpdateResult {
        updateSlot(trigger, slot: .handsFree)
    }

    /// Per-slot save gate: same-slot equality is a no-op, bare `fn` into
    /// hands-free is refused when macOS owns `fn` taps, a trigger that
    /// conflicts with the OTHER slot is refused without saving, otherwise
    /// cancel the active session, save, reset that slot's calibration, and
    /// re-register. Any successful save re-enables its own slot.
    private func updateSlot(_ trigger: ShortcutTrigger, slot: ShortcutSlot) -> TriggerUpdateResult {
        let fixed = trigger.withInteraction(slot == .hold ? .holdToTalk : .handsFree)
        let current = slot == .hold ? configuration.hold : configuration.handsFree
        let other = slot == .hold ? configuration.handsFree : configuration.hold
        guard fixed != current else { return .unchanged }
        if slot == .handsFree,
           !fixed.kind.supportsHandsFreeToggle,
           systemFnUsageProvider() != .none
        {
            log.info("save blocked for hands-free: \(String(describing: fixed.kind), privacy: .public) requires hold-only while macOS owns fn taps")
            return .blocked
        }
        guard !fixed.kind.conflictsWith(other.kind) else {
            log.info("save blocked for \(slot == .hold ? "hold" : "hands-free", privacy: .public): \(String(describing: fixed.kind), privacy: .public) vs other \(String(describing: other.kind), privacy: .public)")
            return .blocked
        }
        cancelActiveSession()
        if slot == .hold {
            configuration.hold = fixed
            configuration.holdEnabled = true
        } else {
            configuration.handsFree = fixed
            configuration.handsFreeEnabled = true
        }
        resetCalibration(for: slot)
        start()
        return .applied
    }

    /// Per-slot enable (replaces the retired global `setEnabled`): turning
    /// a slot off cancels the active session first (a live hold must not
    /// outlive its slot), then updates, recalibrates, and re-registers.
    func setSlotEnabled(_ enabled: Bool, for slot: ShortcutSlot) {
        if !enabled {
            cancelActiveSession()
        }
        if slot == .hold {
            configuration.holdEnabled = enabled
        } else {
            configuration.handsFreeEnabled = enabled
        }
        resetCalibration()
        start()
    }

    /// The recorder's Remove (and ⌫): the slot goes back to deliberately
    /// empty rather than merely switched off.
    func clearSlot(_ slot: ShortcutSlot) {
        cancelActiveSession()
        if slot == .hold {
            configuration.hold = .unassignedHoldToTalk()
            configuration.holdEnabled = false
        } else {
            configuration.handsFree = .unassignedHandsFree()
            configuration.handsFreeEnabled = false
        }
        resetCalibration(for: slot)
        start()
    }

    /// Atomic exchange of the two slots' triggers (the modal's Swap).
    /// Refuses moving bare `fn` into hands-free when macOS owns `fn` taps
    /// (`SystemFnUsage != .none`). Enable flags stay with their slots.
    func swapHoldAndHandsFree() {
        if !configuration.hold.kind.supportsHandsFreeToggle,
           systemFnUsageProvider() != .none
        {
            log.info("swap blocked: cannot place bare fn in hands-free while macOS owns fn taps")
            return
        }
        cancelActiveSession()
        let oldHold = configuration.hold
        configuration.hold = configuration.handsFree.withInteraction(.holdToTalk)
        configuration.handsFree = oldHold.withInteraction(.handsFree)
        resetCalibration()
        start()
        log.info("shortcuts swapped between slots")
    }

    /// Reset both slots to factory triggers with both slots on.
    func resetToDefaults() {
        cancelActiveSession()
        configuration = DualShortcutConfiguration.default()
        resetCalibration()
        start()
        log.info("shortcuts reset to defaults")
    }

    // MARK: - Calibration

    /// Mark a full observed press-release cycle for a slot. Called only from
    /// `receive` on real backend events.
    private func noteObserved(down: Bool, slot: ShortcutSlot) {
        if slot == .hold {
            if down {
                observedDownHold = true
            } else if observedDownHold {
                observedUpAfterDownHold = true
                calibrationHold = .ready
            }
        } else {
            if down {
                observedDownHandsFree = true
            } else if observedDownHandsFree {
                observedUpAfterDownHandsFree = true
                calibrationHandsFree = .ready
            }
        }
    }

    func resetCalibration() {
        resetCalibration(for: .hold)
        resetCalibration(for: .handsFree)
    }

    func resetCalibration(for slot: ShortcutSlot) {
        if case .unassigned = trigger(for: slot).kind {
            setCalibration(.notSet, for: slot)
            return
        }
        if slot == .hold {
            observedDownHold = false
            observedUpAfterDownHold = false
            calibrationHold = .untested
        } else {
            observedDownHandsFree = false
            observedUpAfterDownHandsFree = false
            calibrationHandsFree = .untested
        }
        updateCalibrationForAvailability()
    }

    private func calibration(for slot: ShortcutSlot) -> ShortcutCalibration {
        slot == .hold ? calibrationHold : calibrationHandsFree
    }

    private func setCalibration(_ value: ShortcutCalibration, for slot: ShortcutSlot) {
        if slot == .hold {
            calibrationHold = value
        } else {
            calibrationHandsFree = value
        }
    }

    private func comboMonitor(for slot: ShortcutSlot) -> ModifierHotkeyMonitor {
        slot == .hold ? holdComboMonitor : handsFreeComboMonitor
    }

    private func trigger(for slot: ShortcutSlot) -> ShortcutTrigger {
        slot == .hold ? configuration.hold : configuration.handsFree
    }

    private func slotRequiresAccessibility(_ slot: ShortcutSlot) -> Bool {
        // Carbon combos ride the window-server hotkey path (no AX needed);
        // anything on the HID tap needs trust. Unassigned needs nothing.
        switch trigger(for: slot).kind {
        case .combo, .unassigned:
            return false
        case .modifierHold, .functionKey:
            return true
        }
    }

    private func slotUsesHIDTap(_ slot: ShortcutSlot) -> Bool {
        slotRequiresAccessibility(slot)
    }

    private func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    private func updateCalibrationForAvailability() {
        guard !isSuspended else { return }
        for slot in ShortcutSlot.allCases {
            if !slotEnabled(slot) {
                setCalibration(.notSet, for: slot)
                continue
            }
            if case .unassigned = trigger(for: slot).kind {
                setCalibration(.notSet, for: slot)
            } else if slotRequiresAccessibility(slot), !isAccessibilityTrusted() {
                setCalibration(.requiresAccessibility, for: slot)
            } else if calibration(for: slot) == .untested, !slotBackendsLive(slot) {
                setCalibration(.notReceivedGlobally, for: slot)
            }
        }
    }

    private func slotBackendsLive(_ slot: ShortcutSlot) -> Bool {
        switch trigger(for: slot).kind {
        case .unassigned:
            return true
        case .combo:
            return comboMonitor(for: slot).isLive
        case .modifierHold, .functionKey:
            return hidMonitor.isLive
        }
    }

    private nonisolated static func worst(of a: ShortcutCalibration, and b: ShortcutCalibration) -> ShortcutCalibration {
        rank(a) >= rank(b) ? a : b
    }

    private nonisolated static func rank(_ calibration: ShortcutCalibration) -> Int {
        switch calibration {
        case .requiresAccessibility: return 4
        case .conflicts: return 3
        case .notReceivedGlobally: return 2
        case .untested: return 1
        case .notSet, .ready: return 0
        }
    }

    // MARK: - Event routing (serialized FIFO task chain)

    private func enqueueCoordinatorAction(_ work: @escaping @MainActor (ShortcutDispatch) async -> Void) {
        let prior = pendingAction
        pendingAction = Task { @MainActor [weak self] in
            _ = await prior?.value
            guard let self else { return }
            await work(self)
        }
    }

    /// Any reconfiguration orphans the in-flight release path, so the
    /// active session (if any) is cancelled deterministically instead of
    /// stranding it recording. Cancel is discard-only.
    private func cancelActiveSession() {
        enqueueCoordinatorAction { dispatch in
            guard let id = dispatch.activeSessionID else { return }
            await dispatch.coordinator.cancel(id)
        }
    }

    /// One Task per user gesture at most (begin/finish/toggle/cancel only —
    /// repeats and ignores never hop).
    private func receive(_ event: ShortcutEvent, from slot: ShortcutSlot) {
        receive(event, from: slot, at: ContinuousClock().now)
    }

    /// Cooldown timestamp after stopping a hands-free session with bare `fn`,
    /// absorbing any duplicate `.flagsChanged` echo macOS HIToolbox/Globe emits
    /// on a quick `fn` tap so a single click to stop hands-free never
    /// cancels finalization or re-triggers `DoubleTapTracker`.
    private var fnHandsFreeStoppedAt: ContinuousClock.Instant?
    nonisolated static let fnHandsFreeStopCooldown: Duration = .milliseconds(400)

    /// Time-injected core: production passes `.now`, tests script instants.
    private func receive(_ event: ShortcutEvent, from slot: ShortcutSlot, at now: ContinuousClock.Instant) {
        // Bare fn only needs tap-protection when macOS owns quick fn taps
        // (`AppleFnUsageType != 0`). When set to "Do Nothing" (`.none`), fn
        // runs through the instant hold path with full double-tap support.
        if slot == .hold, isFnTapProtected {
            receiveFnHold(event, at: now)
            return
        }
        if slot == .hold, isFnHold {
            // While within the post-stop cooldown after clicking `fn` to close
            // hands-free mode, swallow any trailing `.keyUp` or macOS Globe
            // echo `.flagsChanged` pulse so it can never re-arm `holdTap` or
            // restart hands-free.
            if let stoppedAt = fnHandsFreeStoppedAt,
               stoppedAt.duration(to: now) < Self.fnHandsFreeStopCooldown
            {
                holdTap.reset()
                holdTransition.isDown = false
                return
            }
            // When a hands-free session is currently active, a single click of
            // `fn` stops and finalizes it immediately on `.keyDown` (no hold
            // required) and arms the cooldown against macOS Globe echoes.
            if case .keyDown(isRepeat: false) = event, isHandsFreeSessionActive {
                noteObserved(down: true, slot: .hold)
                noteObserved(down: false, slot: .hold)
                fnHandsFreeStoppedAt = now
                holdTap.reset()
                holdTransition.isDown = false
                stopActiveHandsFreeSessionOnClick()
                return
            }
        }
        if case .keyDown = event {
            noteObserved(down: true, slot: slot)
        } else if case .keyUp = event {
            noteObserved(down: false, slot: slot)
        }
        if case .combinationBegan = event, slot == .hold {
            // A press that became a shortcut can never pair with the next
            // tap: the release is swallowed, so the tracker must forget it.
            holdTap.reset()
        }
        let mode: InteractionMode = slot == .hold ? .holdToTalk : .handsFree
        let action: ShortcutTransition
        if slot == .hold {
            action = holdTransition.step(.event(event), mode: mode)
            if case .keyDown(isRepeat: false) = event {
                holdTap.down(at: now)
            } else if case .keyUp = event {
                if holdTap.up(at: now) {
                    convertDoubleTapToHandsFree()
                    return
                }
            }
        } else {
            action = handsFreeTransition.step(.event(event), mode: mode)
        }
        route(action, mode: mode)
    }

    /// Tap-protected bare-fn hold path (active when `SystemFnUsage != .none`).
    /// Quick taps under `FnHoldConfirm.threshold` drop silently so macOS
    /// handles them untouched; sustained holds confirm and route normally;
    /// combination use (`fn+Arrow`, `fn+click`) drops pre-confirm or cancels
    /// post-confirm cleanly without stranding `fnHold.isDown`.
    private func receiveFnHold(_ event: ShortcutEvent, at now: ContinuousClock.Instant) {
        switch event {
        case .keyDown(let isRepeat):
            guard !isRepeat, fnHold.down(at: now) else { return }
            fnConfirmTask?.cancel()
            fnConfirmTask = Task { [weak self] in
                try? await Task.sleep(for: FnHoldConfirm.threshold)
                guard let self else { return }
                guard self.fnHold.shouldConfirm(at: ContinuousClock().now),
                      self.isFnTapProtected,
                      self.slotEnabled(.hold), !self.isSuspended
                else { return }
                if self.hidMonitor.isInCombination(code: UInt16(kVK_Function)) {
                    self.fnHold.reset()
                    self.log.debug("fn hold dropped (combination use)")
                    return
                }
                self.fnHold.markConfirmed()
                self.log.info("fn hold confirmed; routing begin")
                self.noteObserved(down: true, slot: .hold)
                self.route(.begin, mode: .holdToTalk)
            }
        case .keyUp:
            fnConfirmTask?.cancel()
            fnConfirmTask = nil
            switch fnHold.up() {
            case .ignored:
                break
            case .droppedTap:
                self.log.debug("fn tap dropped (sub-threshold)")
            case .finishedHold:
                noteObserved(down: false, slot: .hold)
                route(.finish, mode: .holdToTalk)
            }
        case .monitorLost:
            dropFnPending()
        case .combinationBegan:
            let wasConfirmed = fnHold.isConfirmed
            dropFnPending()
            if wasConfirmed {
                cancelActiveSession()
            }
        }
    }

    private func dropFnPending() {
        fnConfirmTask?.cancel()
        fnConfirmTask = nil
        fnHold.reset()
    }

    /// True while a hands-free session is currently active (`starting` or
    /// `recording`), tracked synchronously as intents are dispatched so a
    /// single click of the hold key (`fn` or Right Option) immediately stops
    /// hands-free on `.keyDown` instead of requiring a hold+release.
    private var isHandsFreeSessionActive = false

    /// Stops an active hands-free session immediately when the user clicks
    /// the hold key once. If the previous hands-free session had already
    /// ended on its own (e.g. error/timeout), falls back to starting hold.
    private func stopActiveHandsFreeSessionOnClick() {
        isHandsFreeSessionActive = false
        enqueueCoordinatorAction { dispatch in
            let state = await dispatch.coordinator.state
            switch state {
            case .starting(let ctx) where ctx.interaction == .handsFree,
                 .recording(let ctx) where ctx.interaction == .handsFree:
                Task { await dispatch.coordinator.toggleHandsFree() }
            default:
                if state.isTerminal {
                    dispatch.fnHandsFreeStoppedAt = nil
                    dispatch.holdTransition.isDown = true
                    dispatch.sounds?.play(.listening)
                    if let id = await dispatch.coordinator.beginHold() {
                        dispatch.activeSessionID = id
                    }
                } else if let id = dispatch.activeSessionID {
                    Task { await dispatch.coordinator.finish(id) }
                }
            }
        }
    }

    /// Double-tap confirmed on the hold slot: serialized strictly behind any
    /// in-flight `begin` via `pendingAction`, cancels the tap's micro-session
    /// and starts a fresh hands-free session without racing `route(.finish)`.
    private func convertDoubleTapToHandsFree() {
        isHandsFreeSessionActive = true
        enqueueCoordinatorAction { dispatch in
            if let current = dispatch.activeSessionID {
                await dispatch.coordinator.cancel(current)
            }
            if let newID = await dispatch.coordinator.toggleHandsFree() {
                dispatch.activeSessionID = newID
                dispatch.isHandsFreeSessionActive = true
            } else {
                dispatch.isHandsFreeSessionActive = false
            }
        }
    }

    private func receiveEscape() {
        _ = holdTransition.step(.escape, mode: .holdToTalk)
        _ = handsFreeTransition.step(.escape, mode: .handsFree)
        holdTap.reset()
        isHandsFreeSessionActive = false
        dropFnPending()
        cancelActiveSession()
    }

    /// Escape-cancel availability: Escape rides the one shared HID tap, which
    /// needs Accessibility trust.
    var isEscapeCancelAvailable: Bool {
        hidMonitor.isLive
    }

    /// Test hooks: drive Escape→cancel without hardware. Seeding mirrors
    /// what route(.begin) stores on a real key-down.
    func seedActiveSessionForTests(_ id: UUID) { activeSessionID = id }

    /// Test hook: drive a backend event for a slot without hardware.
    func receiveForTests(_ event: ShortcutEvent, from slot: ShortcutSlot) { receive(event, from: slot) }
    func receiveEscapeForTests() { receiveEscape() }
    /// Test hook: deterministic time-injected variant (double-tap / fn tests).
    func receiveForTests(_ event: ShortcutEvent, from slot: ShortcutSlot, at now: ContinuousClock.Instant) {
        receive(event, from: slot, at: now)
    }

    private func route(_ action: ShortcutTransition, mode: InteractionMode) {
        switch action {
        case .ignore, .reset:
            break
        case .cancel:
            isHandsFreeSessionActive = false
            cancelActiveSession()
        case .begin:
            // Press cue synchronously on hold begin so it never sits behind
            // the async hop.
            sounds?.play(.listening)
            enqueueCoordinatorAction { dispatch in
                if mode == .handsFree {
                    if let id = await dispatch.coordinator.toggleHandsFree() {
                        dispatch.activeSessionID = id
                        dispatch.isHandsFreeSessionActive = true
                    }
                } else {
                    if let id = await dispatch.coordinator.beginHold() {
                        dispatch.activeSessionID = id
                        dispatch.isHandsFreeSessionActive = false
                    }
                }
            }
        case .toggle:
            enqueueCoordinatorAction { dispatch in
                let state = await dispatch.coordinator.state
                if case .starting(let ctx) = state, ctx.interaction == .handsFree {
                    // Stopping hands-free runs finalizeSession asynchronously so
                    // Escape can still interrupt mid-finalize without deadlocking.
                    dispatch.isHandsFreeSessionActive = false
                    Task { await dispatch.coordinator.toggleHandsFree() }
                    return
                }
                if case .recording(let ctx) = state, ctx.interaction == .handsFree {
                    dispatch.isHandsFreeSessionActive = false
                    Task { await dispatch.coordinator.toggleHandsFree() }
                    return
                }
                // Starting a new hands-free session (or harmless no-op when a
                // hold-to-talk session is already active).
                if let id = await dispatch.coordinator.toggleHandsFree() {
                    dispatch.activeSessionID = id
                    dispatch.isHandsFreeSessionActive = true
                    dispatch.sounds?.play(.listening)
                }
            }
        case .finish:
            enqueueCoordinatorAction { dispatch in
                guard let id = dispatch.activeSessionID else { return }
                dispatch.isHandsFreeSessionActive = false
                // Finalization awaits speech+polish+insertion; spawn so a
                // subsequent Escape or double-tap cancel can interrupt it
                // immediately while still guaranteeing `activeSessionID` was
                // read strictly after the preceding `begin`.
                Task { await dispatch.coordinator.finish(id) }
            }
        }
    }
}
