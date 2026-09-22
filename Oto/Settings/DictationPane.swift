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

    @State private var triggerChoice = TriggerChoice.rightOptionHold
    @State private var interaction: InteractionMode = .holdToTalk
    @State private var calibrationText = "Untested"
    @State private var isRecordingCombo = false
    @State private var comboLabel = "Click to record…"
    @State private var conflictMessage: String?

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

    enum TriggerChoice: String, CaseIterable, Identifiable {
        case rightOptionHold = "Right Option (hold)"
        case dictationKey = "Dictation key"
        case combo = "Custom combo"

        var id: String { rawValue }
    }

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
                Picker("Trigger", selection: $triggerChoice) {
                    ForEach(TriggerChoice.allCases) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                .onChange(of: triggerChoice) { applyTriggerChoice() }

                if triggerChoice == .combo {
                    Button(comboLabel) {
                        isRecordingCombo = true
                        dispatch.setSuspended(true)
                    }
                    .shortcutRecorder(
                        isListening: $isRecordingCombo,
                        onCapture: { modifiers, keyCode, conflicts in
                            dispatch.setSuspended(false)
                            isRecordingCombo = false
                            if ShortcutRecorderConflicts.blocksSaving(conflicts) {
                                conflictMessage = ShortcutRecorderConflicts.describe(conflicts)
                                comboLabel = "Click to record…"
                                return
                            }
                            conflictMessage = conflicts.isEmpty ? nil : ShortcutRecorderConflicts.describe(conflicts)
                            comboLabel = ShortcutRecorderConflicts.describeCombo(modifiers: modifiers, keyCode: keyCode)
                            dispatch.updateTrigger(ShortcutTrigger(
                                kind: .combo(modifiers: modifiers, keyCode: keyCode),
                                interaction: interaction
                            ))
                        },
                        onClear: {
                            dispatch.setSuspended(false)
                            isRecordingCombo = false
                            comboLabel = "Click to record…"
                            conflictMessage = nil
                            dispatch.setEnabled(false)
                        },
                        onCancel: {
                            dispatch.setSuspended(false)
                            isRecordingCombo = false
                        },
                        onInvalid: {
                            NSSound.beep()
                        }
                    )
                    if let conflictMessage {
                        Text(conflictMessage)
                            .foregroundStyle(.secondary)
                    }
                }

                Picker("Mode", selection: $interaction) {
                    Text("Hold to talk").tag(InteractionMode.holdToTalk)
                    Text("Hands-free").tag(InteractionMode.handsFree)
                }
                .pickerStyle(.segmented)
                .onChange(of: interaction) { _, new in
                    dispatch.updateInteraction(new)
                }

                LabeledContent("Test shortcut", value: calibrationText)
                Text("Press and release your shortcut anywhere. Ready appears only after a real global sequence.")
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
            // test-shortcut row only (product behavior, not diagnostics scaffolding).
            while !Task.isCancelled {
                calibrationText = dispatch.calibrationText
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
        interaction = dispatch.configuration.trigger.interaction
        switch dispatch.configuration.trigger.kind {
        case .modifierHold:
            triggerChoice = .rightOptionHold
        case .functionKey:
            triggerChoice = .dictationKey
        case .combo:
            triggerChoice = .combo
        }
        calibrationText = dispatch.calibrationText
    }

    private func applyTriggerChoice() {
        switch triggerChoice {
        case .rightOptionHold:
            dispatch.updateTrigger(ShortcutTrigger(
                kind: .modifierHold(keyCode: UInt16(kVK_RightOption)),
                interaction: interaction
            ))
        case .dictationKey:
            dispatch.updateTrigger(ShortcutTrigger(
                kind: .functionKey(codes: [Int64(kVK_F5), 176]),
                interaction: interaction
            ))
        case .combo:
            break
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
