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
//  Also the resume point: which chapter the walk stopped on, so a quit, a
//  crash, or the menu's re-run continues where the person stopped instead of
//  starting over at Welcome. Cleared by `reset()`/Finish only.
//

import Foundation

/// First-run gate and resume point. Pure over injected defaults — fully
/// unit-tested.
enum OnboardingStore {
    nonisolated static let key = "app.Oto.onboardingVersion"
    nonisolated static let current = 1
    nonisolated static let stepKey = "app.Oto.onboardingStep"

    nonisolated static func shouldShow(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.integer(forKey: key) < current
    }

    nonisolated static func markSeen(defaults: UserDefaults = .standard) {
        defaults.set(current, forKey: key)
    }

    // MARK: - Resume point

    /// The step the walk stopped on, as raw storage. `nil` = never saved (or
    /// cleared): the walk starts at Welcome.
    nonisolated static func progress(defaults: UserDefaults = .standard) -> Int? {
        guard defaults.object(forKey: stepKey) != nil else { return nil }
        return defaults.integer(forKey: stepKey)
    }

    nonisolated static func saveProgress(step: Int, defaults: UserDefaults = .standard) {
        defaults.set(step, forKey: stepKey)
    }

    nonisolated static func clearProgress(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: stepKey)
    }
}
