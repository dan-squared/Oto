//
//  PillColorPicker.swift
//  Oto
//
//  The pill's colour palette, as a settings row control. Five swatches, one
//  click each — a colour wheel would be a worse question ("pick a hex") for
//  the same answer, and it could produce pills the bars vanish on (see
//  PillColor.swift for why the palette is fixed).
//
//  Deliberately a row of bound circles rather than a Picker: a menu hides the
//  choice behind a click, and this is a look you judge by seeing the options
//  at once.
//

import SwiftUI

struct PillColorPicker: View {
    @Binding var selection: PillColor

    var body: some View {
        HStack(spacing: 7) {
            ForEach(PillColor.allCases) { color in
                swatch(color)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pill colour")
        .accessibilityIdentifier("PillColorPicker")
    }

    private func swatch(_ color: PillColor) -> some View {
        let selected = selection == color
        return Button {
            selection = color
        } label: {
            Circle()
                .fill(Color(nsColor: color.swatch))
                // A graphite chip on a dark card has no edge of its own: the
                // hairline is what makes every swatch a visible target.
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
                .frame(width: 15, height: 15)
                .overlay {
                    if selected {
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.85), lineWidth: 1.5)
                            .padding(-3)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(color.displayName)
        .accessibilityLabel(color.displayName)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
