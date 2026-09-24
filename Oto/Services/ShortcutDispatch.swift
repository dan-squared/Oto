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
/// the ONE async hop to the coordinator. Backends emit values; this decides
/// nothing about sessions beyond routing intents.
///
/// Two slots live at once with fixed modes (hold = hold-to-talk,
/// hands-free = hands-free toggle). The coordinator's single-session guard
/// arbitrates simultaneous presses: the first begin wins, the second is a
/// proven no-op.
@MainActor
final class ShortcutDispatch {
    private let coordinator: DictationCoordinator
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
    /// fn-hold confirmation threshold: fn taps at/under this belong to
    /// macOS (emoji, dictation, remap, or nothing — varies by device and
    /// is unobservable), holds past it are Oto's. Matches the tap constant
    /// so the story is single: one number separates system taps from Oto.
    nonisolated static let fnHoldConfirmNanoseconds: UInt64 = 250_000_000
    /// Pending/confirmed bare-fn press. The shared machine stays pristine
    /// for fn (it never steps it); this pair is the whole fn state.
    private var fnPendingDown: ContinuousClock.Instant?
    private var fnConfirmed = false
    private var fnConfirmTask: Task<Void, Never>?

    /// True when the hold slot is a bare fn key — the only trigger with
    /// system tap behavior. All other holds stay instant.
    private var isFnHold: Bool {
        trigger(for: .hold).kind == .modifierHold(keyCode: UInt16(kVK_Function))
    }
    /// Begin-generation counter: every routed begin bumps it synchronously;
    /// the routing Task settles it after storing the id (or nil-ing).
    /// Conversion spins on it so cancel+toggle can never run ahead of a
    /// routed begin and nil on a session whose id hasn't landed yet.
    /// (Without this, down2's begin lands between convert's cancel of the
    /// stale id and its toggle — the toggle then nils on the live micro.)
    private var beginGeneration = 0
    private var beginSettledThrough = 0
    /// Latest session ID returned by the coordinator. Never cleared
    /// eagerly: cancel/finish are idempotent, so a stale ID is a harmless
    /// no-op — but clearing it would strand an Escape-during-starting
    /// cancel. Overwritten by each new begin.
    private var activeSessionID: UUID?
    private(set) var configuration: DualShortcutConfiguration {
        didSet { configuration.save() }
    }

    /// Last real global down/up observed per slot (for calibration). Nil
    /// until a full press-release cycle arrives through a live backend.
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

    /// While true, global registration is suspended (recorder listening).
    private(set) var isSuspended = false

    init(coordinator: DictationCoordinator, configuration: DualShortcutConfiguration = .load()) {
        self.coordinator = coordinator
        self.configuration = configuration

        holdComboMonitor.onEvent = { [weak self] in self?.receive($0, from: .hold) }
        handsFreeComboMonitor.onEvent = { [weak self] in self?.receive($0, from: .handsFree) }
        hidMonitor.onSlotEvent = { [weak self] in self?.receive($0, from: $1) }
        hidMonitor.onEscape = { [weak self] in self?.receiveEscape() }
    }

    // MARK: - Lifecycle

    /// (Re)register backends for the current configuration. Unregisters
    /// first: re-registering can never leave a stale callback behind
    /// (10_NEXT_STEP §1 acceptance).
    func start() {
        stop()
        guard configuration.enabled, !isSuspended else {
            updateCalibrationForAvailability()
            return
        }
        var holdSlots: [UInt16: ShortcutSlot] = [:]
        var functionSlots: [Int64: ShortcutSlot] = [:]
        configureSlot(trigger: configuration.hold, slot: .hold, holdSlots: &holdSlots, functionSlots: &functionSlots)
        configureSlot(
            trigger: configuration.handsFree, slot: .handsFree,
            holdSlots: &holdSlots, functionSlots: &functionSlots
        )
        // One shared HID tap for both slots + one shared Escape observation.
        hidMonitor.configure(holdSlots: holdSlots, functionSlots: functionSlots, escapeObserved: true)
        // HID-kind slots need a live tap; combo slots already reported above.
        for slot in ShortcutSlot.allCases where slotUsesHIDTap(slot) && !hidMonitor.isLive {
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

    /// Re-check Accessibility-derived availability. Called on every menu
    /// open (the one hook guaranteed to run while the user is present —
    /// audit F2 wired the previously zero-caller path here). Revocation
    /// surfaces as unavailable; recovery re-registers. Never rebuilds
    /// while either trigger is physically down — tearing down mid-hold would
    /// strand the release.
    func refreshAvailability() {
        if !isAccessibilityTrusted() {
            let holdGated = slotRequiresAccessibility(.hold)
            let freeGated = slotRequiresAccessibility(.handsFree)
            if holdGated { setCalibration(.requiresAccessibility, for: .hold) }
            if freeGated { setCalibration(.requiresAccessibility, for: .handsFree) }
            // A lone combo slot can still heal without trust; when both
            // slots are AX-gated there is nothing to heal.
            if holdGated && freeGated { return }
        }
        guard !holdTransition.isDown, !handsFreeTransition.isDown, fnPendingDown == nil else { return }
        // Re-register to heal a timed-out tap or revoked backend.
        start()
    }

    // MARK: - Configuration changes

    func updateHoldTrigger(_ trigger: ShortcutTrigger) -> TriggerUpdateResult {
        updateSlot(trigger, slot: .hold)
    }

    func updateHandsFreeTrigger(_ trigger: ShortcutTrigger) -> TriggerUpdateResult {
        updateSlot(trigger, slot: .handsFree)
    }

    /// Per-slot save gate: same-slot equality is a no-op, a trigger that
    /// conflicts with the OTHER slot is refused without saving (preset picks
    /// route through here too — no bypass), otherwise cancel the active
    /// session, save, reset that slot's calibration, and re-register.
    /// Any successful save re-enables globally (F1: today's Delete is a
    /// one-way door — `updateTrigger` never re-enabled — so a fresh explicit
    /// assignment is intent to have shortcuts on).
    private func updateSlot(_ trigger: ShortcutTrigger, slot: ShortcutSlot) -> TriggerUpdateResult {
        let fixed = trigger.withInteraction(slot == .hold ? .holdToTalk : .handsFree)
        let current = slot == .hold ? configuration.hold : configuration.handsFree
        let other = slot == .hold ? configuration.handsFree : configuration.hold
        guard fixed != current else { return .unchanged }
        guard !fixed.kind.conflictsWith(other.kind) else {
            // Silent refusals are undebuggable: name both kinds so device
            // trails show what the person attempted (key metadata only —
            // kinds never carry transcript text).
            log.info("save blocked for \(slot == .hold ? "hold" : "hands-free", privacy: .public): \(String(describing: fixed.kind), privacy: .public) vs other \(String(describing: other.kind), privacy: .public)")
            return .blocked
        }
        cancelActiveSession()
        if slot == .hold {
            configuration.hold = fixed
        } else {
            configuration.handsFree = fixed
        }
        configuration.enabled = true
        resetCalibration(for: slot)
        start()
        return .applied
    }

    func setEnabled(_ enabled: Bool) {
        if !enabled {
            cancelActiveSession()
        }
        configuration.enabled = enabled
        resetCalibration()
        start()
    }

    /// Atomic exchange of the two slots' triggers (the modal's Swap).
    /// Always safe without gating: the kind *pair* is unchanged, only the
    /// assignment flips, so no new conflict can exist by construction.
    /// Stored interactions are re-enforced (belt-and-braces over the
    /// migration-time enforcement).
    func swapHoldAndHandsFree() {
        cancelActiveSession()
        let oldHold = configuration.hold
        configuration.hold = configuration.handsFree.withInteraction(.holdToTalk)
        configuration.handsFree = oldHold.withInteraction(.handsFree)
        configuration.enabled = true
        resetCalibration()
        start()
        log.info("shortcuts swapped between slots")
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
        // anything on the HID tap needs trust.
        if case .combo = trigger(for: slot).kind { return false }
        return true
    }

    private func slotUsesHIDTap(_ slot: ShortcutSlot) -> Bool {
        slotRequiresAccessibility(slot)
    }

    private func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    private func updateCalibrationForAvailability() {
        guard configuration.enabled, !isSuspended else { return }
        for slot in ShortcutSlot.allCases {
            if slotRequiresAccessibility(slot), !isAccessibilityTrusted() {
                setCalibration(.requiresAccessibility, for: slot)
            } else if calibration(for: slot) == .untested, !slotBackendsLive(slot) {
                setCalibration(.notReceivedGlobally, for: slot)
            }
        }
    }

    private func slotBackendsLive(_ slot: ShortcutSlot) -> Bool {
        switch trigger(for: slot).kind {
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
        case .ready: return 0
        }
    }

    // MARK: - Event routing (the single async hop)

    /// Any reconfiguration orphans the in-flight release path, so the
    /// active session (if any) is cancelled deterministically instead of
    /// stranding it recording. Cancel is discard-only.
    private func cancelActiveSession() {
        guard let id = activeSessionID else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.coordinator.cancel(id)
        }
    }

    /// One Task per user gesture at most (begin/finish only — repeats and
    /// ignores never hop). The 12 "no per-event task" limit constrains
    /// event streams, not gesture intents.
    private func receive(_ event: ShortcutEvent, from slot: ShortcutSlot) {
        receive(event, from: slot, at: ContinuousClock().now)
    }

    /// Time-injected core: production passes `.now`, tests script instants.
    private func receive(_ event: ShortcutEvent, from slot: ShortcutSlot, at now: ContinuousClock.Instant) {
        // Bare fn bypasses the shared machine (which begins instantly):
        // its taps belong to macOS, only sustained holds are Oto's.
        if slot == .hold, isFnHold {
            receiveFnHold(event, at: now)
            return
        }
        if case .keyDown = event {
            noteObserved(down: true, slot: slot)
        } else if case .keyUp = event {
            noteObserved(down: false, slot: slot)
        }
        // Modes are slot properties: hold is always hold-to-talk,
        // hands-free always toggles. The transition machines are already
        // mode-parameterized, so each slot steps its own.
        let mode: InteractionMode = slot == .hold ? .holdToTalk : .handsFree
        let action: ShortcutTransition
        if slot == .hold {
            action = holdTransition.step(.event(event), mode: mode)
            if case .keyDown = event {
                holdTap.down(at: now)
            } else if case .keyUp = event {
                if holdTap.up(at: now) {
                    convertDoubleTapToHandsFree()
                }
            }
        } else {
            action = handsFreeTransition.step(.event(event), mode: mode)
        }
        route(action, mode: mode)
    }

    /// Bare-fn hold path. fn taps belong to macOS (emoji, dictation,
    /// remap, or nothing — varies by device/setting and is unobservable),
    /// so Oto commits nothing until a sustained hold: early release drops
    /// silently (no session, no pill, no duck, no conversion, no
    /// calibration trace). Confirmed holds route exactly like any hold.
    /// Events pass through untouched either way — the native tap behavior
    /// is byte-identical. fn never feeds the double-tap tracker: taps are
    /// system gestures, converting them would double-fire against macOS.
    private func receiveFnHold(_ event: ShortcutEvent, at now: ContinuousClock.Instant) {
        switch event {
        case .keyDown(let isRepeat):
            guard !isRepeat, fnPendingDown == nil, !fnConfirmed else { return }
            fnPendingDown = now
            fnConfirmTask?.cancel()
            fnConfirmTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.fnHoldConfirmNanoseconds)
                guard let self else { return }
                // Same press, still held, still fn-hold configured and live.
                // (Reconfig/teardown disarms via stop(); suspend/Escape too.)
                guard self.fnPendingDown == now, self.isFnHold,
                      self.configuration.enabled, !self.isSuspended
                else { return }
                self.fnConfirmed = true
                self.noteObserved(down: true, slot: .hold)
                self.route(.begin, mode: .holdToTalk)
            }
        case .keyUp:
            fnConfirmTask?.cancel()
            fnConfirmTask = nil
            guard fnPendingDown != nil else { return }
            fnPendingDown = nil
            guard fnConfirmed else { return }  // sub-threshold tap: the system's.
            fnConfirmed = false
            noteObserved(down: false, slot: .hold)
            route(.finish, mode: .holdToTalk)
        case .monitorLost:
            dropFnPending()
        }
    }

    /// Disarm fn-hold without touching the coordinator (nothing began, so
    /// there is nothing to cancel — the whole point of confirmation).
    private func dropFnPending() {
        fnConfirmTask?.cancel()
        fnConfirmTask = nil
        fnPendingDown = nil
        fnConfirmed = false
    }
    /// Double-tap confirmed on the hold slot: the tap's own micro-session
    /// is cancelled best-effort (non-terminal → discarded pre-insertion;
    /// near-impossible race watched by the matrix), then the existing
    /// hands-free toggle path begins. Sequenced in ONE Task — cancel
    /// before toggle — so the toggle can never run ahead of the cancel
    /// and nil on a still-live micro. The Task first spins past every
    /// begin routed before the confirm (generation gate): down2's begin
    /// id may not have landed yet, and cancelling the stale id while the
    /// toggle meets the live micro nils the conversion. Zero new
    /// coordinator calls.
    private func convertDoubleTapToHandsFree() {
        let generation = beginGeneration
        Task { [weak self] in
            guard let self else { return }
            while self.beginSettledThrough < generation {
                await Task.yield()
            }
            if let current = self.activeSessionID {
                await self.coordinator.cancel(current)
            }
            if let newID = await self.coordinator.toggleHandsFree() {
                self.activeSessionID = newID
            }
        }
    }

    private func receiveEscape() {
        _ = holdTransition.step(.escape, mode: .holdToTalk)
        _ = handsFreeTransition.step(.escape, mode: .handsFree)
        dropFnPending()
        guard let id = activeSessionID else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.coordinator.cancel(id)
        }
    }

    /// Escape-cancel availability (escape workstream): Escape rides the one
    /// shared HID tap, which needs Accessibility trust. Menu-compat: kept as
    /// a single derived value (shared-tap liveness) so the menu compiles
    /// unchanged; per-slot escape state follows each slot's calibration row.
    var isEscapeCancelAvailable: Bool {
        hidMonitor.isLive
    }

    /// Test hooks: drive Escape→cancel without hardware. Seeding mirrors
    /// what route(.begin) stores on a real key-down.
    func seedActiveSessionForTests(_ id: UUID) { activeSessionID = id }
    func receiveEscapeForTests() { receiveEscape() }
    /// Test hook: drive a backend event for a slot without hardware.
    func receiveForTests(_ event: ShortcutEvent, from slot: ShortcutSlot) { receive(event, from: slot) }
    /// Test hook: deterministic time-injected variant (double-tap tests).
    func receiveForTests(_ event: ShortcutEvent, from slot: ShortcutSlot, at now: ContinuousClock.Instant) {
        receive(event, from: slot, at: now)
    }

    private func route(_ action: ShortcutTransition, mode: InteractionMode) {
        switch action {
        case .ignore, .reset:
            break
        case .begin:
            // Generation-gated by convertDoubleTapToHandsFree: bumped
            // synchronously here, settled by the Task after storing.
            beginGeneration += 1
            let generation = beginGeneration
            // Hands-free begins through the toggle path so the session is
            // recorded with the mode the person actually chose (audit F1).
            // `beginHold` would label it `.holdToTalk` and leave the tested
            // toggle path dead in production. Finish below is mode-agnostic.
            if mode == .handsFree {
                Task { [weak self] in
                    guard let self else { return }
                    defer { self.beginSettledThrough = max(self.beginSettledThrough, generation) }
                    if let id = await self.coordinator.toggleHandsFree() {
                        self.activeSessionID = id
                    }
                }
            } else {
                Task { [weak self] in
                    guard let self else { return }
                    defer { self.beginSettledThrough = max(self.beginSettledThrough, generation) }
                    if let id = await self.coordinator.beginHold() {
                        self.activeSessionID = id
                    }
                }
            }
        case .finish:
            guard let id = activeSessionID else { break }
            Task { [weak self] in
                guard let self else { return }
                await self.coordinator.finish(id)
            }
        }
    }
}
