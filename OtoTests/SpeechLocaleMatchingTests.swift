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
}
