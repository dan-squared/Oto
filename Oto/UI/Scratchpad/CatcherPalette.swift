//
//  CatcherPalette.swift
//  Oto
//
//  Catcher remake v4: ONE adaptive palette for the recovery card.
//  Explicit per-scheme values (pinned by tests, never eyeballed
//  per-mode). Dark preserves the reference near-black card; light is
//  its system-card equivalent. Kills the hardcoded dark fill. Shared
//  with the future scratchpad if users demand it (v4 §8).
//

import SwiftUI

/// Adaptive card palette. Pure value (unit-tested dark≠light); views
/// render exclusively through `card`/`transcript`/`dim` — the
/// hardcoded-fill grep-gate proves no stray colors.
struct CatcherPalette: Equatable, Sendable {
    var cardRed: Double
    var cardGreen: Double
    var cardBlue: Double
    var textOpacity: Double
    var dimOpacity: Double
    var shadowOpacity: Double
    /// Transcript/✕ hue follows the scheme (white on dark, black on light).
    var lightText: Bool

    static let dark = CatcherPalette(
        cardRed: 0.055, cardGreen: 0.055, cardBlue: 0.065,
        textOpacity: 0.9, dimOpacity: 0.6, shadowOpacity: 0.5,
        lightText: true
    )
    static let light = CatcherPalette(
        cardRed: 1.0, cardGreen: 1.0, cardBlue: 1.0,
        textOpacity: 0.85, dimOpacity: 0.55, shadowOpacity: 0.25,
        lightText: false
    )

    static func current(_ scheme: ColorScheme) -> CatcherPalette {
        scheme == .dark ? .dark : .light
    }
}

extension CatcherPalette {
    var card: Color { Color(red: cardRed, green: cardGreen, blue: cardBlue) }
    private var ink: Color { lightText ? .white : .black }
    var transcript: Color { ink.opacity(textOpacity) }
    var dim: Color { ink.opacity(dimOpacity) }
}
