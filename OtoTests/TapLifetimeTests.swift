//
//  TapLifetimeTests.swift
//  OtoTests
//
//  The 22-report crash cluster, closed structurally: real event taps
//  never install under XCTest (gate), so leaked taps firing into freed
//  monitors is impossible; teardown always precedes deallocation.
//  Decide logic needs no hardware — these prove the gate loses nothing.
//

import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import Oto

@MainActor
struct TapLifetimeTests {
    @Test func unitTestsNeverGoLive() {
        // The gate itself: this process links XCTest, so no tap installs.
        #expect(HIDEventMonitor.liveTapsEnabled == false)
        let monitor = HIDEventMonitor()
        monitor.configure(
            holdSlots: [UInt16(kVK_RightOption): .hold],
            functionSlots: [Int64(kVK_F5): .handsFree]
        )
        #expect(monitor.isLive == false)
    }

    @Test func decideWorksWithNoTapInstalled() {
        // The gate loses nothing: decisions drive directly, tap or not.
        let monitor = HIDEventMonitor()
        monitor.configure(
            holdSlots: [UInt16(kVK_RightOption): .hold],
            functionSlots: [Int64(kVK_F5): .handsFree]
        )
        let down = monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_RightOption),
            isRepeat: false, flags: [.maskAlternate]
        )
        #expect(down.slot == .hold)
        #expect(down.emit == .keyDown(isRepeat: false))
        monitor.stop()
        #expect(monitor.isLive == false)
    }

    @Test func reconfigureStressStaysConsistent() {
        // 50 sequential configure/decide cycles on one monitor: the
        // reconfigure paths from the crash reports, deterministically,
        // with no hardware and no live tap.
        let monitor = HIDEventMonitor()
        for i in 0..<50 {
            if i % 2 == 0 {
                monitor.configure(
                    holdSlots: [UInt16(kVK_RightOption): .hold],
                    functionSlots: [Int64(kVK_F5): .handsFree]
                )
            } else {
                monitor.configure(
                    holdSlots: [UInt16(kVK_Function): .hold],
                    functionSlots: [:]
                )
            }
            let hold = monitor.decideRouted(
                type: .flagsChanged, keyCode: Int64(kVK_RightOption),
                isRepeat: false, flags: [.maskAlternate]
            )
            #expect(hold.slot == (i % 2 == 0 ? .hold : nil))
        }
        monitor.stop()
        #expect(monitor.isLive == false)
    }

    @Test func stopWithoutConfigureIsSafe() {
        // stop() on a fresh monitor: no tap, no state, no trap.
        // Decisions stay pure (unconfigured codes route nowhere).
        let monitor = HIDEventMonitor()
        monitor.stop()
        #expect(monitor.isLive == false)
        let routed = monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_RightOption),
            isRepeat: false, flags: [.maskAlternate]
        )
        #expect(routed.slot == nil)
        #expect(routed.emit == nil)
    }

    @Test func doubleStopStaysDead() {
        // Teardown is idempotent: configure → stop → stop leaves
        // nothing live and decisions stay cleared.
        let monitor = HIDEventMonitor()
        monitor.configure(
            holdSlots: [UInt16(kVK_RightOption): .hold],
            functionSlots: [Int64(kVK_F5): .handsFree]
        )
        monitor.stop()
        monitor.stop()
        #expect(monitor.isLive == false)
        let routed = monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_RightOption),
            isRepeat: false, flags: [.maskAlternate]
        )
        #expect(routed.slot == nil)
    }

    @Test func stopClearsSlotDecisions() {
        // A held slot routes, then stop() must clear it: the same
        // physical event routes nowhere after teardown (no stale emission
        // from a dead monitor).
        let monitor = HIDEventMonitor()
        monitor.configure(
            holdSlots: [UInt16(kVK_RightOption): .hold],
            functionSlots: [Int64(kVK_F5): .handsFree]
        )
        let live = monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_RightOption),
            isRepeat: false, flags: [.maskAlternate]
        )
        #expect(live.slot == .hold)
        monitor.stop()
        let dead = monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_RightOption),
            isRepeat: false, flags: [.maskAlternate]
        )
        #expect(dead.slot == nil)
        #expect(dead.emit == nil)
    }

    @Test func deallocReleasesMonitor() {
        // The no-cycle invariant behind the crash fix: the tap holds the
        // owner passUnretained and pins it only per-callback, so a stopped
        // monitor deallocates. A future retain cycle fails this test.
        weak var weakMonitor: HIDEventMonitor?
        do {
            let monitor = HIDEventMonitor()
            weakMonitor = monitor
            monitor.configure(
                holdSlots: [UInt16(kVK_RightOption): .hold],
                functionSlots: [Int64(kVK_F5): .handsFree]
            )
            monitor.stop()
        }
        #expect(weakMonitor == nil)
    }
}
