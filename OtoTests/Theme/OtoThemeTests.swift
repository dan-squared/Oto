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

// `OtoPalette.white` swaps the process-wide NSAppearance.current; running
// these in parallel with other appearance-sensitive tests races the value.
@Suite(.serialized)
struct OtoThemeTests {
    @Test func palettePairsDifferByScheme() {
        let tokens: [NSColor] = [
            OtoPalette.NS.ground, OtoPalette.NS.settingsGround, OtoPalette.NS.ink,
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

    @Test func selectedFillOpacityIsUsable() {
        // The selected sidebar pill is one alpha used by both schemes with
        // opposite polarity; 0 keeps the row invisible, >1 is not a fill.
        #expect(OtoPalette.selectedFillOpacity > 0)
        #expect(OtoPalette.selectedFillOpacity <= 1)
    }

    /// Settings dark uses macOS's default dark ground (not a custom
    /// near-black); light must stay the measured pure white.
    @Test func settingsGroundUsesSystemDarkAndUnchangedInLight() {
        let settingsDark = OtoPalette.white(OtoPalette.NS.settingsGround, for: .darkAqua)
        // AppKit resolves the same gray through different color spaces
        // (~0.09–0.12 depending on the current display profile); the contract
        // is "macOS default dark ground", not one exact byte.
        #expect(settingsDark > 0.08 && settingsDark < 0.13)
        #expect(OtoPalette.white(OtoPalette.NS.settingsGround, for: .aqua) == 1.0)
    }

    @Test func highContrastAppearancesIncreaseSeparation() {
        // UI-12: High Contrast appearances resolve cleanly via
        // performAsCurrentDrawingAppearance and strengthen contrast.
        let standardLightInk = OtoPalette.white(OtoPalette.NS.ink, for: .aqua, highContrastOverride: false)
        let highContrastLightInk = OtoPalette.white(OtoPalette.NS.ink, for: .aqua, highContrastOverride: true)
        #expect(highContrastLightInk < standardLightInk)

        let standardDarkInk = OtoPalette.white(OtoPalette.NS.ink, for: .darkAqua, highContrastOverride: false)
        let highContrastDarkInk = OtoPalette.white(OtoPalette.NS.ink, for: .darkAqua, highContrastOverride: true)
        #expect(highContrastDarkInk > standardDarkInk)

        let standardLightHairline = OtoPalette.white(OtoPalette.NS.hairline, for: .aqua, highContrastOverride: false)
        let highContrastLightHairline = OtoPalette.white(OtoPalette.NS.hairline, for: .aqua, highContrastOverride: true)
        #expect(highContrastLightHairline < standardLightHairline)

        let standardDarkHairline = OtoPalette.white(OtoPalette.NS.hairline, for: .darkAqua, highContrastOverride: false)
        let highContrastDarkHairline = OtoPalette.white(OtoPalette.NS.hairline, for: .darkAqua, highContrastOverride: true)
        #expect(highContrastDarkHairline > standardDarkHairline)
    }
}
