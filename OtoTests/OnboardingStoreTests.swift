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
}
