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

    // MARK: - Combination event (dispatch cancels the stranded hold)

    @Test func combinationEmitsOnceForTheHeldSlot() {
        let monitor = HIDEventMonitor()
        monitor.configure(
            holdSlots: [UInt16(kVK_Command): .hold],
            functionSlots: [:]
        )
        _ = monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_Command),
            isRepeat: false, flags: [.maskCommand]
        )
        // First other key: the hold became a shortcut — one routed event.
        let first = monitor.decideRouted(
            type: .keyDown, keyCode: Int64(kVK_ANSI_1),
            isRepeat: false, flags: [.maskCommand]
        )
        #expect(first.combination == .hold)
        // Same press, more keys: already accounted for, never repeated.
        let second = monitor.decideRouted(
            type: .keyDown, keyCode: Int64(kVK_ANSI_2),
            isRepeat: false, flags: [.maskCommand]
        )
        #expect(second.combination == nil)
        let up = monitor.decideRouted(
            type: .keyUp, keyCode: Int64(kVK_ANSI_2),
            isRepeat: false, flags: [.maskCommand]
        )
        #expect(up.combination == nil)
        // A clean press (no other input) emits no combination at all.
        _ = monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_Command),
            isRepeat: false, flags: []
        )
        _ = monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_Command),
            isRepeat: false, flags: [.maskCommand]
        )
        let clean = monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_Command),
            isRepeat: false, flags: []
        )
        #expect(clean.combination == nil)
        #expect(clean.emit == .keyUp)
    }

    // MARK: - Scoped combination rule (a chord must use the held modifier)

    @Test func crossFamilyChordDoesNotDisqualifyTheHold() {
        // The reported failure: hold Right ⌥ to dictate, press ⌘1 (a
        // transform). Command is independent of the held Option, so the
        // hold survives and its release finishes dictation.
        let monitor = dualMonitor()
        _ = monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_RightOption),
            isRepeat: false, flags: [.maskAlternate]
        )
        let chord = monitor.decideRouted(
            type: .keyDown, keyCode: Int64(kVK_ANSI_1),
            isRepeat: false, flags: [.maskCommand]
        )
        #expect(chord.combination == nil)
        let release = monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_RightOption),
            isRepeat: false, flags: []
        )
        #expect(release.emit == .keyUp)
        #expect(monitor.isInCombination(code: UInt16(kVK_RightOption)) == false)
    }

    @Test func sameFamilyChordStillDisqualifiesTheHold() {
        // ⌥U (dead key) uses the held Option: the hold loses, exactly as
        // before — typing `•` must never dictate.
        let monitor = dualMonitor()
        _ = monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_RightOption),
            isRepeat: false, flags: [.maskAlternate]
        )
        let chord = monitor.decideRouted(
            type: .keyDown, keyCode: Int64(kVK_ANSI_U),
            isRepeat: false, flags: [.maskAlternate]
        )
        #expect(chord.combination == .hold)
        #expect(monitor.isInCombination(code: UInt16(kVK_RightOption)) == true)
        let release = monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_RightOption),
            isRepeat: false, flags: []
        )
        #expect(release.emit == nil)
    }

    @Test func rightCommandHoldIsDisqualifiedByCommandChord() {
        // Re-binding hold to Right ⌘ inverts the matrix correctly: ⌘1 is
        // then a same-family chord and wins.
        let monitor = dualMonitor()
        _ = monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_RightCommand),
            isRepeat: false, flags: [.maskCommand]
        )
        let chord = monitor.decideRouted(
            type: .keyDown, keyCode: Int64(kVK_ANSI_1),
            isRepeat: false, flags: [.maskCommand]
        )
        #expect(chord.combination == .handsFree)
        let release = monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_RightCommand),
            isRepeat: false, flags: []
        )
        #expect(release.emit == nil)
    }

    @Test func modifiedClickDisqualifiesButPlainClickDoesNot() {
        // ⌥-click consumes the held Option; a plain click is independent.
        let monitor = dualMonitor()
        _ = monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_RightOption),
            isRepeat: false, flags: [.maskAlternate]
        )
        let plain = monitor.decideRouted(
            type: .leftMouseDown, keyCode: 0, isRepeat: false, flags: []
        )
        #expect(plain.combination == nil)
        #expect(monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_RightOption),
            isRepeat: false, flags: []
        ).emit == .keyUp)

        _ = monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_RightOption),
            isRepeat: false, flags: [.maskAlternate]
        )
        let modified = monitor.decideRouted(
            type: .leftMouseDown, keyCode: 0, isRepeat: false, flags: [.maskAlternate]
        )
        #expect(modified.combination == .hold)
        #expect(monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_RightOption),
            isRepeat: false, flags: []
        ).emit == nil)
    }

    @Test func fnHoldIsStillDisqualifiedByFnChord() {
        // Regression guard: fn+arrow carries maskSecondaryFn and must stay a
        // combination (system gesture), never a dictation tap.
        let monitor = HIDEventMonitor()
        monitor.configure(
            holdSlots: [UInt16(kVK_Function): .hold],
            functionSlots: [:]
        )
        _ = monitor.decideRouted(
            type: .flagsChanged, keyCode: Int64(kVK_Function),
            isRepeat: false, flags: [.maskSecondaryFn]
        )
        let chord = monitor.decideRouted(
            type: .keyDown, keyCode: Int64(kVK_LeftArrow),
            isRepeat: false, flags: [.maskSecondaryFn]
        )
        #expect(chord.combination == .hold)
        #expect(monitor.isInCombination(code: UInt16(kVK_Function)) == true)
    }
}
