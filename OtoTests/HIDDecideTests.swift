//
//  HIDDecideTests.swift
//  OtoTests
//
//  Audit S3: matrix tests for the HID tap's pure decision layer
//  (type/key/flags → emit/consume). No tap, no runloop, no AX: the monitor
//  is configured (tap creation fails safe without trust) and `decide` is
//  driven directly on the main actor. The C callback, install/uninstall,
//  and timeout recovery stay device-matrix territory.
//

import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import Oto

@MainActor
struct HIDDecideTests {
    private func holdMonitor() -> HIDEventMonitor {
        let monitor = HIDEventMonitor()
        monitor.configure(
            functionCodes: [Int64(kVK_F5), 176],
            holdKeyCode: UInt16(kVK_RightOption)
        )
        return monitor
    }

    // MARK: - Modifier hold: never consumed, combination-aware

    @Test func holdPressEmitsDownUnconsumed() {
        let monitor = holdMonitor()
        let decided = monitor.decide(
            type: .flagsChanged, keyCode: Int64(kVK_RightOption),
            isRepeat: false, flags: [.maskAlternate]
        )
        #expect(decided.emit == .keyDown(isRepeat: false))
        #expect(!decided.consume)
    }

    @Test func holdReleaseEmitsUpUnconsumed() {
        let monitor = holdMonitor()
        _ = monitor.decide(
            type: .flagsChanged, keyCode: Int64(kVK_RightOption),
            isRepeat: false, flags: [.maskAlternate]
        )
        let decided = monitor.decide(
            type: .flagsChanged, keyCode: Int64(kVK_RightOption),
            isRepeat: false, flags: []
        )
        #expect(decided.emit == .keyUp)
        #expect(!decided.consume)
    }

    @Test func foreignModifierEmitsNothing() {
        let monitor = holdMonitor()
        let decided = monitor.decide(
            type: .flagsChanged, keyCode: Int64(kVK_Command),
            isRepeat: false, flags: [.maskCommand]
        )
        #expect(decided.emit == nil)
        #expect(!decided.consume)
    }

    @Test func keyPressWhileHoldingSwallowsRelease() {
        let monitor = holdMonitor()
        _ = monitor.decide(
            type: .flagsChanged, keyCode: Int64(kVK_RightOption),
            isRepeat: false, flags: [.maskAlternate]
        )
        // Typing • (Option-U) mid-hold: the press marks combination use…
        let key = monitor.decide(
            type: .keyDown, keyCode: Int64(kVK_ANSI_U),
            isRepeat: false, flags: [.maskAlternate]
        )
        #expect(key.emit == nil)
        #expect(!key.consume)
        // …so the release emits nothing: no dictation from typing.
        let release = monitor.decide(
            type: .flagsChanged, keyCode: Int64(kVK_RightOption),
            isRepeat: false, flags: []
        )
        #expect(release.emit == nil)
    }

    // MARK: - Function keys: bare press tracked, matched release consumed

    @Test func bareFunctionPressEmitsDownConsumed() {
        let monitor = holdMonitor()
        let decided = monitor.decide(
            type: .keyDown, keyCode: Int64(kVK_F5),
            isRepeat: false, flags: []
        )
        #expect(decided.emit == .keyDown(isRepeat: false))
        #expect(decided.consume)
    }

    @Test func modifiedFunctionPressPassesThrough() {
        let monitor = holdMonitor()
        // ⌘F5 is VoiceOver's: never ours, never consumed.
        let decided = monitor.decide(
            type: .keyDown, keyCode: Int64(kVK_F5),
            isRepeat: false, flags: [.maskCommand]
        )
        #expect(decided.emit == nil)
        #expect(!decided.consume)
    }

    @Test func untrackedFunctionReleasePassesThrough() {
        let monitor = holdMonitor()
        let decided = monitor.decide(
            type: .keyUp, keyCode: Int64(kVK_F5),
            isRepeat: false, flags: []
        )
        #expect(decided.emit == nil)
        #expect(!decided.consume)
    }

    @Test func trackedFunctionReleaseEmitsUpConsumed() {
        let monitor = holdMonitor()
        _ = monitor.decide(
            type: .keyDown, keyCode: Int64(kVK_F5),
            isRepeat: false, flags: []
        )
        let decided = monitor.decide(
            type: .keyUp, keyCode: Int64(kVK_F5),
            isRepeat: false, flags: []
        )
        #expect(decided.emit == .keyUp)
        #expect(decided.consume)
    }

    // MARK: - Escape: observed, never consumed

    @Test func escapePassesThroughUnconsumed() {
        let monitor = holdMonitor()
        let decided = monitor.decide(
            type: .keyDown, keyCode: Int64(kVK_Escape),
            isRepeat: false, flags: []
        )
        #expect(decided.emit == nil)
        #expect(!decided.consume)
    }
}
