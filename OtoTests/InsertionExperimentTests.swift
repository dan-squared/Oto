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

    @Test func translateRejectsUndersizedLayoutBuffer() {
        let tiny = Data(repeating: 0, count: max(1, MemoryLayout<UCKeyboardLayout>.size - 1))
        #expect(PasteKeycodeResolver.translate(
            keyCode: UInt16(kVK_ANSI_V),
            layoutData: tiny,
            keyboardType: 0
        ) == nil)
        #expect(PasteKeycodeResolver.translate(
            keyCode: UInt16(kVK_ANSI_V),
            layoutData: Data(),
            keyboardType: 0
        ) == nil)
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

    @Test func chromiumMajorVersionParsesFourPartVersions() {
        #expect(ChromiumRaceDetector.chromiumMajorVersion("155.0.7123.42") == 155)
        #expect(ChromiumRaceDetector.chromiumMajorVersion("156.1.2.3") == 156)
        #expect(ChromiumRaceDetector.chromiumMajorVersion("157.0.0.1") == 157)
        #expect(ChromiumRaceDetector.chromiumMajorVersion("A") == nil)
        #expect(ChromiumRaceDetector.chromiumMajorVersion("Current") == nil)
        #expect(ChromiumRaceDetector.chromiumMajorVersion("155.0.1") == nil)
    }

    @Test func directTypingChunksWithoutSplittingSurrogatesAndHandlesNewlines() {
        let emoji = "😀" // 2 UTF-16 code units
        let nineteen = String(repeating: "a", count: 19) + emoji
        let strokes = DirectTextTyping.strokes(for: nineteen)
        #expect(strokes.count == 2)
        if case .text(let first) = strokes[0], case .text(let second) = strokes[1] {
            #expect(first.count == 19)
            #expect(second.count == 2)
        } else {
            Issue.record("expected two text strokes")
        }

        let multiline = DirectTextTyping.strokes(for: "hi\r\nthere\nnow")
        #expect(multiline.count == 5)
        #expect(multiline[1] == .lineBreak)
        #expect(multiline[3] == .lineBreak)
    }

    @Test func smartSpacingAddsLeadingSpaceAfterWordsAndSentencePunctuation() {
        #expect(SmartSpacing.apply(to: "world", characterBeforeCaret: "o") == " world")
        #expect(SmartSpacing.apply(to: "next sentence", characterBeforeCaret: ".") == " next sentence")
        #expect(SmartSpacing.apply(to: "after comma", characterBeforeCaret: ",") == " after comma")
        #expect(SmartSpacing.apply(to: "after paren", characterBeforeCaret: ")") == " after paren")
        #expect(SmartSpacing.apply(to: "after digit", characterBeforeCaret: "7") == " after digit")

        // Never adds space at start of field, after whitespace, opening brackets, or symbols.
        #expect(SmartSpacing.apply(to: "start", characterBeforeCaret: nil) == "start")
        #expect(SmartSpacing.apply(to: "after space", characterBeforeCaret: " ") == "after space")
        #expect(SmartSpacing.apply(to: "after newline", characterBeforeCaret: "\n") == "after newline")
        #expect(SmartSpacing.apply(to: "inside paren", characterBeforeCaret: "(") == "inside paren")
        #expect(SmartSpacing.apply(to: "mention", characterBeforeCaret: "@") == "mention")
        #expect(SmartSpacing.apply(to: "100", characterBeforeCaret: "$") == "100")

        // Never adds space before closing punctuation or already-spaced text.
        #expect(SmartSpacing.apply(to: ", however", characterBeforeCaret: "a") == ", however")
        #expect(SmartSpacing.apply(to: ". Done", characterBeforeCaret: "a") == ". Done")
        #expect(SmartSpacing.apply(to: " already spaced", characterBeforeCaret: "a") == " already spaced")
    }
}
