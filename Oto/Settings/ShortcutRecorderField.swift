//
//  ShortcutRecorderField.swift
//  Oto
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Product combo recorder + conflict copy + calibration text. Migrated
/// from the Phase 3 diagnostics section with logic unchanged — only the
/// label died. The classification rules, Escape-cancels, Delete-clears, and invalid-beeps
/// behavior are unchanged and stay covered by `ShortcutRecorderTests`.
enum ShortcutRecorderConflicts {
    nonisolated static func blocksSaving(_ conflicts: [RecorderConflict]) -> Bool {
        conflicts.contains {
            switch $0 {
            case .disallowed: return true
            case .systemShortcut: return false
            }
        }
    }

    nonisolated static func describe(_ conflicts: [RecorderConflict]) -> String {
        conflicts.map { conflict in
            switch conflict {
            case .systemShortcut: return "Also a system shortcut — saved anyway."
            case .disallowed(let reason): return "Blocked: \(reason)"
            }
        }.joined(separator: " ")
    }
}

extension ShortcutDispatch {
    /// Human-readable calibration for the test-shortcut row. Set ONLY by
    /// observed real global events — never by the recorder.
    var calibrationText: String {
        Self.describe(calibration)
    }

    /// Per-slot calibration text for the dual-slot rows.
    func calibrationText(for slot: ShortcutSlot) -> String {
        Self.describe(slot == .hold ? calibrationHold : calibrationHandsFree)
    }

    private nonisolated static func describe(_ calibration: ShortcutCalibration) -> String {
        switch calibration {
        case .untested: return "Untested"
        case .ready: return "Ready"
        case .notReceivedGlobally: return "Not detected yet"
        case .conflicts: return "Conflicts with another shortcut"
        case .requiresAccessibility: return "Requires Accessibility"
        }
    }
}

/// Human key names for keycap chips and labels. Pure table over `kVK_`
/// constants (never hand-written hex) with a `"key <code>"` fallback only
/// when truly unknown. Tested.
enum KeyNames: Sendable {
    /// Single key name: letters as capitals, words for named keys.
    nonisolated static func keyName(for keyCode: UInt32) -> String {
        if let name = table[Int(keyCode)] { return name }
        return "key \(keyCode)"
    }

    /// Carbon modifier mask → glyphs in reference order (⌃⌥⇧⌘).
    nonisolated static func modifierGlyphs(_ carbonMask: UInt32) -> [String] {
        var glyphs: [String] = []
        if carbonMask & UInt32(CarbonModifiers.control) != 0 { glyphs.append("⌃") }
        if carbonMask & UInt32(CarbonModifiers.option) != 0 { glyphs.append("⌥") }
        if carbonMask & UInt32(CarbonModifiers.shift) != 0 { glyphs.append("⇧") }
        if carbonMask & UInt32(CarbonModifiers.command) != 0 { glyphs.append("⌘") }
        return glyphs
    }

    /// Chips for a keycap field, in reference order (modifiers then key).
    /// The factory dictation set renders as one honest label.
    nonisolated static func chips(for kind: ShortcutTrigger.Kind) -> [String] {
        switch kind {
        case .modifierHold(let code):
            return [holdGlyph(for: code)]
        case .functionKey(let codes):
            if isFactoryDictation(codes) { return ["Dictation key"] }
            return codes.sorted().map { keyName(for: UInt32($0)) }
        case .combo(let modifiers, let keyCode):
            return modifierGlyphs(modifiers) + [keyName(for: keyCode)]
        }
    }

    /// One-line label for sentences ("Hold ⌥ and speak.").
    nonisolated static func shortLabel(for kind: ShortcutTrigger.Kind) -> String {
        switch kind {
        case .modifierHold(let code):
            return holdGlyph(for: code)
        case .functionKey(let codes):
            if isFactoryDictation(codes) { return "the Dictation key" }
            return codes.sorted().map { keyName(for: UInt32($0)) }.joined(separator: " ")
        case .combo(let modifiers, let keyCode):
            return (modifierGlyphs(modifiers) + [keyName(for: keyCode)]).joined()
        }
    }

    nonisolated static func isFactoryDictation(_ codes: Set<Int64>) -> Bool {
        codes == Set([Int64(kVK_F5), 176])
    }

    /// All holdable modifier keys, sided, for the hold-key menu.
    nonisolated static var holdOptions: [(label: String, code: UInt16)] {
        [
            ("fn", UInt16(kVK_Function)),
            ("Left Control", UInt16(kVK_Control)),
            ("Right Control", UInt16(kVK_RightControl)),
            ("Left Option", UInt16(kVK_Option)),
            ("Right Option", UInt16(kVK_RightOption)),
            ("Left Command", UInt16(kVK_Command)),
            ("Right Command", UInt16(kVK_RightCommand)),
            ("Left Shift", UInt16(kVK_Shift)),
            ("Right Shift", UInt16(kVK_RightShift)),
        ]
    }

    /// Current hold-key menu label for a kind (glyph + side when known).
    nonisolated static func holdMenuLabel(for kind: ShortcutTrigger.Kind) -> String {
        guard case .modifierHold(let code) = kind else { return "Hold key" }
        return holdOptions.first(where: { $0.code == code })?.label ?? holdGlyph(for: code)
    }

    private nonisolated static func holdGlyph(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Command, kVK_RightCommand: return "⌘"
        case kVK_Shift, kVK_RightShift: return "⇧"
        case kVK_Option, kVK_RightOption: return "⌥"
        case kVK_Control, kVK_RightControl: return "⌃"
        case kVK_Function: return "fn"
        default: return keyName(for: UInt32(keyCode))
        }
    }

    private nonisolated static var table: [Int: String] {
        [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_Space: "Space", kVK_Tab: "Tab", kVK_Return: "Return",
            kVK_Delete: "Delete", kVK_ForwardDelete: "Delete",
            kVK_Escape: "Escape",
            kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_DownArrow: "↓", kVK_UpArrow: "↑",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
            kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16",
            kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
            kVK_Function: "fn",
        ]
    }
}

/// One slot's kind picker. Bare-modifier and F-key capture are NOT in the
/// recorder; they arrive via these presets (Hold key / Dictation key),
/// mirroring the old TriggerChoice — zero new validation rules.
enum SlotKindChoice: String, CaseIterable, Identifiable {
    case holdKey = "Hold key"
    case dictationKey = "Dictation key"
    case combo = "Custom"

    var id: String { rawValue }
}

/// Local key-capture field for combo recording. While `isListening`, a
/// local monitor feeds presses into the pure rules; global registration
/// is already suspended by dispatch. Escape cancels (old kept), Delete
/// clears (disables), anything invalid beeps (old kept).
struct ShortcutRecorderModifier: ViewModifier {
    @Binding var isListening: Bool
    var onCapture: (UInt32, UInt32, [RecorderConflict]) -> Void
    var onClear: () -> Void
    var onCancel: () -> Void
    var onInvalid: (RecorderInvalidReason) -> Void

    @State private var box = MonitorBox()

    func body(content: Content) -> some View {
        content
            .onChange(of: isListening) { _, listening in
                if listening {
                    start()
                } else {
                    stop()
                }
            }
            .onDisappear {
                stop()
            }
    }

    private func start() {
        stop()
        // Snapshot once per listening session; the list cannot change
        // meaningfully mid-capture.
        let system = CarbonHotKeyCenter.enabledSystemShortcuts()
        box.token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Tab moves focus (bubbled); everything else is consumed.
            if event.keyCode == UInt16(kVK_Tab), event.modifierFlags.isEmpty {
                return event
            }
            let outcome = ShortcutRecorderRules.classify(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags,
                systemShortcuts: system
            )
            // Handled synchronously; the callbacks below only set UI state.
            switch outcome {
            case .cancelled:
                onCancel()
            case .cleared:
                onClear()
            case .invalid(let reason):
                onInvalid(reason)
            case .captured(let modifiers, let keyCode, let conflicts):
                onCapture(modifiers, keyCode, conflicts)
            }
            return nil
        }
    }

    private func stop() {
        if let token = box.token {
            NSEvent.removeMonitor(token)
            box.token = nil
        }
    }

    private final class MonitorBox {
        var token: Any?
    }
}

extension View {
    func shortcutRecorder(
        isListening: Binding<Bool>,
        onCapture: @escaping (UInt32, UInt32, [RecorderConflict]) -> Void,
        onClear: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onInvalid: @escaping (RecorderInvalidReason) -> Void
    ) -> some View {
        modifier(ShortcutRecorderModifier(
            isListening: isListening,
            onCapture: onCapture,
            onClear: onClear,
            onCancel: onCancel,
            onInvalid: onInvalid
        ))
    }
}
