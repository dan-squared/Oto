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
        #expect(config.holdEnabled == true)
        #expect(config.handsFreeEnabled == true)
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
            holdEnabled: false,
            handsFreeEnabled: false
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
        #expect(migrated.holdEnabled == false)
        #expect(migrated.handsFreeEnabled == false)
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
        #expect(migrated.holdEnabled == true)
        #expect(migrated.handsFreeEnabled == true)
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

    @Test func holdVersusComboConflictsOnSharedFamilyEitherOrder() {
        // Rule B: a hold begin fires on modifier-down before any combo can
        // complete (only the release is swallowed) — same-family bindings
        // across purposes double-fire, so they are refused both orders.
        let holdOpt = ShortcutTrigger.Kind.modifierHold(keyCode: UInt16(kVK_RightOption))
        let comboOpt = ShortcutTrigger.Kind.combo(
            modifiers: UInt32(CarbonModifiers.option), keyCode: UInt32(kVK_ANSI_D)
        )
        #expect(holdOpt.conflictsWith(comboOpt))
        #expect(comboOpt.conflictsWith(holdOpt))
        // Family-level: left side groups with right (Carbon combos are
        // side-blind, so sides can't be distinguished honestly).
        let holdLeftOpt = ShortcutTrigger.Kind.modifierHold(keyCode: UInt16(kVK_Option))
        #expect(holdLeftOpt.conflictsWith(comboOpt))
        // Different families never collide…
        let holdCmd = ShortcutTrigger.Kind.modifierHold(keyCode: UInt16(kVK_RightCommand))
        #expect(!holdCmd.conflictsWith(comboOpt))
        #expect(!comboOpt.conflictsWith(holdCmd))
        let comboCmd = ShortcutTrigger.Kind.combo(
            modifiers: UInt32(CarbonModifiers.command), keyCode: UInt32(kVK_ANSI_D)
        )
        #expect(!holdOpt.conflictsWith(comboCmd))
        // …and fn holds never conflict with combos (fn is no combo modifier).
        let holdFn = ShortcutTrigger.Kind.modifierHold(keyCode: UInt16(kVK_Function))
        #expect(!holdFn.conflictsWith(comboOpt))
        #expect(!comboOpt.conflictsWith(holdFn))
    }

    @Test func siblingTransformCombosStayAllowed() {
        // Opt+1 vs Opt+2: different digits, Carbon distinguishes by keyCode —
        // the trio the product promises must not refuse itself.
        let one = ShortcutTrigger.Kind.combo(
            modifiers: UInt32(CarbonModifiers.option), keyCode: UInt32(kVK_ANSI_1)
        )
        let two = ShortcutTrigger.Kind.combo(
            modifiers: UInt32(CarbonModifiers.option), keyCode: UInt32(kVK_ANSI_2)
        )
        #expect(!one.conflictsWith(two))
        #expect(!two.conflictsWith(one))
    }

    @Test func refusalCopyNamesPurpose() {
        #expect(ShortcutRefusalMessage.alreadyInUse(by: "Polish") ==
            "Already in use by Polish — pick a different one.")
        #expect(ShortcutRefusalMessage.tooSimilar(
            to: "Push to talk", heldChip: "Right ⌥", glyph: "⌥", family: "Option"
        ) ==
            "Too similar to your Push to talk shortcut (Right ⌥) — ⌥ shortcuts fire on either Option key and would trigger together. Pick a different one.")
        // Rule-aware pick: exact dups get "already in use", same-family
        // hold/combo gets the side-naming "too similar".
        let holdOpt = ShortcutTrigger.Kind.modifierHold(keyCode: UInt16(kVK_RightOption))
        let comboOpt = ShortcutTrigger.Kind.combo(
            modifiers: UInt32(CarbonModifiers.option), keyCode: UInt32(kVK_ANSI_D)
        )
        let similar = ShortcutRefusalMessage.message(
            refused: comboOpt, byExisting: holdOpt, purposeName: "Push to talk"
        )
        #expect(similar.contains("Too similar"))
        #expect(similar.contains("Right ⌥"))
        #expect(similar.contains("either Option key"))
        #expect(ShortcutRefusalMessage.message(
            refused: holdOpt, byExisting: holdOpt, purposeName: "Hands-free"
        ).contains("Already in use by Hands-free"))
        #expect(ShortcutTrigger.Kind.familyName(forHoldCode: UInt16(kVK_RightOption)) == "Option")
        #expect(ShortcutTrigger.Kind.familyGlyph(forHoldCode: UInt16(kVK_RightCommand)) == "⌘")
        #expect(ShortcutTrigger.Kind.familyName(forHoldCode: UInt16(kVK_Function)) == nil)
    }

    @Test func factoryDefaultsSatisfyPolicy() {
        // The out-of-box setup must obey its own rule: right-Cmd hold +
        // unassigned hands-free + Opt+1/2/3 transforms, zero conflicts.
        let config = DualShortcutConfiguration.default()
        let transforms = TransformShortcuts.default()
        #expect(ShortcutAudit.violations(
            hold: config.hold.kind, handsFree: config.handsFree.kind,
            transforms: transforms
        ).isEmpty)
        #expect(transforms.polish == .combo(
            modifiers: UInt32(CarbonModifiers.command), keyCode: UInt32(kVK_ANSI_1)))
    }

    @Test func auditNamesGrandfatheredViolations() {
        // A stored violating pair (Option hold + Opt-digit transforms, the
        // pre-Cmd-trio shape) is named, never silently cleared: the hold
        // plus all three transforms flag each other.
        let clashing = TransformShortcuts(
            polish: .combo(modifiers: UInt32(CarbonModifiers.option), keyCode: UInt32(kVK_ANSI_1)),
            concise: .combo(modifiers: UInt32(CarbonModifiers.option), keyCode: UInt32(kVK_ANSI_2)),
            professional: .combo(modifiers: UInt32(CarbonModifiers.option), keyCode: UInt32(kVK_ANSI_3))
        )
        let violations = ShortcutAudit.violations(
            hold: .modifierHold(keyCode: UInt16(kVK_RightOption)),
            handsFree: .unassigned,
            transforms: clashing
        )
        #expect(violations.count == 4)
        #expect(violations.allSatisfy { $0.message.contains("Too similar") })
    }

    @Test func transformShortcutsRoundTripAndFallBack() {
        let defaults = UserDefaults(suiteName: "test.oto.\(UUID().uuidString)")!
        #expect(TransformShortcuts.load(from: defaults) == .default())
        var custom = TransformShortcuts.default()
        custom.concise = .combo(
            modifiers: UInt32(CarbonModifiers.command), keyCode: UInt32(kVK_ANSI_2)
        )
        custom.save(to: defaults)
        #expect(TransformShortcuts.load(from: defaults) == custom)
        defaults.set("garbage".data(using: .utf8)!, forKey: TransformShortcuts.defaultsKey)
        #expect(TransformShortcuts.load(from: defaults) == .default())
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
            holdEnabled: true,
            handsFreeEnabled: true
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
        #expect(migrated.holdEnabled == true)
        #expect(migrated.handsFreeEnabled == true)
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
            holdEnabled: true,
            handsFreeEnabled: true
        )
        stored.save(to: defaults)

        let loaded = DualShortcutConfiguration.load(from: defaults)
        #expect(loaded.handsFree == .unassignedHandsFree())
        #expect(loaded.hold == .defaultHoldToTalk())
        // Saved back: stable, no migration loop.
        #expect(DualShortcutConfiguration.load(from: defaults) == loaded)
    }

    // MARK: - Global-era blob matrix (retired `enabled` key)

    /// A global-era blob carries hold/handsFree plus the retired `enabled`
    /// key and neither per-slot flag. Built by stripping a real encoding
    /// (never hand-written trigger JSON), so the shape is exact.
    private func globalEraData(enabled: Bool?) throws -> Data {
        let blob = try JSONEncoder().encode(DualShortcutConfiguration.default())
        var dict = try JSONSerialization.jsonObject(with: blob) as! [String: Any]
        dict.removeValue(forKey: "holdEnabled")
        dict.removeValue(forKey: "handsFreeEnabled")
        dict.removeValue(forKey: "enabled")
        if let enabled { dict["enabled"] = enabled }
        return try JSONSerialization.data(withJSONObject: dict)
    }

    @Test func globalOffMapsToBothOff() throws {
        let (defaults, suite) = ephemeralDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try globalEraData(enabled: false), forKey: DualShortcutConfiguration.defaultsKey)
        let loaded = DualShortcutConfiguration.load(from: defaults)
        #expect(loaded.holdEnabled == false)
        #expect(loaded.handsFreeEnabled == false)
        #expect(loaded.hold == .defaultHoldToTalk())
    }

    @Test func globalOnMapsToBothOn() throws {
        let (defaults, suite) = ephemeralDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try globalEraData(enabled: true), forKey: DualShortcutConfiguration.defaultsKey)
        let loaded = DualShortcutConfiguration.load(from: defaults)
        #expect(loaded.holdEnabled == true)
        #expect(loaded.handsFreeEnabled == true)
    }

    @Test func preSlotBlobDefaultsBothOn() throws {
        let (defaults, suite) = ephemeralDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try globalEraData(enabled: nil), forKey: DualShortcutConfiguration.defaultsKey)
        let loaded = DualShortcutConfiguration.load(from: defaults)
        #expect(loaded.holdEnabled == true)
        #expect(loaded.handsFreeEnabled == true)
    }

    @Test func perSlotFlagsWinOverLegacyGlobal() throws {
        // Cannot arise from new code (legacy key never written), but the
        // tolerant decode must prefer the precise flags if both appear.
        let (defaults, suite) = ephemeralDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let blob = try JSONEncoder().encode(DualShortcutConfiguration(
            hold: .defaultHoldToTalk(),
            handsFree: .unassignedHandsFree(),
            holdEnabled: false,
            handsFreeEnabled: true
        ))
        var dict = try JSONSerialization.jsonObject(with: blob) as! [String: Any]
        dict["enabled"] = true
        defaults.set(
            try JSONSerialization.data(withJSONObject: dict),
            forKey: DualShortcutConfiguration.defaultsKey
        )
        let loaded = DualShortcutConfiguration.load(from: defaults)
        #expect(loaded.holdEnabled == false)
        #expect(loaded.handsFreeEnabled == true)
    }

    @Test func legacyGlobalKeyIsNeverWritten() throws {
        let blob = try JSONEncoder().encode(DualShortcutConfiguration(
            hold: .defaultHoldToTalk(),
            handsFree: .unassignedHandsFree(),
            holdEnabled: false,
            handsFreeEnabled: true
        ))
        let dict = try JSONSerialization.jsonObject(with: blob) as! [String: Any]
        #expect(dict["enabled"] == nil)
        #expect(dict["holdEnabled"] as? Bool == false)
        #expect(dict["handsFreeEnabled"] as? Bool == true)
    }
}
