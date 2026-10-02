//
//  DictationPane.swift
//  Oto
//
//  Everything that makes dictation work: speech assets, shortcut, microphone,
//  permissions, and a safe field to try it in. Every row binds a real
//  backend; rows without backends do not exist here. Same logic as before —
//  only the surface changed (Caption + Card + Line rows).
//

import SwiftUI

struct DictationPane: View {
    let dispatch: ShortcutDispatch
    let uiState: SettingsUIState

    @State private var shortcutSummary = "Hold ⌥ and speak."
    @State private var shortcutStatus = "Untested"
    @State private var showShortcutModal = false

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
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                OtoCaption(text: "Speech")
                OtoCard {
                    OtoLine("Readiness", uiState.speechReady ? uiState.languageText : (uiState.prepareFeedback ?? uiState.readinessText)) {
                        if uiState.speechReady {
                            OtoStatus(text: "Ready", tone: .ok)
                        } else {
                            OtoBig(uiState.isPreparing ? "Preparing…" : "Prepare offline speech") {
                                Task { await uiState.runPrepare() }
                            }
                            .disabled(uiState.isPreparing)
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
                .sheet(isPresented: $showShortcutModal, onDismiss: syncFromDispatch) {
                    ShortcutModal(dispatch: dispatch)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                OtoCaption(text: "Microphone")
                OtoCard {
                    OtoLine("Input", "Sets the Mac's input — every app follows it.") {
                        Menu {
                            ForEach(uiState.inputDevices) { device in
                                Button(device.name) {
                                    MicrophoneSelector.setDefaultInput(device)
                                    uiState.refreshMicrophones()
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(uiState.currentInputName)
                                    .font(.system(size: 13))
                                    .foregroundStyle(OtoPalette.ink)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 11))
                                    .foregroundStyle(OtoPalette.muted)
                            }
                        }
                    }
                    OtoRule()
                    MicStatusRow(uiState: uiState, title: "Status")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                OtoCaption(text: "Permissions")
                OtoCard {
                    AccessibilityRow(uiState: uiState)
                    OtoRule()
                    SpeechStatusRow(uiState: uiState)
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
                            .accessibilityIdentifier("CatcherToggle")
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
        .onAppear {
            // Fast only: shortcut summary (the config can change in the
            // modal or onboarding, so re-sync on every visit and on modal
            // close) plus grant-in-System-Settings flows live with no
            // flash (never re-probes speech or devices here).
            syncFromDispatch()
            uiState.refreshPermissions()
        }
    }

    // MARK: - Shortcut

    private func syncFromDispatch() {
        shortcutSummary = "Hold \(KeyNames.shortLabel(for: dispatch.configuration.hold.kind)) and speak."
        shortcutStatus = dispatch.calibrationText
    }
}
