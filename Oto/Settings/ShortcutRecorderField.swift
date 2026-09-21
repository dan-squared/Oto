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

    nonisolated static func describeCombo(modifiers: UInt32, keyCode: UInt32) -> String {
        var parts: [String] = []
        if modifiers & UInt32(CarbonModifiers.command) != 0 { parts.append("⌘") }
        if modifiers & UInt32(CarbonModifiers.shift) != 0 { parts.append("⇧") }
        if modifiers & UInt32(CarbonModifiers.option) != 0 { parts.append("⌥") }
        if modifiers & UInt32(CarbonModifiers.control) != 0 { parts.append("⌃") }
        parts.append("key \(keyCode)")
        return parts.joined()
    }
}

extension ShortcutDispatch {
    /// Human-readable calibration for the test-shortcut row. Set ONLY by
    /// observed real global events — never by the recorder.
    var calibrationText: String {
        switch calibration {
        case .untested: return "Untested"
        case .ready: return "Ready"
        case .notReceivedGlobally: return "Not received globally"
        case .conflicts: return "Conflicts with another shortcut"
        case .requiresAccessibility: return "Requires Accessibility"
        }
    }
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
    var onInvalid: () -> Void

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
            case .invalid:
                onInvalid()
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
        onInvalid: @escaping () -> Void
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
