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
    case begin
    case finish
    case ignore
    case reset
}

/// What the person holds. Carbon combos need a real key; bare modifiers
/// and function-row keys ride their own detectors (see monitors).
struct ShortcutTrigger: Equatable, Sendable, Codable {
    enum Kind: Equatable, Sendable, Codable {
        /// Right/left Option (or another single modifier) held down.
        case modifierHold(keyCode: UInt16)
        /// Bare F-key or the Dictation key on the HID tap path.
        case functionKey(codes: Set<Int64>)
        /// Ordinary combo (modifiers + real key) on the Carbon path.
        case combo(modifiers: UInt32, keyCode: UInt32)
    }

    var kind: Kind
    var interaction: InteractionMode

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
/// UserDefaults); no competing store. Absorbed by `PreferencesStore` in
/// Phase 5 — the Codable shape already matches that future.
struct ShortcutConfiguration: Equatable, Sendable, Codable {
    var trigger: ShortcutTrigger
    var enabled: Bool

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
