//
//  DockVisibilityTests.swift
//  OtoTests
//
//  Phase 5 dock setting: the toggle is one scalar + one documented call.
//  These tests pin what the UI depends on — default ON (preserves current
//  behavior on upgrade), the shown→policy mapping (an inversion here would
//  hide the Dock when the toggle says show), and the defaults round-trip.
//  `apply()` itself is NOT unit-tested: it requires a live NSApp and its
//  verdict belongs to the device matrix + UI existence test.
//

import AppKit
import Foundation
import Testing
@testable import Oto

struct DockVisibilityTests {
    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "app.Oto.tests.dock-\(UUID().uuidString)")!
    }

    @Test func defaultIsShownWhenKeyAbsent() {
        #expect(DockVisibility.isShown(defaults: isolatedDefaults()) == true)
    }

    @Test func shownMapsToRegularHiddenMapsToAccessory() {
        #expect(DockVisibility.policy(for: true) == .regular)
        #expect(DockVisibility.policy(for: false) == .accessory)
    }

    @Test func defaultsRoundTrip() {
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: DockVisibility.defaultsKey)
        #expect(DockVisibility.isShown(defaults: defaults) == false)
        defaults.set(true, forKey: DockVisibility.defaultsKey)
        #expect(DockVisibility.isShown(defaults: defaults) == true)
    }
}
