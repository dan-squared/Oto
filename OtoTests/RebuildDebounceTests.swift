//
//  RebuildDebounceTests.swift
//  OtoTests
//
//  bt-sco-flap.md: config-change flurries (Bluetooth SCO bring-up) must
//  coalesce into one rebuild per quiet window — tearing down on every
//  flutter multiplies silence gaps. Pure decision function, deterministic.
//

import Foundation
import Testing
@testable import Oto

struct RebuildDebounceTests {
    private let policy = RebuildDebouncePolicy(quietNanoseconds: 1_500_000_000)

    @Test func firstChangeRebuildsImmediately() {
        #expect(policy.shouldRebuildNow(now: Date(), lastRebuild: nil))
    }

    @Test func flurryInsideWindowDefers() {
        let last = Date()
        let now = last.addingTimeInterval(0.2)
        #expect(!policy.shouldRebuildNow(now: now, lastRebuild: last))
    }

    @Test func settledLinkRebuildsAgain() {
        let last = Date()
        let now = last.addingTimeInterval(5.0)
        #expect(policy.shouldRebuildNow(now: now, lastRebuild: last))
    }

    @Test func settledWindowRebuilds() {
        // Asserted CLEAR of the 1.5s line, not on it: Date doubles near
        // current timestamps carry ~120ns of rounding slop, so an exact
        // boundary assertion would be a coin flip across runs.
        let last = Date()
        let now = last.addingTimeInterval(1.6)
        #expect(policy.shouldRebuildNow(now: now, lastRebuild: last))
    }

    @Test func tighterWindowFlapsLess() {
        let strict = RebuildDebouncePolicy(quietNanoseconds: 5_000_000_000)
        let last = Date()
        #expect(!strict.shouldRebuildNow(now: last.addingTimeInterval(2.0), lastRebuild: last))
        #expect(strict.shouldRebuildNow(now: last.addingTimeInterval(6.0), lastRebuild: last))
    }
}
