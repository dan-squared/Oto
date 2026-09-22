//
//  NoTargetModalTests.swift
//  OtoTests
//
//  Slice 6C1: the kill-switch setting. Default ON (absent key teaches the
//  flow); explicit OFF sticks. The Settings toggle literal is pinned to the
//  helper key — rename one and this fails before users drift.
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Oto

@MainActor
struct NoTargetModalTests {
    @Test func absentKeyMeansOn() {
        let defaults = UserDefaults(suiteName: "oto-modal-test-\(UUID().uuidString)")!
        #expect(NoTargetModalSettings.isEnabled(defaults: defaults))
    }

    @Test func explicitOffSticks() {
        let defaults = UserDefaults(suiteName: "oto-modal-test-\(UUID().uuidString)")!
        defaults.set(false, forKey: NoTargetModalSettings.key)
        #expect(!NoTargetModalSettings.isEnabled(defaults: defaults))
        defaults.set(true, forKey: NoTargetModalSettings.key)
        #expect(NoTargetModalSettings.isEnabled(defaults: defaults))
    }

    @Test func settingsToggleKeyMatches() {
        // DictationPane's @AppStorage literal must equal this key.
        #expect(NoTargetModalSettings.key == "app.Oto.noTargetModal")
    }

    @Test func prewarmBuildsWithoutShowing() {
        // v4 F3b: construction moves to launch; show() only positions +
        // orders. No rebuild across calls (identity stable by hasPanel).
        let modal = NoTargetModalController()
        #expect(!modal.hasPanel)
        modal.prewarm()
        #expect(modal.hasPanel)
        #expect(!modal.isVisible)
        modal.prewarm()
        #expect(modal.hasPanel)
        modal.hide()
    }

    // MARK: - v4 remake (minimal adaptive UI + pill morph)

    @Test func nonactivatingRecipeRetained() {
        // The focus-steal defense survives the reflow: the catcher never
        // takes key (editing lives in the optional scratchpad, never here).
        let modal = NoTargetModalController()
        modal.prewarm()
        #expect(modal.isNonactivating)
        modal.hide()
    }

    @Test func paletteSchemesDifferAndPin() {
        // Dark preserves the reference near-black card; light is its
        // system-card equivalent. Rename a value and this fails before
        // users see drift.
        #expect(CatcherPalette.dark != CatcherPalette.light)
        #expect(CatcherPalette.dark.cardRed == 0.055)
        #expect(CatcherPalette.dark.cardGreen == 0.055)
        #expect(CatcherPalette.dark.cardBlue == 0.065)
        #expect(CatcherPalette.dark.lightText)
        #expect(!CatcherPalette.light.lightText)
        #expect(CatcherPalette.light.cardRed == 1.0)
        #expect(CatcherPalette.current(.dark) == .dark)
        #expect(CatcherPalette.current(.light) == .light)
    }

    @Test func morphEndFrameCentersAndClamps() {
        // Roomy screen: centered 464×168. Small screen: clamped into the
        // visible frame (never off-screen, never oversized).
        let roomy = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let end = NoTargetModalController.morphEndFrame(visible: roomy)
        #expect(end == NSRect(x: 488, y: 366, width: 464, height: 168))
        let small = NSRect(x: 0, y: 0, width: 400, height: 100)
        let clamped = NoTargetModalController.morphEndFrame(visible: small)
        #expect(clamped == NSRect(x: 0, y: 0, width: 400, height: 100))
        let offset = NSRect(x: 1440, y: 0, width: 1512, height: 982)
        let moved = NoTargetModalController.morphEndFrame(visible: offset)
        #expect(moved == NSRect(x: 1440 + 524, y: 407, width: 464, height: 168))
    }
}
