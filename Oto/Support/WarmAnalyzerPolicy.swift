//
//  WarmAnalyzerPolicy.swift
//  Oto
//
//  P2 (plan/p2-warm-analyzer.md): pure analyzer-reuse policy + experiment flag.
//
//  This file is PERMANENT but currently INERT: nothing calls `decide()` yet —
//  the warm slot that would call it is blocked on the hardware probe
//  (P2 plan §Probe). Landing the pure part now because it is probe-independent
//  (the rules don't depend on the probe outcome) and fully unit-testable with
//  no hardware. Conservative by design: every doubt rebuilds (= today's
//  behavior).
//

import Foundation

/// How the previous session ended, from the reuse policy's point of view.
enum WarmOutcome: Sendable, Equatable {
    case completed
    case failed
    case cancelled

    // Explicit: the synthesized conformance inherits default MainActor
    // isolation and would be unusable from `decide()` (same reason
    // `PolishAvailability` carries its own ==).
    nonisolated static func == (lhs: WarmOutcome, rhs: WarmOutcome) -> Bool {
        switch (lhs, rhs) {
        case (.completed, .completed), (.failed, .failed), (.cancelled, .cancelled):
            return true
        default:
            return false
        }
    }
}

/// Everything `decide()` may look at. Pure value — tests construct it freely.
struct WarmStateInput: Sendable, Equatable {
    var lastUse: ContinuousClock.Instant
    var now: ContinuousClock.Instant
    var sameLocale: Bool
    var memoryPressureSinceLastUse: Bool
    var lastOutcome: WarmOutcome

    nonisolated static func == (lhs: WarmStateInput, rhs: WarmStateInput) -> Bool {
        lhs.lastUse == rhs.lastUse
            && lhs.now == rhs.now
            && lhs.sameLocale == rhs.sameLocale
            && lhs.memoryPressureSinceLastUse == rhs.memoryPressureSinceLastUse
            && lhs.lastOutcome == rhs.lastOutcome
    }
}

enum WarmDecision: Sendable, Equatable {
    case reuse
    case rebuild

    nonisolated static func == (lhs: WarmDecision, rhs: WarmDecision) -> Bool {
        switch (lhs, rhs) {
        case (.reuse, .reuse), (.rebuild, .rebuild):
            return true
        default:
            return false
        }
    }
}

enum WarmAnalyzerPolicy {
    /// Starting idle cap: re-armed every session end. P1 session-spacing data
    /// sets the final number before default-on is even considered.
    nonisolated static let warmIdleLimit: Duration = .seconds(60)

    /// `reuse` ONLY IF completed AND same locale AND fresh AND no memory
    /// pressure. A `.failed` or `.cancelled` engine is never borrowed.
    nonisolated static func decide(_ input: WarmStateInput) -> WarmDecision {
        guard input.lastOutcome == .completed else { return .rebuild }
        guard input.sameLocale else { return .rebuild }
        guard !input.memoryPressureSinceLastUse else { return .rebuild }
        guard input.lastUse.duration(to: input.now) <= warmIdleLimit else { return .rebuild }
        return .reuse
    }
}

/// Hidden A/B seam (P2 flag): `defaults write app.Oto.warmAnalyzer -bool YES`
/// + relaunch enables the warm slot once it exists (it doesn't yet — the slot
/// lands after the probe). Default false: this whole workstream is inert until
/// P1's signposts prove the win on the matrix. Shape copied from
/// `InsertionExperiment.current()`.
struct WarmAnalyzerExperiment: Sendable, Equatable {
    var enabled: Bool

    nonisolated static func == (lhs: WarmAnalyzerExperiment, rhs: WarmAnalyzerExperiment) -> Bool {
        lhs.enabled == rhs.enabled
    }

    nonisolated static let enabledKey = "app.Oto.warmAnalyzer"

    nonisolated static func current(defaults: UserDefaults = .standard) -> WarmAnalyzerExperiment {
        WarmAnalyzerExperiment(enabled: defaults.bool(forKey: enabledKey))
    }
}
