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
    static let ink = Color(nsColor: NS.ink)
    static let muted = Color(nsColor: NS.muted)
    static let faint = Color(nsColor: NS.faint)
    static let hairline = Color(nsColor: NS.hairline)
    static let wash = Color(nsColor: NS.wash)
    static let hover = Color(nsColor: NS.hover)

    /// Test accessor: the white component of a pair token under an
    /// explicit appearance (all tokens are monochrome by construction).
    nonisolated static func white(_ color: NSColor, for name: NSAppearance.Name) -> CGFloat {
        let previous = NSAppearance.current
        NSAppearance.current = NSAppearance(named: name)
        defer { NSAppearance.current = previous }
        guard let gray = color.usingColorSpace(.genericGray) else { return -1 }
        var white: CGFloat = -1
        gray.getWhite(&white, alpha: nil)
        return white
    }

    enum NS {
        nonisolated static let ground = pair(1.0, 0.11)
        nonisolated static let ink = pair(0.09, 0.93)
        nonisolated static let muted = pair(0.55, 0.58)
        nonisolated static let faint = pair(0.83, 0.32)
        nonisolated static let hairline = pair(0.91, 0.20)
        nonisolated static let wash = pair(0.937, 0.175)
        nonisolated static let hover = pair(0.965, 0.15)

        nonisolated private static func pair(_ light: CGFloat, _ dark: CGFloat) -> NSColor {
            NSColor(name: nil) { appearance in
                let dim = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(white: dim ? dark : light, alpha: 1)
            }
        }
    }
}
