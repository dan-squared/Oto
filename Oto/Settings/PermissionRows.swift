//
//  PermissionRows.swift
//  Oto
//
//  The three system-permission rows behind dictation, shared by DictationPane
//  and PrivacyPane (their bodies were verbatim duplicates). Row bodies only —
//  cards, captions and rules stay with the panes, so no pane changes pixels.
//  Driven by the hoisted SettingsUIState, like the panes themselves.
//
//  One control per row. A state that has a remedy is the button: the pill
//  reads "Not allowed" and opens the System Settings pane that can undo it.
//  Nothing stacks a second button under the status.
//

import Speech
import SwiftUI

/// Microphone status row. Title differs by pane ("Status" under Dictation's
/// Microphone card, "Microphone" in Privacy), so it arrives as a param.
struct MicStatusRow: View {
    let uiState: SettingsUIState
    let title: String

    var body: some View {
        LabeledContent(title) {
            switch uiState.micAction {
            case .none:
                OtoStatus(text: uiState.micText, tone: uiState.micTone)
            case .allow:
                OtoStatusAction(
                    text: uiState.micText,
                    tone: uiState.micTone,
                    help: "Ask for microphone access"
                ) {
                    Task {
                        _ = await uiState.ensureMicrophoneGrant()
                        uiState.refreshPermissions()
                    }
                }
            case .openSettings:
                OtoStatusAction(
                    text: uiState.micText,
                    tone: uiState.micTone,
                    help: "Open System Settings → Privacy & Security → Microphone"
                ) {
                    SettingsLinkOpener.open(MicSettingsLink.candidates())
                }
            }
        }
    }
}

/// Accessibility row. Identical in both panes.
struct AccessibilityRow: View {
    let uiState: SettingsUIState

    var body: some View {
        LabeledContent("Accessibility") {
            if uiState.axTrusted {
                OtoStatus(text: "Allowed", tone: .ok)
            } else {
                OtoStatusAction(
                    text: "Not allowed",
                    tone: .warn,
                    help: "Open System Settings → Privacy & Security → Accessibility"
                ) {
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

/// Speech-recognition status row. Identical in both panes. One trailing
/// control: the pill is the button where a grant or a Settings trip exists,
/// and the readout where there is nothing left to do.
struct SpeechStatusRow: View {
    let uiState: SettingsUIState

    var body: some View {
        LabeledContent("Speech recognition") {
            switch uiState.speechAction {
            case .none:
                OtoStatus(text: uiState.speechText, tone: uiState.speechTone)
            case .allow:
                OtoStatusAction(
                    text: uiState.speechText,
                    tone: uiState.speechTone,
                    help: "Ask for speech recognition access"
                ) {
                    Task {
                        _ = await uiState.ensureSpeechGrant()
                        uiState.refreshPermissions()
                    }
                }
            case .openSettings:
                OtoStatusAction(
                    text: uiState.speechText,
                    tone: uiState.speechTone,
                    help: "Open System Settings → Privacy & Security → Speech Recognition"
                ) {
                    SettingsLinkOpener.open(SpeechSettingsLink.candidates())
                }
            }
        }
    }
}
