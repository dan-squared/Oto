//
//  OnboardingTheme.swift
//  Oto
//
//  The stage's colours, resolved through the app's one adaptive table. The
//  onboarding is a native window, so it follows the system appearance: in
//  Light Mode the stage is paper and the ink is dark, and every value here
//  mirrors by construction. Nothing on the stage is a literal white or black.
//

import SwiftUI

enum OnboardingTheme {
    /// Type and icons.
    static var ink: Color { OtoPalette.ink }
    /// Secondary lines under a title.
    static var muted: Color { OtoPalette.muted }
    /// Tertiary notes and hints.
    static var faint: Color { OtoPalette.faint }

    /// A chapter card's fill: a few percent of ink, so it reads as a slightly
    /// raised surface on either polarity.
    static var card: Color { OtoPalette.ink.opacity(0.055) }
    static var cardEdge: Color { OtoPalette.ink.opacity(0.10) }

    /// A quiet well — the try-it field, a preview's inner plate.
    static var field: Color { OtoPalette.ink.opacity(0.05) }
    static var fieldEdge: Color { OtoPalette.ink.opacity(0.12) }

    static var divider: Color { OtoPalette.ink.opacity(0.10) }

    /// The chapter tag pill: quieter where a chapter only shows.
    static var tagIdle: Color { OtoPalette.ink.opacity(0.08) }
    static var tagActive: Color { OtoPalette.ink.opacity(0.16) }
    static var tagIdleText: Color { OtoPalette.ink.opacity(0.7) }

    /// The footer's clock.
    static var dashTrack: Color { OtoPalette.ink.opacity(0.18) }
    static var dashFill: Color { OtoPalette.ink.opacity(0.92) }

    /// The one pill: the app's inversion — light on dark, ink on paper.
    static var pill: Color { OtoPalette.ink }
    static var pillLabel: Color { OtoPalette.ground }
}
