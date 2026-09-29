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
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var defaultInputUID: String?
    // Catcher kill-switch (6C1): default ON — the modal teaches the
    // no-textbox flow. Key owned by NoTargetModalSettings; the literal is
    // pinned equal to it by NoTargetModalTests.
    @AppStorage("app.Oto.noTargetModal") private var catcherEnabled = true
    // Media-duck kill-switch (Phase 7, spike-green): default ON — bleed
    // ruins transcripts, resume is automatic. Key owned by
    // MediaDuckSettings; the literal is pinned equal to it by MediaDuckTests.
    @AppStorage("app.Oto.muteMediaWhileDictating") private var muteMedia = true

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                OtoCaption(text: "Speech")
                OtoCard {
                    OtoLine("Readiness", speechReady ? languageText : (prepareFeedback ?? readinessText)) {
                        if speechReady {
                            OtoStatus(text: "Ready", tone: .ok)
                        } else {
                            OtoBig(isPreparing ? "Preparing…" : "Prepare offline speech") {
                                Task { await runPrepare() }
                            }
                            .disabled(isPreparing)
                        }
                    }
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
                    OtoLine("Input", "Sets the Mac's input — every app follows it.") {
                        Menu {
                            ForEach(inputDevices) { device in
                                Button(device.name) {
                                    MicrophoneSelector.setDefaultInput(device)
                                    refreshMicrophones()
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(currentInputName)
                                    .font(.system(size: 13))
                                    .foregroundStyle(OtoPalette.ink)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 11))
                                    .foregroundStyle(OtoPalette.muted)
                            }
                        }
                    }
                    OtoRule()
                    OtoLine("Status", micDeniedGuidance) {
                        VStack(alignment: .trailing, spacing: 8) {
                            OtoStatus(text: micText, tone: micTone)
                            if !micAllowed {
                                OtoBig("Allow microphone access") {
                                    Task {
                                        _ = await permissions.ensureMicrophone()
                                        refreshPermissions()
                                    }
                                }
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                OtoCaption(text: "Permissions")
                OtoCard {
                    OtoLine("Accessibility", axTrusted ? nil : "Global keys and insertion need it.") {
                        VStack(alignment: .trailing, spacing: 8) {
                            OtoStatus(text: axTrusted ? "Allowed" : "Not allowed", tone: axTrusted ? .ok : .warn)
                            if !axTrusted {
                                OtoBig("Open Accessibility settings") {
                                    requestAccessibilityPrompt()
                                    Task {
                                        try? await Task.sleep(for: .seconds(2))
                                        refreshPermissions()
                                    }
                                }
                            }
                        }
                    }
                    OtoRule()
                    OtoLine("Speech recognition", nil) {
                        OtoStatus(text: speechText, tone: speechTone)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                OtoCaption(text: "Catcher")
                OtoCard {
                    OtoLine(
                        "Show catcher when there's nowhere to paste",
                        "No text field? Oto opens a small window with your transcript and a Copy button. Off: auto-copies instead."
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
                        "Silences speakers while you dictate, then restores the volume — even after a crash."
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
                Text("Dictate anywhere, or here — Oto captures the frontmost app.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(OtoPalette.muted)
                    .padding(.leading, 2)
            }
        }
        .task {
            syncFromDispatch()
            refreshMicrophones()
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

    // MARK: - Microphone devices

    private var micAllowed: Bool { micText == "Allowed" }

    private var micTone: OtoStatus.Tone {
        micAllowed ? .ok : (micText == "Not asked yet" ? .idle : .warn)
    }

    private var micDeniedGuidance: String? {
        micAllowed || micText == "Not asked yet"
            ? nil
            : "Allow it in System Settings → Privacy & Security → Microphone."
    }

    private var speechTone: OtoStatus.Tone {
        switch speechText {
        case "Allowed": .ok
        case "Not asked yet", "Checking…", "Unknown": .idle
        default: .warn
        }
    }

    private var speechReady: Bool { readinessText == "Ready" }

    private var currentInputName: String {
        inputDevices.first(where: { $0.uid == defaultInputUID })?.name ?? "System default"
    }

    private func refreshMicrophones() {
        inputDevices = MicrophoneSelector.inputDevices()
        defaultInputUID = MicrophoneSelector.defaultInputUID()
    }

    // MARK: - Permissions

    private func refreshPermissions() {
        switch permissions.microphoneStatus() {
        case .granted:
            micText = "Allowed"
        case .denied:
            micText = "Denied"
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
