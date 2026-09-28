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

/// Single HID event tap owning ALL global key detection: function-row
/// keys AND bare-modifier hold. One tap, one runloop source.
///
/// WHY THIS EXISTS: NSEvent monitors (global AND local) wedge
/// MenuBarExtra menu tracking on this macOS — proven by bisect (menu
/// works with monitors off, freezes with either flagsChanged monitor
/// on). A CGEvent tap lives below AppKit tracking and is immune by
/// construction. Cost: the default trigger now requires Accessibility
/// trust (tapCreate fails without it) — consistent with 07 §5.2, and
/// Phase 4 insertion needs AX regardless.
///
/// Rules:
/// - Function keys: bare press only, repeats tracked, matched releases
///   consumed (keeps macOS dictation from firing alongside).
/// - Modifier hold: flagsChanged press/release, NEVER consumed (the
///   system must still see Option held for app-switching etc.). Any
///   other key/mouse-down while held marks combination-use and swallows
///   the release — holding Option to type `•` never dictates.
/// - Tap timeout/deactivation → re-enable + `monitorLost` (02 rule 5).
/// - Empty configuration uninstalls: not in the key path at all unless
///   the person asked for it.
@MainActor
final class HIDEventMonitor {
    /// Emitted for normalized physical events. Synchronous, value-only.
    var onEvent: ((ShortcutEvent) -> Void)?
    /// Escape was pressed (observed only — never consumed; it still reaches
    /// the focused app). Wired to coordinator cancel by dispatch.
    var onEscape: (() -> Void)?

    private(set) var isLive = false

    private var functionCodes: Set<Int64> = []
    private var holdCode: UInt16?
    private var escapeObserved = false
    private var hold = ModifierHoldState()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pressedFunctionCode: Int64?

    // MARK: - Dual-slot path (hold + hands-free live together)

    /// Tagged events for the dual-slot dispatch. Set only by the slot-tagged
    /// `configure` below; the legacy `onEvent` stays silent in slot mode so
    /// the two paths never double-emit.
    var onSlotEvent: ((ShortcutEvent, ShortcutSlot) -> Void)?

    /// Whether the last `configure` was the slot-tagged one. Decides which
    /// decision layer the C callback drives.
    private var slotMode = false
    private var holdSlots: [UInt16: ShortcutSlot] = [:]
    private var functionSlots: [Int64: ShortcutSlot] = [:]
    private var slotHolds: [UInt16: ModifierHoldState] = [:]
    private var pressedFunction: (code: Int64, slot: ShortcutSlot)?

    /// Slot-tagged configuration: two hold codes + a function-code→slot map
    /// multiplexed over the ONE tap, with a single shared Escape observation.
    /// Single-slot convenience for the legacy path is preserved separately
    /// below (existing decide-matrix tests keep passing unmodified).
    func configure(
        holdSlots: [UInt16: ShortcutSlot],
        functionSlots: [Int64: ShortcutSlot],
        escapeObserved: Bool = true
    ) {
        self.holdSlots = holdSlots
        self.functionSlots = functionSlots
        self.escapeObserved = escapeObserved
        slotMode = true
        slotHolds = Dictionary(uniqueKeysWithValues: holdSlots.keys.map { ($0, ModifierHoldState()) })
        pressedFunction = nil
        // Clear legacy state so the paths never mix.
        functionCodes = []
        holdCode = nil
        hold = ModifierHoldState()
        pressedFunctionCode = nil
        sync()
        isLive = tap != nil
    }

    // MARK: - Legacy single-slot path (unchanged)

    func configure(functionCodes: Set<Int64>, holdKeyCode: UInt16?, escapeObserved: Bool = true) {
        self.functionCodes = functionCodes
        self.holdCode = holdKeyCode
        // Escape observation defaults ON whenever the tap lives: cancel
        // must work on every trigger kind (combo triggers have no other
        // Escape backend since NSEvent monitors are banned).
        self.escapeObserved = escapeObserved
        hold = ModifierHoldState()
        pressedFunctionCode = nil
        slotMode = false
        holdSlots = [:]
        functionSlots = [:]
        slotHolds = [:]
        pressedFunction = nil
        sync()
        isLive = tap != nil
    }

    func stop() {
        uninstall()
        functionCodes = []
        holdCode = nil
        hold = ModifierHoldState()
        pressedFunctionCode = nil
        slotMode = false
        holdSlots = [:]
        functionSlots = [:]
        slotHolds = [:]
        pressedFunction = nil
        isLive = false
    }

    /// Read-only combination-use probe: true when another key/mouse went
    /// down while this hold code was held (fn+arrows, fn+click, …). Lets
    /// fn-hold confirmation drop system gestures instead of committing.
    func isInCombination(code: UInt16) -> Bool {
        if let state = slotHolds[code] { return state.usedInCombination }
        if holdCode == code { return hold.usedInCombination }
        return false
    }

    func noteMonitorLost() {
        hold = ModifierHoldState()
        pressedFunctionCode = nil
        slotHolds = Dictionary(uniqueKeysWithValues: slotHolds.keys.map { ($0, ModifierHoldState()) })
        pressedFunction = nil
        if slotMode {
            // Both transition machines reset their local pressed state; the
            // coordinator owns the session outcome either way.
            onSlotEvent?(.monitorLost, .hold)
            onSlotEvent?(.monitorLost, .handsFree)
        } else {
            onEvent?(.monitorLost)
        }
    }

    // MARK: - Private

    private func sync() {
        if functionCodes.isEmpty, holdCode == nil, !escapeObserved {
            uninstall()
        } else {
            install()
        }
    }

    private func install() {
        guard tap == nil else { return }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HIDEventMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(
                (1 << CGEventType.keyDown.rawValue)
                    | (1 << CGEventType.keyUp.rawValue)
                    | (1 << CGEventType.flagsChanged.rawValue)
                    | (1 << CGEventType.leftMouseDown.rawValue)
                    | (1 << CGEventType.rightMouseDown.rawValue)
                    | (1 << CGEventType.otherMouseDown.rawValue)
            ),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // tapCreate fails without Accessibility trust. Choice is kept;
            // sync() retries on next launch/trigger change/activation, and
            // dispatch reports unavailable meanwhile.
            return
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func uninstall() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.tap = nil
        }
    }

    /// Runs from a C callback on the main runloop: the consume decision is
    /// synchronous HERE; actions hop async. Never blocks, never awaits.
    private nonisolated func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The tap lives on the main runloop; anything else means the
        // assumeIsolated below would trap. Pass through unconsumed (safe
        // default) and canary in Debug — symmetric with CarbonHotKey.
        guard Thread.isMainThread else {
            assertionFailure("HID event tap must run on the main runloop.")
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DispatchQueue.main.async { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, let tap = self.tap else { return }
                    CGEvent.tapEnable(tap: tap, enable: true)
                    self.noteMonitorLost()
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown || type == .keyUp || type == .flagsChanged
            || type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
        else {
            return Unmanaged.passUnretained(event)
        }

        // Sendable snapshot before the isolation boundary: the non-Sendable
        // CGEvent must not cross into the @Sendable assumeIsolated body
        // (Swift 6 region isolation). Field reads are valid synchronously.
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let flags = event.flags
        if MainActor.assumeIsolated({ self.slotMode }) {
            let routed: (slot: ShortcutSlot?, emit: ShortcutEvent?, consume: Bool) = MainActor.assumeIsolated {
                self.decideRouted(type: type, keyCode: keyCode, isRepeat: isRepeat, flags: flags)
            }
            if let emit = routed.emit, let slot = routed.slot {
                DispatchQueue.main.async { [weak self] in self?.onSlotEvent?(emit, slot) }
            }
            return routed.consume ? nil : Unmanaged.passUnretained(event)
        }
        let decided: (emit: ShortcutEvent?, consume: Bool) = MainActor.assumeIsolated {
            self.decide(type: type, keyCode: keyCode, isRepeat: isRepeat, flags: flags)
        }

        if let emit = decided.emit {
            DispatchQueue.main.async { [weak self] in self?.onEvent?(emit) }
        }
        return decided.consume ? nil : Unmanaged.passUnretained(event)
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
        switch type {
        case .flagsChanged:
            return decideHold(keyCode: keyCode, flags: flags)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Mouse press while holding = combination use (Option-click).
            // Never consumed.
            _ = hold.step(.otherActivity)
            return (nil, false)
        case .keyDown:
            // Any real press while holding marks combination use (the
            // emission below is independent of it).
            _ = hold.step(.otherActivity)
            if escapeObserved, keyCode == Int64(kVK_Escape) {
                // Observed only — Escape always passes through to the
                // focused app AND cancels our session. Async hop below.
                let onEscape = onEscape
                DispatchQueue.main.async { onEscape?() }
                return (nil, false)
            }
            return decideFunction(keyCode: keyCode, isRepeat: isRepeat, flags: flags, isDown: true)
        case .keyUp:
            _ = hold.step(.otherActivity)
            return decideFunction(keyCode: keyCode, isRepeat: false, flags: flags, isDown: false)
        default:
            return (nil, false)
        }
    }

    private func decideHold(keyCode: Int64, flags: CGEventFlags) -> (emit: ShortcutEvent?, consume: Bool) {
        guard let holdCode, keyCode == Int64(holdCode) else {
            return (nil, false)
        }
        guard let flag = ModifierHoldState.flag(for: holdCode) else {
            return (nil, false)
        }
        let down = flags.contains(flag)
        // NEVER consume flagsChanged: the system must still see Option
        // held for app-switching, typing, and everything else.
        return (hold.step(.flags(down: down)), false)
    }

    func decideFunction(
        keyCode: Int64,
        isRepeat: Bool,
        flags: CGEventFlags,
        isDown: Bool
    ) -> (emit: ShortcutEvent?, consume: Bool) {
        if isDown {
            if isRepeat {
                // Repeat of the tracked press: report it (the transition
                // machine ignores repeats), keep consuming so the key
                // never types through mid-hold.
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
            // Releases match by tracking (not flags): a bare press held
            // across a Shift tap must still finish on release, never stick.
            guard functionCodes.contains(keyCode), pressedFunctionCode == keyCode else {
                return (nil, false)
            }
            pressedFunctionCode = nil
            return (.keyUp, true)
        }
    }

    /// Slot-tagged decision layer for dual-slot mode. Same rules as the
    /// legacy `decide` above, routed per key: each hold code steps its own
    /// `ModifierHoldState`, each function code maps to its slot, and
    /// combination-use marks every held slot. Exposed internal for the
    /// dual decide-matrix tests; the C callback and tap lifecycle stay
    /// private, exactly like the legacy layer.
    func decideRouted(
        type: CGEventType,
        keyCode: Int64,
        isRepeat: Bool,
        flags: CGEventFlags
    ) -> (slot: ShortcutSlot?, emit: ShortcutEvent?, consume: Bool) {
        switch type {
        case .flagsChanged:
            return decideRoutedHold(keyCode: keyCode, flags: flags)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            markAllHoldsCombinationUse()
            return (nil, nil, false)
        case .keyDown:
            markAllHoldsCombinationUse()
            if escapeObserved, keyCode == Int64(kVK_Escape) {
                let onEscape = onEscape
                DispatchQueue.main.async { onEscape?() }
                return (nil, nil, false)
            }
            return decideRoutedFunction(keyCode: keyCode, isRepeat: isRepeat, flags: flags, isDown: true)
        case .keyUp:
            markAllHoldsCombinationUse()
            return decideRoutedFunction(keyCode: keyCode, isRepeat: false, flags: flags, isDown: false)
        default:
            return (nil, nil, false)
        }
    }

    private func decideRoutedHold(keyCode: Int64, flags: CGEventFlags) -> (slot: ShortcutSlot?, emit: ShortcutEvent?, consume: Bool) {
        let code = UInt16(clamping: keyCode)
        guard let slot = holdSlots[code], keyCode == Int64(code) else {
            return (nil, nil, false)
        }
        guard let flag = ModifierHoldState.flag(for: code) else {
            return (nil, nil, false)
        }
        let down = flags.contains(flag)
        var state = slotHolds[code] ?? ModifierHoldState()
        let emit = state.step(.flags(down: down))
        slotHolds[code] = state
        // NEVER consume flagsChanged: the system must still see the modifier.
        return (slot, emit, false)
    }

    private func markAllHoldsCombinationUse() {
        for code in slotHolds.keys {
            _ = slotHolds[code]?.step(.otherActivity)
        }
    }

    private func decideRoutedFunction(
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
}

/// Pure bare-modifier hold tracking: press → down, clean release → up,
/// release-after-other-activity → swallowed. No hardware, no async.
struct ModifierHoldState: Equatable, Sendable {
    private(set) var isDown = false
    private(set) var usedInCombination = false

    enum HoldEvent: Equatable, Sendable {
        case flags(down: Bool)
        case otherActivity
    }

    nonisolated mutating func step(_ event: HoldEvent) -> ShortcutEvent? {
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
        case .otherActivity:
            if isDown { usedInCombination = true }
            return nil
        }
    }

    /// CGEvent flag family for a modifier key code.
    nonisolated static func flag(for keyCode: UInt16) -> CGEventFlags? {
        switch keyCode {
        case UInt16(kVK_Shift), UInt16(kVK_RightShift): return .maskShift
        case UInt16(kVK_Command), UInt16(kVK_RightCommand): return .maskCommand
        case UInt16(kVK_Option), UInt16(kVK_RightOption): return .maskAlternate
        case UInt16(kVK_Control), UInt16(kVK_RightControl): return .maskControl
        case UInt16(kVK_Function): return .maskSecondaryFn
        default: return nil
        }
    }
}
