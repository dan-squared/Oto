//
//  PillColorTests.swift
//  OtoTests
//
//  The pill's colour is one persisted scalar plus one derivation. Both are
//  pure: default resolution, round-trip, the palette's shape, and the
//  Reduce-Transparency swap are all headless (no window server, no material).
//

import AppKit
import Foundation
import Testing
@testable import Oto

@MainActor
struct PillColorTests {
    private func scratchDefaults() -> (UserDefaults, String) {
        let suite = "oto-pill-color-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func freshInstallIsGraphite() {
        // User ask, 2026-11-01: the default is black, not red.
        #expect(PillColor.freshDefault == .graphite)
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(PillColor.current(defaults: defaults) == .graphite)
    }

    @Test func unknownStoredValueFallsBack() {
        // A stale string (renamed case, hand-edited plist) must never wedge
        // the pill on a colour that no longer exists.
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("chartreuse", forKey: PillColor.defaultsKey)
        #expect(PillColor.current(defaults: defaults) == .graphite)
    }

    @Test func saveRoundTrips() {
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        for color in PillColor.allCases {
            PillColor.save(color, defaults: defaults)
            #expect(PillColor.current(defaults: defaults) == color)
        }
    }

    @Test func settingsKeyIsPinned() {
        // GeneralPane's @AppStorage literal. A silent rename would leave the
        // picker writing a key nobody reads.
        #expect(PillColor.defaultsKey == "app.Oto.pillColor")
    }

    @Test func casesAreDistinctAndNamed() {
        #expect(Set(PillColor.allCases.map(\.rawValue)).count == PillColor.allCases.count)
        #expect(PillColor.allCases.allSatisfy { !$0.displayName.isEmpty })
        #expect(Set(PillColor.allCases.map(\.displayName)).count == PillColor.allCases.count)
    }

    @Test func everyColorBuildsTheSameStopCount() {
        // The ramp is one 9-stop gradient for every colour (tips mirrored
        // around the waist). A palette that changed the count would change
        // the ramp's shape, not just its hue.
        for color in PillColor.allCases {
            let palette = PillPalette(color: color)
            #expect(palette.bodyStops.count == 9)
            #expect(palette.bodyLocations.count == 9)
            #expect(palette.bodyColors(opaque: false).count == 9)
            #expect(palette.bodyLocations.map(\.doubleValue) == PillPalette.stops.map(Double.init))
            // Symmetric by construction: stop i and stop 8-i share a colour.
            for i in 0..<4 {
                #expect(palette.bodyStops[i].color.alphaComponent
                    == palette.bodyStops[8 - i].color.alphaComponent)
            }
        }
    }

    @Test func waistIsTheDensestStop() {
        for color in PillColor.allCases {
            let alphas = PillPalette(color: color).bodyStops.map(\.color.alphaComponent)
            #expect(alphas[4] == PillPalette.waistAlpha)
            #expect(alphas[4] >= (alphas.max() ?? 0))
            #expect(alphas[0] == PillPalette.tipAlpha)
        }
    }

    @Test func reduceTransparencyGoesOpaque() {
        // With the frost hidden the ramp alone carries the colour, so every
        // stop must be full alpha — the fallback is flat colour, never grey.
        for color in PillColor.allCases {
            let palette = PillPalette(color: color)
            #expect(palette.bodyColors(opaque: true).allSatisfy { $0.alpha == 1 })
            #expect(palette.bodyColors(opaque: false).contains { $0.alpha < 1 })
        }
    }

    @Test func graphiteIsUntintedAndDark() {
        // Black glass, not silver: the material is left untinted and the
        // waist really is near-black.
        let palette = PillPalette(color: .graphite)
        #expect(palette.tint == nil)
        let waist = palette.bodyStops[4].color.usingColorSpace(.sRGB)
        let luminance = 0.2126 * waist!.redComponent
            + 0.7152 * waist!.greenComponent
            + 0.0722 * waist!.blueComponent
        #expect(luminance < 0.16)
        // And its tips stay dark too — a graphite pill lightened like the
        // chromatic ones would read as a grey capsule.
        #expect(PillColor.graphite.tipDepth < PillColor.crimson.tipDepth)
    }

    @Test func chromaticPillsKeepTheirHue() {
        // Every non-graphite palette must keep the hue the user picked at its
        // waist (a mix bug would silently turn crimson to salmon).
        for color in PillColor.allCases where color != .graphite {
            let palette = PillPalette(color: color)
            let base = color.base.usingColorSpace(.sRGB)!
            let waist = palette.bodyStops[4].color.usingColorSpace(.sRGB)!
            #expect(abs(waist.redComponent - base.redComponent) < 0.02)
            #expect(abs(waist.greenComponent - base.greenComponent) < 0.02)
            #expect(abs(waist.blueComponent - base.blueComponent) < 0.02)
            #expect(palette.tint != nil)
        }
    }

    @Test func swatchesAreOpaqueAndMatchTheWaist() {
        // The Settings chip is the colour the user will actually see, at
        // full alpha (a 0.74-alpha chip is nearly invisible on a card).
        for color in PillColor.allCases {
            let swatch = color.swatch.usingColorSpace(.sRGB)!
            #expect(swatch.alphaComponent == 1)
            let waist = PillPalette(color: color).bodyStops[4].color.usingColorSpace(.sRGB)!
            #expect(abs(swatch.redComponent - waist.redComponent) < 0.001)
            #expect(abs(swatch.greenComponent - waist.greenComponent) < 0.001)
            #expect(abs(swatch.blueComponent - waist.blueComponent) < 0.001)
        }
    }
}
