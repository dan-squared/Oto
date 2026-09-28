//
//  DictationPane.swift
//  Oto
//
//  Everything that makes dictation work: speech assets, shortcut, microphone,
//  permissions, and a safe field to try it in. Every row binds a real
//  backend; rows without backends do not exist here. Same logic as before —
//  only the surface changed (Caption + Card + Line rows).
//

import ApplicationServices
import Carbon.HIToolbox
import Speech
import SwiftUI

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
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                OtoCaption(text: "Speech")
                OtoCard {
                    OtoLine("Readiness", readinessText) { EmptyView() }
                    OtoRule()
                    OtoLine("Language", languageText) { EmptyView() }
                    OtoRule()
                    HStack {
                        OtoPill("Prepare offline speech") {
                            Task { await runPrepare() }
                        }
                        .disabled(isPreparing)
                        if let prepareFeedback {
                            Text(prepareFeedback)
                                .font(.system(size: 11.5))
                                .foregroundStyle(OtoPalette.muted)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                OtoCaption(text: "Shortcut")
                OtoCard {
                    OtoLine(shortcutSummary, shortcutStatus) {
                        OtoPill("Change") {
                            showShortcutModal = true
                        }
                    }
                }
                .sheet(isPresented: $showShortcutModal) {
                    ShortcutModal(dispatch: dispatch)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                OtoCaption(text: "Microphone")
                OtoCard {
                    // No enumeration seam exists: Oto follows the system default
                    // input (Yap parity). A picker here would be a dead control.
                    OtoLine("Input", "System default input") { EmptyView() }
                    OtoRule()
                    OtoLine("Status", micText) {
                        if micText != "Allowed" {
                            OtoPill("Allow microphone access") {
                                Task {
                                    _ = await permissions.ensureMicrophone()
                                    refreshPermissions()
                                }
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                OtoCaption(text: "Permissions")
                OtoCard {
                    OtoLine("Accessibility", axTrusted ? "Allowed" : "Not allowed") {
                        if !axTrusted {
                            OtoPill("Open Accessibility settings") {
                                requestAccessibilityPrompt()
                                Task {
                                    try? await Task.sleep(for: .seconds(2))
                                    refreshPermissions()
                                }
                            }
                        }
                    }
                    OtoRule()
                    OtoLine("Speech recognition", speechText) { EmptyView() }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                OtoCaption(text: "Catcher")
                OtoCard {
                    OtoLine(
                        "Show catcher when there's nowhere to paste",
                        "When dictation finishes with no text field to receive it, Oto opens a small window with the transcript and a Copy button. Off: the transcript is copied to the clipboard automatically instead."
                    ) {
                        OtoSwitch(on: $catcherEnabled)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                OtoCaption(text: "Media")
                OtoCard {
                    OtoLine(
                        "Mute media while dictating",
                        "Oto silences speaker output while you dictate so it can't bleed into the transcript, then restores your exact volume. A relaunch restores it even if Oto was killed mid-dictation."
                    ) {
                        OtoSwitch(on: $muteMedia)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                OtoCaption(text: "Try it")
                OtoCard {
                    TextEditor(text: $trialText)
                        .font(.system(size: 13))
                        .foregroundStyle(OtoPalette.ink)
                        .frame(minHeight: 70)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                }
                Text("Dictate anywhere, or into this field — Oto captures whichever app is frontmost, including its own window.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(OtoPalette.muted)
                    .padding(.leading, 2)
            }
        }
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
