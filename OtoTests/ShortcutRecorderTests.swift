//
//  ShortcutRecorderTests.swift
//  OtoTests
//
//  Recorder validation + configuration persistence. Pure and deterministic.
//

import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Oto

// Touches UserDefaults + config values: main-actor suite (Swift 6).
@MainActor
struct ShortcutRecorderTests {
    // MARK: - Classification

    @Test func escapeCancels() {
        #expect(
            ShortcutRecorderRules.classify(keyCode: UInt16(kVK_Escape), modifiers: [], systemShortcuts: []) == .cancelled
        )
    }

    @Test func deleteClears() {
        #expect(
            ShortcutRecorderRules.classify(keyCode: UInt16(kVK_Delete), modifiers: [], systemShortcuts: []) == .cleared
        )
    }

    @Test func plainLetterIsInvalid() {
        #expect(
            ShortcutRecorderRules.classify(keyCode: UInt16(kVK_ANSI_D), modifiers: [], systemShortcuts: []) == .invalid
        )
    }

    @Test func bareShiftIsInvalid() {
        #expect(
            ShortcutRecorderRules.classify(keyCode: UInt16(kVK_Shift), modifiers: [.shift], systemShortcuts: []) == .invalid
        )
    }

    @Test func shiftLetterIsInvalid() {
        #expect(
            ShortcutRecorderRules.classify(
                keyCode: UInt16(kVK_ANSI_D),
                modifiers: [.shift],
                systemShortcuts: []
            ) == .invalid
        )
    }

    @Test func validComboCapturesWithoutConflicts() {
        let outcome = ShortcutRecorderRules.classify(
            keyCode: UInt16(kVK_ANSI_D),
            modifiers: [.command, .shift],
            systemShortcuts: []
        )
        guard case .captured(let mods, let code, let conflicts) = outcome else {
            Issue.record("expected captured, got \(outcome)")
            return
        }
        #expect(mods == UInt32(CarbonModifiers.command | CarbonModifiers.shift))
        #expect(code == UInt32(kVK_ANSI_D))
        #expect(conflicts.isEmpty)
    }

    @Test func systemConflictIsFlagged() {
        let outcome = ShortcutRecorderRules.classify(
            keyCode: UInt16(kVK_ANSI_D),
            modifiers: [.command, .shift],
            systemShortcuts: [(keyCode: Int(kVK_ANSI_D), modifiers: CarbonModifiers.command | CarbonModifiers.shift)]
        )
        guard case .captured(_, _, let conflicts) = outcome else {
            Issue.record("expected captured, got \(outcome)")
            return
        }
        #expect(conflicts.contains(.systemShortcut))
    }

    @Test func commandSpaceIsDisallowed() {
        let outcome = ShortcutRecorderRules.classify(
            keyCode: UInt16(kVK_Space),
            modifiers: [.command],
            systemShortcuts: []
        )
        guard case .captured(_, _, let conflicts) = outcome else {
            Issue.record("expected captured, got \(outcome)")
            return
        }
        #expect(conflicts.contains(where: {
            if case .disallowed = $0 { return true }
            return false
        }))
    }

    // MARK: - Conflict policy copy (audit S4 gap: blocksSaving/describe
    // had zero coverage despite gating what the UI saves)

    @Test func disallowedBlocksSystemWarns() {
        #expect(ShortcutRecorderConflicts.blocksSaving([.systemShortcut]) == false)
        #expect(ShortcutRecorderConflicts.blocksSaving([.disallowed(reason: "x")]) == true)
        #expect(ShortcutRecorderConflicts.blocksSaving([]) == false)
    }

    @Test func describeNamesEachConflict() {
        #expect(ShortcutRecorderConflicts.describe([.systemShortcut]).contains("system shortcut"))
        #expect(ShortcutRecorderConflicts.describe([.disallowed(reason: "sandboxed")]).contains("sandboxed"))
        #expect(ShortcutRecorderConflicts.describe([]).isEmpty)
    }

    @Test func functionKeyCapturesBare() {
        let outcome = ShortcutRecorderRules.classify(
            keyCode: UInt16(kVK_F5),
            modifiers: [],
            systemShortcuts: []
        )
        guard case .captured(_, let code, _) = outcome else {
            Issue.record("expected captured, got \(outcome)")
            return
        }
        #expect(code == UInt32(kVK_F5))
    }

    // MARK: - Configuration persistence

    @Test func configurationRoundTripsThroughUserDefaults() {
        let suite = "app.Oto.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = ShortcutConfiguration(
            trigger: ShortcutTrigger(
                kind: .combo(modifiers: UInt32(CarbonModifiers.command | CarbonModifiers.shift), keyCode: UInt32(kVK_ANSI_D)),
                interaction: .handsFree
            ),
            enabled: true
        )
        original.save(to: defaults)
        #expect(ShortcutConfiguration.load(from: defaults) == original)
    }

    @Test func missingConfigurationFallsBackToDefault() {
        let defaults = UserDefaults(suiteName: "app.Oto.tests.\(UUID().uuidString)")!
        let loaded = ShortcutConfiguration.load(from: defaults)
        #expect(loaded == .default())
        #expect(loaded.trigger == .defaultHoldToTalk())
    }
}
