//
//  LocaleSnapshotCacheTests.swift
//  OtoTests
//
//  P3 (plan/p3-locale-cache.md): pure press-path decision + flag seam.
//  No system locale calls (candidates are synthetic), no hardware, no TCC.
//  Instance tests use fresh `LocaleSnapshotCache()` per test — the `shared`
//  singleton is never touched, so no test can poison another.
//

import Foundation
import Testing
@testable import Oto

@MainActor
struct LocaleSnapshotCacheTests {
    private static let supported = [
        Locale(identifier: "de_DE"),
        Locale(identifier: "en_GB"),
        Locale(identifier: "en_US"),
    ]

    private static func snapshot(takenAt: ContinuousClock.Instant) -> LocaleSnapshot {
        LocaleSnapshot(supported: supported, installed: supported, takenAt: takenAt)
    }

    @Test func nilSnapshotRequeries() {
        let decision = LocaleSnapshotCache.decide(
            current: Locale(identifier: "en_US"),
            snapshot: nil,
            now: ContinuousClock.now
        )
        #expect(decision == .requery)
    }

    @Test func freshResolvableSnapshotIsUsed() {
        let now = ContinuousClock.now
        let decision = LocaleSnapshotCache.decide(
            current: Locale(identifier: "en_US"),
            snapshot: Self.snapshot(takenAt: now),
            now: now
        )
        // Same answer the slow path would compute — the cache skips the
        // fetch, never the match.
        let expected = SpeechLocaleMatching.bestMatch(
            for: Locale(identifier: "en_US"), in: Self.supported)
        #expect(decision == .use(expected!))
    }

    @Test func expiredSnapshotRequeries() {
        let now = ContinuousClock.now
        let stale = now - .seconds(660) // 11 min > 10-min cap
        let decision = LocaleSnapshotCache.decide(
            current: Locale(identifier: "en_US"),
            snapshot: Self.snapshot(takenAt: stale),
            now: now
        )
        #expect(decision == .requery)
    }

    @Test func unresolvableLocaleRequeries() {
        // ja_JP is in neither list: the slow path must run to produce the
        // honest `unsupportedLocale` readiness — never a stale match.
        let now = ContinuousClock.now
        let decision = LocaleSnapshotCache.decide(
            current: Locale(identifier: "ja_JP"),
            snapshot: Self.snapshot(takenAt: now),
            now: now
        )
        #expect(decision == .requery)
    }

    @Test func storeThenResolveUsesSnapshot() {
        let cache = LocaleSnapshotCache()
        #expect(cache.resolve(current: Locale(identifier: "en_US")) == .requery)
        cache.store(supported: Self.supported, installed: Self.supported)
        let decision = cache.resolve(current: Locale(identifier: "en_US"))
        let expected = SpeechLocaleMatching.bestMatch(
            for: Locale(identifier: "en_US"), in: Self.supported)
        #expect(decision == .use(expected!))
    }

    @Test func invalidateClearsSnapshot() {
        let cache = LocaleSnapshotCache()
        cache.store(supported: Self.supported, installed: Self.supported)
        cache.invalidate()
        #expect(cache.resolve(current: Locale(identifier: "en_US")) == .requery)
    }

    @Test func flagDefaultsFalse() {
        let defaults = UserDefaults(suiteName: "test.oto.\(UUID().uuidString)")!
        #expect(LocaleCacheExperiment.current(defaults: defaults).enabled == false)
    }

    @Test func flagReadsDefaults() {
        let defaults = UserDefaults(suiteName: "test.oto.\(UUID().uuidString)")!
        defaults.set(true, forKey: LocaleCacheExperiment.enabledKey)
        #expect(LocaleCacheExperiment.current(defaults: defaults).enabled == true)
    }
}
