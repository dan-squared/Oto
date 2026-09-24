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

    /// Copy with the interaction replaced. Dispatch enforces the slot's
    /// fixed mode at the routing call site; stored triggers carry it too
    /// so a lone trigger value never implies the wrong gesture.
    func withInteraction(_ interaction: InteractionMode) -> ShortcutTrigger {
        ShortcutTrigger(kind: kind, interaction: interaction)
    }
}

/// Which live slot a global event belongs to. Modes are slot properties,
/// not user data: hold drives beginHold/finish, hands-free drives
/// toggleHandsFree. Named `ShortcutSlot` (not `Slot`) to avoid the generic
/// word colliding with future SwiftUI/container `Slot` types.
enum ShortcutSlot: Equatable, Sendable, Codable, CaseIterable {
    case hold
    case handsFree
}

extension ShortcutTrigger.Kind {
    /// Cross-slot conflict check. Same kind+codes = conflict. Asymmetric
    /// pairs that resolve deterministically are NOT conflicts (documented,
    /// never blocked):
    /// - modifierHold-vs-combo sharing the modifier: the combo fires and the
    ///   hold release is swallowed by `usedInCombination` (combo wins by
    ///   construction).
    /// - functionKey-vs-combo: separated by the bare-press `shouldFire` rule
    ///   unless the combo IS that function key bare (same keyCode, no
    ///   modifiers).
    /// - modifierHold-vs-functionKey: disjoint detection paths, never collide.
    /// Combo-vs-combo is deliberately conservative: the same keyCode blocks
    /// even with disjoint modifiers (saving near-identical shortcuts for
    /// both modes is confusing UX either way).
    nonisolated func conflictsWith(_ other: ShortcutTrigger.Kind) -> Bool {
        switch (self, other) {
        case (.modifierHold(let a), .modifierHold(let b)):
            return a == b
        case (.functionKey(let a), .functionKey(let b)):
            return !a.isDisjoint(with: b)
        case (.combo(_, let a), .combo(_, let b)):
            return a == b
        case (.modifierHold, .combo), (.combo, .modifierHold):
            return false
        case (.modifierHold, .functionKey), (.functionKey, .modifierHold):
            return false
        case (.functionKey(let codes), .combo(let modifiers, let keyCode)),
             (.combo(let modifiers, let keyCode), .functionKey(let codes)):
            return modifiers == 0 && codes.contains(Int64(keyCode))
        }
    }
}

/// Oto-owned shortcut configuration. Persisted by Oto (scalars in
/// UserDefaults); no competing store (the 12:46 one-store rule — a separate
/// PreferencesStore was considered and rejected in Phase 5).
///
/// READ-ONLY MIGRATION SOURCE for `DualShortcutConfiguration`. Do not write
/// new code against this type; it is decoded once during migration and never
/// written again. Removed no earlier than 2 releases.
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

/// Two live shortcut slots with fixed modes: hold drives beginHold/finish,
/// hands-free drives toggleHandsFree. One global `enabled` (per-slot enable
/// deferred — no product ask, doubles calibration/test surface). Today's
/// two presets become the two factory defaults, so a fresh install behaves
/// exactly like the old single-slot default + the Dictation-key preset.
struct DualShortcutConfiguration: Equatable, Sendable, Codable {
    var hold: ShortcutTrigger
    var handsFree: ShortcutTrigger
    var enabled: Bool

    nonisolated static func == (lhs: DualShortcutConfiguration, rhs: DualShortcutConfiguration) -> Bool {
        lhs.hold == rhs.hold && lhs.handsFree == rhs.handsFree && lhs.enabled == rhs.enabled
    }

    static let defaultsKey = "app.Oto.dualShortcutConfiguration"

    static func `default`() -> DualShortcutConfiguration {
        DualShortcutConfiguration(
            hold: .defaultHoldToTalk(),
            handsFree: .dictationKeyHandsFree(),
            enabled: true
        )
    }

    static func load(from defaults: UserDefaults = .standard) -> DualShortcutConfiguration {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(DualShortcutConfiguration.self, from: data)
        else {
            // One-shot migration from the single-slot store: the old trigger
            // lands in its matching slot, the other slot takes the factory
            // default. The old key is left in place (read-only fallback,
            // never written again).
            if let migrated = migrate(from: defaults) { return migrated }
            return .default()
        }
        return decoded
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func migrate(from defaults: UserDefaults) -> DualShortcutConfiguration? {
        guard let data = defaults.data(forKey: ShortcutConfiguration.defaultsKey),
              let old = try? JSONDecoder().decode(ShortcutConfiguration.self, from: data)
        else { return nil }
        var config = DualShortcutConfiguration.default()
        config.enabled = old.enabled
        switch old.trigger.interaction {
        case .holdToTalk:
            config.hold = old.trigger.withInteraction(.holdToTalk)
        case .handsFree:
            config.handsFree = old.trigger.withInteraction(.handsFree)
        }
        return config
    }
}
