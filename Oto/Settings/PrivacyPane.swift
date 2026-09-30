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
                OtoLine("Microphone", uiState.micDeniedGuidance) {
                    VStack(alignment: .trailing, spacing: 8) {
                        OtoStatus(text: uiState.micText, tone: uiState.micTone)
                        if !uiState.micAllowed {
                            OtoBig("Allow microphone access") {
                                Task {
                                    _ = await uiState.ensureMicrophoneGrant()
                                    uiState.refreshPermissions()
                                }
                            }
                        }
                    }
                }
                OtoRule()
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
                OtoRule()
                OtoLine("Speech recognition", nil) {
                    OtoStatus(text: uiState.speechText, tone: uiState.speechTone)
                }
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
