//
//  OnboardingStoreTests.swift
//  OtoTests
//
//  First-run gate: absent key shows (fresh install teaches), marked key
//  hides, a version bump re-shows once. Closing without Finish writes
//  nothing — covered by `markSeen` being the only writer.
//

import Foundation
import Testing
@testable import Oto

struct OnboardingStoreTests {
    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "app.Oto.tests.onboarding-\(UUID().uuidString)")!
    }

    @Test func absentKeyShows() {
        #expect(OnboardingStore.shouldShow(defaults: isolatedDefaults()) == true)
    }

    @Test func markedKeyHides() {
        let defaults = isolatedDefaults()
        OnboardingStore.markSeen(defaults: defaults)
        #expect(OnboardingStore.shouldShow(defaults: defaults) == false)
    }

    @Test func markSeenWritesCurrentVersion() {
        let defaults = isolatedDefaults()
        OnboardingStore.markSeen(defaults: defaults)
        #expect(defaults.integer(forKey: OnboardingStore.key) == OnboardingStore.current)
    }

    @Test func olderVersionReshows() {
        let defaults = isolatedDefaults()
        defaults.set(OnboardingStore.current - 1, forKey: OnboardingStore.key)
        #expect(OnboardingStore.shouldShow(defaults: defaults) == true)
    }

    @Test func corruptValueReshows() {
        // A non-integer value (crashed write, foreign tooling) reads as
        // 0 via integer(forKey:) — below current, so onboarding teaches
        // instead of skipping a potentially unseen user.
        let defaults = isolatedDefaults()
        defaults.set("seen", forKey: OnboardingStore.key)
        #expect(OnboardingStore.shouldShow(defaults: defaults) == true)
    }

    @Test func futureVersionHides() {
        // A newer version than this build knows means a newer build
        // already taught — never re-show stale content over it.
        let defaults = isolatedDefaults()
        defaults.set(OnboardingStore.current + 1, forKey: OnboardingStore.key)
        #expect(OnboardingStore.shouldShow(defaults: defaults) == false)
    }

    // MARK: - Resume point

    @Test func progressRoundTrips() {
        let defaults = isolatedDefaults()
        #expect(OnboardingStore.progress(defaults: defaults) == nil)
        OnboardingStore.saveProgress(step: 3, defaults: defaults)
        #expect(OnboardingStore.progress(defaults: defaults) == 3)
    }

    @Test func clearingLeavesNothingBehind() {
        let defaults = isolatedDefaults()
        OnboardingStore.saveProgress(step: 3, defaults: defaults)
        OnboardingStore.clearProgress(defaults: defaults)
        #expect(OnboardingStore.progress(defaults: defaults) == nil)
        #expect(defaults.object(forKey: OnboardingStore.stepKey) == nil)
    }

    @Test func resumeIsIndependentOfTheVersionGate() {
        // Finishing marks the version seen *and* clears the walk; the two
        // keys answer different questions and must not alias.
        let defaults = isolatedDefaults()
        OnboardingStore.saveProgress(step: 2, defaults: defaults)
        OnboardingStore.markSeen(defaults: defaults)
        #expect(OnboardingStore.progress(defaults: defaults) == 2)
    }
}
