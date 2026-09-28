//
//  OtoIconTests.swift
//  OtoTests
//
//  Icon contract: every OtoIcon has a body, every body parses to a
//  non-empty path inside the 24-grid, and parsing is deterministic.
//  Pixels belong to the device matrix; geometry belongs here.
//

import AppKit
import SwiftUI
import Testing
@testable import Oto

struct OtoIconTests {
    @Test func everyIconHasABody() {
        for icon in OtoIcon.allCases {
            let body = OtoIconPath.path(for: icon)
            #expect(!body.isEmpty, "\(icon) renders nothing")
        }
    }

    @Test func everyIconFitsTheGrid() {
        for icon in OtoIcon.allCases {
            let rect = OtoIconPath.path(for: icon).boundingRect
            #expect(rect.minX >= -0.5 && rect.minY >= -0.5, "\(icon) escapes left/top: \(rect)")
            #expect(rect.maxX <= 24.5 && rect.maxY <= 24.5, "\(icon) escapes right/bottom: \(rect)")
        }
    }

    @Test func parsingIsDeterministic() {
        let first = OtoIconPath.path(for: OtoIcon.gear)
        let second = OtoIconPath.path(for: OtoIcon.gear)
        #expect(first == second)
    }

    @Test func clockCircleRenders() {
        // The set's one circle element (Clock01 face) must survive as
        // geometry, not vanish through a path-only parser.
        let rect = OtoIconPath.path(for: OtoIcon.clock).boundingRect
        #expect(rect.width > 18 && rect.height > 18)
    }

    @Test func palettePairsDifferByScheme() {
        let tokens: [NSColor] = [
            OtoPalette.NS.ground, OtoPalette.NS.ink,
            OtoPalette.NS.muted, OtoPalette.NS.faint,
            OtoPalette.NS.hairline, OtoPalette.NS.wash,
            OtoPalette.NS.hover,
        ]
        for token in tokens {
            let light = OtoPalette.white(token, for: .aqua)
            let dark = OtoPalette.white(token, for: .darkAqua)
            #expect(abs(light - dark) > 0.01, "pair does not resolve per scheme")
        }
    }
}
