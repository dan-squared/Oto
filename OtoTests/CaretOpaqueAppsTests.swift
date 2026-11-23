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
        #expect(CaretOpaqueApps.isOpaque("com.googlecode.iterm2"))
        #expect(CaretOpaqueApps.isOpaque("dev.warp.Warp-Stable"))
        #expect(CaretOpaqueApps.isOpaque("org.alacritty"))
        #expect(CaretOpaqueApps.isOpaque("net.kovidgoyal.kitty"))
        #expect(CaretOpaqueApps.isOpaque("com.github.wez.wezterm"))
        #expect(CaretOpaqueApps.isOpaque("dev.zed.Zed"))
        #expect(CaretOpaqueApps.isOpaque("org.gnu.Emacs"))
        #expect(CaretOpaqueApps.isOpaque("com.jetbrains.intellij"))
        #expect(CaretOpaqueApps.isOpaque("com.jetbrains.pycharm"))
        #expect(CaretOpaqueApps.isOpaque("COM.JETBRAINS.WebStorm"))
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
