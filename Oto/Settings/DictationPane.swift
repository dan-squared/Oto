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

    @State private var shortcutSummary = "Hold ⌥ and speak."
    @State private var shortcutStatus = "Untested"
    @State private var showShortcutModal = false

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
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Shortcuts")
                            .font(.headline)
                        Text(shortcutSummary)
                            .foregroundStyle(.secondary)
                        Text(shortcutStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Change") {
                        showShortcutModal = true
                    }
                }
                .sheet(isPresented: $showShortcutModal) {
                    ShortcutModal(dispatch: dispatch)
                }
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
            // summary row only (per-slot status lives in the modal).
            while !Task.isCancelled {
                shortcutSummary = "Hold \(KeyNames.shortLabel(for: dispatch.configuration.hold.kind)) and speak."
                shortcutStatus = dispatch.calibrationText
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
        shortcutSummary = "Hold \(KeyNames.shortLabel(for: dispatch.configuration.hold.kind)) and speak."
        shortcutStatus = dispatch.calibrationText
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
