//
//  SpeechLocalePreferenceTests.swift
//  OtoTests
//
//  Unit tests for `SpeechLocalePreference`: UserDefaults persistence,
//  system fallback, cache invalidation / notification contract, and
//  deterministic locale deduplication + sorting.
//

import Foundation
import Synchronization
import Testing
@testable import Oto

struct SpeechLocalePreferenceTests {
    private static let sampleLocales = [
        Locale(identifier: "en_US"),
        Locale(identifier: "de_DE"),
        Locale(identifier: "fr_FR"),
    ]

    private func makeIsolatedDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "test.oto.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, suiteName)
    }

    @Test func defaultPreferenceIsNilAndResolvesToSystemLocale() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(SpeechLocalePreference.selectedIdentifier(defaults: defaults) == nil)
        let system = Locale(identifier: "fr-FR")
        #expect(SpeechLocalePreference.effectiveLocale(system: system, defaults: defaults) == system)
    }

    @Test func explicitIdentifierResolvesAndWhitespaceResetsToNil() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = LocaleSnapshotCache(notificationCenter: NotificationCenter())

        SpeechLocalePreference.setSelectedIdentifier("de-DE", defaults: defaults, cache: cache)
        #expect(SpeechLocalePreference.selectedIdentifier(defaults: defaults) == "de-DE")
        #expect(
            SpeechLocalePreference.effectiveLocale(
                system: Locale(identifier: "en-US"),
                defaults: defaults
            ) == Locale(identifier: "de-DE")
        )

        SpeechLocalePreference.setSelectedIdentifier("  ja-JP \n", defaults: defaults, cache: cache)
        #expect(SpeechLocalePreference.selectedIdentifier(defaults: defaults) == "ja-JP")

        SpeechLocalePreference.setSelectedIdentifier("   \t ", defaults: defaults, cache: cache)
        #expect(SpeechLocalePreference.selectedIdentifier(defaults: defaults) == nil)
        #expect(
            SpeechLocalePreference.effectiveLocale(
                system: Locale(identifier: "en-US"),
                defaults: defaults
            ) == Locale(identifier: "en-US")
        )

        SpeechLocalePreference.setSelectedIdentifier("es-ES", defaults: defaults, cache: cache)
        SpeechLocalePreference.setSelectedIdentifier("", defaults: defaults, cache: cache)
        #expect(SpeechLocalePreference.selectedIdentifier(defaults: defaults) == nil)
    }

    @Test func changingPreferencePostsNotificationAndInvalidatesCache() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let center = NotificationCenter()
        let invalidations = Mutex(0)
        let token = center.addObserver(
            forName: .otoSpeechLocaleInvalidated,
            object: nil,
            queue: nil
        ) { _ in
            invalidations.withLock { $0 += 1 }
        }
        defer { center.removeObserver(token) }

        let cache = LocaleSnapshotCache(notificationCenter: center)
        cache.store(supported: Self.sampleLocales, installed: Self.sampleLocales)

        SpeechLocalePreference.setSelectedIdentifier("de-DE", defaults: defaults, cache: cache)
        #expect(invalidations.withLock { $0 } == 1)
        #expect(cache.resolve(current: Locale(identifier: "en-US")) == .requery)

        cache.store(supported: Self.sampleLocales, installed: Self.sampleLocales)
        SpeechLocalePreference.setSelectedIdentifier("fr-FR", defaults: defaults, cache: cache)
        #expect(invalidations.withLock { $0 } == 2)
        #expect(cache.resolve(current: Locale(identifier: "en-US")) == .requery)

        cache.store(supported: Self.sampleLocales, installed: Self.sampleLocales)
        SpeechLocalePreference.setSelectedIdentifier(nil, defaults: defaults, cache: cache)
        #expect(invalidations.withLock { $0 } == 3)
        #expect(cache.resolve(current: Locale(identifier: "en-US")) == .requery)
    }

    @Test func settingSamePreferenceTwiceDoesNotSpuriouslyInvalidate() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let center = NotificationCenter()
        let invalidations = Mutex(0)
        let token = center.addObserver(
            forName: .otoSpeechLocaleInvalidated,
            object: nil,
            queue: nil
        ) { _ in
            invalidations.withLock { $0 += 1 }
        }
        defer { center.removeObserver(token) }

        let cache = LocaleSnapshotCache(notificationCenter: center)
        cache.store(supported: Self.sampleLocales, installed: Self.sampleLocales)

        // Already nil -> setting nil or whitespace does not invalidate.
        SpeechLocalePreference.setSelectedIdentifier(nil, defaults: defaults, cache: cache)
        SpeechLocalePreference.setSelectedIdentifier("   ", defaults: defaults, cache: cache)
        #expect(invalidations.withLock { $0 } == 0)
        #expect(cache.resolve(current: Locale(identifier: "en-US")) != .requery)

        // First set invalidates once; repeating the same value does not.
        SpeechLocalePreference.setSelectedIdentifier("de-DE", defaults: defaults, cache: cache)
        #expect(invalidations.withLock { $0 } == 1)
        cache.store(supported: Self.sampleLocales, installed: Self.sampleLocales)

        SpeechLocalePreference.setSelectedIdentifier("de-DE", defaults: defaults, cache: cache)
        #expect(invalidations.withLock { $0 } == 1)
        #expect(cache.resolve(current: Locale(identifier: "en-US")) != .requery)
    }

    @Test func dedupedSortedLocalesDeduplicatesAndSortsDeterministically() {
        let displayLocale = Locale(identifier: "en-US")
        let input = [
            Locale(identifier: "fr-FR"),
            Locale(identifier: "en_US"),
            Locale(identifier: "de_DE"),
            Locale(identifier: "en-US"),
            Locale(identifier: "fr_FR"),
            Locale(identifier: "de-DE"),
        ]

        let result = SpeechLocalePreference.dedupedSortedLocales(input, in: displayLocale)
        let tags = result.map { $0.identifier(.bcp47) }
        #expect(tags == ["en-US", "fr-FR", "de-DE"])

        let names = result.map { SpeechLocalePreference.displayName(for: $0, in: displayLocale) }
        #expect(names == ["English (US)", "French (France)", "German (Germany)"])
    }

    @Test func displayNameStripsUserCountryExtensionAndUsesConciseRegionLabels() {
        let displayLocale = Locale(identifier: "en-US")

        let enUSWithEthiopia = SpeechLocalePreference.displayName(
            for: Locale(identifier: "en-US-u-rg-etzzzz"),
            in: displayLocale
        )
        #expect(enUSWithEthiopia == "English (US)")
        #expect(!enUSWithEthiopia.contains("Ethiopia"))
        #expect(!enUSWithEthiopia.contains("Region="))

        let enGBWithEthiopia = SpeechLocalePreference.displayName(
            for: Locale(identifier: "en-GB-u-rg-etzzzz"),
            in: displayLocale
        )
        #expect(enGBWithEthiopia == "English (UK)")
        #expect(!enGBWithEthiopia.contains("Ethiopia"))
        #expect(!enGBWithEthiopia.contains("Region="))

        #expect(
            SpeechLocalePreference.displayName(for: Locale(identifier: "mul"), in: displayLocale)
                == "Multilingual"
        )
    }

    @Test func displayNamesOmitsRedundantRegionForSingleVariantLanguages() {
        let displayLocale = Locale(identifier: "en-US")
        let locales = [
            Locale(identifier: "en-US"),
            Locale(identifier: "en-GB"),
            Locale(identifier: "en-AU"),
            Locale(identifier: "ja-JP"),
            Locale(identifier: "ko-KR"),
            Locale(identifier: "hi-IN"),
        ]

        let names = SpeechLocalePreference.displayNames(for: locales, in: displayLocale)
        #expect(names["en-US"] == "English (US)")
        #expect(names["en-GB"] == "English (UK)")
        #expect(names["en-AU"] == "English (Australia)")
        #expect(names["ja-JP"] == "Japanese")
        #expect(names["ko-KR"] == "Korean")
        #expect(names["hi-IN"] == "Hindi")
    }

    @Test func canonicalizesUnderscoreLocaleIdentifiersToBCP47() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = LocaleSnapshotCache(notificationCenter: NotificationCenter())

        SpeechLocalePreference.setSelectedIdentifier("en_US", defaults: defaults, cache: cache)
        #expect(SpeechLocalePreference.selectedIdentifier(defaults: defaults) == "en-US")

        // Pre-existing legacy underscore value in UserDefaults also reads canonically.
        defaults.set("fr_FR", forKey: SpeechLocalePreference.defaultsKey)
        #expect(SpeechLocalePreference.selectedIdentifier(defaults: defaults) == "fr-FR")
    }
}
