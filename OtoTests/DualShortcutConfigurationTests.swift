//
//  DualShortcutConfigurationTests.swift
//  OtoTests
//
//  Dual-slot config: Codable round-trip, factory defaults, one-shot
//  migration from the single-slot store, and the full conflictsWith matrix.
//  No hardware, no async, deterministic.
//

import Carbon.HIToolbox
import Foundation
import Testing
@testable import Oto

@MainActor
struct DualShortcutConfigurationTests {
    private func ephemeralDefaults() -> (UserDefaults, String) {
        let suite = "app.Oto.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    // MARK: - Defaults

    @Test func factoryDefaultsShipEmptyHandsFree() {
        let config = DualShortcutConfiguration.default()
        #expect(config.hold == .defaultHoldToTalk())
        #expect(config.handsFree == .unassignedHandsFree())
        #expect(config.enabled == true)
        // Fixed modes from birth: no slot can imply the wrong gesture.
        #expect(config.hold.interaction == .holdToTalk)
        #expect(config.handsFree.interaction == .handsFree)
    }

    // MARK: - Round-trip

    @Test func roundTripsThroughUserDefaults() {
        let (defaults, suite) = ephemeralDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = DualShortcutConfiguration(
            hold: ShortcutTrigger(
                kind: .combo(
                    modifiers: UInt32(CarbonModifiers.command | CarbonModifiers.control),
                    keyCode: UInt32(kVK_ANSI_G)
                ),
                interaction: .holdToTalk
            ),
            handsFree: .dictationKeyHandsFree(),
            enabled: false
        )
        original.save(to: defaults)
        #expect(DualShortcutConfiguration.load(from: defaults) == original)
    }

    @Test func missingEverythingFallsBackToDefault() {
        let (defaults, suite) = ephemeralDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(DualShortcutConfiguration.load(from: defaults) == .default())
    }

    // MARK: - Migration

    @Test func holdToTalkOldConfigLandsInHoldSlot() {
        let (defaults, suite) = ephemeralDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = ShortcutConfiguration(
            trigger: ShortcutTrigger(
                kind: .combo(
                    modifiers: UInt32(CarbonModifiers.command | CarbonModifiers.shift),
                    keyCode: UInt32(kVK_ANSI_D)
                ),
                interaction: .holdToTalk
            ),
            enabled: false
        )
        old.save(to: defaults)

        let migrated = DualShortcutConfiguration.load(from: defaults)
        #expect(migrated.hold == old.trigger)
        #expect(migrated.hold.interaction == .holdToTalk)
        #expect(migrated.handsFree == .unassignedHandsFree())
        #expect(migrated.enabled == false)
        // Old key left in place, still decodable as the old type.
        #expect(ShortcutConfiguration.load(from: defaults) == old)
    }

    @Test func handsFreeOldConfigLandsInHandsFreeSlot() {
        let (defaults, suite) = ephemeralDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = ShortcutConfiguration(
            trigger: ShortcutTrigger(
                kind: .modifierHold(keyCode: UInt16(kVK_RightOption)),
                interaction: .handsFree
            ),
            enabled: true
        )
        old.save(to: defaults)

        let migrated = DualShortcutConfiguration.load(from: defaults)
        #expect(migrated.handsFree.kind == old.trigger.kind)
        #expect(migrated.handsFree.interaction == .handsFree)
        #expect(migrated.hold == .defaultHoldToTalk())
        #expect(migrated.enabled == true)
        #expect(ShortcutConfiguration.load(from: defaults) == old)
    }

    // MARK: - conflictsWith matrix (all 9 kind pairs)

    @Test func holdVersusHoldConflictsOnlyOnSameCode() {
        let a = ShortcutTrigger.Kind.modifierHold(keyCode: UInt16(kVK_RightOption))
        #expect(a.conflictsWith(.modifierHold(keyCode: UInt16(kVK_RightOption))))
        #expect(!a.conflictsWith(.modifierHold(keyCode: UInt16(kVK_RightCommand))))
    }

    @Test func functionVersusFunctionConflictsOnlyOnOverlap() {
        let a = ShortcutTrigger.Kind.functionKey(codes: [Int64(kVK_F5), 176])
        #expect(a.conflictsWith(.functionKey(codes: [176])))
        #expect(!a.conflictsWith(.functionKey(codes: [Int64(kVK_F6)])))
    }

    @Test func comboVersusComboConservativelyConflictsOnSameKey() {
        let mods = UInt32(CarbonModifiers.command)
        let otherMods = UInt32(CarbonModifiers.option)
        let a = ShortcutTrigger.Kind.combo(modifiers: mods, keyCode: UInt32(kVK_ANSI_D))
        // Same key even with disjoint modifiers: blocked by design.
        #expect(a.conflictsWith(.combo(modifiers: otherMods, keyCode: UInt32(kVK_ANSI_D))))
        #expect(!a.conflictsWith(.combo(modifiers: mods, keyCode: UInt32(kVK_ANSI_G))))
    }

    @Test func holdVersusComboNeverConflictsEitherOrder() {
        let hold = ShortcutTrigger.Kind.modifierHold(keyCode: UInt16(kVK_RightOption))
        let combo = ShortcutTrigger.Kind.combo(
            modifiers: UInt32(CarbonModifiers.option), keyCode: UInt32(kVK_ANSI_D)
        )
        // Combo wins by construction (hold release swallowed).
        #expect(!hold.conflictsWith(combo))
        #expect(!combo.conflictsWith(hold))
    }

    @Test func holdVersusFunctionNeverConflictsEitherOrder() {
        let hold = ShortcutTrigger.Kind.modifierHold(keyCode: UInt16(kVK_RightOption))
        let fn = ShortcutTrigger.Kind.functionKey(codes: [Int64(kVK_F5)])
        #expect(!hold.conflictsWith(fn))
        #expect(!fn.conflictsWith(hold))
    }

    @Test func functionVersusComboConflictsOnlyWhenBareAndContained() {
        let fn = ShortcutTrigger.Kind.functionKey(codes: [Int64(kVK_F5), 176])
        let bare = ShortcutTrigger.Kind.combo(modifiers: 0, keyCode: UInt32(kVK_F5))
        let modified = ShortcutTrigger.Kind.combo(
            modifiers: UInt32(CarbonModifiers.command), keyCode: UInt32(kVK_F5)
        )
        let otherKey = ShortcutTrigger.Kind.combo(modifiers: 0, keyCode: UInt32(kVK_ANSI_D))
        #expect(fn.conflictsWith(bare))
        #expect(bare.conflictsWith(fn))
        // Modified presses never reach the bare-press path.
        #expect(!fn.conflictsWith(modified))
        #expect(!modified.conflictsWith(fn))
        #expect(!fn.conflictsWith(otherKey))
        #expect(!otherKey.conflictsWith(fn))
    }

    @Test func factoryDefaultsDoNotConflict() {
        #expect(!DualShortcutConfiguration.default().hold.kind.conflictsWith(
            DualShortcutConfiguration.default().handsFree.kind
        ))
    }

    // MARK: - Unassigned slot

    @Test func unassignedConflictsWithNothing() {
        let kinds: [ShortcutTrigger.Kind] = [
            .modifierHold(keyCode: UInt16(kVK_RightOption)),
            .functionKey(codes: [Int64(kVK_F5)]),
            .combo(modifiers: UInt32(CarbonModifiers.command), keyCode: UInt32(kVK_ANSI_D)),
            .unassigned,
        ]
        for kind in kinds {
            #expect(!ShortcutTrigger.Kind.unassigned.conflictsWith(kind))
            #expect(!kind.conflictsWith(.unassigned))
        }
        #expect(ShortcutTrigger.Kind.unassigned == .unassigned)
    }

    @Test func unassignedRoundTrips() {
        let (defaults, suite) = ephemeralDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = DualShortcutConfiguration(
            hold: .defaultHoldToTalk(),
            handsFree: .unassignedHandsFree(),
            enabled: true
        )
        original.save(to: defaults)
        #expect(DualShortcutConfiguration.load(from: defaults) == original)
    }

    @Test func policyPropsSingleSourceFnRules() {
        let fn = ShortcutTrigger.Kind.modifierHold(keyCode: UInt16(kVK_Function))
        #expect(fn.isSystemTapSensitive == true)
        #expect(fn.supportsHandsFreeToggle == false)
        let others: [ShortcutTrigger.Kind] = [
            .modifierHold(keyCode: UInt16(kVK_RightOption)),
            .modifierHold(keyCode: UInt16(kVK_Control)),
            .functionKey(codes: [Int64(kVK_F5), 176]),
            .combo(modifiers: UInt32(CarbonModifiers.command), keyCode: UInt32(kVK_ANSI_D)),
            .unassigned,
        ]
        for kind in others {
            #expect(kind.isSystemTapSensitive == false)
            #expect(kind.supportsHandsFreeToggle == true)
        }
    }

    // MARK: - fn-hands-free normalization

    @Test func dictationOldConfigPreserved() {
        // Stored F5 is a working binding: migration preserves it exactly.
        let (defaults, suite) = ephemeralDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = ShortcutConfiguration(
            trigger: .dictationKeyHandsFree(),
            enabled: true
        )
        old.save(to: defaults)

        let migrated = DualShortcutConfiguration.load(from: defaults)
        #expect(migrated.handsFree == .dictationKeyHandsFree())
        #expect(migrated.hold == .defaultHoldToTalk())
    }

    @Test func handsFreeFnMigratesToUnassigned() {
        let (defaults, suite) = ephemeralDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = ShortcutConfiguration(
            trigger: ShortcutTrigger(
                kind: .modifierHold(keyCode: UInt16(kVK_Function)),
                interaction: .handsFree
            ),
            enabled: true
        )
        old.save(to: defaults)

        let migrated = DualShortcutConfiguration.load(from: defaults)
        #expect(migrated.handsFree == .unassignedHandsFree())
        #expect(migrated.hold == .defaultHoldToTalk())
        #expect(migrated.enabled == true)
    }

    @Test func storedFnHandsFreeNormalizesOnce() {
        let (defaults, suite) = ephemeralDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let stored = DualShortcutConfiguration(
            hold: .defaultHoldToTalk(),
            handsFree: ShortcutTrigger(
                kind: .modifierHold(keyCode: UInt16(kVK_Function)),
                interaction: .handsFree
            ),
            enabled: true
        )
        stored.save(to: defaults)

        let loaded = DualShortcutConfiguration.load(from: defaults)
        #expect(loaded.handsFree == .unassignedHandsFree())
        #expect(loaded.hold == .defaultHoldToTalk())
        // Saved back: stable, no migration loop.
        #expect(DualShortcutConfiguration.load(from: defaults) == loaded)
    }
}
