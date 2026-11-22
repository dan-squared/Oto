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

    static var divider: Color { OtoPalette.ink.opacity(0.10) }

    /// The one pill: the app's inversion — light on dark, ink on paper.
    static var pill: Color { OtoPalette.ink }
    static var pillLabel: Color { OtoPalette.ground }

    // MARK: - The chapter tag

    /// The small pill that names a chapter, above its title: a quiet lift
    /// off the page with the icon and short text at reading weight.
    static var tagIdle: Color { OtoPalette.ink.opacity(0.06) }
    static var tagIdleText: Color { OtoPalette.muted }

    // MARK: - The media panel

    /// The chapter's frame on the right. With no pictures in the walk, this is
    /// an empty, quiet surface: a neutral lift off the page, never a colour of
    /// its own — cool blue read as a different window in Dark Mode.
    static var mediaTop: Color { self.tint(light: (0.975, 0.975, 0.98), dark: (0.32, 0.32, 0.325)) }
    static var mediaBottom: Color { self.tint(light: (0.94, 0.94, 0.945), dark: (0.26, 0.26, 0.265)) }
    static var mediaEdge: Color { OtoPalette.ink.opacity(0.07) }

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
