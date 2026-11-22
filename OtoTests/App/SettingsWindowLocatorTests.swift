//
//  SettingsWindowLocatorTests.swift
//  OtoTests
//
//  The single-open guard. There is no singular `Window` scene in
//  MacOSX27.0.sdk and `openWindow(id:)` cannot focus an existing window, so
//  "is this the Settings window?" is a hand-written predicate — and a
//  hand-written predicate is exactly what must be pinned. Synthetic
//  NSWindows, no scene and no run loop: the unit bundle is app-hosted, so
//  AppKit is live.
//

import AppKit
import Testing
@testable import Oto

@MainActor
struct SettingsWindowLocatorTests {
    private static let standard: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]

    private func makeWindow(
        title: String,
        styleMask: NSWindow.StyleMask = SettingsWindowLocatorTests.standard
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = title
        return window
    }

    @Test func matchesTheSettingsWindow() {
        let window = makeWindow(title: SettingsWindowLocator.windowTitle)
        #expect(SettingsWindowLocator.isSettings(window))
    }

    @Test func rejectsOtherTitledWindows() {
        // The onboarding window is AppKit-hosted and titled.
        #expect(SettingsWindowLocator.isSettings(makeWindow(title: "Welcome to Oto")) == false)
        // An untitled titled window is not ours either.
        #expect(SettingsWindowLocator.isSettings(makeWindow(title: "")) == false)
    }

    @Test func rejectsPanelsAndUtilityWindows() {
        // Every Oto panel (catcher, permission modal) is an NSPanel, and a
        // utility window is never a document-style Settings window.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = SettingsWindowLocator.windowTitle
        #expect(SettingsWindowLocator.isSettings(panel) == false)

        // A utility window can only be a PANEL: AppKit silently drops
        // `.utilityWindow` from a plain NSWindow's mask (measured — the
        // titled/closable bits survive, the utility bit does not), so the
        // utility case is only reachable, and only needs rejecting, as a
        // panel.
        let utility = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        utility.title = SettingsWindowLocator.windowTitle
        #expect(utility.styleMask.contains(.utilityWindow))
        #expect(SettingsWindowLocator.isSettings(utility) == false)
    }

    @Test func picksTheSettingsWindowOutOfTheAppsWindows() {
        let windows = [
            makeWindow(title: ""),                                  // some other scene
            makeWindow(title: "Welcome to Oto"),                     // onboarding
            makeWindow(title: SettingsWindowLocator.windowTitle),   // ours
            makeWindow(title: SettingsWindowLocator.windowTitle),   // a duplicate, ignored
        ]
        let found = SettingsWindowLocator.settingsWindow(in: windows)
        #expect(found === windows[2])
        #expect(SettingsWindowLocator.settingsWindow(in: Array(windows.prefix(2))) == nil)
    }
}
