//
//  NoTargetModalTests.swift
//  OtoTests
//
//  Slice 6C1: the kill-switch setting. Default ON (absent key teaches the
//  flow); explicit OFF sticks. The Settings toggle literal is pinned to the
//  helper key — rename one and this fails before users drift.
//

import Foundation
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
}
