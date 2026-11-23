//
//  OtoPalette.swift
//  Oto
//
//  The app's color language, copied value-for-value from the reference
//  browser's pairs (ground/ink/muted/faint/hairline/wash/hover). Every
//  color is a light/dark pair resolving against the window's appearance —
//  nothing outside this file knows which scheme is live.
//

import AppKit
import SwiftUI

enum OtoPalette {
    static let ground = Color(nsColor: NS.ground)
    /// Settings' own ground: macOS's default dark window colour in dark
    /// mode, pure white in light. Not the earlier custom near-black.
    static let settingsGround = Color(nsColor: NS.settingsGround)
    static let ink = Color(nsColor: NS.ink)
    static let muted = Color(nsColor: NS.muted)
    static let faint = Color(nsColor: NS.faint)
    static let hairline = Color(nsColor: NS.hairline)
    static let wash = Color(nsColor: NS.wash)
    static let hover = Color(nsColor: NS.hover)
    static let safe = Color(nsColor: NS.safe)
    static let unsafe = Color(nsColor: NS.unsafe)

    /// Empty-state example chips carry no hue of their own any more: the
    /// panel is neutral and only the chip's icon is coloured, from the pill
    /// palette (`PillColor.accent(forDark:)`, user ask 2026-11-01).

    /// Opacity of the selected sidebar row's monochrome fill. Both schemes
    /// share this alpha with opposite polarity (white on dark, black on
    /// light), so the two looks stay mirrored by construction and the
    /// "tinted translucent" strength is one number, not a hunt.
    nonisolated static let selectedFillOpacity: CGFloat = 0.85

    /// Test accessor: the white component of a pair token under an
    /// explicit appearance (all tokens are monochrome by construction).
    /// `highContrastOverride` lets tests exercise Increase Contrast without
    /// mutating system preferences (on macOS 27 `NSAppearance(named: .accessibilityHighContrastAqua)`
    /// normalizes its `.name` to `.aqua` unless Increase Contrast is live).
    nonisolated static func white(
        _ color: NSColor,
        for name: NSAppearance.Name,
        highContrastOverride: Bool? = nil
    ) -> CGFloat {
        guard let appearance = NSAppearance(named: name) else { return -1 }
        let previousOverride = NS.highContrastOverride
        NS.highContrastOverride = highContrastOverride
        defer { NS.highContrastOverride = previousOverride }
        var white: CGFloat = -1
        appearance.performAsCurrentDrawingAppearance {
            if let gray = color.usingColorSpace(.genericGray) {
                gray.getWhite(&white, alpha: nil)
            }
        }
        return white
    }

    enum NS {
        nonisolated static let ground = pair(1.0, 0.11, highContrastLight: 1.0, highContrastDark: 0.06)
        /// Settings-only. Light stays pure white (the measured grouped-form
        /// ground); dark uses macOS's own dark under-page background
        /// (`NSColor.underPageBackgroundColor`, 0.118 measured on this SDK),
        /// not a custom near-black. The grouped form still reads as a card
        /// against it without crushing the window.
        nonisolated static let settingsGround = pair(1.0, 0.118, highContrastLight: 1.0, highContrastDark: 0.06)
        nonisolated static let ink = pair(0.09, 0.93, highContrastLight: 0.0, highContrastDark: 1.0)
        nonisolated static let muted = pair(0.55, 0.58, highContrastLight: 0.35, highContrastDark: 0.78)
        nonisolated static let faint = pair(0.83, 0.32, highContrastLight: 0.65, highContrastDark: 0.48)
        nonisolated static let hairline = pair(0.91, 0.20, highContrastLight: 0.68, highContrastDark: 0.45)
        nonisolated static let wash = pair(0.937, 0.175, highContrastLight: 0.90, highContrastDark: 0.22)
        nonisolated static let hover = pair(0.965, 0.15, highContrastLight: 0.93, highContrastDark: 0.26)
        nonisolated static let safe = tint(
            light: (0.08, 0.50, 0.24), dark: (0.29, 0.87, 0.50),
            highContrastLight: (0.04, 0.40, 0.18), highContrastDark: (0.40, 0.96, 0.60)
        )
        nonisolated static let unsafe = tint(
            light: (0.71, 0.33, 0.04), dark: (0.98, 0.75, 0.14),
            highContrastLight: (0.58, 0.24, 0.0), highContrastDark: (1.0, 0.84, 0.26)
        )

        /// Test-only seam used by `OtoPalette.white(_:for:highContrastOverride:)`.
        nonisolated(unsafe) static var highContrastOverride: Bool?

        nonisolated private static let supportedAppearances: [NSAppearance.Name] = [
            .accessibilityHighContrastDarkAqua,
            .accessibilityHighContrastAqua,
            .darkAqua,
            .aqua,
        ]

        nonisolated private static func resolvePolarity(_ appearance: NSAppearance) -> (dark: Bool, highContrast: Bool) {
            let systemIncreaseContrast = highContrastOverride
                ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            switch appearance.name {
            case .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark:
                return (true, true)
            case .accessibilityHighContrastAqua, .accessibilityHighContrastVibrantLight:
                return (false, true)
            default:
                break
            }
            switch appearance.bestMatch(from: supportedAppearances) {
            case .accessibilityHighContrastDarkAqua:
                return (true, true)
            case .accessibilityHighContrastAqua:
                return (false, true)
            case .darkAqua:
                return (true, systemIncreaseContrast)
            default:
                return (false, systemIncreaseContrast)
            }
        }

        nonisolated private static func tint(
            light: (CGFloat, CGFloat, CGFloat),
            dark: (CGFloat, CGFloat, CGFloat),
            highContrastLight: (CGFloat, CGFloat, CGFloat)? = nil,
            highContrastDark: (CGFloat, CGFloat, CGFloat)? = nil
        ) -> NSColor {
            NSColor(name: nil) { appearance in
                let (isDark, isHighContrast) = resolvePolarity(appearance)
                let c: (CGFloat, CGFloat, CGFloat)
                if isDark {
                    c = (isHighContrast ? highContrastDark : nil) ?? dark
                } else {
                    c = (isHighContrast ? highContrastLight : nil) ?? light
                }
                return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
            }
        }

        nonisolated private static func pair(
            _ light: CGFloat,
            _ dark: CGFloat,
            highContrastLight: CGFloat? = nil,
            highContrastDark: CGFloat? = nil
        ) -> NSColor {
            NSColor(name: nil) { appearance in
                let (isDark, isHighContrast) = resolvePolarity(appearance)
                let value: CGFloat
                if isDark {
                    value = (isHighContrast ? highContrastDark : nil) ?? dark
                } else {
                    value = (isHighContrast ? highContrastLight : nil) ?? light
                }
                return NSColor(white: value, alpha: 1)
            }
        }
    }
}
