//
//  OnboardingTheme.swift
//  Oto
//
//  The stage's colours, resolved through the app's one adaptive table. The
//  onboarding is a native window, so it follows the system appearance: in
//  Light Mode the stage is paper and the ink is dark, and every value here
//  mirrors by construction. The stage itself is pure white or pure black, not
//  the window's native background — the onboarding is a page, not a panel.
//

import AppKit
import SwiftUI

enum OnboardingTheme {
    /// The page: pure white in Light, pure black in Dark. The shader paints the
    /// same value behind the first frame, so there is no seam anywhere.
    static var ground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .black : .white
        })
    }

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

    // MARK: - The media panel

    /// The chapter's film frame. Until a chapter has a picture or a film, a
    /// two-stop field stands in: cool silver on paper, deep slate at night —
    /// the only place on the stage with a colour of its own.
    static var mediaTop: Color { self.tint(light: (0.90, 0.94, 1.00), dark: (0.13, 0.17, 0.24)) }
    static var mediaBottom: Color { self.tint(light: (0.73, 0.82, 0.95), dark: (0.05, 0.07, 0.11)) }
    static var mediaEdge: Color { OtoPalette.ink.opacity(0.10) }

    // MARK: - Private

    private static func tint(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let value = isDark ? dark : light
            return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: 1)
        })
    }
}
