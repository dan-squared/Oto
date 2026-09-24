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
        // Copy button: system gray on dark, solid black on light.
        #expect(CatcherPalette.dark.copyRed == 0.5)
        #expect(CatcherPalette.dark.copyOpacity == 0.35)
        #expect(CatcherPalette.light.copyRed == 0.0)
        #expect(CatcherPalette.light.copyOpacity == 1.0)
    }

    @Test func morphEndFrameAtSlotGrowsInPlace() {        // v6: same x as the pill (both centered), slot-anchored y —
        // top grows down from the pill's top edge, bottom up from its
        // bottom edge. Zero travel, pure vertical growth.
        let roomy = NSRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(NoTargetModalController.morphEndFrameAtSlot(visible: roomy, position: .bottom, height: 168)
            == NSRect(x: 488, y: 28, width: 464, height: 168))
        #expect(NoTargetModalController.morphEndFrameAtSlot(visible: roomy, position: .top, height: 168)
            == NSRect(x: 488, y: 720, width: 464, height: 168))
        #expect(NoTargetModalController.morphEndFrameAtSlot(visible: roomy, position: .bottom, height: 300)
            == NSRect(x: 488, y: 28, width: 464, height: 300))
        #expect(NoTargetModalController.morphEndFrameAtSlot(visible: roomy, position: .top, height: 300)
            == NSRect(x: 488, y: 588, width: 464, height: 300))
        // Narrow screen: floor at full card width (audit F1) — a
        // squeezed frame would amputate Copy; overflow stays visible.
        let narrow = NSRect(x: 0, y: 0, width: 400, height: 500)
        #expect(NoTargetModalController.morphEndFrameAtSlot(visible: narrow, position: .bottom, height: 168)
            == NSRect(x: -32, y: 28, width: 464, height: 168))
        let offset = NSRect(x: 1440, y: 0, width: 1512, height: 982)
        #expect(NoTargetModalController.morphEndFrameAtSlot(visible: offset, position: .top, height: 168)
            == NSRect(x: 1964, y: 802, width: 464, height: 168))
        // Pathological height: keep the slot edge when it fits, clamp
        // into visible when it doesn't (a parked-off-screen card helps no
        // one; X overflow stays explicit per audit F1).
        let tiny = NSRect(x: 0, y: 0, width: 400, height: 100)
        #expect(NoTargetModalController.morphEndFrameAtSlot(visible: tiny, position: .bottom, height: 100)
            == NSRect(x: -32, y: 0, width: 464, height: 100))
        #expect(NoTargetModalController.morphEndFrameAtSlot(visible: tiny, position: .top, height: 100)
            == NSRect(x: -32, y: 0, width: 464, height: 100))
    }

    @Test func contentMaskPathMatchesCard() {
        // Variant-B mask geometry: the path must bound the card exactly
        // (464×168, r22) — the mask clips everything SwiftUI paints to
        // the silhouette, so any drift here re-opens the frame.
        let box = NoTargetModalController.contentMaskPath(
            size: CGSize(
                width: NoTargetModalController.width,
                height: NoTargetModalController.height
            )
        ).boundingBox
        #expect(box == NSRect(
            x: 0, y: 0,
            width: NoTargetModalController.width,
            height: NoTargetModalController.height
        ))
        #expect(NoTargetModalController.contentMaskPath(size: CGSize(width: 464, height: 300)).boundingBox
            == NSRect(x: 0, y: 0, width: 464, height: 300))
        #expect(NoTargetModalController.cornerRadius == 22)
    }

    // MARK: - v8 catchup polish (wrap, grow, cap, Copied-close)

    @Test func displayWordsCapsAtOneHundred() {
        #expect(CatcherText.wordCount("hello brave new world") == 4)
        #expect(CatcherText.isOverLimit("hello") == false)
        let short = "dictate this exactly"
        #expect(CatcherText.displayWords(short) == short)
        let long = Array(repeating: "word", count: 101).joined(separator: " ")
        #expect(CatcherText.isOverLimit(long) == true)
        let shown = CatcherText.displayWords(long)
        #expect(CatcherText.wordCount(shown) == 100)
        #expect(shown.hasSuffix("…"))
        // Data never truncates: the cap is pixels, recovery keeps all.
        #expect(shown != long)
    }

    @Test func layoutHeightGrowsAtFixedWidth() {
        let minH = NoTargetModalController.height
        let small = CatcherLayout.height(for: "hi", cardWidth: 464, minHeight: minH, maxHeight: 900)
        #expect(small == minH)
        let tall = CatcherLayout.height(
            for: Array(repeating: "word", count: 100).joined(separator: " "),
            cardWidth: 464, minHeight: minH, maxHeight: 900
        )
        #expect(tall > minH)
        // Screen clamp: pathological text never overflows tiny displays.
        let huge = String(repeating: "word ", count: 500)
        let clamped = CatcherLayout.height(for: huge, cardWidth: 464, minHeight: minH, maxHeight: 200)
        #expect(clamped == 200)
        // Chrome math is explicit: card padding, text inset, gap, button.
        let chrome: CGFloat = 20 + 18 + 18 + 44 + 20
        #expect(CatcherLayout.chromeHeight == chrome)
        let innerWidth: CGFloat = 464 - 40 - 56
        #expect(CatcherLayout.textWidth(cardWidth: 464) == innerWidth)
    }

    @Test func pillWordsFitPillWidth() {
        // Greedy fill at pill metrics: never overflows, always Copied.
        let shown = CatcherText.pillWords(
            Array(repeating: "word", count: 101).joined(separator: " ")
        )
        #expect(shown.hasSuffix("Copied"))
        let font = NSFont.systemFont(ofSize: 11)
        let width = (shown as NSString).boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: font]
        ).width
        #expect(width <= 76)
        #expect(CatcherText.pillWords("hi") == "hi… Copied")
    }

    @Test func copyShowsCopiedThenCloses() async {
        let board = NSPasteboard(name: NSPasteboard.Name("oto-catcher-\(UUID().uuidString)"))
        let modal = NoTargetModalController()
        modal.show(text: "kept words", displayID: nil, reduceMotion: true)
        modal.copy(pasteboard: board)
        #expect(modal.copied == true)
        #expect(board.string(forType: .string) == "kept words")
        try? await Task.sleep(for: .milliseconds(800))
        #expect(modal.copied == false)
    }

    @Test func recopyInsideWindowRestartsClose() async {
        let board = NSPasteboard(name: NSPasteboard.Name("oto-catcher-\(UUID().uuidString)"))
        let modal = NoTargetModalController()
        modal.show(text: "kept words", displayID: nil, reduceMotion: true)
        modal.copy(pasteboard: board)
        try? await Task.sleep(for: .milliseconds(300))
        modal.copy(pasteboard: board)
        // Stale timer must not clear the live Copied: still lit at +700
        // (close lands at re-copy + 600).
        try? await Task.sleep(for: .milliseconds(400))
        #expect(modal.copied == true)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(modal.copied == false)
    }
}
