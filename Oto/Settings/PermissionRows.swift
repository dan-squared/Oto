//
//  PermissionRows.swift
//  Oto
//
//  The three system-permission rows behind dictation, shared by DictationPane
//  and PrivacyPane (their bodies were verbatim duplicates). Row bodies only —
//  cards, captions and rules stay with the panes, so no pane changes pixels.
//  Driven by the hoisted SettingsUIState, like the panes themselves.
//

import Speech
import SwiftUI

/// Microphone status row. Title differs by pane ("Status" under Dictation's
/// Microphone card, "Microphone" in Privacy), so it arrives as a param.
struct MicStatusRow: View {
    let uiState: SettingsUIState
    let title: String

    var body: some View {
        // One trailing slot, always exactly one control (same contract as
        // the speech row): the Allow button sits IN the status slot while
        // a prompt exists; otherwise the status pill.
        OtoLine(title, uiState.micDeniedGuidance) {
            if uiState.micPermission == .notDetermined {
                OtoBig("Allow microphone access") {
                    Task {
                        _ = await uiState.ensureMicrophoneGrant()
                        uiState.refreshPermissions()
                    }
                }
            } else {
                OtoStatus(text: uiState.micText, tone: uiState.micTone)
            }
        }
    }
}

/// Accessibility row. Identical in both panes.
struct AccessibilityRow: View {
    let uiState: SettingsUIState

    var body: some View {
        OtoLine("Accessibility", uiState.axTrusted ? nil : "Global keys and insertion need it.") {
            VStack(alignment: .trailing, spacing: 8) {
                OtoStatus(text: uiState.axTrusted ? "Allowed" : "Not allowed", tone: uiState.axTrusted ? .ok : .warn)
                if !uiState.axTrusted {
                    OtoBig("Open Accessibility settings") {
                        uiState.requestAccessibilityPrompt()
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            uiState.refreshPermissions()
                        }
                    }
                }
            }
        }
    }
}

/// Speech-recognition status row. Identical in both panes. One trailing
/// slot, always exactly one control: the Allow button sits IN the status
/// slot (never below it) while a prompt exists; otherwise the status
/// pill. Denied gets Settings guidance instead of a dead button — no
/// prompt exists to show, so a button would lie.
struct SpeechStatusRow: View {
    let uiState: SettingsUIState

    var body: some View {
        OtoLine("Speech recognition", uiState.speechDeniedGuidance) {
            if uiState.speechPermission == .notDetermined {
                OtoBig("Allow speech recognition") {
                    Task {
                        _ = await uiState.ensureSpeechGrant()
                        uiState.refreshPermissions()
                    }
                }
            } else {
                OtoStatus(text: uiState.speechText, tone: uiState.speechTone)
            }
        }
    }
}
