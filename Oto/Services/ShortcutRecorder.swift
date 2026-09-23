//
//  ShortcutRecorder.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import AppKit
import Carbon.HIToolbox
import Foundation

/// Recorder validation outcome. The old value is preserved on every path
/// except a fully valid, conflict-cleared capture (07 §5.2 + 10_NEXT_STEP).
enum RecorderOutcome: Equatable, Sendable {
    /// Escape or blur without capture: keep old, no message.
    case cancelled
    /// Delete/backspace with empty modifiers: clear to unassigned.
    case cleared
    /// Invalid (modifier-only, plain letter, bare shift): keep old + beep.
    case invalid
    /// Valid combo captured; conflicts listed for the UI to present.
    case captured(modifiers: UInt32, keyCode: UInt32, conflicts: [RecorderConflict])

    // Explicit: compared in tests from nonisolated contexts (Swift 6).
    nonisolated static func == (lhs: RecorderOutcome, rhs: RecorderOutcome) -> Bool {
        switch (lhs, rhs) {
        case (.cancelled, .cancelled), (.cleared, .cleared), (.invalid, .invalid):
            return true
        case (.captured(let lm, let lk, let lc), .captured(let rm, let rk, let rc)):
            return lm == rm && lk == rk && lc == rc
        default:
            return false
        }
    }
}

/// A conflict the UI must present before saving (policy: system WARNS,
/// sandboxed-disallowed BLOCKS — from the 3.1.0 reference `ConflictPolicy`,
/// Oto-owned). Note: no menu-item check — Oto cannot enumerate other apps'
/// menus, and its own menu is trivial, so that branch was dead in
/// production (audit D4) and is gone rather than kept as theater.
enum RecorderConflict: Equatable, Sendable {
    case systemShortcut
    case disallowed(reason: String)

    // Explicit: compared in tests and UI copy from any domain (Swift 6).
    nonisolated static func == (lhs: RecorderConflict, rhs: RecorderConflict) -> Bool {
        switch (lhs, rhs) {
        case (.systemShortcut, .systemShortcut):
            return true
        case (.disallowed(let a), .disallowed(let b)):
            return a == b
        default:
            return false
        }
    }
}

/// Pure recorder rules: NSEvent → outcome. No monitors, no side effects —
/// exhaustively unit-tested. The view owns the local key-down monitor and
/// feeds events here; global registration is suspended while listening
/// (dispatch owns that).
enum ShortcutRecorderRules: Sendable {
    /// Pure NSEvent → outcome mapping: `nonisolated` (Swift 6).
    nonisolated static func classify(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        systemShortcuts: [(keyCode: Int, modifiers: Int)]
    ) -> RecorderOutcome {
        let relevant = modifiers.intersection([.command, .shift, .option, .control])

        // Escape with no modifiers: cancel, keep old.
        if keyCode == UInt16(kVK_Escape), relevant.isEmpty {
            return .cancelled
        }

        // Delete with no modifiers: clear to unassigned.
        if keyCode == UInt16(kVK_Delete) || keyCode == UInt16(kVK_ForwardDelete),
           relevant.isEmpty
        {
            return .cleared
        }

        // A combo needs a real modifier (shift alone never works) or a
        // function key. Bare modifiers are held via the modifier-hold
        // path, never recorded as combos: invalid keeps the old value.
        let isFunction = Self.functionKeyCodes.contains(keyCode)
        let hasRealModifier = !relevant.subtracting([.shift, .function]).isEmpty
        guard hasRealModifier || isFunction else {
            return .invalid
        }

        let carbon = relevant.carbonMask
        var conflicts: [RecorderConflict] = []

        if systemShortcuts.contains(where: { $0.keyCode == Int(keyCode) && $0.modifiers == carbon }) {
            conflicts.append(.systemShortcut)
        }
        if isReservedSystemCombo(modifiers: carbon, keyCode: keyCode) {
            conflicts.append(.disallowed(reason: "Reserved by the system on this macOS version."))
        }
        return .captured(modifiers: UInt32(carbon), keyCode: UInt32(keyCode), conflicts: conflicts)
    }

    /// F1–F12 key codes for the bare-shift exception. Explicit list —
    /// no range tricks (a malformed range traps the whole test runner).
    nonisolated static var functionKeyCodes: Set<UInt16> {
        [
            UInt16(kVK_F1), UInt16(kVK_F2), UInt16(kVK_F3),
            UInt16(kVK_F4), UInt16(kVK_F5), UInt16(kVK_F6),
            UInt16(kVK_F7), UInt16(kVK_F8), UInt16(kVK_F9),
            UInt16(kVK_F10), UInt16(kVK_F11), UInt16(kVK_F12),
        ]
    }

    /// Combos the system reserves regardless of sandbox state (Spotlight
    /// ⌘Space, Siri/dictation system keys, lock-screen class combos).
    /// Conservative best-effort list; device-matrix findings extend it,
    /// never shrink validation silently. (Was `isDisallowedInSandbox` —
    /// renamed when the app went unsandboxed; the reservation is a
    /// system property, not a sandbox one.)
    nonisolated static func isReservedSystemCombo(modifiers: Int, keyCode: UInt16) -> Bool {
        // Spotlight (⌘Space), Siri/dictation system keys, and lock-screen
        // class combos never reach a sandboxed app.
        if modifiers == CarbonModifiers.command, keyCode == UInt16(kVK_Space) {
            return true
        }
        return false
    }
}
