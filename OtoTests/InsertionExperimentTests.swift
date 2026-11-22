//
//  InsertionExperimentTests.swift
//  OtoTests
//
//  Phase 8b Slice 3: layout-aware paste keys (pure walker fully scripted,
//  incl. Dvorak remap + failure fallback) and the hidden A/B seam
//  (defaults byte-identical to today; parsing pinned).
//

import Carbon.HIToolbox
import Foundation
import Testing
@testable import Oto

@MainActor
struct InsertionExperimentTests {
    /// Scripted layout: keycode → produced character (US positions).
    private static func usTranslator(_ map: [UInt16: String]) -> (UInt16) -> String? {
        { map[$0] }
    }

    @Test func walkerFindsLetterByPosition() {
        let us: [UInt16: String] = [
            UInt16(kVK_ANSI_V): "v", UInt16(kVK_ANSI_C): "c",
            UInt16(kVK_ANSI_Z): "z", UInt16(kVK_ANSI_A): "a",
        ]
        #expect(PasteKeycodeResolver.keyCode(
            for: "v", translate: Self.usTranslator(us)
        ) == UInt16(kVK_ANSI_V))
        #expect(PasteKeycodeResolver.keyCode(
            for: "C", translate: Self.usTranslator(us)
        ) == UInt16(kVK_ANSI_C))
    }

    @Test func walkerFollowsDvorakRemap() {
        // Dvorak: "v" lives where QWERTY keeps "." (ANSI_Period).
        let dvorak: [UInt16: String] = [
            UInt16(kVK_ANSI_V): "v",
            UInt16(kVK_ANSI_Period): "v",
        ]
        #expect(PasteKeycodeResolver.keyCode(
            for: "v", translate: Self.usTranslator(dvorak)
        ) == UInt16(kVK_ANSI_V))
        // First position wins (scan order 0..<128): V's own key sorts
        // before Period, so the native key is preferred either way.
        let moved: [UInt16: String] = [UInt16(kVK_ANSI_Period): "v"]
        #expect(PasteKeycodeResolver.keyCode(
            for: "v", translate: Self.usTranslator(moved)
        ) == UInt16(kVK_ANSI_Period))
    }

    @Test func walkerFailsOpenToNil() {
        #expect(PasteKeycodeResolver.keyCode(
            for: "v", translate: Self.usTranslator([:])
        ) == nil)
        #expect(PasteKeycodeResolver.keyCode(
            for: "v", translate: { _ in nil }
        ) == nil)
    }

    @Test func fallbacksMatchToday() {
        #expect(PasteKeycodeResolver.fallback(for: "v") == UInt16(kVK_ANSI_V))
        #expect(PasteKeycodeResolver.fallback(for: "C") == UInt16(kVK_ANSI_C))
        #expect(PasteKeycodeResolver.fallback(for: "z") == UInt16(kVK_ANSI_Z))
        #expect(PasteKeycodeResolver.fallback(for: "q") == UInt16(kVK_ANSI_V))
    }

    @Test func experimentDefaultsMatchToday() {
        let defaults = UserDefaults(suiteName: "test.oto.\(UUID().uuidString)")!
        let xp = InsertionExperiment.current(defaults: defaults)
        #expect(!xp.useDefaultEventSource)
        #expect(xp.keyStepNs == InsertionTimings().keyStep)
        #expect(xp.restoreDelayNs == InsertionTimings().restoreDelay)
    }

    @Test func experimentParsesOverrides() {
        let defaults = UserDefaults(suiteName: "test.oto.\(UUID().uuidString)")!
        defaults.set("default", forKey: InsertionExperiment.sourceKey)
        defaults.set(UInt64(0), forKey: InsertionExperiment.keyStepKey)
        defaults.set(UInt64(500_000_000), forKey: InsertionExperiment.restoreDelayKey)
        let xp = InsertionExperiment.current(defaults: defaults)
        #expect(xp.useDefaultEventSource)
        #expect(xp.keyStepNs == 0)
        #expect(xp.restoreDelayNs == 500_000_000)
        // Unknown source strings fail safe to private (today).
        defaults.set("quantum", forKey: InsertionExperiment.sourceKey)
        #expect(!InsertionExperiment.current(defaults: defaults).useDefaultEventSource)
    }
}
