//
//  DictationPane.swift
//  Oto
//

import ApplicationServices
import Carbon.HIToolbox
import Speech
import SwiftUI

/// Everything that makes dictation work: speech assets, shortcut, microphone,
/// permissions, and a safe field to try it in. Every row binds to a real
/// backend; rows without backends do not exist here.
struct DictationPane: View {
    let dispatch: ShortcutDispatch
    let preparer: SpeechAssetPreparer
    let permissions: PermissionsManager

    @State private var readinessText = "Checking…"
    @State private var languageText = "—"
    @State private var prepareFeedback: String?
    @State private var isPreparing = false

    @State private var holdChoice = SlotKindChoice.holdKey
    @State private var handsFreeChoice = SlotKindChoice.dictationKey
    @State private var holdCalibrationText = "Untested"
    @State private var handsFreeCalibrationText = "Untested"
    @State private var isRecordingHold = false
    @State private var isRecordingHandsFree = false
    @State private var holdComboLabel = "Click to record…"
    @State private var handsFreeComboLabel = "Click to record…"
    @State private var holdConflictMessage: String?
    @State private var handsFreeConflictMessage: String?

    @State private var micText = "Checking…"
    @State private var axTrusted = false
    @State private var speechText = "Checking…"
    @State private var trialText = ""
    // Catcher kill-switch (6C1): default ON — the modal teaches the
    // no-textbox flow. Key owned by NoTargetModalSettings; the literal is
    // pinned equal to it by NoTargetModalTests.
    @AppStorage("app.Oto.noTargetModal") private var catcherEnabled = true
    // Media-duck kill-switch (Phase 7, spike-green): default ON — bleed
    // ruins transcripts, resume is automatic. Key owned by
    // MediaDuckSettings; the literal is pinned equal to it by MediaDuckTests.
    @AppStorage("app.Oto.muteMediaWhileDictating") private var muteMedia = true

    var body: some View {
        Form {
            Section("Speech") {
                LabeledContent("Readiness", value: readinessText)
                LabeledContent("Language", value: languageText)
                Button("Prepare offline speech") {
                    Task { await runPrepare() }
                }
                .disabled(isPreparing)
                if let prepareFeedback {
                    Text(prepareFeedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Shortcut") {
                ShortcutSlotRow(
                    title: "Hold to talk",
                    choice: $holdChoice,
                    comboLabel: holdComboLabel,
                    conflictMessage: holdConflictMessage,
                    calibrationText: holdCalibrationText,
                    isRecording: $isRecordingHold,
                    recordingDisabled: isRecordingHandsFree,
                    onKindChange: { applySlotChoice(slot: .hold) },
                    onBeginRecording: { dispatch.setSuspended(true) },
                    onCapture: { modifiers, keyCode, conflicts in
                        captureCombo(modifiers: modifiers, keyCode: keyCode, conflicts: conflicts, slot: .hold)
                    },
                    onClear: { clearSlot(.hold) },
                    onCancel: { cancelRecording(slot: .hold) },
                    onInvalid: { NSSound.beep() }
                )

                ShortcutSlotRow(
                    title: "Hands-free",
                    choice: $handsFreeChoice,
                    comboLabel: handsFreeComboLabel,
                    conflictMessage: handsFreeConflictMessage,
                    calibrationText: handsFreeCalibrationText,
                    isRecording: $isRecordingHandsFree,
                    recordingDisabled: isRecordingHold,
                    onKindChange: { applySlotChoice(slot: .handsFree) },
                    onBeginRecording: { dispatch.setSuspended(true) },
                    onCapture: { modifiers, keyCode, conflicts in
                        captureCombo(modifiers: modifiers, keyCode: keyCode, conflicts: conflicts, slot: .handsFree)
                    },
                    onClear: { clearSlot(.handsFree) },
                    onCancel: { cancelRecording(slot: .handsFree) },
                    onInvalid: { NSSound.beep() }
                )

                Text("Press either shortcut anywhere. Ready appears per row after a real global sequence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Microphone") {
                // No enumeration seam exists: Oto follows the system default
                // input (Yap parity). A picker here would be a dead control.
                LabeledContent("Input", value: "System default input")
                LabeledContent("Status", value: micText)
                if micText != "Allowed" {
                    Button("Allow microphone access") {
                        Task {
                            _ = await permissions.ensureMicrophone()
                            refreshPermissions()
                        }
                    }
                }
            }

            Section("Permissions") {
                LabeledContent("Accessibility", value: axTrusted ? "Allowed" : "Not allowed")
                if !axTrusted {
                    Button("Open Accessibility settings") {
                        requestAccessibilityPrompt()
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            refreshPermissions()
                        }
                    }
                }
                LabeledContent("Speech recognition", value: speechText)
            }

            Section("Catcher") {
                Toggle("Show catcher when there's nowhere to paste", isOn: $catcherEnabled)
                Text("When dictation finishes with no text field to receive it, Oto opens a small window with the transcript and a Copy button. Off: the transcript is copied to the clipboard automatically instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Media") {
                Toggle("Mute media while dictating", isOn: $muteMedia)
                Text("Oto silences speaker output while you dictate so it can't bleed into the transcript, then restores your exact volume. A relaunch restores it even if Oto was killed mid-dictation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Try it") {
                TextEditor(text: $trialText)
                    .frame(minHeight: 70)
                Text("Dictate anywhere, or into this field — Oto captures whichever app is frontmost, including its own window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // No .navigationTitle: sections self-label, and a stacked
        // sidebar+detail title inflates the toolbar zone (§11).
        .task {
            syncFromDispatch()
            await refreshSpeech()
            refreshPermissions()
            // Calibration reflects live backend state; the poll serves the
            // test-shortcut rows only (product behavior, not diagnostics scaffolding).
            while !Task.isCancelled {
                holdCalibrationText = dispatch.calibrationText(for: .hold)
                handsFreeCalibrationText = dispatch.calibrationText(for: .handsFree)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    // MARK: - Speech

    private func refreshSpeech() async {
        let report = await preparer.status()
        if let tag = report.resolved?.identifier(.bcp47) {
            let systemTag = Locale.current.identifier(.bcp47)
            languageText = tag == systemTag
                ? tag
                : "\(systemTag) → engine uses \(tag)"
        } else {
            languageText = Locale.current.identifier(.bcp47)
        }
        readinessText = report.readiness.errorDescription ?? "Ready"
    }

    private func runPrepare() async {
        isPreparing = true
        prepareFeedback = "Preparing…"
        prepareFeedback = await preparer.prepareDefault()
        isPreparing = false
        await refreshSpeech()
    }

    // MARK: - Shortcut

    private func syncFromDispatch() {
        holdChoice = slotChoice(for: dispatch.configuration.hold.kind)
        handsFreeChoice = slotChoice(for: dispatch.configuration.handsFree.kind)
        holdCalibrationText = dispatch.calibrationText(for: .hold)
        handsFreeCalibrationText = dispatch.calibrationText(for: .handsFree)
    }

    private func slotChoice(for kind: ShortcutTrigger.Kind) -> SlotKindChoice {
        switch kind {
        case .modifierHold:
            return .holdKey
        case .functionKey:
            return .dictationKey
        case .combo:
            return .combo
        }
    }

    /// Preset picks route through the per-slot save gate (never direct
    /// assignment): a preset equal to the other slot's live trigger is
    /// refused with the same message — no bypass.
    private func applySlotChoice(slot: ShortcutSlot) {
        let choice = slot == .hold ? holdChoice : handsFreeChoice
        guard choice != .combo else { return }
        let result = saveSlot(kind: presetKind(for: choice), slot: slot)
        if result == .blocked {
            revertChoice(slot: slot)
        }
    }

    private func presetKind(for choice: SlotKindChoice) -> ShortcutTrigger.Kind {
        switch choice {
        case .holdKey:
            return .modifierHold(keyCode: UInt16(kVK_RightOption))
        case .dictationKey:
            return .functionKey(codes: [Int64(kVK_F5), 176])
        case .combo:
            // Unreachable: combo picks arrive via capture, not presets.
            return .modifierHold(keyCode: UInt16(kVK_RightOption))
        }
    }

    /// Save a kind into a slot with the slot's fixed interaction. Returns the
    /// gate outcome so callers can surface the conflict message.
    @discardableResult
    private func saveSlot(kind: ShortcutTrigger.Kind, slot: ShortcutSlot) -> TriggerUpdateResult {
        let interaction: InteractionMode = slot == .hold ? .holdToTalk : .handsFree
        let trigger = ShortcutTrigger(kind: kind, interaction: interaction)
        return slot == .hold
            ? dispatch.updateHoldTrigger(trigger)
            : dispatch.updateHandsFreeTrigger(trigger)
    }

    private func otherTitle(for slot: ShortcutSlot) -> String {
        slot == .hold ? "Hands-free" : "Hold to talk"
    }

    private func setConflictMessage(_ message: String?, slot: ShortcutSlot) {
        if slot == .hold {
            holdConflictMessage = message
        } else {
            handsFreeConflictMessage = message
        }
    }

    /// A refused save keeps the old trigger: revert the picker and name the
    /// conflict.
    private func revertChoice(slot: ShortcutSlot) {
        let stored = slot == .hold ? dispatch.configuration.hold : dispatch.configuration.handsFree
        if slot == .hold {
            holdChoice = slotChoice(for: stored.kind)
        } else {
            handsFreeChoice = slotChoice(for: stored.kind)
        }
        setConflictMessage("Same as your \(otherTitle(for: slot)) shortcut — pick a different one.", slot: slot)
    }

    private func captureCombo(modifiers: UInt32, keyCode: UInt32, conflicts: [RecorderConflict], slot: ShortcutSlot) {
        dispatch.setSuspended(false)
        setRecording(false, slot: slot)
        if ShortcutRecorderConflicts.blocksSaving(conflicts) {
            setConflictMessage(ShortcutRecorderConflicts.describe(conflicts), slot: slot)
            setComboLabel("Click to record…", slot: slot)
            return
        }
        switch saveSlot(kind: .combo(modifiers: modifiers, keyCode: keyCode), slot: slot) {
        case .blocked:
            // Old trigger kept; keep the old label too.
            setConflictMessage("Same as your \(otherTitle(for: slot)) shortcut — pick a different one.", slot: slot)
        case .applied, .unchanged:
            setConflictMessage(
                conflicts.isEmpty ? nil : ShortcutRecorderConflicts.describe(conflicts),
                slot: slot
            )
            setComboLabel(ShortcutRecorderConflicts.describeCombo(modifiers: modifiers, keyCode: keyCode), slot: slot)
        }
    }

    /// Delete clears to unassigned AND disables globally (one `enabled`
    /// switch for both slots). The stored trigger is kept; any fresh
    /// capture or preset re-enables (F1).
    private func clearSlot(_ slot: ShortcutSlot) {
        dispatch.setSuspended(false)
        setRecording(false, slot: slot)
        setComboLabel("Click to record…", slot: slot)
        setConflictMessage(nil, slot: slot)
        dispatch.setEnabled(false)
    }

    private func cancelRecording(slot: ShortcutSlot) {
        dispatch.setSuspended(false)
        setRecording(false, slot: slot)
    }

    private func setRecording(_ recording: Bool, slot: ShortcutSlot) {
        if slot == .hold {
            isRecordingHold = recording
        } else {
            isRecordingHandsFree = recording
        }
    }

    private func setComboLabel(_ label: String, slot: ShortcutSlot) {
        if slot == .hold {
            holdComboLabel = label
        } else {
            handsFreeComboLabel = label
        }
    }

    // MARK: - Permissions

    private func refreshPermissions() {
        switch permissions.microphoneStatus() {
        case .granted:
            micText = "Allowed"
        case .denied:
            micText = "Denied — allow in System Settings → Privacy & Security → Microphone."
        case .notDetermined:
            micText = "Not asked yet"
        }
        axTrusted = AXIsProcessTrusted()
        switch permissions.speechStatus() {
        case .authorized:
            speechText = "Allowed"
        case .denied, .restricted:
            speechText = "Not allowed"
        case .notDetermined:
            speechText = "Not asked yet"
        @unknown default:
            speechText = "Unknown"
        }
    }

    /// Apple's blessed prompt: opens System Settings at the Accessibility
    /// page itself when untrusted, no-ops when trusted. Verified in the
    /// macOS 27 headers (10.9+); no raw Settings URLs.
    private func requestAccessibilityPrompt() {
        _ = AXIsProcessTrustedWithOptions([
            PermissionsManager.axPromptKey: true,
        ] as CFDictionary)
    }
}
