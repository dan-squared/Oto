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
        VStack(alignment: .leading, spacing: 6) {
            OtoCaption(text: "Privacy")
            OtoCard {
                MicStatusRow(uiState: uiState, title: "Microphone")
                OtoRule()
                AccessibilityRow(uiState: uiState)
                OtoRule()
                SpeechStatusRow(uiState: uiState)
            }
            Text("Oto stores what you choose: rules, snippets, and transcripts only if you enable history. Never audio or other apps' content.")
                .font(.system(size: 11.5))
                .foregroundStyle(OtoPalette.muted)
                .padding(.leading, 2)
        }
        .task {
            // Slow state is hoisted (loaded once per window open) — keep
            // only the fast grant-flow refresh on appear.
            uiState.refreshPermissions()
        }
    }
}
