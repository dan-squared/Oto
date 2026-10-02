//
//  SettingsUITests.swift
//  OtoUITests
//
//  Phase 5: 03 acceptance — Settings opens as ONE native window. The menu
//  path (SettingsLink) is device-matrix covered: XCUITest cannot reach the
//  system menu bar in this environment (probed: systemuiserver vends zero
//  menu bars to the runner), so this test drives the equivalent Cmd-comma
//  path, which targets the same native scene. Menu-bar-only app, so the test
//  starts from zero windows — except first-run onboarding ("Welcome to
//  Oto"), which is finished and dismissed here when present (that doubles
//  as onboarding dismissal coverage). Any other window at launch is itself
//  a failure. No mic, no tap, no dictation.
//
//  NOTE: finishing onboarding writes `app.Oto.onboardingVersion` to the
//  real defaults domain on the test machine. The onboarding device matrix
//  starts from the wipe protocol, which clears it — never read this test's
//  pass as proof of first-launch behavior; the matrix owns that.
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

        finishOnboardingIfPresent(app)
        XCTAssertEqual(app.windows.count, 0, "Oto must launch windowless")

        app.activate()
        app.typeKey(",", modifierFlags: .command)

        let settingsWindow = app.windows.firstMatch
        XCTAssertTrue(
            settingsWindow.waitForExistence(timeout: 10),
            "Exactly one Settings window must open"
        )
        XCTAssertEqual(app.windows.count, 1, "Only one Settings window may exist")

        // Native chrome proof: the standard traffic lights exist, and the
        // native sidebar lists all four destinations (labels, not custom
        // buttons — rows are native List cells).
        XCTAssertTrue(settingsWindow.buttons["_XCUI:CloseWindow"].exists)
        for name in ["General", "Dictation", "Dictionary", "Snippets", "History", "Privacy", "Intelligence"] {
            XCTAssertTrue(
                settingsWindow.descendants(matching: .any)[name].exists,
                "Sidebar must list \(name)"
            )
        }

        // Dock setting (phase-5-dock-visibility): single source of truth in
        // Settings General. Existence only — never flipped here (flipping
        // would hide the runner's Dock via setActivationPolicy).
        settingsWindow.descendants(matching: .any)["General"].click()
        XCTAssertTrue(
            settingsWindow.descendants(matching: .any)["ShowInDockToggle"]
                .waitForExistence(timeout: 10),
            "General must expose the Show-in-Dock toggle"
        )

        // Catcher toggle: flip it and flip it back, asserting the value
        // round-trips through the real defaults. Self-restoring by
        // construction — the runner leaves the pref as it found it.
        // (The Dock toggle above stays existence-only: flipping it would
        // hide the runner's Dock.)
        settingsWindow.descendants(matching: .any)["Dictation"].click()
        let catcher = settingsWindow.toggles["CatcherToggle"]
        XCTAssertTrue(
            catcher.waitForExistence(timeout: 10),
            "Dictation must expose the catcher toggle"
        )
        guard let before = catcher.value as? String else {
            XCTFail("Catcher toggle must expose an On/Off value")
            return
        }
        catcher.click()
        let flipped = before == "On" ? "Off" : "On"
        wait(
            for: [expectation(for: NSPredicate(format: "value == %@", flipped), evaluatedWith: catcher, handler: nil)],
            timeout: 5
        )
        XCTAssertEqual(catcher.value as? String, flipped, "Catcher toggle must flip from \(before) to \(flipped)")
        catcher.click()
        wait(
            for: [expectation(for: NSPredicate(format: "value == %@", before), evaluatedWith: catcher, handler: nil)],
            timeout: 5
        )
        XCTAssertEqual(catcher.value as? String, before, "Catcher toggle must restore to \(before)")
    }

    /// First-run onboarding ("Welcome to Oto") is the only window allowed
    /// at launch besides none. When present: prove it stands alone, walk
    /// it to Finish (Continue is never gated, Finish marks seen), and prove
    /// it closes. When absent (already seen): nothing to do.
    @MainActor
    private func finishOnboardingIfPresent(_ app: XCUIApplication) {
        let onboarding = app.windows["Welcome to Oto"]
        guard onboarding.waitForExistence(timeout: 5) else { return }
        XCTAssertEqual(app.windows.count, 1, "First launch shows only onboarding")
        for _ in 0..<4 {
            let cont = onboarding.buttons["Continue"]
            guard cont.waitForExistence(timeout: 5) else { break }
            cont.click()
        }
        let finish = onboarding.buttons["Finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5), "Onboarding must reach Finish")
        finish.click()
        XCTAssertTrue(
            onboarding.waitForNonExistence(timeout: 5),
            "Finish must close onboarding"
        )
    }
}
