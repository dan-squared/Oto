//
//  FnHoldConfirmTests.swift
//  OtoTests
//
//  Bare-fn hold confirmation core: taps at/under threshold belong to
//  macOS; only a still-held press past threshold confirms. Instants in,
//  verdicts out — no timers, fully deterministic. The threshold is pinned
//  to the tap constant (one number separates system taps from Oto holds).
//

import Foundation
import Testing
@testable import Oto

struct FnHoldConfirmTests {
    private func at(_ ms: Int, from base: ContinuousClock.Instant) -> ContinuousClock.Instant {
        base + .milliseconds(ms)
    }

    @Test func thresholdIs200ms() {
        #expect(FnHoldConfirm.threshold == .milliseconds(200))
    }

    @Test func subThresholdReleaseDrops() {
        var confirm = FnHoldConfirm()
        let t0 = ContinuousClock().now
        #expect(confirm.down(at: t0) == true)
        #expect(confirm.up() == .droppedTap)
    }

    @Test func confirmFiresPastThresholdWhileHeld() {
        var confirm = FnHoldConfirm()
        let t0 = ContinuousClock().now
        #expect(confirm.down(at: t0) == true)
        #expect(confirm.shouldConfirm(at: at(199, from: t0)) == false)
        #expect(confirm.shouldConfirm(at: at(200, from: t0)) == true)
        #expect(confirm.isConfirmed == false)
        confirm.markConfirmed()
        #expect(confirm.isConfirmed == true)
        #expect(confirm.up() == .finishedHold)
        #expect(confirm.isConfirmed == false)
    }

    @Test func duplicateDownIgnored() {
        var confirm = FnHoldConfirm()
        let t0 = ContinuousClock().now
        #expect(confirm.down(at: t0) == true)
        #expect(confirm.down(at: at(10, from: t0)) == false)
        #expect(confirm.up() == .droppedTap)
    }

    @Test func strayReleaseIgnored() {
        var confirm = FnHoldConfirm()
        #expect(confirm.up() == .ignored)
    }

    @Test func resetDisarms() {
        var confirm = FnHoldConfirm()
        let t0 = ContinuousClock().now
        #expect(confirm.down(at: t0) == true)
        confirm.reset()
        #expect(confirm.isDown == false)
        #expect(confirm.shouldConfirm(at: at(9000, from: t0)) == false)
        #expect(confirm.up() == .ignored)
    }

    @Test func isDownTracksPress() {
        var confirm = FnHoldConfirm()
        #expect(confirm.isDown == false)
        let t0 = ContinuousClock().now
        _ = confirm.down(at: t0)
        #expect(confirm.isDown == true)
        _ = confirm.up()
        #expect(confirm.isDown == false)
    }
}
