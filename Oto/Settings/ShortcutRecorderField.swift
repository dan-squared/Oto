//
//  ShortcutRecorderField.swift
//  Oto
//

import AppKit
import Carbon.HIToolbox
import SwiftUI
import os

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
        case .notSet: return "Not set"
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
    /// The factory dictation set renders as one honest label. Unassigned
    /// renders no chips — the field shows its record placeholder instead.
    nonisolated static func chips(for kind: ShortcutTrigger.Kind) -> [String] {
        switch kind {
        case .unassigned:
            return []
        case .modifierHold(let code):
            return [holdChip(for: code)]
        case .functionKey(let codes):
            if isFactoryDictation(codes) { return ["Dictation key"] }
            return codes.sorted().map { keyName(for: UInt32($0)) }
        case .combo(let modifiers, let keyCode):
            return modifierGlyphs(modifiers) + [keyName(for: keyCode)]
        }
    }

    /// One-line label for sentences ("Hold Right ⌥ and speak." — sided,
    /// never ambiguous). Unassigned has no label; callers show record
    /// affordances instead (hold is never unassigned).
    nonisolated static func shortLabel(for kind: ShortcutTrigger.Kind) -> String {
        switch kind {
        case .unassigned:
            return "a shortcut"
        case .modifierHold(let code):
            return holdChip(for: code)
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
        return holdOptions.first(where: { $0.code == code })?.label ?? keyName(for: UInt32(code))
    }

    /// Sided chip for a held modifier ("Right ⌥", never bare "⌥" — both
    /// sides shared one glyph and users couldn't tell them apart).
    nonisolated static func holdChip(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Command: return "Left ⌘"
        case kVK_RightCommand: return "Right ⌘"
        case kVK_Shift: return "Left ⇧"
        case kVK_RightShift: return "Right ⇧"
        case kVK_Option: return "Left ⌥"
        case kVK_RightOption: return "Right ⌥"
        case kVK_Control: return "Left ⌃"
        case kVK_RightControl: return "Right ⌃"
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
            kVK_ANSI_Equal: "=", kVK_ANSI_Minus: "-",
            kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Quote: "'", kVK_ANSI_Semicolon: ";",
            kVK_ANSI_Backslash: "\\", kVK_ANSI_Comma: ",",
            kVK_ANSI_Slash: "/", kVK_ANSI_Period: ".",
            kVK_ANSI_Grave: "`",
            kVK_ANSI_Keypad0: "0", kVK_ANSI_Keypad1: "1",
            kVK_ANSI_Keypad2: "2", kVK_ANSI_Keypad3: "3",
            kVK_ANSI_Keypad4: "4", kVK_ANSI_Keypad5: "5",
            kVK_ANSI_Keypad6: "6", kVK_ANSI_Keypad7: "7",
            kVK_ANSI_Keypad8: "8", kVK_ANSI_Keypad9: "9",
            kVK_ANSI_KeypadDecimal: ".", kVK_ANSI_KeypadMultiply: "*",
            kVK_ANSI_KeypadPlus: "+", kVK_ANSI_KeypadClear: "Clear",
            kVK_ANSI_KeypadDivide: "/", kVK_ANSI_KeypadEnter: "Enter",
            kVK_ANSI_KeypadMinus: "-", kVK_ANSI_KeypadEquals: "=",
            kVK_Space: "Space", kVK_Tab: "Tab", kVK_Return: "Return",
            kVK_Delete: "Delete", kVK_ForwardDelete: "Delete",
            kVK_Escape: "Escape", kVK_CapsLock: "Caps Lock",
            kVK_Home: "Home", kVK_End: "End",
            kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
            kVK_Help: "Help", kVK_ContextualMenu: "Menu",
            kVK_ISO_Section: "§", kVK_JIS_Yen: "¥",
            kVK_JIS_Underscore: "_", kVK_JIS_KeypadComma: ",",
            kVK_JIS_Eisu: "Eisu",
            kVK_VolumeUp: "Volume Up", kVK_VolumeDown: "Volume Down",
            kVK_Mute: "Mute",
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

/// Local key-capture field for combo recording. While `isListening`, a
/// local monitor feeds presses into the pure rules; global registration
/// is already suspended by dispatch. Escape cancels (old kept), Delete
/// clears (disables), anything invalid beeps (old kept).
struct ShortcutRecorderModifier: ViewModifier {
    @Binding var isListening: Bool
    var onCapture: (UInt32, UInt32, [RecorderConflict]) -> Void
    var onCaptureModifier: (UInt16) -> Void
    var onClear: () -> Void
    var onCancel: () -> Void
    var onInvalid: (RecorderInvalidReason) -> Void
    /// The recorder surface can show the exact refused caps without making
    /// capture policy part of the shared monitor.
    var onInvalidInput: ((RecorderInvalidReason, UInt16, NSEvent.ModifierFlags) -> Void)? = nil

    @State private var box = MonitorBox()

    /// Standing trap for mystery keys (e.g. 241): invalid captures
    /// otherwise leave no trace — the combo path logs in the modal,
    /// but beeps never do. Key metadata only (codes, never keystroke
    /// streams), same privacy as the combo line. Logged through a
    /// static func (never `Self.` in monitor closures).
    private static let invalidLog = Logger(subsystem: "app.Oto", category: "shortcut")

    private static func logInvalid(keyCode: UInt16, mods: UInt, reason: String) {
        invalidLog.info("capture-invalid key=\(keyCode, privacy: .public) mods=\(mods, privacy: .public) reason=\(reason, privacy: .public)")
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                if isListening { start() }
            }
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
        box.token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [box] event in
            // Any keyDown ends a pending lone-modifier arm (the combo path
            // owns the gesture from here); priority order below is unchanged.
            box.flags.stepKeyDown()
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
                ShortcutRecorderModifier.logInvalid(keyCode: event.keyCode, mods: event.modifierFlags.rawValue, reason: String(describing: reason))
                onInvalid(reason)
                onInvalidInput?(reason, event.keyCode, event.modifierFlags)
            case .captured(let modifiers, let keyCode, let conflicts):
                onCapture(modifiers, keyCode, conflicts)
            case .captureModifier(let code):
                // Bare fn as keyDown (code 63): same staging as a flags
                // capture — both call sites already suspend, stop, log.
                onCaptureModifier(code)
            }
            return nil
        }
        // Bare modifiers emit flagsChanged, never keyDown — without this
        // monitor they are deafeningly silent (no beep, no message). Never
        // consumed: the system must keep seeing every modifier.
        box.flagsToken = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [box] event in
            guard let flag = FlagsCaptureState.nsFlag(for: event.keyCode) else { return event }
            let down = event.modifierFlags.contains(flag)
            let outcome = down
                ? box.flags.stepFlagsDown(code: event.keyCode)
                : box.flags.stepFlagsUp(code: event.keyCode)
            switch outcome {
            case .none:
                break
            case .capture(let code):
                onCaptureModifier(code)
            case .chord:
                ShortcutRecorderModifier.logInvalid(keyCode: event.keyCode, mods: event.modifierFlags.rawValue, reason: "chordOnly")
                onInvalid(.chordOnly)
                onInvalidInput?(.chordOnly, event.keyCode, event.modifierFlags)
            }
            return event
        }
    }

    private func stop() {
        if let token = box.token {
            NSEvent.removeMonitor(token)
            box.token = nil
        }
        if let token = box.flagsToken {
            NSEvent.removeMonitor(token)
            box.flagsToken = nil
        }
        box.flags.reset()
    }

    private final class MonitorBox {
        var token: Any?
        var flagsToken: Any?
        var flags = FlagsCaptureState()
    }
}

extension View {
    func shortcutRecorder(
        isListening: Binding<Bool>,
        onCapture: @escaping (UInt32, UInt32, [RecorderConflict]) -> Void,
        onCaptureModifier: @escaping (UInt16) -> Void = { _ in },
        onClear: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onInvalid: @escaping (RecorderInvalidReason) -> Void
    ) -> some View {
        modifier(ShortcutRecorderModifier(
            isListening: isListening,
            onCapture: onCapture,
            onCaptureModifier: onCaptureModifier,
            onClear: onClear,
            onCancel: onCancel,
            onInvalid: onInvalid
        ))
    }
}

/// The anchored recorder every shortcut row opens: Dictation's two slots and
/// onboarding's hold key. It owns the glass, the refusal red and the accept
/// green, and it always resumes dispatch when it goes — a recorder that is
/// left listening eats the keys the window needs (Return included).
struct ShortcutCapturePopover: View {
    let dispatch: ShortcutDispatch
    let slot: ShortcutSlot
    /// Called whenever the slot's value changes while the popover is still
    /// open (clear, capture), so the row behind it can redraw at once.
    var onChange: () -> Void = {}
    let onClose: () -> Void

    @State private var isListening = false
    @State private var message: String?
    @State private var modifierFlags: NSEvent.ModifierFlags = []
    @State private var modifierMonitor: Any?
    @State private var attemptedChips: [String] = []
    @State private var refusal: String?
    @State private var glow: OtoRecorderGlow.Tone?
    /// The slot has no shortcut: seeded on appear and flipped by Remove/⌫.
    /// Local because `ShortcutDispatch` is not observable — the popover's
    /// own answer must not wait for the row to re-render.
    @State private var isCleared = false
    @State private var closeTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(shownChips, id: \.self) { chip in
                    OtoKey(text: chip)
                }
                if !isCleared || !shownChips.isEmpty {
                    Text(attemptedChips.isEmpty ? "…and a key" : "not available")
                        .font(.callout)
                        .foregroundStyle(refusal == nil ? Color.secondary : Color.red)
                } else {
                    // An empty slot asks for a shortcut in the row's own
                    // words, so Remove and the pill tell the same story.
                    Text("Record shortcut")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 94)
            .background { OtoRecorderGlow(tone: glow) }
            .modifier(ShortcutRecorderModifier(
                isListening: $isListening,
                onCapture: { modifiers, keyCode, conflicts in
                    finishCapture(kind: .combo(modifiers: modifiers, keyCode: keyCode), conflicts: conflicts)
                },
                onCaptureModifier: { code in
                    finishCapture(kind: .modifierHold(keyCode: code), conflicts: [])
                },
                onClear: {
                    // ⌫ removes the shortcut instead of closing the glass:
                    // the recorder stays armed for the replacement, and the
                    // row behind it already reads "Record shortcut".
                    clearShortcut()
                },
                onCancel: {
                    dispatch.setSuspended(false)
                    isListening = false
                    onClose()
                },
                onInvalid: { reason in
                    NSSound.beep()
                    refuse(reason.message)
                },
                onInvalidInput: { _, keyCode, flags in
                    attemptedChips = Self.chips(for: keyCode, flags: flags)
                }
            ))

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }

            Divider()
            HStack(spacing: 8) {
                if !isCleared {
                    Button {
                        clearShortcut()
                    } label: {
                        HStack(spacing: 6) {
                            Text("Remove")
                            OtoKey(text: "⌫", compact: true)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Remove this shortcut")
                }
                Spacer()
                Button {
                    dispatch.setSuspended(false)
                    isListening = false
                    onClose()
                } label: {
                    HStack(spacing: 6) {
                        Text("Close")
                        OtoKey(text: "esc", compact: true)
                    }
                }
                .buttonStyle(.plain)
                .help("Close shortcut recorder")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .frame(width: 252)
        .presentationBackground(.ultraThinMaterial)
        .presentationCornerRadius(20)
        .onAppear {
            isCleared = currentKind == .unassigned
            dispatch.setSuspended(true)
            isListening = true
            modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                modifierFlags = event.modifierFlags
                attemptedChips = []
                refusal = nil
                glow = nil
                return event
            }
        }
        .onChange(of: isListening) { _, listening in
            if listening {
                modifierFlags = NSEvent.modifierFlags
                glow = nil
            } else {
                modifierFlags = []
            }
        }
        .onDisappear {
            dispatch.setSuspended(false)
            closeTask?.cancel()
            closeTask = nil
            if let modifierMonitor {
                NSEvent.removeMonitor(modifierMonitor)
                self.modifierMonitor = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .otoProbeClearRecorder)) { _ in
            // Probe-only (never posted in normal use): exercises the same
            // path as ⌫ so the cleared glass can be captured.
            clearShortcut()
        }
    }

    private var heldModifierChips: [String] {
        var chips: [String] = []
        if modifierFlags.contains(.control) { chips.append("⌃") }
        if modifierFlags.contains(.option) { chips.append("⌥") }
        if modifierFlags.contains(.shift) { chips.append("⇧") }
        if modifierFlags.contains(.command) { chips.append("⌘") }
        return chips
    }

    private var shownChips: [String] {
        attemptedChips.isEmpty ? heldModifierChips : attemptedChips
    }

    private static func chips(for keyCode: UInt16, flags: NSEvent.ModifierFlags) -> [String] {
        var chips: [String] = []
        if flags.contains(.control) { chips.append("⌃") }
        if flags.contains(.option) { chips.append("⌥") }
        if flags.contains(.shift) { chips.append("⇧") }
        if flags.contains(.command) { chips.append("⌘") }
        chips.append(KeyNames.keyName(for: UInt32(keyCode)))
        return chips
    }

    private func finishCapture(kind: ShortcutTrigger.Kind, conflicts: [RecorderConflict]) {
        guard !ShortcutRecorderConflicts.blocksSaving(conflicts) else {
            refuse(ShortcutRecorderConflicts.describe(conflicts))
            return
        }
        let trigger = ShortcutTrigger(kind: kind, interaction: slot == .hold ? .holdToTalk : .handsFree)
        let result = slot == .hold
            ? dispatch.updateHoldTrigger(trigger)
            : dispatch.updateHandsFreeTrigger(trigger)
        if result == .blocked {
            refuse("That shortcut is already in use by the other mode.")
        } else {
            accept()
        }
    }

    private func refuse(_ text: String) {
        message = text
        refusal = text
        glow = .refused
    }

    private var currentKind: ShortcutTrigger.Kind {
        slot == .hold ? dispatch.configuration.hold.kind : dispatch.configuration.handsFree.kind
    }

    /// Remove (and ⌫): the keys leave the slot, the glass stays. A recorder
    /// that closed on clear hid the one fact the person needed — that the
    /// shortcut was gone — behind a row still showing the old chips.
    private func clearShortcut() {
        dispatch.clearSlot(slot)
        attemptedChips = []
        refusal = nil
        message = nil
        glow = nil
        isCleared = true
        onChange()
    }

    /// A saved combination answers on the glass, then the popover goes: the
    /// row behind it already shows the new keys. Dispatch resumes at once so
    /// the shortcut is live during the flash.
    private func accept() {
        dispatch.setSuspended(false)
        isListening = false
        isCleared = false
        refusal = nil
        glow = .accepted
        onChange()
        closeTask?.cancel()
        closeTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            onClose()
        }
    }
}

/// Shared Firstlight-style recorder surface for shortcut rows outside
/// Dictation. Capture policy remains supplied by the owning feature.
struct TransformShortcutCapturePopover: View {
    @Binding var isListening: Bool
    /// Returns a refusal copy when the pressed combination cannot be saved.
    /// Keeping the popover open makes a failed record actionable.
    let onCapture: (UInt32, UInt32, [RecorderConflict]) -> String?
    let onCaptureModifier: (UInt16) -> String?
    let onClear: () -> Void
    let onCancel: () -> Void
    let onInvalid: (RecorderInvalidReason) -> Void

    @State private var attemptedChips: [String] = []
    @State private var refusal: String?
    @State private var glow: OtoRecorderGlow.Tone?
    /// Capture and presentation are separate: a saved combination stops the
    /// monitor at once but keeps the popover up for the green flash, and only
    /// then clears `isListening` so the parent dismisses it.
    @State private var capturing = true
    @State private var closeTask: Task<Void, Never>?

    @State private var modifierFlags: NSEvent.ModifierFlags = []
    @State private var monitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(shownChips, id: \.self) { chip in
                    OtoKey(text: chip)
                }
                Text(attemptedChips.isEmpty ? "…and a key" : "not available")
                    .font(.system(size: 11))
                    .foregroundStyle(refusal == nil ? Color.secondary : Color.red)
            }
            .frame(maxWidth: .infinity, minHeight: 94)
            .background { OtoRecorderGlow(tone: glow) }
            .modifier(ShortcutRecorderModifier(
                isListening: $capturing,
                onCapture: { modifiers, keyCode, conflicts in
                    if let message = onCapture(modifiers, keyCode, conflicts) {
                        refuse(message)
                        attemptedChips = Self.chips(for: UInt16(keyCode), flags: NSEvent.modifierFlags)
                    } else {
                        accept()
                    }
                },
                onCaptureModifier: { code in
                    if let message = onCaptureModifier(code) {
                        refuse(message)
                        attemptedChips = [KeyNames.holdChip(for: code)]
                    } else {
                        accept()
                    }
                },
                onClear: onClear,
                onCancel: onCancel,
                onInvalid: onInvalid,
                onInvalidInput: { reason, keyCode, flags in
                    refuse(reason.message)
                    attemptedChips = Self.chips(for: keyCode, flags: flags)
                }
            ))

            Divider()
            HStack {
                Spacer()
                Button {
                    isListening = false
                    onCancel()
                } label: {
                    HStack(spacing: 6) {
                        Text("Close")
                        OtoKey(text: "esc", compact: true)
                    }
                }
                .buttonStyle(.plain)
                .help("Close shortcut recorder")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .frame(width: 252)
        .presentationBackground(.ultraThinMaterial)
        .presentationCornerRadius(20)
        .onAppear {
            capturing = true
            modifierFlags = NSEvent.modifierFlags
            monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                modifierFlags = event.modifierFlags
                attemptedChips = []
                refusal = nil
                glow = nil
                return event
            }
        }
        .onDisappear {
            closeTask?.cancel()
            closeTask = nil
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }

    private func refuse(_ message: String) {
        refusal = message
        glow = .refused
    }

    /// The combination landed: stop hearing keys, answer on the glass, then
    /// let the parent dismiss the popover once the green has been seen.
    private func accept() {
        capturing = false
        refusal = nil
        glow = .accepted
        closeTask?.cancel()
        closeTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            isListening = false
        }
    }

    private var heldModifierChips: [String] {
        var chips: [String] = []
        if modifierFlags.contains(.control) { chips.append("⌃") }
        if modifierFlags.contains(.option) { chips.append("⌥") }
        if modifierFlags.contains(.shift) { chips.append("⇧") }
        if modifierFlags.contains(.command) { chips.append("⌘") }
        return chips
    }

    private var shownChips: [String] {
        attemptedChips.isEmpty ? heldModifierChips : attemptedChips
    }

    private static func chips(for keyCode: UInt16, flags: NSEvent.ModifierFlags) -> [String] {
        var chips: [String] = []
        if flags.contains(.control) { chips.append("⌃") }
        if flags.contains(.option) { chips.append("⌥") }
        if flags.contains(.shift) { chips.append("⇧") }
        if flags.contains(.command) { chips.append("⌘") }
        chips.append(KeyNames.keyName(for: UInt32(keyCode)))
        return chips
    }
}
