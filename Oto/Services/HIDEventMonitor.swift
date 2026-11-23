//
//  HIDEventMonitor.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import IOKit.hid
import Synchronization

/// Single HID event tap owning ALL global key detection: function-row
/// keys AND bare-modifier hold. Runs on a dedicated high-priority
/// background `CFRunLoop` thread so main-thread stalls never freeze
/// system-wide macOS input.
///
/// WHY THIS EXISTS: NSEvent monitors (global AND local) wedge
/// MenuBarExtra menu tracking on this macOS — proven by bisect (menu
/// works with monitors off, freezes with either flagsChanged monitor
/// on). A CGEvent tap lives below AppKit tracking and is immune by
/// construction. Cost: the default trigger requires Accessibility
/// trust (tapCreate fails without it).
///
/// Rules:
/// - Function keys: bare press only, repeats tracked, matched releases
///   consumed (keeps macOS dictation from firing alongside).
/// - Modifier hold: flagsChanged press/release (plus keyDown/keyUp and
///   optional IOHIDManager for fn/Globe), NEVER consumed (the system
///   must still see Option/fn held for app-switching etc.). Another
///   keyDown or mouse-down that *uses this modifier* while it is held
///   (Option-U, Option-click) marks combination-use and swallows the
///   release; keyUp never disqualifies (typing rollover), and independent
///   input (Command-1 while Option is held) does not.
/// - Tap timeout/deactivation → re-enable immediately inside the tap
///   callback, verify `CGEvent.tapIsEnabled`, mark dead if still disabled,
///   and emit `monitorLost`.
/// - Empty configuration uninstalls: not in the key path at all unless
///   the person asked for it.
@MainActor
final class HIDEventMonitor {
    /// Synthetic event marker matching `InsertionEvents.syntheticMarker` ("OTO").
    /// Oto's own synthetic paste/copy/undo events are ignored at the top of `handle`.
    nonisolated static let syntheticMarker: Int64 = 0x4F54_4F

    /// Globe key code delivered by many Apple and external keyboards alongside `kVK_Function` (63).
    nonisolated static let globeKeyCode: Int64 = 179

    /// Emitted for normalized physical events (legacy single-slot path).
    var onEvent: ((ShortcutEvent) -> Void)?
    /// Escape was pressed (observed only — never consumed; it still reaches
    /// the focused app). Wired to coordinator cancel by dispatch.
    var onEscape: (() -> Void)?
    /// Tagged events for the dual-slot dispatch. Set only by the slot-tagged
    /// `configure` below; the legacy `onEvent` stays silent in slot mode so
    /// the two paths never double-emit.
    var onSlotEvent: ((ShortcutEvent, ShortcutSlot) -> Void)?

    private(set) var isLive = false

    /// Thread-safe routing & hold state accessed both from MainActor
    /// configuration methods and synchronously on the background tap thread.
    private nonisolated let state = Mutex(MonitorState())

    /// C-tap + optional IOHIDManager lifetime owner on its own background
    /// `CFRunLoop` thread.
    private nonisolated let lifetime = TapLifetime()

    isolated deinit {
        lifetime.uninstall()
    }

    // MARK: - Dual-slot path (hold + hands-free live together)

    /// Slot-tagged configuration: two hold codes + a function-code→slot map
    /// multiplexed over the ONE tap, with a single shared Escape observation.
    /// Single-slot convenience for the legacy path is preserved separately
    /// below (existing decide-matrix tests keep passing unmodified).
    func configure(
        holdSlots: [UInt16: ShortcutSlot],
        functionSlots: [Int64: ShortcutSlot],
        escapeObserved: Bool = true
    ) {
        state.withLock { s in
            s.holdSlots = holdSlots
            s.functionSlots = functionSlots
            s.escapeObserved = escapeObserved
            s.slotMode = true
            s.slotHolds = Dictionary(uniqueKeysWithValues: holdSlots.keys.map { ($0, ModifierHoldState()) })
            s.pressedFunction = nil
            // Clear legacy state so the paths never mix.
            s.functionCodes = []
            s.holdCode = nil
            s.hold = ModifierHoldState()
            s.pressedFunctionCode = nil
        }
        sync()
        isLive = lifetime.verifyLive()
    }

    // MARK: - Legacy single-slot path

    func configure(functionCodes: Set<Int64>, holdKeyCode: UInt16?, escapeObserved: Bool = true) {
        state.withLock { s in
            s.functionCodes = functionCodes
            s.holdCode = holdKeyCode
            // Escape observation defaults ON whenever the tap lives: cancel
            // must work on every trigger kind (combo triggers have no other
            // Escape backend since NSEvent monitors are banned).
            s.escapeObserved = escapeObserved
            s.hold = ModifierHoldState()
            s.pressedFunctionCode = nil
            s.slotMode = false
            s.holdSlots = [:]
            s.functionSlots = [:]
            s.slotHolds = [:]
            s.pressedFunction = nil
        }
        sync()
        isLive = lifetime.verifyLive()
    }

    func stop() {
        lifetime.uninstall()
        state.withLock { s in
            s.functionCodes = []
            s.holdCode = nil
            s.hold = ModifierHoldState()
            s.pressedFunctionCode = nil
            s.slotMode = false
            s.holdSlots = [:]
            s.functionSlots = [:]
            s.slotHolds = [:]
            s.pressedFunction = nil
            s.escapeObserved = false
        }
        isLive = false
    }

    /// Live-checks the underlying `CGEventTap` via `CGEvent.tapIsEnabled(tap:)`
    /// and updates `isLive` without tearing down a healthy tap.
    @discardableResult
    func verifyLive() -> Bool {
        let live = lifetime.verifyLive()
        isLive = live
        return live
    }

    /// Read-only combination-use probe: true when another key/mouse went
    /// down while this hold code was held (fn+arrows, fn+click, …). Lets
    /// fn-hold confirmation drop system gestures instead of committing.
    func isInCombination(code: UInt16) -> Bool {
        state.withLock { s in
            if let holdState = s.slotHolds[code] { return holdState.usedInCombination }
            if s.holdCode == code { return s.hold.usedInCombination }
            return false
        }
    }

    func noteMonitorLost() {
        let isSlotMode = state.withLock { s -> Bool in
            s.hold = ModifierHoldState()
            s.pressedFunctionCode = nil
            s.slotHolds = Dictionary(uniqueKeysWithValues: s.slotHolds.keys.map { ($0, ModifierHoldState()) })
            s.pressedFunction = nil
            return s.slotMode
        }
        if isSlotMode {
            // Both transition machines reset their local pressed state; the
            // coordinator owns the session outcome either way.
            onSlotEvent?(.monitorLost, .hold)
            onSlotEvent?(.monitorLost, .handsFree)
        } else {
            onEvent?(.monitorLost)
        }
    }

    // MARK: - Private

    /// Unit-test gate: real event taps never install under XCTest.
    /// Decide logic is fully driveable without hardware, and leaked
    /// taps from parallel tests firing into freed monitors crashed the
    /// runner (22-report cluster) — impossible with the gate closed.
    /// UI tests launch the app (no XCTest linked in) → fully live there.
    /// Immutable per process (test host vs app) — never toggled.
    nonisolated static let liveTapsEnabled = NSClassFromString("XCTestCase") == nil

    private func sync() {
        let isEmpty = state.withLock { s in
            s.holdSlots.isEmpty
                && s.functionSlots.isEmpty
                && s.functionCodes.isEmpty
                && s.holdCode == nil
                && !s.escapeObserved
        }
        if isEmpty {
            lifetime.uninstall()
        } else if Self.liveTapsEnabled {
            if !lifetime.verifyLive() {
                lifetime.uninstall()
                lifetime.install(owner: self)
            }
        }
        // Gate closed (unit tests): configured logically, never live.
    }

    /// Runs from the C event-tap callback on the dedicated background
    /// `CFRunLoop` thread: synchronous consume decision under `state`'s
    /// `Mutex` (microseconds, never blocks MainActor); event emissions hop
    /// asynchronously to MainActor in strict FIFO order via `DispatchQueue.main`.
    fileprivate nonisolated func handle(
        type: CGEventType,
        event: CGEvent,
        tap: CFMachPort?
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let reenabled: Bool
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                reenabled = CGEvent.tapIsEnabled(tap: tap)
            } else {
                reenabled = false
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if !reenabled {
                        self.isLive = false
                    }
                    self.noteMonitorLost()
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // Ignore Oto's own synthetic paste/copy/undo keystrokes.
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown || type == .keyUp || type == .flagsChanged
            || type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
        else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let flags = event.flags

        let outcome = state.withLock { s in
            s.process(type: type, keyCode: keyCode, isRepeat: isRepeat, flags: flags)
        }

        switch outcome {
        case .routed(let decision, let triggerEscape):
            if triggerEscape || !decision.combinations.isEmpty || (decision.emit != nil && decision.slot != nil) {
                let combinations = decision.combinations
                let emit = decision.emit
                let slot = decision.slot
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        // Combination first: any hold that this press just disqualified is
                        // cancelled before Escape or the press's own event reaches dispatch.
                        for combination in combinations {
                            self.onSlotEvent?(.combinationBegan, combination)
                        }
                        if triggerEscape {
                            self.onEscape?()
                        }
                        if let emit, let slot {
                            self.onSlotEvent?(emit, slot)
                        }
                    }
                }
            }
            return decision.consume ? nil : Unmanaged.passUnretained(event)

        case .legacy(let emit, let consume, let triggerEscape):
            if triggerEscape || emit != nil {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if triggerEscape {
                            self.onEscape?()
                        }
                        if let emit {
                            self.onEvent?(emit)
                        }
                    }
                }
            }
            return consume ? nil : Unmanaged.passUnretained(event)
        }
    }

    /// Physical `fn`/Globe event delivered by the optional `IOHIDManager`
    /// on the background `CFRunLoop` thread. Deduplicates cleanly against
    /// `CGEventTap` via `ModifierHoldState`'s idempotent `isDown` guard.
    fileprivate nonisolated func handleHIDFn(isDown: Bool) {
        let outcome = state.withLock { s in
            s.processHIDFn(isDown: isDown)
        }
        switch outcome {
        case .none:
            break
        case .slot(let slot, let emit):
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.onSlotEvent?(emit, slot)
                }
            }
        case .legacy(let emit):
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.onEvent?(emit)
                }
            }
        }
    }

    /// Stale-hold watchdog (borrowed from Hex): periodically checks live
    /// WindowServer + HID modifier flags ONLY when a modifier hold is
    /// currently marked `isDown`. If BOTH `.combinedSessionState` and
    /// `.hidSystemState` report the key is physically up, releases it
    /// immediately so `fn` (or any modifier hold) can never fail to close
    /// when macOS swallows a release event.
    fileprivate nonisolated func reconcilePhysicalModifierState() {
        let hasHeld = state.withLock { $0.hasAnyHeldModifier }
        guard hasHeld else { return }

        let combined = CGEventSource.flagsState(.combinedSessionState)
        let hid = CGEventSource.flagsState(.hidSystemState)
        let releases = state.withLock { s in
            s.reconcileStaleHolds(combinedFlags: combined, hidFlags: hid)
        }
        guard !releases.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for release in releases {
                    switch release {
                    case .none:
                        break
                    case .slot(let slot, let emit):
                        self.onSlotEvent?(emit, slot)
                    case .legacy(let emit):
                        self.onEvent?(emit)
                    }
                }
            }
        }
    }

    /// Exposed internal for the decide-matrix tests (audit S3): the C
    /// callback and tap lifecycle stay private; only the pure
    /// type/key/flags → (emit, consume) decision is tested.
    func decide(
        type: CGEventType,
        keyCode: Int64,
        isRepeat: Bool,
        flags: CGEventFlags
    ) -> (emit: ShortcutEvent?, consume: Bool) {
        let result = state.withLock { s in
            s.decideLegacy(type: type, keyCode: keyCode, isRepeat: isRepeat, flags: flags)
        }
        if result.triggerEscape {
            let onEscape = onEscape
            DispatchQueue.main.async { onEscape?() }
        }
        return (result.emit, result.consume)
    }

    func decideFunction(
        keyCode: Int64,
        isRepeat: Bool,
        flags: CGEventFlags,
        isDown: Bool
    ) -> (emit: ShortcutEvent?, consume: Bool) {
        state.withLock { s in
            s.decideFunction(keyCode: keyCode, isRepeat: isRepeat, flags: flags, isDown: isDown)
        }
    }

    /// Slot-tagged decision layer for dual-slot mode. Exposed internal for
    /// the dual decide-matrix tests; returns `RoutedDecision` carrying all
    /// disqualified combination slots (`combinations`) plus `combination`
    /// (`combinations.first`) for single-slot convenience.
    func decideRouted(
        type: CGEventType,
        keyCode: Int64,
        isRepeat: Bool,
        flags: CGEventFlags
    ) -> RoutedDecision {
        let result = state.withLock { s in
            s.decideRouted(type: type, keyCode: keyCode, isRepeat: isRepeat, flags: flags)
        }
        if result.triggerEscape {
            let onEscape = onEscape
            DispatchQueue.main.async { onEscape?() }
        }
        return result.decision
    }

    /// Internal test hook for `IOHIDManager` physical `fn`/Globe deduplication.
    func decideHIDFn(isDown: Bool) -> (slot: ShortcutSlot?, emit: ShortcutEvent?) {
        let outcome = state.withLock { s in
            s.processHIDFn(isDown: isDown)
        }
        switch outcome {
        case .none: return (nil, nil)
        case .slot(let slot, let emit): return (slot, emit)
        case .legacy(let emit): return (nil, emit)
        }
    }
}

/// Decision output of `HIDEventMonitor.decideRouted`. Carries every held
/// slot disqualified by a chord (`combinations`) so no second slot is ever
/// dropped due to unordered dictionary iteration.
nonisolated struct RoutedDecision: Equatable, Sendable {
    var slot: ShortcutSlot?
    var emit: ShortcutEvent?
    var combinations: [ShortcutSlot]
    var consume: Bool

    /// Convenience accessor for the first disqualified slot (if any).
    var combination: ShortcutSlot? { combinations.first }
}

/// Pure, thread-safe decision core owned inside `HIDEventMonitor`'s `Mutex`.
private nonisolated struct MonitorState: Sendable {
    enum ProcessOutcome: Sendable {
        case routed(decision: RoutedDecision, triggerEscape: Bool)
        case legacy(emit: ShortcutEvent?, consume: Bool, triggerEscape: Bool)
    }

    enum HIDFnOutcome: Sendable {
        case none
        case slot(ShortcutSlot, ShortcutEvent)
        case legacy(ShortcutEvent)
    }

    var slotMode = false
    var escapeObserved = false

    // Legacy single-slot state
    var functionCodes: Set<Int64> = []
    var holdCode: UInt16?
    var hold = ModifierHoldState()
    var pressedFunctionCode: Int64?

    // Dual-slot state
    var holdSlots: [UInt16: ShortcutSlot] = [:]
    var functionSlots: [Int64: ShortcutSlot] = [:]
    var slotHolds: [UInt16: ModifierHoldState] = [:]
    var pressedFunction: (code: Int64, slot: ShortcutSlot)?

    mutating func process(
        type: CGEventType,
        keyCode: Int64,
        isRepeat: Bool,
        flags: CGEventFlags
    ) -> ProcessOutcome {
        if slotMode {
            let result = decideRouted(type: type, keyCode: keyCode, isRepeat: isRepeat, flags: flags)
            return .routed(decision: result.decision, triggerEscape: result.triggerEscape)
        } else {
            let result = decideLegacy(type: type, keyCode: keyCode, isRepeat: isRepeat, flags: flags)
            return .legacy(emit: result.emit, consume: result.consume, triggerEscape: result.triggerEscape)
        }
    }

    var hasAnyHeldModifier: Bool {
        if slotMode {
            return slotHolds.values.contains { $0.isDown }
        }
        return hold.isDown
    }

    mutating func reconcileStaleHolds(
        combinedFlags: CGEventFlags,
        hidFlags: CGEventFlags
    ) -> [HIDFnOutcome] {
        var releases: [HIDFnOutcome] = []
        if slotMode {
            for slot in ShortcutSlot.allCases {
                guard let entry = holdSlots.first(where: { $0.value == slot }) else { continue }
                let code = entry.key
                guard var holdState = slotHolds[code], holdState.isDown else { continue }
                // Require BOTH `.combinedSessionState` and `.hidSystemState` to
                // report the modifier flag cleared before synthesizing a stale
                // release. On Apple Silicon MacBooks, TopCase `fn` only sets
                // `.maskSecondaryFn` in `.combinedSessionState` (never in
                // `.hidSystemState`), so checking only `.hidSystemState` would
                // prematurely cut a live `fn` press in half.
                let stillDownHID = ModifierHoldState.isModifierDown(keyCode: code, flags: hidFlags)
                let stillDownCombined = ModifierHoldState.isModifierDown(keyCode: code, flags: combinedFlags)
                if !stillDownHID && !stillDownCombined {
                    if let emit = holdState.step(.flags(down: false)) {
                        releases.append(.slot(slot, emit))
                    }
                    slotHolds[code] = holdState
                }
            }
        } else if let holdCode, hold.isDown {
            let stillDownHID = ModifierHoldState.isModifierDown(keyCode: holdCode, flags: hidFlags)
            let stillDownCombined = ModifierHoldState.isModifierDown(keyCode: holdCode, flags: combinedFlags)
            if !stillDownHID && !stillDownCombined {
                if let emit = hold.step(.flags(down: false)) {
                    releases.append(.legacy(emit))
                }
            }
        }
        return releases
    }

    mutating func processHIDFn(isDown: Bool) -> HIDFnOutcome {
        let fnCode = UInt16(kVK_Function)
        if slotMode {
            guard let slot = holdSlots[fnCode] else { return .none }
            var holdState = slotHolds[fnCode] ?? ModifierHoldState()
            let emit = holdState.step(.flags(down: isDown))
            slotHolds[fnCode] = holdState
            if let emit { return .slot(slot, emit) }
            return .none
        } else {
            guard holdCode == fnCode else { return .none }
            if let emit = hold.step(.flags(down: isDown)) {
                return .legacy(emit)
            }
            return .none
        }
    }

    // MARK: - Legacy single-slot decisions

    mutating func decideLegacy(
        type: CGEventType,
        keyCode: Int64,
        isRepeat: Bool,
        flags: CGEventFlags
    ) -> (emit: ShortcutEvent?, consume: Bool, triggerEscape: Bool) {
        switch type {
        case .flagsChanged:
            let decided = decideHold(keyCode: keyCode, flags: flags)
            return (decided.emit, decided.consume, false)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            _ = hold.step(
                .otherActivity(usesHeldModifier: holdModifierInUse(holdCode: holdCode, flags: flags))
            )
            return (nil, false, false)
        case .keyDown:
            if isBareFnKeyEvent(keyCode: keyCode, flags: flags),
               holdCode == UInt16(kVK_Function)
            {
                return (hold.step(.flags(down: true)), false, false)
            }
            _ = hold.step(
                .otherActivity(usesHeldModifier: holdModifierInUse(holdCode: holdCode, flags: flags))
            )
            if escapeObserved, keyCode == Int64(kVK_Escape) {
                return (nil, false, true)
            }
            let decided = decideFunction(keyCode: keyCode, isRepeat: isRepeat, flags: flags, isDown: true)
            return (decided.emit, decided.consume, false)
        case .keyUp:
            if Self.isFnKeyCode(keyCode), holdCode == UInt16(kVK_Function), hold.isDown {
                return (hold.step(.flags(down: false)), false, false)
            }
            // Never mark combination-use on keyUp: normal typing rollover
            // (releasing a letter shortly after pressing a modifier) must not
            // falsely cancel dictation.
            let decided = decideFunction(keyCode: keyCode, isRepeat: false, flags: flags, isDown: false)
            return (decided.emit, decided.consume, false)
        default:
            return (nil, false, false)
        }
    }

    private mutating func decideHold(keyCode: Int64, flags: CGEventFlags) -> (emit: ShortcutEvent?, consume: Bool) {
        guard let holdCode, ModifierHoldState.flag(for: holdCode) != nil else {
            return (nil, false)
        }
        let down = ModifierHoldState.isModifierDown(keyCode: holdCode, flags: flags)
        // Always release a held modifier when ANY `.flagsChanged` event clears
        // its flag — even if macOS delivered the release with keyCode == 0 or
        // another modifier's keyCode (common with fn/Globe).
        if hold.isDown, !down {
            return (hold.step(.flags(down: false)), false)
        }
        // For press, require matching keyCode (or keyCode == 0 with fn flag set).
        let matches = Self.matchesHoldCode(keyCode: keyCode, configuredCode: holdCode)
            || (holdCode == UInt16(kVK_Function) && keyCode == 0 && down)
        guard matches else { return (nil, false) }
        return (hold.step(.flags(down: down)), false)
    }

    private func holdModifierInUse(holdCode: UInt16?, flags: CGEventFlags) -> Bool {
        guard let holdCode else { return false }
        return ModifierHoldState.isModifierDown(keyCode: holdCode, flags: flags)
    }

    mutating func decideFunction(
        keyCode: Int64,
        isRepeat: Bool,
        flags: CGEventFlags,
        isDown: Bool
    ) -> (emit: ShortcutEvent?, consume: Bool) {
        if isDown {
            if isRepeat {
                return pressedFunctionCode == keyCode ? (.keyDown(isRepeat: true), true) : (nil, false)
            }
            guard FunctionKeyMatching.shouldFire(
                codes: functionCodes,
                keyCode: keyCode,
                flags: flags,
                isRepeat: false
            ) else {
                return (nil, false)
            }
            guard pressedFunctionCode == nil else { return (nil, true) }
            pressedFunctionCode = keyCode
            return (.keyDown(isRepeat: false), true)
        } else {
            guard functionCodes.contains(keyCode), pressedFunctionCode == keyCode else {
                return (nil, false)
            }
            pressedFunctionCode = nil
            return (.keyUp, true)
        }
    }

    // MARK: - Dual-slot decisions

    mutating func decideRouted(
        type: CGEventType,
        keyCode: Int64,
        isRepeat: Bool,
        flags: CGEventFlags
    ) -> (decision: RoutedDecision, triggerEscape: Bool) {
        switch type {
        case .flagsChanged:
            let decided = decideRoutedHold(keyCode: keyCode, flags: flags)
            return (
                RoutedDecision(slot: decided.slot, emit: decided.emit, combinations: [], consume: decided.consume),
                false
            )
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return (
                RoutedDecision(
                    slot: nil,
                    emit: nil,
                    combinations: markAllHoldsCombinationUse(flags: flags),
                    consume: false
                ),
                false
            )
        case .keyDown:
            // External keyboards that deliver fn/Globe (63 or 179) as keyDown
            // WITHOUT `.maskSecondaryFn` flagsChanged: handle as a physical fn
            // press. When `.maskSecondaryFn` is present, `.flagsChanged` is the
            // single authoritative channel (matching Hex: prevents `.keyDown(179)`
            // + `.flagsChanged(63)` from double-firing on a single quick tap).
            if Self.isFnKeyCode(keyCode) {
                if isBareFnKeyEvent(keyCode: keyCode, flags: flags),
                   !flags.contains(.maskSecondaryFn),
                   let slot = holdSlots[UInt16(kVK_Function)]
                {
                    let fnCode = UInt16(kVK_Function)
                    var holdState = slotHolds[fnCode] ?? ModifierHoldState()
                    let emit = holdState.step(.flags(down: true))
                    slotHolds[fnCode] = holdState
                    return (
                        RoutedDecision(slot: slot, emit: emit, combinations: [], consume: false),
                        false
                    )
                }
                // Never treat the Globe key's own synthetic keyDown(179/63) as a
                // combination chord with the fn modifier hold.
                return (
                    RoutedDecision(slot: nil, emit: nil, combinations: [], consume: false),
                    false
                )
            }
            let combinations = markAllHoldsCombinationUse(flags: flags)
            if escapeObserved, keyCode == Int64(kVK_Escape) {
                return (
                    RoutedDecision(slot: nil, emit: nil, combinations: combinations, consume: false),
                    true
                )
            }
            let decided = decideRoutedFunction(keyCode: keyCode, isRepeat: isRepeat, flags: flags, isDown: true)
            return (
                RoutedDecision(slot: decided.slot, emit: decided.emit, combinations: combinations, consume: decided.consume),
                false
            )
        case .keyUp:
            // Matching keyUp for external keyboards that deliver fn/Globe as key
            // events without `.maskSecondaryFn`. Never release while
            // `.maskSecondaryFn` is still active on `.flagsChanged`.
            if Self.isFnKeyCode(keyCode) {
                if !flags.contains(.maskSecondaryFn),
                   let slot = holdSlots[UInt16(kVK_Function)],
                   let existing = slotHolds[UInt16(kVK_Function)],
                   existing.isDown
                {
                    let fnCode = UInt16(kVK_Function)
                    var holdState = existing
                    let emit = holdState.step(.flags(down: false))
                    slotHolds[fnCode] = holdState
                    return (
                        RoutedDecision(slot: slot, emit: emit, combinations: [], consume: false),
                        false
                    )
                }
                return (
                    RoutedDecision(slot: nil, emit: nil, combinations: [], consume: false),
                    false
                )
            }
            // Never mark combination-use on keyUp (prevents typing-rollover false cancel).
            let decided = decideRoutedFunction(keyCode: keyCode, isRepeat: false, flags: flags, isDown: false)
            return (
                RoutedDecision(slot: decided.slot, emit: decided.emit, combinations: [], consume: decided.consume),
                false
            )
        default:
            return (RoutedDecision(slot: nil, emit: nil, combinations: [], consume: false), false)
        }
    }

    private mutating func decideRoutedHold(
        keyCode: Int64,
        flags: CGEventFlags
    ) -> (slot: ShortcutSlot?, emit: ShortcutEvent?, consume: Bool) {
        // First, check if the exact keyCode matches a configured hold slot.
        if let matchedCode = canonicalHoldCode(for: keyCode),
           let slot = holdSlots[matchedCode],
           ModifierHoldState.flag(for: matchedCode) != nil
        {
            let down = ModifierHoldState.isModifierDown(keyCode: matchedCode, flags: flags)
            var holdState = slotHolds[matchedCode] ?? ModifierHoldState()
            let wasDown = holdState.isDown
            let emit = holdState.step(.flags(down: down))
            slotHolds[matchedCode] = holdState
            // Return this slot whenever it handled the event (including a
            // swallowed release after combination use). Only fall through if
            // this key didn't change state and another held key just released.
            if wasDown != down || emit != nil {
                return (slot, emit, false)
            }
            // Check whether another held slot cleared on this same flagsChanged.
            for otherSlot in ShortcutSlot.allCases where otherSlot != slot {
                guard let entry = holdSlots.first(where: { $0.value == otherSlot }) else { continue }
                let code = entry.key
                guard var otherState = slotHolds[code], otherState.isDown else { continue }
                if !ModifierHoldState.isModifierDown(keyCode: code, flags: flags) {
                    let otherEmit = otherState.step(.flags(down: false))
                    slotHolds[code] = otherState
                    return (otherSlot, otherEmit, false)
                }
            }
            return (slot, nil, false)
        }

        // Second: release ANY currently-held modifier slot whose live flag just
        // cleared on this `.flagsChanged` event, even if macOS reported keyCode
        // 0 or another modifier's keyCode (fixes fn/Globe failing to close).
        for slot in ShortcutSlot.allCases {
            guard let entry = holdSlots.first(where: { $0.value == slot }) else { continue }
            let code = entry.key
            guard var holdState = slotHolds[code], holdState.isDown else { continue }
            if !ModifierHoldState.isModifierDown(keyCode: code, flags: flags) {
                let emit = holdState.step(.flags(down: false))
                slotHolds[code] = holdState
                return (slot, emit, false)
            }
        }

        // Third: some keyboards / macOS builds deliver bare fn press with
        // keyCode == 0 and `.maskSecondaryFn` set on `.flagsChanged`.
        let fnCode = UInt16(kVK_Function)
        if keyCode == 0,
           let slot = holdSlots[fnCode],
           ModifierHoldState.isModifierDown(keyCode: fnCode, flags: flags)
        {
            var holdState = slotHolds[fnCode] ?? ModifierHoldState()
            if !holdState.isDown {
                let emit = holdState.step(.flags(down: true))
                slotHolds[fnCode] = holdState
                return (slot, emit, false)
            }
        }

        // NEVER consume flagsChanged: the system must still see the modifier.
        return (nil, nil, false)
    }

    /// Marks every held modifier slot whose own modifier appears in `flags`
    /// as combination use, returning ALL slots that transitioned on this input
    /// in deterministic `ShortcutSlot.allCases` order.
    private mutating func markAllHoldsCombinationUse(flags: CGEventFlags) -> [ShortcutSlot] {
        var transitioned: [ShortcutSlot] = []
        for slot in ShortcutSlot.allCases {
            guard let entry = holdSlots.first(where: { $0.value == slot }) else { continue }
            let code = entry.key
            guard var holdState = slotHolds[code], holdState.isDown, !holdState.usedInCombination else {
                continue
            }
            let usesHeldModifier = ModifierHoldState.isModifierDown(keyCode: code, flags: flags)
            _ = holdState.step(.otherActivity(usesHeldModifier: usesHeldModifier))
            slotHolds[code] = holdState
            if holdState.usedInCombination {
                transitioned.append(slot)
            }
        }
        return transitioned
    }

    private mutating func decideRoutedFunction(
        keyCode: Int64,
        isRepeat: Bool,
        flags: CGEventFlags,
        isDown: Bool
    ) -> (slot: ShortcutSlot?, emit: ShortcutEvent?, consume: Bool) {
        if isDown {
            if isRepeat {
                return pressedFunction.flatMap { $0.code == keyCode ? ($0.slot, .keyDown(isRepeat: true), true) : nil }
                    ?? (nil, nil, false)
            }
            guard let slot = functionSlots[keyCode],
                  FunctionKeyMatching.shouldFire(
                      codes: Set(functionSlots.keys),
                      keyCode: keyCode,
                      flags: flags,
                      isRepeat: false
                  )
            else {
                return (nil, nil, false)
            }
            guard pressedFunction == nil else { return (slot, nil, true) }
            pressedFunction = (keyCode, slot)
            return (slot, .keyDown(isRepeat: false), true)
        } else {
            guard let pressed = pressedFunction,
                  pressed.code == keyCode,
                  functionSlots[keyCode] != nil
            else {
                return (nil, nil, false)
            }
            pressedFunction = nil
            return (pressed.slot, .keyUp, true)
        }
    }

    // MARK: - fn / Globe matching helpers

    private static func isFnKeyCode(_ keyCode: Int64) -> Bool {
        keyCode == Int64(kVK_Function) || keyCode == HIDEventMonitor.globeKeyCode
    }

    private func isBareFnKeyEvent(keyCode: Int64, flags: CGEventFlags) -> Bool {
        Self.isFnKeyCode(keyCode)
            && flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty
    }

    private static func matchesHoldCode(keyCode: Int64, configuredCode: UInt16) -> Bool {
        if keyCode == Int64(configuredCode) { return true }
        if configuredCode == UInt16(kVK_Function), keyCode == HIDEventMonitor.globeKeyCode {
            return true
        }
        return false
    }

    private func canonicalHoldCode(for keyCode: Int64) -> UInt16? {
        if keyCode >= 0 && keyCode <= Int64(UInt16.max) {
            let code = UInt16(keyCode)
            if holdSlots[code] != nil { return code }
        }
        if keyCode == HIDEventMonitor.globeKeyCode, holdSlots[UInt16(kVK_Function)] != nil {
            return UInt16(kVK_Function)
        }
        return nil
    }
}

/// Pure bare-modifier hold tracking: press → down, clean release → up,
/// release-after-combination-use → swallowed. No hardware, no async.
///
/// "Combination use" is scoped to the held modifier: input whose own flags
/// contain this modifier family (⌥U while holding ⌥, a ⌥-click) disqualifies
/// the hold; independent input (⌘1 while holding ⌥, a Shift tap, a plain
/// click) does not, so the release still finishes the dictation.
nonisolated struct ModifierHoldState: Equatable, Sendable {
    // Device-sided modifier masks from IOKit/hidsystem/IOLLEvent.h.
    static let deviceLeftControlMask: UInt64  = 0x0000_0001
    static let deviceLeftShiftMask: UInt64    = 0x0000_0002
    static let deviceRightShiftMask: UInt64   = 0x0000_0004
    static let deviceLeftCommandMask: UInt64  = 0x0000_0008
    static let deviceRightCommandMask: UInt64 = 0x0000_0010
    static let deviceLeftAltMask: UInt64      = 0x0000_0020
    static let deviceRightAltMask: UInt64     = 0x0000_0040
    static let deviceRightControlMask: UInt64 = 0x0000_2000

    private(set) var isDown = false
    private(set) var usedInCombination = false

    enum HoldEvent: Equatable, Sendable {
        case flags(down: Bool)
        /// Another input arrived. `usesHeldModifier` is true when that
        /// input's CGEventFlags contain this slot's modifier — i.e.
        /// the modifier is being consumed as part of a chord.
        case otherActivity(usesHeldModifier: Bool)
    }

    mutating func step(_ event: HoldEvent) -> ShortcutEvent? {
        switch event {
        case .flags(let down):
            if down {
                guard !isDown else { return nil }
                isDown = true
                usedInCombination = false
                return .keyDown(isRepeat: false)
            } else {
                guard isDown else { return nil }
                isDown = false
                defer { usedInCombination = false }
                return usedInCombination ? nil : .keyUp
            }
        case .otherActivity(let usesHeldModifier):
            if isDown, usesHeldModifier { usedInCombination = true }
            return nil
        }
    }

    /// CGEvent flag family for a modifier key code.
    static func flag(for keyCode: UInt16) -> CGEventFlags? {
        switch keyCode {
        case UInt16(kVK_Shift), UInt16(kVK_RightShift): return .maskShift
        case UInt16(kVK_Command), UInt16(kVK_RightCommand): return .maskCommand
        case UInt16(kVK_Option), UInt16(kVK_RightOption): return .maskAlternate
        case UInt16(kVK_Control), UInt16(kVK_RightControl): return .maskControl
        case UInt16(kVK_Function), UInt16(HIDEventMonitor.globeKeyCode): return .maskSecondaryFn
        default: return nil
        }
    }

    /// Side-aware modifier press check: uses the device-sided `NX_DEVICE*`
    /// bitmask whenever the corresponding family's device-side bits are present
    /// in `flags.rawValue` (preventing stuck holds when the opposite side is
    /// still held), and falls back to the generic family mask when device-side
    /// bits are absent (e.g. synthetic events and unit tests).
    static func isModifierDown(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        let raw = flags.rawValue
        switch keyCode {
        case UInt16(kVK_Shift):
            let family = deviceLeftShiftMask | deviceRightShiftMask
            return (raw & family) != 0 ? (raw & deviceLeftShiftMask) != 0 : flags.contains(.maskShift)
        case UInt16(kVK_RightShift):
            let family = deviceLeftShiftMask | deviceRightShiftMask
            return (raw & family) != 0 ? (raw & deviceRightShiftMask) != 0 : flags.contains(.maskShift)
        case UInt16(kVK_Command):
            let family = deviceLeftCommandMask | deviceRightCommandMask
            return (raw & family) != 0 ? (raw & deviceLeftCommandMask) != 0 : flags.contains(.maskCommand)
        case UInt16(kVK_RightCommand):
            let family = deviceLeftCommandMask | deviceRightCommandMask
            return (raw & family) != 0 ? (raw & deviceRightCommandMask) != 0 : flags.contains(.maskCommand)
        case UInt16(kVK_Option):
            let family = deviceLeftAltMask | deviceRightAltMask
            return (raw & family) != 0 ? (raw & deviceLeftAltMask) != 0 : flags.contains(.maskAlternate)
        case UInt16(kVK_RightOption):
            let family = deviceLeftAltMask | deviceRightAltMask
            return (raw & family) != 0 ? (raw & deviceRightAltMask) != 0 : flags.contains(.maskAlternate)
        case UInt16(kVK_Control):
            let family = deviceLeftControlMask | deviceRightControlMask
            return (raw & family) != 0 ? (raw & deviceLeftControlMask) != 0 : flags.contains(.maskControl)
        case UInt16(kVK_RightControl):
            let family = deviceLeftControlMask | deviceRightControlMask
            return (raw & family) != 0 ? (raw & deviceRightControlMask) != 0 : flags.contains(.maskControl)
        case UInt16(kVK_Function), UInt16(HIDEventMonitor.globeKeyCode):
            return flags.contains(.maskSecondaryFn)
        default:
            return false
        }
    }
}

/// Retained trampoline passed as `userInfo` to the C event tap and optional
/// `IOHIDManager` callbacks. Holds a `Mutex`-guarded weak reference to the
/// owning `HIDEventMonitor` (plus the active `CFMachPort` for immediate
/// re-enable on timeout) and is cleared on `uninstall()` before the tap thread
/// releases it — eliminating UAF/resurrection and retain cycles by construction.
private nonisolated final class TapCallbackBox: Sendable {
    private struct WeakOwner: @unchecked Sendable {
        weak var monitor: HIDEventMonitor?
        var tap: CFMachPort?
    }

    private let storage: Mutex<WeakOwner>

    init(monitor: HIDEventMonitor) {
        self.storage = Mutex(WeakOwner(monitor: monitor, tap: nil))
    }

    var monitor: HIDEventMonitor? {
        storage.withLock { $0.monitor }
    }

    var tap: CFMachPort? {
        storage.withLock { $0.tap }
    }

    func setTap(_ tap: CFMachPort?) {
        storage.withLock { $0.tap = tap }
    }

    func clear() {
        storage.withLock {
            $0.monitor = nil
            $0.tap = nil
        }
    }
}

/// Owns the background `CFRunLoop` thread, `CGEventTap`, `CFRunLoopSource`,
/// and optional `IOHIDManager` observer for `fn`/Globe.
///
/// Lifecycle:
/// - `install(owner:)` spawns a dedicated `.userInteractive` `Thread`, creates
///   the tap + optional `IOHIDManager` on that thread's `CFRunLoop`, and waits
///   for startup to settle before returning so `isLive` is immediately accurate.
/// - `uninstall()` clears the weak owner trampoline, stops the background
///   `CFRunLoop` via `CFRunLoopStop`, and waits for the thread to cleanly
///   unschedule/close `IOHIDManager`, remove + invalidate `CFRunLoopSource`,
///   disable + invalidate `CFMachPort`, and release the trampoline box.
nonisolated final class TapLifetime: Sendable {
    private struct Handles: @unchecked Sendable {
        var tap: CFMachPort?
        var runLoop: CFRunLoop?
        var thread: Thread?
        var stoppedSemaphore: DispatchSemaphore?
        var callbackBox: TapCallbackBox?
    }

    private let handles = Mutex(Handles())

    var isLive: Bool {
        handles.withLock { $0.tap != nil }
    }

    func verifyLive() -> Bool {
        handles.withLock { h in
            guard let tap = h.tap else { return false }
            return CGEvent.tapIsEnabled(tap: tap)
        }
    }

    func install(owner: HIDEventMonitor) {
        let alreadyInstalled = handles.withLock { $0.tap != nil || $0.thread != nil }
        guard !alreadyInstalled else { return }

        let box = TapCallbackBox(monitor: owner)
        let ready = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)

        let thread = Thread { [weak self] in
            let boxPtr = Unmanaged.passRetained(box).toOpaque()
            defer {
                box.clear()
                Unmanaged<TapCallbackBox>.fromOpaque(boxPtr).release()
                self?.handles.withLock { h in
                    h.tap = nil
                    h.runLoop = nil
                    h.thread = nil
                    h.stoppedSemaphore = nil
                    h.callbackBox = nil
                }
                stopped.signal()
            }

            let mask = CGEventMask(
                (1 << CGEventType.keyDown.rawValue)
                    | (1 << CGEventType.keyUp.rawValue)
                    | (1 << CGEventType.flagsChanged.rawValue)
                    | (1 << CGEventType.leftMouseDown.rawValue)
                    | (1 << CGEventType.rightMouseDown.rawValue)
                    | (1 << CGEventType.otherMouseDown.rawValue)
            )
            guard let tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, userInfo in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    let callbackBox = Unmanaged<TapCallbackBox>.fromOpaque(userInfo).takeUnretainedValue()
                    guard let monitor = callbackBox.monitor else { return Unmanaged.passUnretained(event) }
                    return monitor.handle(type: type, event: event, tap: callbackBox.tap)
                },
                userInfo: boxPtr
            ) else {
                // tapCreate fails without Accessibility trust.
                ready.signal()
                return
            }

            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
                ready.signal()
                return
            }

            guard let runLoop = CFRunLoopGetCurrent() else {
                CFRunLoopSourceInvalidate(source)
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
                ready.signal()
                return
            }
            box.setTap(tap)
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)

            // Do NOT attach a parallel IOHIDManager for fn/Globe alongside the
            // live CGEventTap: on a quick tap (<40 ms), IOHIDManager delivers
            // down+up before WindowServer delivers CGEventTap's flagsChanged
            // down+up, causing a single physical click of fn to fire TWICE
            // (turning a single click to stop hands-free into a double-tap that
            // immediately restarts hands-free). CGEventTap at .cghidEventTap is
            // the single authoritative source, matching all other modifier keys.

            // Lightweight stale-hold watchdog on this runloop (150 ms):
            // zero work when idle; while a hold key is down, reconciles against
            // live WindowServer + HID flags if both report the key is up.
            var timerCtx = CFRunLoopTimerContext(
                version: 0,
                info: boxPtr,
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let watchdog = CFRunLoopTimerCreate(
                kCFAllocatorDefault,
                CFAbsoluteTimeGetCurrent() + 0.15,
                0.15,
                0,
                0,
                { _, info in
                    guard let info else { return }
                    let callbackBox = Unmanaged<TapCallbackBox>.fromOpaque(info).takeUnretainedValue()
                    callbackBox.monitor?.reconcilePhysicalModifierState()
                },
                &timerCtx
            )
            if let watchdog {
                CFRunLoopAddTimer(runLoop, watchdog, .commonModes)
            }

            self?.handles.withLock { h in
                h.tap = tap
                h.runLoop = runLoop
                h.stoppedSemaphore = stopped
                h.callbackBox = box
            }
            ready.signal()

            CFRunLoopRun()

            // Teardown on the runloop thread: guaranteed no callbacks can fire after this.
            if let watchdog {
                CFRunLoopRemoveTimer(runLoop, watchdog, .commonModes)
                CFRunLoopTimerInvalidate(watchdog)
            }
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFRunLoopSourceInvalidate(source)
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }

        thread.name = "app.Oto.hid-tap"
        thread.qualityOfService = QualityOfService.userInteractive
        handles.withLock { $0.thread = thread }
        thread.start()
        ready.wait()
    }

    func uninstall() {
        let snapshot: (runLoop: CFRunLoop?, thread: Thread?, stopped: DispatchSemaphore?) = handles.withLock { h in
            h.callbackBox?.clear()
            let result = (h.runLoop, h.thread, h.stoppedSemaphore)
            h.tap = nil
            h.runLoop = nil
            h.callbackBox = nil
            return result
        }
        guard let runLoop = snapshot.runLoop else { return }
        CFRunLoopStop(runLoop)
        if let stopped = snapshot.stopped, snapshot.thread !== Thread.current {
            _ = stopped.wait(timeout: .now() + .seconds(2))
        }
    }

    private static func installOptionalFnHIDManager(
        on runLoop: CFRunLoop?,
        context: UnsafeMutableRawPointer
    ) -> IOHIDManager? {
        guard let runLoop else { return nil }
        // Borrowed from Hex (physical_keys.rs): check existing Input Monitoring
        // access before opening so we never trigger an unwanted permission prompt.
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            return nil
        }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [[String: Int]] = [
            [
                kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
            ],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        IOHIDManagerRegisterInputValueCallback(manager, { ctx, _, _, value in
            guard let ctx else { return }
            let callbackBox = Unmanaged<TapCallbackBox>.fromOpaque(ctx).takeUnretainedValue()
            guard let monitor = callbackBox.monitor else { return }
            let element = IOHIDValueGetElement(value)
            let page = IOHIDElementGetUsagePage(element)
            let usage = IOHIDElementGetUsage(element)
            // Apple Vendor TopCase KeyboardFn (0x00FF / 0x0003) only: level-sensitive
            // physical hold state. Deliberately skips Consumer Globe (0x000C / 0x029D)
            // which pulses 1→0 on press on some keyboards and prematurely closes holds.
            guard page == 0x00FF && usage == 0x0003 else { return }
            let isDown = IOHIDValueGetIntegerValue(value) != 0
            monitor.handleHIDFn(isDown: isDown)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.commonModes.rawValue)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, CFRunLoopMode.commonModes.rawValue)
            return nil
        }
        return manager
    }

    deinit {
        uninstall()
    }
}
