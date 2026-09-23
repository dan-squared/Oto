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

    @Test func morphEndFrameAtSlotGrowsInPlace() {        // v6: same x as the pill (both centered), slot-anchored y —
        // top grows down from the pill's top edge, bottom up from its
        // bottom edge. Zero travel, pure vertical growth.
        let roomy = NSRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(NoTargetModalController.morphEndFrameAtSlot(visible: roomy, position: .bottom)
            == NSRect(x: 488, y: 28, width: 464, height: 168))
        #expect(NoTargetModalController.morphEndFrameAtSlot(visible: roomy, position: .top)
            == NSRect(x: 488, y: 720, width: 464, height: 168))
        // Narrow screen: floor at full card width (audit F1) — a
        // squeezed frame would amputate Copy; overflow stays visible.
        let narrow = NSRect(x: 0, y: 0, width: 400, height: 500)
        #expect(NoTargetModalController.morphEndFrameAtSlot(visible: narrow, position: .bottom)
            == NSRect(x: -32, y: 28, width: 464, height: 168))
        let offset = NSRect(x: 1440, y: 0, width: 1512, height: 982)
        #expect(NoTargetModalController.morphEndFrameAtSlot(visible: offset, position: .top)
            == NSRect(x: 1964, y: 802, width: 464, height: 168))
        // Pathological height: keep the slot edge, shrink inward.
        let tiny = NSRect(x: 0, y: 0, width: 400, height: 100)
        #expect(NoTargetModalController.morphEndFrameAtSlot(visible: tiny, position: .bottom)
            == NSRect(x: -32, y: 28, width: 464, height: 100))
        #expect(NoTargetModalController.morphEndFrameAtSlot(visible: tiny, position: .top)
            == NSRect(x: -32, y: 0, width: 464, height: 100))
    }

    @Test func contentMaskPathMatchesCard() {
        // Variant-B mask geometry: the path must bound the card exactly
        // (464×168, r22) — the mask clips everything SwiftUI paints to
        // the silhouette, so any drift here re-opens the frame.
        let box = NoTargetModalController.contentMaskPath().boundingBox
        #expect(box == NSRect(
            x: 0, y: 0,
            width: NoTargetModalController.width,
            height: NoTargetModalController.height
        ))
        #expect(NoTargetModalController.cornerRadius == 22)
    }
}
