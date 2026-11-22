//
//  OtoMotion.swift
//  Oto
//
//  One motion family for interface transitions (the reference's two-spring
//  system). New Theme-kit surfaces use these; the pill/catcher renderers
//  keep their tuned timings. Reduce Motion collapses everything to
//  immediate — the Mac's setting, honored, never argued with.
//

import AppKit
import SwiftUI

enum OtoMotion {
    /// Follows the Mac's Reduce Motion setting.
    nonisolated static var reduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Place-to-place (page slides, rail selection).
    static var glide: Animation? {
        reduced ? nil : .spring(response: 0.34, dampingFraction: 0.82)
    }

    /// Arrive/leave (overlays, confirmations).
    static var settle: Animation? {
        reduced ? nil : .spring(response: 0.30, dampingFraction: 0.86)
    }

    /// Hovers only.
    static var quick: Animation? {
        reduced ? nil : .easeOut(duration: 0.14)
    }
}
