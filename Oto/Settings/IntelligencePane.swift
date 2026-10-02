//
//  IntelligencePane.swift
//  Oto
//
//  Apple Intelligence status + master switch. Slice A holds status, toggle,
//  and Manual (Clean up buttons on History entries). The behavior picker
//  (Upgrade-if-fast / Automatic) arrives with Slice B — no dead controls:
//  every row here binds a live backend today.
//

import SwiftUI

struct IntelligencePane: View {
    let polish: any PolishServing

    @AppStorage(IntelligenceSettings.enabledKey) private var enabled = true
    @AppStorage(IntelligenceSettings.modeKey) private var modeRaw = IntelligenceMode.upgrade.rawValue
    @State private var availability: PolishAvailability = .available

    /// Bound through the raw string so a future value stored by a newer
    /// build never crashes this one — unknown reads as manual (same rule
    /// as `PolishBehavior.current`).
    private var mode: Binding<IntelligenceMode> {
        Binding(
            get: { IntelligenceMode(rawValue: modeRaw) ?? .manual },
            set: { modeRaw = $0.rawValue }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            OtoCaption(text: "Intelligence")
            OtoCard {
                OtoLine("Apple Intelligence", statusDetail) {
                    OtoStatus(text: statusText, tone: statusTone)
                }
            }
            OtoCard {
                OtoLine(
                    "Clean up transcripts",
                    "Fix grammar and remove filler words from History entries."
                ) {
                    OtoSwitch(on: $enabled)
                }
            }
            OtoCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("When to clean up")
                        .font(.system(size: 13))
                        .foregroundStyle(OtoPalette.ink)
                    OtoSegmented(
                        options: [
                            (.manual, "Manual"),
                            (.upgrade, "Upgrade if fast"),
                        ],
                        selection: mode
                    )
                    Text("Manual cleans only when you tap Clean up. Upgrade if fast inserts your words instantly, then swaps in the cleanup when it is ready.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(OtoPalette.muted)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
            Text("On-device only — transcripts and prompts never leave this Mac. Off means exactly today's app: no model contact at all.")
                .font(.system(size: 11.5))
                .foregroundStyle(OtoPalette.muted)
                .padding(.leading, 2)
        }
        .onAppear {
            availability = polish.availability()
        }
    }

    private var statusText: String {
        availability == .available ? "Ready" : "Not available"
    }

    private var statusTone: OtoStatus.Tone {
        availability == .available ? .ok : .idle
    }

    private var statusDetail: String? {
        if case .unavailable(let copy) = availability { return copy }
        return enabled ? nil : "Turned off — turn it on to use cleanup."
    }
}
