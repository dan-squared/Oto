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

    // MARK: - Hands-free

    @Test func handsFreeTogglesOnDownsIgnoresUps() {
        var machine = HotkeyTransitionState()
        #expect(machine.step(.event(.keyDown(isRepeat: false)), mode: .handsFree) == .begin)
        #expect(machine.step(.event(.keyUp), mode: .handsFree) == .ignore)
        #expect(machine.step(.event(.keyDown(isRepeat: true)), mode: .handsFree) == .ignore)
        #expect(machine.step(.event(.keyDown(isRepeat: false)), mode: .handsFree) == .finish)
        #expect(machine.step(.event(.keyUp), mode: .handsFree) == .ignore)
        #expect(machine.step(.event(.keyDown(isRepeat: false)), mode: .handsFree) == .begin)
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
        #expect(free.step(.event(.keyDown(isRepeat: false)), mode: .handsFree) == .begin)
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
        #expect(state.step(.otherActivity) == nil)
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
        #expect(state.step(.otherActivity) == nil)
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
}
