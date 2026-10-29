//
//  PrivacyPane.swift
//  Oto
//
//  What Oto stores and the three system permissions behind dictation.
//  Statuses render from the hoisted model (loaded once per window open);
//  only the fast grant-flow refresh runs on appear.
//

import SwiftUI

struct PrivacyPane: View {
    let uiState: SettingsUIState

    var body: some View {
        OtoPaneForm {
            // No "Privacy" header — the sidebar already says it.
            Section {
                MicStatusRow(uiState: uiState, title: "Microphone")
                AccessibilityRow(uiState: uiState)
                SpeechStatusRow(uiState: uiState)
                OtoPanelNote("Oto stores what you choose: rules, snippets, and transcripts only if you enable history. Never audio or other apps' content.")
            }
            .task {
                // Slow state is hoisted (loaded once per window open) — keep
                // only the fast grant-flow refresh on appear.
                uiState.refreshPermissions()
            }
        }
    }
}
