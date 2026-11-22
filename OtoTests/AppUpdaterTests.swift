//
//  AppUpdaterTests.swift
//  OtoTests
//
//  The Check for Updates control must never be silent. These pin the status
//  text/busy transitions the menu and About pane render, without a live feed.
//

import Testing
@testable import Oto

@MainActor
struct AppUpdaterTests {
    @Test func statusReportsEveryStage() async {
        let status = UpdaterStatus()
        let delegate = UpdaterDelegate(status: status)

        delegate.markDownloading()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(status.text == "Downloading update…")
        #expect(status.isBusy)

        delegate.markUpToDate()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(status.text == "Up to date")
        #expect(!status.isBusy)

        delegate.markFound("1.1")
        try? await Task.sleep(for: .milliseconds(20))
        #expect(status.text == "Update 1.1 found")

        delegate.markDownloaded()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(status.text == "Update downloaded — ready to install")

        delegate.markDownloadFailed("offline")
        try? await Task.sleep(for: .milliseconds(20))
        #expect(status.text == "Download failed: offline")

        delegate.markCheckFailed("bad feed")
        try? await Task.sleep(for: .milliseconds(20))
        #expect(status.text == "Update check failed: bad feed")
    }

    @Test func finishingACheckSaysUpToDateOrNamesTheError() async {
        let status = UpdaterStatus()
        let delegate = UpdaterDelegate(status: status)
        status.set("Checking for Updates…", busy: true)

        delegate.finishCheck(errorMessage: nil)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(status.text == "Up to date")
        #expect(!status.isBusy)

        status.set("Checking for Updates…", busy: true)
        delegate.finishCheck(errorMessage: "timed out")
        try? await Task.sleep(for: .milliseconds(20))
        #expect(status.text == "Update check failed: timed out")
        #expect(!status.isBusy)
    }

    @Test func resultLabelRevertsToActionAfterItsDwell() async {
        let status = UpdaterStatus()
        let delegate = UpdaterDelegate(status: status)
        delegate.markUpToDate()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(status.showingResult)
        try? await Task.sleep(for: .seconds(2.7))
        #expect(!status.showingResult)
        #expect(status.text == "Up to date")
    }

    @Test func buttonItselfCarriesTheState() {
        #expect(AppUpdater.buttonTitle(
            text: "Checking for Updates…", isBusy: true, showingResult: false
        ) == "Checking for Updates…")
        #expect(AppUpdater.buttonTitle(
            text: "Up to date", isBusy: false, showingResult: true
        ) == "Up to date")
        #expect(AppUpdater.buttonTitle(
            text: UpdaterStatus.idleText, isBusy: false, showingResult: false
        ) == "Check for Updates…")
        #expect(AppUpdater.buttonTitle(
            text: "Update check failed: offline", isBusy: false, showingResult: true
        ) == "Update check failed: offline")
    }

    @Test func disabledUpdaterCannotCheck() {
        let updater = AppUpdater(disabled: true)
        #expect(!updater.canCheckForUpdates)
        #expect(updater.statusText == "Checks for updates automatically")
    }
}
