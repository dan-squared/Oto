//
//  HIDDecideDualTests.swift
//  OtoTests
//
//  Slot-tagged decision layer: two hold codes route independently,
//  function codes map to slots, combination-use swallows only the held
//  slot's release, Escape is observed once. No tap, no runloop, no AX:
//  `decideRouted` is driven directly on the main actor. The legacy
//  `HIDDecideTests` suite stays untouched and green.
//

import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import Oto

@MainActor
struct HIDDecideDualTests {
    private func dualMonitor() -> HIDEventMonitor {
        let monitor = HIDEventMonitor()
        monitor.configure(
            holdSlots: [
                UInt16(kVK_RightOption): .hold,
                UInt16(kVK_RightCommand): .handsFree,
            ],
            functionSlots: [Int64(kVK_F5): .handsFree]
        )
        return monitor
    }

    // MARK: - Two hold codes route independently

    @Test func eachHoldCodeEmitsForItsOwnSlot() {
        let monitor = dualMonitor()
        let holdDown = monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_RightOption),
            isRepeat: false, flags: [.maskAlternate]
        )
        #expect(holdDown.slot == .hold)
        #expect(holdDown.emit == .keyDown(isRepeat: false))
        #expect(!holdDown.consume)

        let freeDown = monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_RightCommand),
            isRepeat: false, flags: [.maskCommand]
        )
        #expect(freeDown.slot == .handsFree)
        #expect(freeDown.emit == .keyDown(isRepeat: false))
        #expect(!freeDown.consume)
    }

    @Test func releasesRouteIndependentlyPerSlot() {
        let monitor = dualMonitor()
        _ = monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_RightOption),
            isRepeat: false, flags: [.maskAlternate]
        )
        _ = monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_RightCommand),
            isRepeat: false, flags: [.maskCommand]
        )
        let holdUp = monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_RightOption),
            isRepeat: false, flags: []
        )
        #expect(holdUp.slot == .hold)
        #expect(holdUp.emit == .keyUp)
        // The hands-free hold is still down: its release still emits.
        let freeUp = monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_RightCommand),
            isRepeat: false, flags: []
        )
        #expect(freeUp.slot == .handsFree)
        #expect(freeUp.emit == .keyUp)
    }

    // MARK: - Function code to slot map

    @Test func functionPressAndReleaseCarryTheirSlot() {
        let monitor = dualMonitor()
        let down = monitor.decideRouted(
            type: .keyDown, keyCode: Int64(kVK_F5),
            isRepeat: false, flags: []
        )
        #expect(down.slot == .handsFree)
        #expect(down.emit == .keyDown(isRepeat: false))
        #expect(down.consume)

        let up = monitor.decideRouted(
            type: .keyUp, keyCode: Int64(kVK_F5),
            isRepeat: false, flags: []
        )
        #expect(up.slot == .handsFree)
        #expect(up.emit == .keyUp)
        #expect(up.consume)
    }

    // MARK: - Combination-use swallows only the held slot's release

    @Test func typingMidHoldSwallowsOnlyThatSlotsRelease() {
        let monitor = dualMonitor()
        _ = monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_RightOption),
            isRepeat: false, flags: [.maskAlternate]
        )
        // Typing • (Option-U) mid-hold marks combination use everywhere…
        _ = monitor.decideRouted(
            type: .keyDown, keyCode: Int64(kVK_ANSI_U),
            isRepeat: false, flags: [.maskAlternate]
        )
        // …so the held slot's release emits nothing…
        let swallowed = monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_RightOption),
            isRepeat: false, flags: []
        )
        #expect(swallowed.slot == .hold)
        #expect(swallowed.emit == nil)
        // …while the untouched slot still routes cleanly.
        let freeDown = monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_RightCommand),
            isRepeat: false, flags: [.maskCommand]
        )
        #expect(freeDown.slot == .handsFree)
        #expect(freeDown.emit == .keyDown(isRepeat: false))
    }

    // MARK: - Escape observed once, never consumed

    @Test func escapeEmitsNothingAndFiresOnce() async {
        let monitor = dualMonitor()
        var fires = 0
        monitor.onEscape = { fires += 1 }
        for _ in 0..<2 {
            let decided = monitor.decideRouted(
                type: .keyDown, keyCode: Int64(kVK_Escape),
                isRepeat: false, flags: []
            )
            #expect(decided.slot == nil)
            #expect(decided.emit == nil)
            #expect(!decided.consume)
        }
        // The Escape hop is async; poll, never bare-sleep-assert.
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while clock.now < deadline {
            if fires == 2 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(fires == 2)
    }

    // MARK: - Combination-use probe (fn-hold confirmation consults this)

    @Test func combinationProbeReflectsHeldSlotUse() {
        let monitor = HIDEventMonitor()
        monitor.configure(
            holdSlots: [UInt16(kVK_Function): .hold],
            functionSlots: [:]
        )
        _ = monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_Function),
            isRepeat: false, flags: [.maskSecondaryFn]
        )
        #expect(monitor.isInCombination(code: UInt16(kVK_Function)) == false)
        // fn held + another key: system gesture (fn+arrows, fn+click class).
        _ = monitor.decideRouted(
            type: .keyDown, keyCode: Int64(kVK_ANSI_D),
            isRepeat: false, flags: [.maskSecondaryFn]
        )
        #expect(monitor.isInCombination(code: UInt16(kVK_Function)) == true)
        // Clean release resets the flag.
        _ = monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_Function),
            isRepeat: false, flags: []
        )
        #expect(monitor.isInCombination(code: UInt16(kVK_Function)) == false)
        // Untracked codes never report combination use.
        #expect(monitor.isInCombination(code: UInt16(kVK_RightOption)) == false)
    }
}
