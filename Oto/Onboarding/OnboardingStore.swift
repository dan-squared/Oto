//
//  OnboardingStore.swift
//  Oto
//
//  First-run gate: versioned key, absent = show. Bumped versions re-show
//  once (migration path for future onboarding content). Closing the window
//  without Finish marks nothing — a red-close can never skip onboarding.
//  `NoTargetModalSettings` precedent: the absent-key default is the
//  teaching path.
//

import Foundation

/// First-run gate. Pure over injected defaults — fully unit-tested.
enum OnboardingStore {
    nonisolated static let key = "app.Oto.onboardingVersion"
    nonisolated static let current = 1

    nonisolated static func shouldShow(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.integer(forKey: key) < current
    }

    nonisolated static func markSeen(defaults: UserDefaults = .standard) {
        defaults.set(current, forKey: key)
    }
}
