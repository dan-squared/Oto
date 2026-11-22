//
//  PermissionRows.swift
//  Oto
//
//  The system-permission rows behind dictation. Privacy is their one home —
//  Dictation no longer repeats them (round 2, 2026-10-31). Row bodies only —
//  cards, captions and rules stay with the pane, so no pane changes pixels.
//  Driven by the hoisted SettingsUIState, like the panes themselves.
//
//  One control per row. A state that has a remedy is the button: the pill
//  reads "Allow" (never the dead state) and does the right thing per state —
//  the system prompt where one exists, the System Settings pane where not.
//  Nothing stacks a second button under the status.
//

import SwiftUI

/// Microphone status row. The title arrives as a param because Privacy names
/// the grant where Dictation's (removed) copy named the status.
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
                    text: uiState.micActionText,
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
                    text: uiState.micActionText,
                    tone: uiState.micTone,
                    help: "Open System Settings → Privacy & Security → Microphone"
                ) {
                    SettingsLinkOpener.open(MicSettingsLink.candidates())
                }
            }
        }
    }
}

/// Accessibility row. No in-product prompt exists for a denial, so the press
/// is Apple's blessed prompt (which opens the pane when untrusted) and the
/// row re-reads trust two seconds later, once the person has switched back.
struct AccessibilityRow: View {
    let uiState: SettingsUIState

    var body: some View {
        LabeledContent("Accessibility") {
            if uiState.axTrusted {
                OtoStatus(text: "Allowed", tone: .ok)
            } else {
                OtoStatusAction(
                    text: uiState.axActionText,
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
