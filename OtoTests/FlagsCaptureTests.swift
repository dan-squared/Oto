//
//  FlagsCaptureTests.swift
//  OtoTests
//
//  Bare-modifier capture: lone press+release stages a modifierHold;
//  chords refuse; any keyDown disarms; untrackable codes fall through.
//  Pure state machine — no monitors, no hardware.
//

import Carbon.HIToolbox
import AppKit
import Foundation
import Testing
@testable import Oto

struct FlagsCaptureTests {
    @Test func loneModifierPressReleaseCapturesSidedCode() {
        var state = FlagsCaptureState()
        #expect(state.stepFlagsDown(code: UInt16(kVK_RightOption)) == .none)
        #expect(state.stepFlagsUp(code: UInt16(kVK_RightOption)) == .capture(code: UInt16(kVK_RightOption)))
    }

    @Test func eachModifierFamilyCaptures() {
        for code in [
            kVK_Function, kVK_Control, kVK_RightControl,
            kVK_Option, kVK_RightOption, kVK_Command, kVK_RightCommand,
            kVK_Shift, kVK_RightShift,
        ] {
            var state = FlagsCaptureState()
            #expect(state.stepFlagsDown(code: UInt16(code)) == .none)
            #expect(state.stepFlagsUp(code: UInt16(code)) == .capture(code: UInt16(code)))
        }
    }

    @Test func chordRefusesImmediately() {
        var state = FlagsCaptureState()
        #expect(state.stepFlagsDown(code: UInt16(kVK_Control)) == .none)
        #expect(state.stepFlagsDown(code: UInt16(kVK_Shift)) == .chord)
        // Releases after a chord are silent (already refused).
        #expect(state.stepFlagsUp(code: UInt16(kVK_Shift)) == .none)
        #expect(state.stepFlagsUp(code: UInt16(kVK_Control)) == .none)
    }

    @Test func keyDownDisarmsPendingArm() {
        var state = FlagsCaptureState()
        #expect(state.stepFlagsDown(code: UInt16(kVK_Command)) == .none)
        state.stepKeyDown()
        // The release after a combo belongs to the combo path, not us.
        #expect(state.stepFlagsUp(code: UInt16(kVK_Command)) == .none)
    }

    @Test func untrackableCodeFallsThrough() {
        // CapsLock has no CGEvent flag: never armed, never captured — its
        // keyDown reaches classify, which refuses it honestly.
        var state = FlagsCaptureState()
        #expect(state.stepFlagsDown(code: UInt16(kVK_CapsLock)) == .none)
        #expect(state.stepFlagsUp(code: UInt16(kVK_CapsLock)) == .none)
    }

    @Test func releaseWithoutArmSilent() {
        var state = FlagsCaptureState()
        #expect(state.stepFlagsUp(code: UInt16(kVK_Option)) == .none)
    }

    @Test func nsFlagMapping() {
        #expect(FlagsCaptureState.nsFlag(for: UInt16(kVK_RightOption)) == .option)
        #expect(FlagsCaptureState.nsFlag(for: UInt16(kVK_Function)) == .function)
        #expect(FlagsCaptureState.nsFlag(for: UInt16(kVK_CapsLock)) == nil)
    }

    @Test func chordReasonMessage() {
        #expect(RecorderInvalidReason.chordOnly.message.contains("One key"))
    }
}
