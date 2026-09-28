//
//  ShortcutModal.swift
//  Oto
//
//  Reference-shaped Shortcuts sheet: one card per live slot with keycap
//  chips, pencil/trash affordances, kind presets, and a Reset/Done footer.
//  All edits stage locally; Done applies through the dispatch gate, ✕
//  discards. A blocked save offers Swap (atomic exchange, safe by
//  construction) instead of a dead-end refusal.
//
//  Frameless-sheet rule: the sheet window is the only frame — NO Form,
//  GroupBox, List, or background panel inside. Plain ScrollView + VStack +
//  cards. The recorder rules, local monitor, and suspend discipline are
//  reused verbatim from ShortcutRecorderField.
//

import Carbon.HIToolbox
import SwiftUI
import os

/// One slot's keycap-chip field: live-or-staged binding as chips, pencil to
/// re-record, trash to stage a clear. The combo recorder rides the field;
/// only one card records at a time (the other disables).
struct KeycapField: View {
    let chips: [String]
    let isRecording: Bool
    let disabled: Bool
    /// Shown when no binding is staged or saved (opt-in slot).
    let emptyPlaceholder: String
    /// Trash tooltip; differs when there is nothing to clear.
    let trashHelp: String
    let onArm: () -> Void
    let onTrash: () -> Void
    var recorder: ShortcutRecorderModifier

    var body: some View {
        HStack(spacing: 8) {
            Button {
                onArm()
            } label: {
                HStack(spacing: 4) {
                    if isRecording {
                        Text("Press your shortcut…")
                            .foregroundStyle(.secondary)
                    } else if chips.isEmpty {
                        Text(emptyPlaceholder)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(chips, id: \.self) { chip in
                            Text(chip)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(disabled)

            Button {
                onTrash()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .help("Clear (shortcuts turn off when you press Done)")
        }
        .modifier(recorder)
    }
}

struct ShortcutModal: View {
    let dispatch: ShortcutDispatch
    @Environment(\.dismiss) private var dismiss

    /// Capture trail: key metadata only (codes, never keystroke streams).
    /// Names the mystery keys (e.g. key 241) at their source.
    private let log = Logger(subsystem: "app.Oto", category: "shortcut")

    @State private var staging = ShortcutStaging(live: .default())
    @State private var isRecordingHold = false
    @State private var isRecordingHandsFree = false
    @State private var holdMessage: String?
    @State private var handsFreeMessage: String?
    @State private var showSwapHold = false
    @State private var showSwapHandsFree = false

    private static let recorderHint =
        "Combinations like ⌘⇧D record here — bare keys live in presets below. Delete clears, Escape cancels."

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shortcuts")
                        .font(.title2)
                        .bold()
                    Text("Two ways to talk. Click a shortcut to change it.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Discard changes")
            }

            slotCard(
                slot: .hold,
                title: "Push to talk",
                subtitle: "Hold to say something short"
            )
            slotCard(
                slot: .handsFree,
                title: "Hands-free mode",
                subtitle: "Press once to start, press again to stop"
            )

            HStack {
                Button("Reset to default") {
                    resetToDefaults()
                }
                .disabled(isRecordingHold || isRecordingHandsFree)
                Spacer()
                Button("Done") {
                    applyDone()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRecordingHold || isRecordingHandsFree)
            }
        }
        .padding(20)
        .frame(minWidth: 560)
        .task {
            staging = ShortcutStaging(live: dispatch.configuration)
        }
        .onDisappear {
            // Safety: an armed recording suspends global shortcuts — never
            // leave them suspended behind a dismissed sheet. Idempotent.
            dispatch.setSuspended(false)
        }
    }

    // MARK: - Cards

    private func slotCard(slot: ShortcutSlot, title: String, subtitle: String) -> some View {
        let recording = slot == .hold ? isRecordingHold : isRecordingHandsFree
        let otherRecording = slot == .hold ? isRecordingHandsFree : isRecordingHold
        // Opt-in slot with nothing assigned: placeholder + hints instead
        // of chips; recording into it activates the slot on Done.
        let isEmpty = staging.effectiveKind(for: slot) == .unassigned
        return VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .foregroundStyle(.secondary)
                .font(.subheadline)

            if slot == .handsFree {
                // Derived, non-editable double-tap row: always the hold
                // key, whatever it is. No recorder, no toggle, no state —
                // it mirrors the effective hold binding live (staged or
                // saved). Conversion itself lives in dispatch and fires
                // for every hold kind EXCEPT bare fn: fn taps belong to
                // macOS, and fn presses bypass the machine that would
                // finish a converted session (no third-tap stop exists).
                HStack(spacing: 4) {
                    Text("Double tap")
                        .foregroundStyle(.secondary)
                    ForEach(KeyNames.chips(for: staging.effectiveKind(for: .hold)), id: \.self) { chip in
                        Text(chip)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary, lineWidth: 1)
                )
                if case .modifierHold(let code) = staging.effectiveKind(for: .hold),
                   code == UInt16(kVK_Function)
                {
                    Text("Double taps are handled by macOS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            KeycapField(
                chips: KeyNames.chips(for: staging.effectiveKind(for: slot)),
                isRecording: recording,
                disabled: otherRecording,
                emptyPlaceholder: slot == .handsFree ? "Click to add a shortcut…" : "Click to record…",
                trashHelp: isEmpty ? "Nothing assigned" : "Clear (shortcuts turn off when you press Done)",
                onArm: {
                    dispatch.setSuspended(true)
                    setRecording(true, slot: slot)
                },
                onTrash: { stageClear(slot: slot) },
                recorder: ShortcutRecorderModifier(
                    isListening: slot == .hold ? $isRecordingHold : $isRecordingHandsFree,
                    onCapture: { modifiers, keyCode, conflicts in
                        capture(modifiers: modifiers, keyCode: keyCode, conflicts: conflicts, slot: slot)
                    },
                    onCaptureModifier: { code in
                        captureModifier(code: code, slot: slot)
                    },
                    onClear: { stageClear(slot: slot) },
                    onCancel: { cancelRecording(slot: slot) },
                    onInvalid: { reason in
                        NSSound.beep()
                        setMessage(reason.message, slot: slot)
                    }
                )
            )

            if slot == .handsFree, isEmpty, message(for: slot) == nil {
                // The opt-in toggle is empty: double-tap of the hold key
                // is the always-on path, no setup needed.
                Text("Double-tap \(KeyNames.shortLabel(for: staging.effectiveKind(for: .hold))) anytime — no setup needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Picker("Type", selection: presetBinding(for: slot)) {
                    ForEach(SlotKindChoice.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(otherRecording)

                if slotChoice(for: staging.effectiveKind(for: slot)) == .holdKey {
                    Menu {
                        ForEach(KeyNames.holdOptions, id: \.code) { option in
                            Button(option.label) {
                                stage(kind: .modifierHold(keyCode: option.code), slot: slot)
                            }
                        }
                    } label: {
                        Text(KeyNames.holdMenuLabel(for: staging.effectiveKind(for: slot)))
                    }
                    .disabled(otherRecording)
                    .help("Choose which key to hold")
                }
            }

            if recording, message(for: slot) == nil {
                Text(Self.recorderHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let message = message(for: slot) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption)
                    if showSwap(for: slot) {
                        Spacer()
                        Button("Swap") {
                            swapSlots()
                        }
                        .buttonStyle(.link)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - Staging

    private func presetBinding(for slot: ShortcutSlot) -> Binding<SlotKindChoice> {
        Binding(
            get: { slotChoice(for: staging.effectiveKind(for: slot)) },
            set: { choice in
                switch choice {
                case .holdKey:
                    stage(kind: .modifierHold(keyCode: UInt16(kVK_RightOption)), slot: slot)
                case .dictationKey:
                    stage(kind: .functionKey(codes: [Int64(kVK_F5), 176]), slot: slot)
                case .combo:
                    break // captures stage via capture(), never presets
                }
            }
        )
    }

    private func slotChoice(for kind: ShortcutTrigger.Kind) -> SlotKindChoice {
        switch kind {
        case .modifierHold: return .holdKey
        case .functionKey: return .dictationKey
        case .combo, .unassigned: return .combo
        }
    }

    private func trigger(kind: ShortcutTrigger.Kind, slot: ShortcutSlot) -> ShortcutTrigger {
        ShortcutTrigger(kind: kind, interaction: slot == .hold ? .holdToTalk : .handsFree)
    }

    /// Stage a kind; a kind equal to live unstages (no phantom change).
    /// Advisory gate runs immediately so conflicts surface before Done.
    /// Bare fn is hold-only: an instant toggle cannot share a key with
    /// system taps, so staging it hands-free is refused with guidance
    /// (never staged, never saved).
    /// Stage a kind; a kind equal to live unstages (no phantom change).
    /// Advisory gate runs immediately so conflicts surface before Done.
    /// Hands-free fn refusal derives from the model policy (same rule as
    /// dispatch): an instant toggle cannot share a key with system taps.
    private func stage(kind: ShortcutTrigger.Kind, slot: ShortcutSlot) {
        if slot == .handsFree, !kind.supportsHandsFreeToggle {
            setMessage("fn taps belong to macOS — use Push to talk or a combination.", slot: slot)
            setShowSwap(false, slot: slot)
            return
        }
        let liveKind = slot == .hold ? staging.live.hold.kind : staging.live.handsFree.kind
        if kind == liveKind {
            if slot == .hold {
                staging.stagedHoldKind = nil
                staging.stagedHoldCleared = false
            } else {
                staging.stagedHandsFreeKind = nil
                staging.stagedHandsFreeCleared = false
            }
            setMessage(nil, slot: slot)
            setShowSwap(false, slot: slot)
            return
        }
        if slot == .hold {
            staging.stagedHoldKind = kind
            staging.stagedHoldCleared = false
        } else {
            staging.stagedHandsFreeKind = kind
            staging.stagedHandsFreeCleared = false
        }
        refreshAdvisory(for: slot)
    }

    private func stageClear(slot: ShortcutSlot) {
        dispatch.setSuspended(false)
        setRecording(false, slot: slot)
        // Clearing an already-empty slot is a message-clear no-op: there
        // is no binding to remove and, crucially, no global disable.
        if case .unassigned = staging.effectiveKind(for: slot) {
            setMessage(nil, slot: slot)
            setShowSwap(false, slot: slot)
            return
        }
        if slot == .hold {
            staging.stagedHoldKind = nil
            staging.stagedHoldCleared = true
        } else {
            staging.stagedHandsFreeKind = nil
            staging.stagedHandsFreeCleared = true
        }
        setShowSwap(false, slot: slot)
        setMessage("Cleared — shortcuts turn off for both when you press Done.", slot: slot)
    }

    private func capture(modifiers: UInt32, keyCode: UInt32, conflicts: [RecorderConflict], slot: ShortcutSlot) {
        dispatch.setSuspended(false)
        setRecording(false, slot: slot)
        log.info("capture mods=\(modifiers, privacy: .public) key=\(keyCode, privacy: .public) conflicts=\(conflicts.count, privacy: .public) slot=\(slot == .hold ? "hold" : "hands-free", privacy: .public)")
        if ShortcutRecorderConflicts.blocksSaving(conflicts) {
            setMessage(ShortcutRecorderConflicts.describe(conflicts), slot: slot)
            setShowSwap(false, slot: slot)
            return
        }
        stage(kind: .combo(modifiers: modifiers, keyCode: keyCode), slot: slot)
        if message(for: slot) == nil, !conflicts.isEmpty {
            setMessage(ShortcutRecorderConflicts.describe(conflicts), slot: slot)
        }
    }

    private func captureModifier(code: UInt16, slot: ShortcutSlot) {
        dispatch.setSuspended(false)
        setRecording(false, slot: slot)
        log.info("captureModifier code=\(code, privacy: .public) slot=\(slot == .hold ? "hold" : "hands-free", privacy: .public)")
        stage(kind: .modifierHold(keyCode: code), slot: slot)
    }

    private func cancelRecording(slot: ShortcutSlot) {
        dispatch.setSuspended(false)
        setRecording(false, slot: slot)
    }

    private func otherTitle(for slot: ShortcutSlot) -> String {
        slot == .hold ? "Hands-free mode" : "Push to talk"
    }

    /// Advisory gate: same refusal Done would give, shown early with Swap.
    /// A grandfathered live fn in hands-free (swap predating the gate)
    /// gets guidance here, never a block. Derived from the model policy.
    private func refreshAdvisory(for slot: ShortcutSlot) {
        let preview = staging.donePreview()
        let result = slot == .hold ? preview.hold : preview.handsFree
        if result == .blocked {
            setMessage(
                "Same as your \(otherTitle(for: slot)) shortcut — pick a different one or swap.",
                slot: slot
            )
            setShowSwap(true, slot: slot)
        } else if slot == .handsFree,
                  !staging.effectiveKind(for: slot).supportsHandsFreeToggle
        {
            setMessage("fn taps belong to macOS — use Push to talk or a combination.", slot: slot)
            setShowSwap(false, slot: slot)
        } else {
            setMessage(nil, slot: slot)
            setShowSwap(false, slot: slot)
        }
    }

    /// Surfaces the hands-free fn guidance after resyncs that clear
    /// staged state (open, swap, reset). Hold card untouched. With the
    /// load-time migration, live fn here arises only via swap.
    private func refreshFnGuidance() {
        if !staging.effectiveKind(for: .handsFree).supportsHandsFreeToggle {
            setMessage("fn taps belong to macOS — use Push to talk or a combination.", slot: .handsFree)
            setShowSwap(false, slot: .handsFree)
        }
    }

    // MARK: - Footer

    private func applyDone() {
        if staging.stagedHoldKind != nil {
            let result = dispatch.updateHoldTrigger(
                trigger(kind: staging.stagedHoldKind!, slot: .hold)
            )
            if result == .blocked {
                setMessage(
                    "Same as your \(otherTitle(for: .hold)) shortcut — pick a different one or swap.",
                    slot: .hold
                )
                setShowSwap(true, slot: .hold)
            } else {
                // Applied: the staged value is live now — a stale message
                // (e.g. a capture-time warning) must not survive it.
                setMessage(nil, slot: .hold)
                setShowSwap(false, slot: .hold)
            }
        }
        if staging.stagedHandsFreeKind != nil {
            let result = dispatch.updateHandsFreeTrigger(
                trigger(kind: staging.stagedHandsFreeKind!, slot: .handsFree)
            )
            if result == .blocked {
                setMessage(
                    "Same as your \(otherTitle(for: .handsFree)) shortcut — pick a different one or swap.",
                    slot: .handsFree
                )
                setShowSwap(true, slot: .handsFree)
            } else {
                setMessage(nil, slot: .handsFree)
                setShowSwap(false, slot: .handsFree)
            }
        }
        // Clears land last: an explicit staged clear wins over F1 re-enable.
        if staging.stagedHoldCleared || staging.stagedHandsFreeCleared {
            dispatch.setEnabled(false)
        }
        staging = ShortcutStaging(live: dispatch.configuration)
        if !showSwapHold && !showSwapHandsFree {
            dismiss()
        }
    }

    private func resetToDefaults() {
        _ = dispatch.updateHoldTrigger(.defaultHoldToTalk())
        _ = dispatch.updateHandsFreeTrigger(.unassignedHandsFree())
        staging = ShortcutStaging(live: dispatch.configuration)
        clearMessages()
        refreshFnGuidance()
    }

    private func swapSlots() {
        dispatch.swapHoldAndHandsFree()
        staging = ShortcutStaging(live: dispatch.configuration)
        clearMessages()
        refreshFnGuidance()
    }

    // MARK: - Per-slot state helpers

    private func message(for slot: ShortcutSlot) -> String? {
        slot == .hold ? holdMessage : handsFreeMessage
    }

    private func setMessage(_ message: String?, slot: ShortcutSlot) {
        if slot == .hold {
            holdMessage = message
        } else {
            handsFreeMessage = message
        }
    }

    private func showSwap(for slot: ShortcutSlot) -> Bool {
        slot == .hold ? showSwapHold : showSwapHandsFree
    }

    private func setShowSwap(_ show: Bool, slot: ShortcutSlot) {
        if slot == .hold {
            showSwapHold = show
        } else {
            showSwapHandsFree = show
        }
    }

    private func clearMessages() {
        holdMessage = nil
        handsFreeMessage = nil
        showSwapHold = false
        showSwapHandsFree = false
    }

    private func setRecording(_ recording: Bool, slot: ShortcutSlot) {
        if slot == .hold {
            isRecordingHold = recording
        } else {
            isRecordingHandsFree = recording
        }
    }
}
