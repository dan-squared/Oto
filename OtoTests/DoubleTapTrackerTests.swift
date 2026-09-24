//
//  DoubleTapTrackerTests.swift
//  OtoTests
//
//  Pure tap-tempo tracker: instants in, confirmation out. No clock reads,
//  no timers, fully deterministic. Thresholds pinned (matrix tunes).
//

import Foundation
import Testing
@testable import Oto

struct DoubleTapTrackerTests {
    private func at(_ ms: Int, from base: ContinuousClock.Instant) -> ContinuousClock.Instant {
        base + .milliseconds(ms)
    }

    @Test func quickQuickConfirms() {
        var tracker = DoubleTapTracker()
        let t0 = ContinuousClock().now
        tracker.down(at: at(0, from: t0))
        #expect(tracker.up(at: at(100, from: t0)) == false)
        tracker.down(at: at(250, from: t0))
        #expect(tracker.up(at: at(320, from: t0)) == true)
    }

    @Test func slowPressClearsPending() {
        var tracker = DoubleTapTracker()
        let t0 = ContinuousClock().now
        tracker.down(at: at(0, from: t0))
        #expect(tracker.up(at: at(100, from: t0)) == false)
        // Slow second press: ordinary hold, pair dead even though the gap
        // from the first down is small.
        tracker.down(at: at(200, from: t0))
        #expect(tracker.up(at: at(600, from: t0)) == false)
    }

    @Test func wideGapRejects() {
        var tracker = DoubleTapTracker()
        let t0 = ContinuousClock().now
        tracker.down(at: at(0, from: t0))
        #expect(tracker.up(at: at(100, from: t0)) == false)
        tracker.down(at: at(2000, from: t0))
        #expect(tracker.up(at: at(2100, from: t0)) == false)
    }

    @Test func singleTapSilent() {
        var tracker = DoubleTapTracker()
        let t0 = ContinuousClock().now
        tracker.down(at: at(0, from: t0))
        #expect(tracker.up(at: at(80, from: t0)) == false)
    }

    @Test func upWithoutDownSilent() {
        var tracker = DoubleTapTracker()
        #expect(tracker.up(at: ContinuousClock().now) == false)
    }

    @Test func pairsAreNonOverlapping() {
        var tracker = DoubleTapTracker()
        let t0 = ContinuousClock().now
        tracker.down(at: at(0, from: t0))
        #expect(tracker.up(at: at(80, from: t0)) == false)
        tracker.down(at: at(200, from: t0))
        #expect(tracker.up(at: at(280, from: t0)) == true)
        // Third tap starts a fresh pair, never a cascade.
        tracker.down(at: at(400, from: t0))
        #expect(tracker.up(at: at(480, from: t0)) == false)
        tracker.down(at: at(600, from: t0))
        #expect(tracker.up(at: at(680, from: t0)) == true)
    }

    @Test func thresholdsPinned() {
        #expect(DoubleTapTracker.maxPressDuration == .milliseconds(250))
        #expect(DoubleTapTracker.maxGap == .milliseconds(350))
    }
}
