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

/// The scrollable card stack every list pane uses. The `Form` lives here
/// rather than in `SettingsRoot` so a pane can choose the borderless canvas
/// instead — an empty state is the pane, not a card inside one.
struct OtoPaneForm<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        Form { content() }
            .formStyle(.grouped)
            // The titlebar's back/forward pill and the pane's switch sit 8 pt
            // from the detail column's edge; the grouped Form's default 20 pt
            // margin left the cards hanging 12 pt inside them (reported
            // 2026-10-29). Matching the toolbar's inset lines the top controls
            // up with the card edges on both sides.
            .contentMargins(.horizontal, 8, for: .scrollContent)
    }
}

/// The borderless pane: content centred in the whole detail column, with no
/// card or row chrome around it. Used only for empty states.
struct OtoPaneCanvas<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            content()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }
}
