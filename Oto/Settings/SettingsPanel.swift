//
//  SettingsPanel.swift
//  Oto
//
//  The note that belongs to a control lives in the same card as the control,
//  under a divider — as Firstlight's panels do. A Form `footer:` puts the
//  same words outside the card in fine print, where the control and its
//  explanation read as two unrelated things.
//

import SwiftUI

/// Explanatory copy inside a settings panel. Use it as the last row of the
/// `Section` that owns the control, never as that section's `footer:`.
struct OtoPanelNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}
