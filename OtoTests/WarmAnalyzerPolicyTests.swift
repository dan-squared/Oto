//
//  WarmAnalyzerPolicyTests.swift
//  OtoTests
//
//  P2 (plan/p2-warm-analyzer.md): pure reuse-policy contracts. No system
//  calls, no hardware, deterministic. Every failure mode defaults to rebuild
//  (= today's behavior) — these tests pin that conservatism.
//

import Foundation
import Testing
@testable import Oto

@MainActor
struct WarmAnalyzerPolicyTests {
    private static func input(
        age: Duration = .seconds(10),
        sameLocale: Bool = true,
        pressure: Bool = false,
        outcome: WarmOutcome = .completed
    ) -> WarmStateInput {
        let now = ContinuousClock.now
        return WarmStateInput(
            lastUse: now - age,
            now: now,
            sameLocale: sameLocale,
            memoryPressureSinceLastUse: pressure,
            lastOutcome: outcome
        )
    }

    @Test func freshCompletedSameLocaleReuses() {
        #expect(WarmAnalyzerPolicy.decide(Self.input()) == .reuse)
    }

    @Test func failedNeverReuses() {
        #expect(WarmAnalyzerPolicy.decide(Self.input(outcome: .failed)) == .rebuild)
    }

    @Test func cancelledNeverReuses() {
        #expect(WarmAnalyzerPolicy.decide(Self.input(outcome: .cancelled)) == .rebuild)
    }

    @Test func localeChangeRebuilds() {
        #expect(WarmAnalyzerPolicy.decide(Self.input(sameLocale: false)) == .rebuild)
    }

    @Test func memoryPressureRebuilds() {
        #expect(WarmAnalyzerPolicy.decide(Self.input(pressure: true)) == .rebuild)
    }

    @Test func expiredIdleRebuilds() {
        #expect(WarmAnalyzerPolicy.decide(Self.input(age: .seconds(61))) == .rebuild)
    }

    @Test func exactlyAtLimitReuses() {
        // Boundary is inclusive (<=): a session that ended exactly one limit
        // ago is still warm. Implementations must not use strict <.
        #expect(WarmAnalyzerPolicy.decide(Self.input(age: .seconds(60))) == .reuse)
    }

    @Test func flagDefaultsFalse() {
        let defaults = UserDefaults(suiteName: "test.oto.\(UUID().uuidString)")!
        #expect(WarmAnalyzerExperiment.current(defaults: defaults).enabled == false)
    }

    @Test func flagReadsDefaults() {
        let defaults = UserDefaults(suiteName: "test.oto.\(UUID().uuidString)")!
        defaults.set(true, forKey: WarmAnalyzerExperiment.enabledKey)
        #expect(WarmAnalyzerExperiment.current(defaults: defaults).enabled == true)
    }
}
