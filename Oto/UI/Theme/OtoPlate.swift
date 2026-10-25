//
//  OtoPlate.swift
//  Oto
//
//  Panel composition: hairline cards with ruled lines (OtoCard + OtoRule),
//  title/detail/control rows (OtoLine), and small over-card headings
//  (OtoCaption). Panels say what goes in them; this file says how panels
//  read as one kind of thing.
//

import SwiftUI

/// Native grouped container used by the settings panes.
struct OtoCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GroupBox {
            content()
                // GroupBox otherwise takes the ideal width of its contents.
                // Flexible content (empty states and multi-line controls in
                // particular) must share the same trailing edge as row cards.
                .frame(maxWidth: .infinity, alignment: .leading)
        }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The hairline between two lines of a card, inset like the text.
struct OtoRule: View {
    var inset: CGFloat = 0
    var body: some View { Divider().padding(.leading, inset) }
}

/// One thing to set or do: what it is on the left, the control on the right.
struct OtoLine<Control: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let control: () -> Control

    init(_ title: String, _ detail: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let detail {
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            control()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small heading over a card, for when a panel has more than one.
struct OtoCaption: View {
    let text: String
    init(text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// Native macOS empty state for a settings list with no saved entries.
struct OtoNothing: View {
    let systemName: String
    let text: String
    let detail: String

    var body: some View {
        ContentUnavailableView(text, systemImage: systemName, description: Text(detail))
            .frame(maxWidth: .infinity, minHeight: 240)
    }
}
