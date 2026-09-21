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

    /// Fires when a previously-live registration fails to resume (e.g.
    /// another app grabbed the combo while asleep). Dispatch surfaces it
    /// as a conflict; the trigger choice is preserved for retry.
    var onRegistrationFailure: (() -> Void)?

    private var carbonHotKey: CarbonHotKey?
    /// Carbon may re-deliver pressed events while held; normalize those to
    /// repeats here so the transition machine never sees a second "first"
    /// down (which would wrongly toggle hands-free off mid-hold).
    private var carbonDown = false

    func configure(comboModifiers: UInt32, keyCode: UInt32) {
        stop()
        carbonHotKey = CarbonHotKey(
            carbonKeyCode: Int(keyCode),
            carbonModifiers: Int(comboModifiers),
            onKeyDown: { [weak self] in
                guard let self else { return }
                let repeatPress = self.carbonDown
                self.carbonDown = true
                self.onEvent?(.keyDown(isRepeat: repeatPress))
            },
            onKeyUp: { [weak self] in
                guard let self else { return }
                self.carbonDown = false
                self.onEvent?(.keyUp)
            }
        )
        // Registration failure (conflict) surfaces as nil → not live,
        // never silent.
        isLive = carbonHotKey != nil
    }

    func stop() {
        carbonHotKey = nil
        carbonDown = false
        isLive = false
    }
}
