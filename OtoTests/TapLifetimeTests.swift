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
}
