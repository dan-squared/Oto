//
//  CaretOpaqueAppsTests.swift
//  OtoTests
//
//  Only a known terminal loses the v7 post-paste proof. Nil, empty and
//  near-miss bundle IDs must stay verifiable, or the catcher stops working
//  for every normal app.
//

import Foundation
import Testing
@testable import Oto

struct CaretOpaqueAppsTests {
    @Test func knownTerminalsAreOpaque() {
        #expect(CaretOpaqueApps.isOpaque("com.mitchellh.ghostty"))
        #expect(CaretOpaqueApps.isOpaque("com.apple.Terminal"))
        #expect(CaretOpaqueApps.isOpaque("com.superlogical.rex"))
    }

    @Test func matchingIsNormalized() {
        #expect(CaretOpaqueApps.isOpaque(" COM.MITCHELLH.GHOSTTY "))
        #expect(CaretOpaqueApps.isOpaque("Com.Apple.Terminal\n"))
    }

    @Test func unknownNilAndEmptyStayVerifiable() {
        #expect(!CaretOpaqueApps.isOpaque(nil))
        #expect(!CaretOpaqueApps.isOpaque(""))
        #expect(!CaretOpaqueApps.isOpaque("   "))
        #expect(!CaretOpaqueApps.isOpaque("com.example.App"))
        #expect(!CaretOpaqueApps.isOpaque("com.apple.TextEdit"))
    }

    @Test func helperProcessIsNotTheApp() {
        // Target capture uses the owning app, never a helper; a helper ID
        // must not silently inherit the terminal exemption.
        #expect(!CaretOpaqueApps.isOpaque("com.mitchellh.ghostty.helper"))
        #expect(!CaretOpaqueApps.isOpaque("com.apple.Terminal.SomeService"))
    }
}
