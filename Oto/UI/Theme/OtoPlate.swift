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

/// A group of lines in one hairline box.
struct OtoCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .background(OtoPalette.ground)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(OtoPalette.hairline, lineWidth: 1)
            )
    }
}

/// The hairline between two lines of a card, inset like the text.
struct OtoRule: View {
    var inset: CGFloat = 14
    var body: some View {
        Rectangle().fill(OtoPalette.hairline).frame(height: 1).padding(.leading, inset)
    }
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
                    .font(.system(size: 13))
                    .foregroundStyle(OtoPalette.ink)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(OtoPalette.muted)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// A small heading over a card, for when a panel has more than one.
struct OtoCaption: View {
    let text: String
    init(text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(OtoPalette.muted)
            .padding(.leading, 2)
    }
}

/// What a panel says when its list is empty.
struct OtoNothing: View {
    let icon: OtoIcon
    let text: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            OtoIconView(icon: icon, size: 22)
                .foregroundStyle(OtoPalette.faint)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OtoPalette.ink)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(OtoPalette.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
    }
}
