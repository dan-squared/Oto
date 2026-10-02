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

    @AppStorage("app.Oto.intelligenceEnabled") private var enabled = true
    @State private var availability: PolishAvailability = .available

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
