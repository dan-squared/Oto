//
//  SettingsWindowDresserTests.swift
//  OtoTests
//
//  Dressing gate: the Settings window gets dressed, onboarding and
//  untitled panels never do. Property sets on unshown NSWindows are
//  headless-safe; pixels belong to the device matrix.
//

import AppKit
import Testing
@testable import Oto

@MainActor
struct SettingsWindowDresserTests {
    private func makeWindow(title: String, style: NSWindow.StyleMask = [.titled, .closable]) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: style, backing: .buffered, defer: false
        )
        window.title = title
        return window
    }

    @Test func onboardingWindowIsNeverDressed() {
        #expect(SettingsWindowDresser.shouldDress(makeWindow(title: SettingsWindowDresser.onboardingTitle)) == false)
    }

    @Test func untitledPanelIsNeverDressed() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        #expect(SettingsWindowDresser.shouldDress(window) == false)
    }

    @Test func titledWindowIsDressed() {
        let window = makeWindow(title: "Oto Settings")
        #expect(SettingsWindowDresser.shouldDress(window) == true)
        SettingsWindowDresser.dress(window)
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent == true)
        #expect(window.title == "Oto Settings")
    }
}
