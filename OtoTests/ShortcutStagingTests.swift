//
//  ShortcutStagingTests.swift
//  OtoTests
//
//  Modal staging model: effective values, Done-gate preview, Swap clearing
//  staged edits, staged-clear semantics. Pure, no hardware.
//

import Carbon.HIToolbox
import Foundation
import Testing
@testable import Oto

@MainActor
struct ShortcutStagingTests {
    private func comboD() -> ShortcutTrigger.Kind {
        .combo(
            modifiers: UInt32(CarbonModifiers.command | CarbonModifiers.shift),
            keyCode: UInt32(kVK_ANSI_D)
        )
    }

    @Test func untouchedStagesPreviewUnchanged() {
        let staging = ShortcutStaging(live: .default())
        #expect(staging.hasChanges == false)
        #expect(staging.effectiveKind(for: .hold) == DualShortcutConfiguration.default().hold.kind)
        #expect(staging.effectiveKind(for: .handsFree) == DualShortcutConfiguration.default().handsFree.kind)
        let preview = staging.donePreview()
        #expect(preview.hold == .unchanged)
        #expect(preview.handsFree == .unchanged)
        #expect(preview.disablesGlobally == false)
    }

    @Test func distinctStagedKindPreviewsApplied() {
        var staging = ShortcutStaging(live: .default())
        staging.stagedHoldKind = comboD()
        #expect(staging.hasChanges == true)
        #expect(staging.effectiveKind(for: .hold) == comboD())
        let preview = staging.donePreview()
        #expect(preview.hold == .applied)
        #expect(preview.handsFree == .unchanged)
    }

    @Test func stagedKindMatchingOtherSlotPreviewsBlocked() {
        var staging = ShortcutStaging(live: .default())
        staging.stagedHandsFreeKind = DualShortcutConfiguration.default().hold.kind
        let preview = staging.donePreview()
        #expect(preview.handsFree == .blocked)
        #expect(preview.hold == .unchanged)
    }

    @Test func stagedKindEqualToLivePreviewsUnchanged() {
        var staging = ShortcutStaging(live: .default())
        staging.stagedHoldKind = DualShortcutConfiguration.default().hold.kind
        #expect(staging.donePreview().hold == .unchanged)
    }

    @Test func stagedClearDisablesGlobally() {
        var staging = ShortcutStaging(live: .default())
        staging.stagedHoldCleared = true
        #expect(staging.hasChanges == true)
        #expect(staging.isClearedStaged(for: .hold) == true)
        #expect(staging.isClearedStaged(for: .handsFree) == false)
        let preview = staging.donePreview()
        #expect(preview.disablesGlobally == true)
        #expect(preview.hold == .unchanged)
        // Clearing never conflicts: the stored trigger is kept.
        #expect(staging.effectiveKind(for: .hold) == DualShortcutConfiguration.default().hold.kind)
    }

    @Test func clearStagedResetsEverything() {
        var staging = ShortcutStaging(live: .default())
        staging.stagedHoldKind = comboD()
        staging.stagedHandsFreeCleared = true
        staging.clearStaged()
        #expect(staging.hasChanges == false)
        #expect(staging.donePreview().disablesGlobally == false)
    }
}
