//
//  OtoThemeTests.swift
//  OtoTests
//
//  Theme contract: every palette pair resolves differently per scheme.
//  Pixels belong to the device matrix; resolution belongs here.
//

import AppKit
import Testing
@testable import Oto

struct OtoThemeTests {
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
