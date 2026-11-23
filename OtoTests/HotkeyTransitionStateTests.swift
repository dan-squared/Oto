//
//  HotkeyTransitionStateTests.swift
//  OtoTests
//
//  Exhaustive matrix for the pure transition machine: no hardware, no
//  async, deterministic. Every hold/hands-free/loss/Escape rule from 02.
//

import Carbon.HIToolbox
import Foundation
import Testing
@testable import Oto

struct HotkeyTransitionStateTests {
    // MARK: - Hold-to-talk

    @Test func holdDownBeginsUpFinishes() {
        var machine = HotkeyTransitionState()
        #expect(machine.step(.event(.keyDown(isRepeat: false)), mode: .holdToTalk) == .begin)
        #expect(machine.step(.event(.keyUp), mode: .holdToTalk) == .finish)
    }

    @Test func holdRepeatIsIgnored() {
        var machine = HotkeyTransitionState()
        #expect(machine.step(.event(.keyDown(isRepeat: false)), mode: .holdToTalk) == .begin)
        #expect(machine.step(.event(.keyDown(isRepeat: true)), mode: .holdToTalk) == .ignore)
        #expect(machine.step(.event(.keyUp), mode: .holdToTalk) == .finish)
    }

    @Test func holdSecondDownWhileActiveIsIgnored() {
        var machine = HotkeyTransitionState()
        #expect(machine.step(.event(.keyDown(isRepeat: false)), mode: .holdToTalk) == .begin)
        #expect(machine.step(.event(.keyDown(isRepeat: false)), mode: .holdToTalk) == .ignore)
    }

    @Test func holdUpWithoutDownIsIgnored() {
        var machine = HotkeyTransitionState()
        #expect(machine.step(.event(.keyUp), mode: .holdToTalk) == .ignore)
    }

    @Test func holdUpWhileStartingStillFinishes() {
        // Release-during-preparation: the machine emits finish; the
        // coordinator turns it into finish-when-ready.
        var machine = HotkeyTransitionState()
        #expect(machine.step(.event(.keyDown(isRepeat: false)), mode: .holdToTalk) == .begin)
        #expect(machine.step(.event(.keyUp), mode: .holdToTalk) == .finish)
    }

    // MARK: - Combination (a bare-modifier hold became a shortcut)

    @Test func combinationCancelsLiveHoldAndForgetsThePress() {
        // ⌘ held for push-to-talk, then ⌘1: the press was a shortcut, not
        // dictation. Discard it; the release the monitor swallows must not
        // finish (insert) anything.
        var machine = HotkeyTransitionState()
        #expect(machine.step(.event(.keyDown(isRepeat: false)), mode: .holdToTalk) == .begin)
        #expect(machine.step(.event(.combinationBegan), mode: .holdToTalk) == .cancel)
        #expect(machine.step(.event(.keyUp), mode: .holdToTalk) == .ignore)
        // Next press begins cleanly — no stuck "pressed" state.
        #expect(machine.step(.event(.keyDown(isRepeat: false)), mode: .holdToTalk) == .begin)
    }

    @Test func combinationWithoutAHoldIsIgnored() {
        var machine = HotkeyTransitionState()
        #expect(machine.step(.event(.combinationBegan), mode: .holdToTalk) == .ignore)
        #expect(machine.step(.event(.combinationBegan), mode: .handsFree) == .ignore)
    }

    @Test func combinationNeverCancelsHandsFree() {
        // Hands-free is meant to keep running while you do other things.
        var machine = HotkeyTransitionState()
        #expect(machine.step(.event(.keyDown(isRepeat: false)), mode: .handsFree) == .toggle)
        #expect(machine.step(.event(.combinationBegan), mode: .handsFree) == .ignore)
        // The stateless toggle fires again on its second press.
        #expect(machine.step(.event(.keyDown(isRepeat: false)), mode: .handsFree) == .toggle)
    }

    // MARK: - Hands-free

    @Test func handsFreeTogglesOnDownsIgnoresUps() {
        var machine = HotkeyTransitionState()
        #expect(machine.step(.event(.keyDown(isRepeat: false)), mode: .handsFree) == .toggle)
        #expect(machine.step(.event(.keyUp), mode: .handsFree) == .ignore)
        #expect(machine.step(.event(.keyDown(isRepeat: true)), mode: .handsFree) == .ignore)
        #expect(machine.step(.event(.keyDown(isRepeat: false)), mode: .handsFree) == .toggle)
        #expect(machine.step(.event(.keyUp), mode: .handsFree) == .ignore)
        #expect(machine.step(.event(.keyDown(isRepeat: false)), mode: .handsFree) == .toggle)
    }

    // MARK: - Loss and Escape

    @Test func monitorLossResets() {
        var machine = HotkeyTransitionState()
        #expect(machine.step(.event(.keyDown(isRepeat: false)), mode: .holdToTalk) == .begin)
        #expect(machine.step(.event(.monitorLost), mode: .holdToTalk) == .reset)
        // Local pressed state cleared: a later up is meaningless.
        #expect(machine.step(.event(.keyUp), mode: .holdToTalk) == .ignore)
    }

    @Test func escapeResetsInBothModes() {
        var down = HotkeyTransitionState()
        #expect(down.step(.event(.keyDown(isRepeat: false)), mode: .holdToTalk) == .begin)
        #expect(down.step(.escape, mode: .holdToTalk) == .reset)

        var free = HotkeyTransitionState()
        #expect(free.step(.event(.keyDown(isRepeat: false)), mode: .handsFree) == .toggle)
        #expect(free.step(.escape, mode: .handsFree) == .reset)
    }

    // MARK: - Function-key matching

    @Test func functionKeyFiresOnlyBareNonRepeat() {        let codes: Set<Int64> = [Int64(kVK_F5), 176]
        #expect(FunctionKeyMatching.shouldFire(codes: codes, keyCode: Int64(kVK_F5), flags: [], isRepeat: false))
        #expect(FunctionKeyMatching.shouldFire(codes: codes, keyCode: 176, flags: [], isRepeat: false))
        #expect(!FunctionKeyMatching.shouldFire(codes: codes, keyCode: Int64(kVK_F5), flags: [], isRepeat: true))
        #expect(!FunctionKeyMatching.shouldFire(codes: codes, keyCode: Int64(kVK_F5), flags: [.maskCommand], isRepeat: false))
        #expect(!FunctionKeyMatching.shouldFire(codes: codes, keyCode: Int64(kVK_F5), flags: [.maskShift], isRepeat: false))
        #expect(!FunctionKeyMatching.shouldFire(codes: codes, keyCode: Int64(kVK_F6), flags: [], isRepeat: false))
        #expect(!FunctionKeyMatching.shouldFire(codes: [], keyCode: Int64(kVK_F5), flags: [], isRepeat: false))
    }
}

struct ModifierHoldStateTests {
    @Test func cleanPressReleaseEmitsDownThenUp() {
        var state = ModifierHoldState()
        #expect(state.step(.flags(down: true)) == .keyDown(isRepeat: false))
        #expect(state.step(.flags(down: false)) == .keyUp)
    }

    @Test func releaseAfterOtherActivityIsSwallowed() {
        var state = ModifierHoldState()
        #expect(state.step(.flags(down: true)) == .keyDown(isRepeat: false))
        #expect(state.step(.otherActivity(usesHeldModifier: true)) == nil)
        #expect(state.step(.flags(down: false)) == nil)
    }

    @Test func independentActivityKeepsTheHoldAlive() {
        // ⌘1 while Right ⌥ is held: the chord does not use Option, so the
        // hold is still a plain hold and finishes normally on release.
        var state = ModifierHoldState()
        #expect(state.step(.flags(down: true)) == .keyDown(isRepeat: false))
        #expect(state.step(.otherActivity(usesHeldModifier: false)) == nil)
        #expect(state.step(.flags(down: false)) == .keyUp)
    }

    @Test func independentActivityThenCombinationStillSwallows() {
        // Independence early does not immunise the hold: a later chord that
        // does use Option still wins.
        var state = ModifierHoldState()
        #expect(state.step(.flags(down: true)) == .keyDown(isRepeat: false))
        #expect(state.step(.otherActivity(usesHeldModifier: false)) == nil)
        #expect(state.step(.otherActivity(usesHeldModifier: true)) == nil)
        #expect(state.step(.flags(down: false)) == nil)
    }

    @Test func strayReleaseEmitsNothing() {
        var state = ModifierHoldState()
        #expect(state.step(.flags(down: false)) == nil)
    }

    @Test func doublePressEmitsOnce() {
        var state = ModifierHoldState()
        #expect(state.step(.flags(down: true)) == .keyDown(isRepeat: false))
        #expect(state.step(.flags(down: true)) == nil)
        #expect(state.step(.flags(down: false)) == .keyUp)
    }

    @Test func activityWhileUpIsIgnored() {
        var state = ModifierHoldState()
        #expect(state.step(.otherActivity(usesHeldModifier: true)) == nil)
        #expect(state.step(.flags(down: true)) == .keyDown(isRepeat: false))
    }

    @Test func flagFamiliesResolve() {
        #expect(ModifierHoldState.flag(for: UInt16(kVK_RightOption)) == .maskAlternate)
        #expect(ModifierHoldState.flag(for: UInt16(kVK_Option)) == .maskAlternate)
        #expect(ModifierHoldState.flag(for: UInt16(kVK_RightShift)) == .maskShift)
        #expect(ModifierHoldState.flag(for: UInt16(kVK_RightCommand)) == .maskCommand)
        #expect(ModifierHoldState.flag(for: UInt16(kVK_RightControl)) == .maskControl)
        #expect(ModifierHoldState.flag(for: UInt16(kVK_ANSI_D)) == nil)
    }

    @Test func sidedModifierMasksDistinguishLeftAndRightAndFallBack() {
        let leftOpt = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | ModifierHoldState.deviceLeftAltMask)
        let rightOpt = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | ModifierHoldState.deviceRightAltMask)
        #expect(ModifierHoldState.isModifierDown(keyCode: UInt16(kVK_Option), flags: leftOpt) == true)
        #expect(ModifierHoldState.isModifierDown(keyCode: UInt16(kVK_RightOption), flags: leftOpt) == false)
        #expect(ModifierHoldState.isModifierDown(keyCode: UInt16(kVK_RightOption), flags: rightOpt) == true)
        #expect(ModifierHoldState.isModifierDown(keyCode: UInt16(kVK_Option), flags: rightOpt) == false)
        // Fallback when device bits are absent (synthetic events):
        #expect(ModifierHoldState.isModifierDown(keyCode: UInt16(kVK_RightOption), flags: [.maskAlternate]) == true)
        #expect(ModifierHoldState.isModifierDown(keyCode: UInt16(kVK_RightOption), flags: []) == false)
    }

    @MainActor
    @Test func modifierHotkeyMonitorHealsStaleCarbonDown() {
        let monitor = ModifierHotkeyMonitor()
        let t0 = ContinuousClock().now
        #expect(monitor.stepCarbonKeyDown(at: t0) == .keyDown(isRepeat: false))
        // Immediate duplicate within 1.5s is normalized to repeat.
        #expect(monitor.stepCarbonKeyDown(at: t0 + .milliseconds(200)) == .keyDown(isRepeat: true))
        // Missed keyUp followed by press >1.5s later heals as a fresh press.
        #expect(monitor.stepCarbonKeyDown(at: t0 + .milliseconds(2000)) == .keyDown(isRepeat: false))
        // stop() clears carbonDown immediately.
        monitor.stop()
        #expect(monitor.stepCarbonKeyDown(at: t0 + .milliseconds(2050)) == .keyDown(isRepeat: false))
        #expect(monitor.stepCarbonKeyUp() == .keyUp)
    }
}
