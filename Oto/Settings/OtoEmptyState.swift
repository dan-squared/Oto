//
//  OtoEmptyState.swift
//  Oto
//
//  The quiet pane: what a list says when it has nothing to list. Measured from
//  the reference's "Spaces" empty state, which was captured from a 578 pt
//  detail column — the same width as this app's detail column, so the numbers
//  carry over unchanged:
//
//    tile 56 (radius 13) · title 19 · paragraph 14 · chips 28 · button 34 ·
//    footnote 12 with inline keycaps.
//
//  The composition is borderless on purpose: it is the pane, not a card in a
//  form. That is why the panes own their `Form` (see `OtoPaneForm`), so an
//  empty state can stand without a row around it.
//

import SwiftUI

/// A tinted example chip. Illustrative only: it names the kinds of thing the
/// pane holds, the way the reference's chips name its spaces.
struct OtoEmptyChip: Identifiable {
    enum Tint {
        case violet
        case blue
        case green

        var fill: Color {
            switch self {
            case .violet: OtoPalette.chipViolet
            case .blue: OtoPalette.chipBlue
            case .green: OtoPalette.chipGreen
            }
        }
    }

    let symbol: String
    let label: String
    let tint: Tint

    var id: String { label }
}

/// A muted line under the button that can carry the app's own keycaps inside
/// the sentence, as the reference does with its ⌃1 … ⌃9 hint.
struct OtoEmptyFootnote {
    let lead: String
    var keys: [String] = []
    var tail: String = ""
}

struct OtoEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var chips: [OtoEmptyChip] = []
    var actionTitle: String?
    var action: (() -> Void)?
    var footnote: OtoEmptyFootnote?

    var body: some View {
        VStack(spacing: 0) {
            self.tile

            Text(self.title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(OtoPalette.ink)
                .multilineTextAlignment(.center)
                .padding(.top, 16)
                .accessibilityAddTraits(.isHeader)

            Text(self.message)
                .font(.system(size: 14))
                .foregroundStyle(OtoPalette.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
                .padding(.top, 8)

            if !self.chips.isEmpty {
                HStack(spacing: 8) {
                    ForEach(self.chips) { chip in
                        HStack(spacing: 6) {
                            Image(systemName: chip.symbol)
                                .font(.system(size: 11, weight: .medium))
                            Text(chip.label)
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(OtoPalette.ink)
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                        .background(
                            chip.tint.fill,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                    }
                }
                .padding(.top, 18)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(OtoPalette.ground)
                        .padding(.horizontal, 18)
                        .frame(height: 34)
                        .background(
                            OtoPalette.ink,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                }
                .buttonStyle(OtoBounce())
                .padding(.top, 16)
            }

            if let footnote {
                self.footnote(footnote)
                    .padding(.top, 19)
            }
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var tile: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(OtoPalette.wash)
            .frame(width: 56, height: 56)
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(OtoPalette.hairline, lineWidth: 0.75)
            )
            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
            .overlay(
                Image(systemName: self.symbol)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(OtoPalette.ink)
            )
            .accessibilityHidden(true)
    }

    private func footnote(_ footnote: OtoEmptyFootnote) -> some View {
        let tokens = Self.tokens(for: footnote)
        return OtoFlowLayout(spacing: 4, lineSpacing: 5) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                switch token {
                case .word(let word):
                    Text(word)
                        .font(.system(size: 12))
                        .foregroundStyle(OtoPalette.faint)
                        .fixedSize()
                case .key(let key):
                    OtoKey(text: key, compact: true)
                }
            }
        }
        .frame(maxWidth: 320)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.plainText(for: footnote))
    }

    private enum Token {
        case word(String)
        case key(String)
    }

    private static func tokens(for footnote: OtoEmptyFootnote) -> [Token] {
        let words = footnote.lead
            .split(separator: " ")
            .map { Token.word(String($0)) }
        let keys = footnote.keys.map { Token.key($0) }
        let tail = footnote.tail
            .split(separator: " ")
            .map { Token.word(String($0)) }
        return words + keys + tail
    }

    private static func plainText(for footnote: OtoEmptyFootnote) -> String {
        let keys = footnote.keys.isEmpty ? "" : " \(footnote.keys.joined(separator: "+"))"
        return "\(footnote.lead)\(keys)\(footnote.tail.isEmpty ? "" : " \(footnote.tail)")"
    }
}

/// A minimal wrapping layout: words and keycaps flow like a sentence and each
/// line is centred, which the plain `HStack` cannot do. Nothing else uses it.
struct OtoFlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 5

    private struct Line {
        var range: Range<Int>
        var width: CGFloat
        var height: CGFloat
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let width = proposal.width ?? .greatestFiniteMagnitude
        let lines = self.lines(width: width, subviews: subviews)
        let height = lines.isEmpty
            ? 0
            : lines.reduce(0) { $0 + $1.height } + self.lineSpacing * CGFloat(lines.count - 1)
        return CGSize(width: lines.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var y = bounds.minY
        for line in self.lines(width: bounds.width, subviews: subviews) {
            var x = bounds.minX + max(0, (bounds.width - line.width) / 2)
            for index in line.range {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + self.spacing
            }
            y += line.height + self.lineSpacing
        }
    }

    private func lines(width: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = []
        var start = 0
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let advance = lineWidth == 0 ? size.width : lineWidth + self.spacing + size.width
            if advance > width, lineWidth > 0 {
                lines.append(Line(range: start..<index, width: lineWidth, height: lineHeight))
                start = index
                lineWidth = size.width
                lineHeight = size.height
            } else {
                lineWidth = advance
                lineHeight = max(lineHeight, size.height)
            }
        }
        if start < subviews.count {
            lines.append(Line(range: start..<subviews.count, width: lineWidth, height: lineHeight))
        }
        return lines
    }
}
