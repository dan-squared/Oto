//
//  ModifierHotkeyMonitor.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import AppKit
import Carbon.HIToolbox
import Foundation

/// Ordinary combo shortcuts via first-party Carbon registration.
/// Emits values only; never decides session behavior (12 limit).
///
/// NOTE: bare-modifier hold detection used to live here on NSEvent
/// flagsChanged monitors. Both global and local NSEvent monitors wedge
/// MenuBarExtra menu tracking on this macOS (proven by bisect), so ALL
/// NSEvent monitoring is banned from the trigger path — modifier-hold
/// moved to the HID tap (`HIDEventMonitor`), which lives below AppKit
/// tracking and is immune by construction.
@MainActor
final class ModifierHotkeyMonitor {
    /// Emitted for every normalized physical event. One synchronous hop;
    /// no Task-per-event (12 limit).
    var onEvent: ((ShortcutEvent) -> Void)?

    /// True after `configure` with a live registration. Observed by
    /// dispatch for the calibration row (never claimed without proof).
    private(set) var isLive = false

    /// If `kEventHotKeyReleased` is missed (e.g. menu tracking or screen lock),
    /// a subsequent press arriving after this interval is treated as a fresh
    /// press rather than stuck forever as an auto-repeat.
    nonisolated static let stalePressTimeout: Duration = .milliseconds(1500)

    private var carbonHotKey: CarbonHotKey?
    /// Carbon may re-deliver pressed events while held; normalize those to
    /// repeats here so the transition machine never sees a second "first"
    /// down (which would wrongly toggle hands-free off mid-hold).
    private var carbonDown = false
    private var carbonDownAt: ContinuousClock.Instant?

    func configure(comboModifiers: UInt32, keyCode: UInt32) {
        stop()
        carbonHotKey = CarbonHotKey(
            carbonKeyCode: Int(keyCode),
            carbonModifiers: Int(comboModifiers),
            onKeyDown: { [weak self] in
                guard let self else { return }
                let event = self.stepCarbonKeyDown()
                self.onEvent?(event)
            },
            onKeyUp: { [weak self] in
                guard let self else { return }
                let event = self.stepCarbonKeyUp()
                self.onEvent?(event)
            }
        )
        // Registration failure (conflict) surfaces as nil → not live,
        // never silent.
        isLive = carbonHotKey != nil
    }

    func stop() {
        carbonHotKey = nil
        carbonDown = false
        carbonDownAt = nil
        isLive = false
    }

    /// Pure key-down normalization exposed internally for unit tests.
    func stepCarbonKeyDown(at now: ContinuousClock.Instant = ContinuousClock().now) -> ShortcutEvent {
        let isStale = carbonDownAt.map { $0.duration(to: now) > Self.stalePressTimeout } ?? true
        let repeatPress = carbonDown && !isStale
        carbonDown = true
        carbonDownAt = now
        return .keyDown(isRepeat: repeatPress)
    }

    /// Pure key-up normalization exposed internally for unit tests.
    func stepCarbonKeyUp() -> ShortcutEvent {
        carbonDown = false
        carbonDownAt = nil
        return .keyUp
    }
}
