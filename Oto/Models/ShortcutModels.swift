//
//  ShortcutModels.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import AppKit
import Carbon.HIToolbox
import Foundation

/// Physical key event, already normalized by a backend. Backends emit
/// values; they never decide session behavior (12 limit).
enum ShortcutEvent: Equatable, Sendable {
    // Explicit: compared in transition tests from any domain (Swift 6).
    nonisolated static func == (lhs: ShortcutEvent, rhs: ShortcutEvent) -> Bool {
        switch (lhs, rhs) {
        case (.keyDown(let a), .keyDown(let b)):
            return a == b
        case (.keyUp, .keyUp), (.monitorLost, .monitorLost):
            return true
        default:
            return false
        }
    }

    /// Key/combo went down. `isRepeat` marks auto-repeat (never begins).
    case keyDown(isRepeat: Bool)
    /// The tracked key/combo was released.
    case keyUp
    /// The backend lost the trail (tap timeout, deactivation, revocation).
    /// Local pressed state resets; the coordinator owns the session outcome.
    case monitorLost
}

/// Transition out of the pure state machine. `begin`/`finish` map to one
/// coordinator call each; everything else is local bookkeeping.
enum ShortcutTransition: Equatable, Sendable {
    // Explicit: compared in transition tests from any domain (Swift 6).
    nonisolated static func == (lhs: ShortcutTransition, rhs: ShortcutTransition) -> Bool {
        switch (lhs, rhs) {
        case (.begin, .begin), (.finish, .finish), (.ignore, .ignore), (.reset, .reset):
            return true
        default:
            return false
        }
    }

    case begin
    case finish
    case ignore
    case reset
}

/// What the person holds. Carbon combos need a real key; bare modifiers
/// and function-row keys ride their own detectors (see monitors).
struct ShortcutTrigger: Equatable, Sendable, Codable {
    enum Kind: Equatable, Sendable, Codable {
        // Explicit: compared in tests/config diffing from any domain (Swift 6).
        nonisolated static func == (lhs: Kind, rhs: Kind) -> Bool {
            switch (lhs, rhs) {
            case (.modifierHold(let a), .modifierHold(let b)):
                return a == b
            case (.functionKey(let a), .functionKey(let b)):
                return a == b
            case (.combo(let am, let ak), .combo(let rm, let rk)):
                return am == rm && ak == rk
            default:
                return false
            }
        }

        /// Right/left Option (or another single modifier) held down.
        case modifierHold(keyCode: UInt16)
        /// Bare F-key or the Dictation key on the HID tap path.
        case functionKey(codes: Set<Int64>)
        /// Ordinary combo (modifiers + real key) on the Carbon path.
        case combo(modifiers: UInt32, keyCode: UInt32)
    }

    var kind: Kind
    var interaction: InteractionMode

    nonisolated static func == (lhs: ShortcutTrigger, rhs: ShortcutTrigger) -> Bool {
        lhs.kind == rhs.kind && lhs.interaction == rhs.interaction
    }

    static func defaultHoldToTalk() -> ShortcutTrigger {
        ShortcutTrigger(
            kind: .modifierHold(keyCode: UInt16(kVK_RightOption)),
            interaction: .holdToTalk
        )
    }

    static func dictationKeyHandsFree() -> ShortcutTrigger {
        ShortcutTrigger(
            kind: .functionKey(codes: [Int64(kVK_F5), 176]),
            interaction: .handsFree
        )
    }
}

/// Oto-owned shortcut configuration. Persisted by Oto (scalars in
/// UserDefaults); no competing store (the 12:46 one-store rule — a separate
/// PreferencesStore was considered and rejected in Phase 5).
struct ShortcutConfiguration: Equatable, Sendable, Codable {
    var trigger: ShortcutTrigger
    var enabled: Bool

    nonisolated static func == (lhs: ShortcutConfiguration, rhs: ShortcutConfiguration) -> Bool {
        lhs.trigger == rhs.trigger && lhs.enabled == rhs.enabled
    }

    static let defaultsKey = "app.Oto.shortcutConfiguration"

    static func `default`() -> ShortcutConfiguration {
        ShortcutConfiguration(trigger: .defaultHoldToTalk(), enabled: true)
    }

    static func load(from defaults: UserDefaults = .standard) -> ShortcutConfiguration {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(ShortcutConfiguration.self, from: data)
        else { return .default() }
        return decoded
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
