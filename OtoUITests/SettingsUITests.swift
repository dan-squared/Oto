//
//  SettingsUITests.swift
//  OtoUITests
//
//  Phase 5: 03 acceptance — Settings opens as ONE native window. The menu
//  path (SettingsLink) is device-matrix covered: XCUITest cannot reach the
//  system menu bar in this environment (probed: systemuiserver vends zero
//  menu bars to the runner), so this test drives the equivalent Cmd-comma
//  path, which targets the same native scene. Menu-bar-only app, so the test
//  starts from zero windows (any window at launch would itself be a failure).
//  No mic, no tap, no dictation.
//

import XCTest

final class SettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSettingsOpensAsOneNativeWindow() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertEqual(app.windows.count, 0, "Oto must launch windowless")

        app.activate()
        app.typeKey(",", modifierFlags: .command)

        let settingsWindow = app.windows.firstMatch
        XCTAssertTrue(
            settingsWindow.waitForExistence(timeout: 10),
            "Exactly one Settings window must open"
        )
        XCTAssertEqual(app.windows.count, 1, "Only one Settings window may exist")

        // Native chrome proof: the standard traffic lights exist (the deleted
        // custom titlebar would fail exactly here), and both toolbar tabs
        // prove the top-bar root (§phase-5-topbar: no sidebar exists at all).
        XCTAssertTrue(settingsWindow.buttons["_XCUI:CloseWindow"].exists)
        XCTAssertTrue(settingsWindow.buttons["General"].exists)
        XCTAssertTrue(settingsWindow.buttons["Dictation"].exists)

        // Dock setting (phase-5-dock-visibility): single source of truth in
        // Settings General. Existence only — never flipped here (flipping
        // would hide the runner's Dock via setActivationPolicy).
        settingsWindow.buttons["General"].click()
        XCTAssertTrue(
            settingsWindow.descendants(matching: .any)["ShowInDockToggle"]
                .waitForExistence(timeout: 10),
            "General must expose the Show-in-Dock toggle"
        )
    }
}
