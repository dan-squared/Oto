//
//  SpeechLocaleMatchingTests.swift
//  OtoTests
//
//  Pure locale-matching tests: synthetic candidate lists, no system calls,
//  no hardware. Deterministic.
//

import Foundation
import Testing
@testable import Oto

struct SpeechLocaleMatchingTests {
    private static let candidates = [
        Locale(identifier: "en_GB"),
        Locale(identifier: "en_US"),
        Locale(identifier: "de_DE"),
        Locale(identifier: "fr_FR"),
    ]

    @Test func exactMatchWins() {
        #expect(
            SpeechLocaleMatching.bestMatch(
                for: Locale(identifier: "en_US"),
                in: Self.candidates
            ) == Locale(identifier: "en_US")
        )
    }

    @Test func sameLanguageAnyRegionFallsBack() {
        // en_AU is not offered: any English region matches (stable order).
        let match = SpeechLocaleMatching.bestMatch(
            for: Locale(identifier: "en_AU"),
            in: Self.candidates
        )
        #expect(match?.language.languageCode?.identifier == "en")
    }

    @Test func unknownLanguageMatchesNothing() {
        #expect(
            SpeechLocaleMatching.bestMatch(
                for: Locale(identifier: "ja_JP"),
                in: Self.candidates
            ) == nil
        )
    }

    @Test func emptyCandidatesMatchNothing() {
        #expect(
            SpeechLocaleMatching.bestMatch(
                for: Locale(identifier: "en_US"),
                in: [Locale]()
            ) == nil
        )
    }

    @Test func regionSpecificMatchPrefersSameRegion() {
        // en_GB requested: en_GB outranks en_US (same language, same region
        // beats same language, other region).
        #expect(
            SpeechLocaleMatching.bestMatch(
                for: Locale(identifier: "en_GB"),
                in: Self.candidates
            ) == Locale(identifier: "en_GB")
        )
    }

    @Test func regionOverrideWidensToLanguageRegion() {
        // The motivating bug class: when system language and region
        // disagree, macOS reports en_US@rg=… (BCP-47 en-US-u-rg-…) — no
        // engine lists that string, so exact comparison must widen to
        // language+region instead of reporting unsupported.
        let match = SpeechLocaleMatching.bestMatch(
            for: Locale(identifier: "en-US-u-rg-eszzzz"),
            in: Self.candidates
        )
        #expect(match == Locale(identifier: "en_US"))
    }

    @Test func scriptAwareMatchingPrefersMatchingScriptBeforeCrossScriptFallback() {
        let zhCandidates = [
            Locale(identifier: "zh_CN"),
            Locale(identifier: "zh_TW"),
        ]
        // zh-Hant must resolve to zh_TW (Traditional), not zh_CN (Simplified).
        #expect(
            SpeechLocaleMatching.bestMatch(
                for: Locale(identifier: "zh-Hant"),
                in: zhCandidates
            ) == Locale(identifier: "zh_TW")
        )
        // zh-Hant-HK widens to same script zh_TW rather than zh_CN.
        #expect(
            SpeechLocaleMatching.bestMatch(
                for: Locale(identifier: "zh-Hant-HK"),
                in: zhCandidates
            ) == Locale(identifier: "zh_TW")
        )
        // zh-Hans resolves to zh_CN (Simplified).
        #expect(
            SpeechLocaleMatching.bestMatch(
                for: Locale(identifier: "zh-Hans"),
                in: zhCandidates
            ) == Locale(identifier: "zh_CN")
        )
    }
}
