//
//  AppUpdater.swift
//  Oto
//
//  The one Sparkle updater instance. Built by OtoApp, shared by the menu and
//  the About pane so "Check for Updates…" has one truth. Sparkle is never
//  started in tests, UI tests, or screenshot probes: those must not touch the
//  network or pop a permission dialog.
//
//  The button is never silent: every lifecycle callback publishes a short
//  status string ("Checking…", "Up to date", "Downloading…", "Update found",
//  or the error) that both surfaces render. The helper methods are internal
//  so the status machine is pinned by unit tests without a live feed.
//

import Foundation
import Observation
import Sparkle

/// Observable state, separate from the controller because Sparkle requires
/// its delegate at controller-init time.
@MainActor
@Observable
final class UpdaterStatus {
    nonisolated static let idleText = "Checks for updates automatically"

    private(set) var text = idleText
    private(set) var isBusy = false
    /// A finished result is shown briefly in the button itself, then the
    /// button returns to its action label. No second row anywhere.
    private(set) var showingResult = false
    private var generation = 0

    func set(_ text: String, busy: Bool) {
        self.text = text
        self.isBusy = busy
        generation += 1
        let current = generation
        showingResult = !busy && text != Self.idleText
        guard showingResult else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard current == self.generation, !self.isBusy else { return }
            self.showingResult = false
        }
    }
}

/// Sparkle calls the delegate from its own queue; mark methods `nonisolated`
/// and hop to the main actor before touching observable state.
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate, Sendable {
    let status: UpdaterStatus

    nonisolated init(status: UpdaterStatus) {
        self.status = status
    }

    nonisolated private func report(_ text: String, busy: Bool = false) {
        Task { @MainActor in status.set(text, busy: busy) }
    }

    // MARK: Testable status transitions

    nonisolated func markUpToDate() { report("Up to date") }
    nonisolated func markFound(_ version: String) { report("Update \(version) found") }
    nonisolated func markDownloading() { report("Downloading update…", busy: true) }
    nonisolated func markDownloaded() { report("Update downloaded — ready to install") }
    nonisolated func markDownloadFailed(_ reason: String) { report("Download failed: \(reason)") }
    nonisolated func markCheckFailed(_ reason: String) { report("Update check failed: \(reason)") }

    nonisolated func finishCheck(errorMessage: String?) {
        Task { @MainActor in
            if status.text.hasPrefix("Checking") {
                status.set(
                    errorMessage.map { "Update check failed: \($0)" } ?? "Up to date",
                    busy: false
                )
            } else {
                status.set(status.text, busy: false)
            }
        }
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) { markUpToDate() }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        markFound(item.displayVersionString)
    }

    nonisolated func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        markDownloading()
    }

    nonisolated func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        markDownloaded()
    }

    nonisolated func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        markDownloadFailed(error.localizedDescription)
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        markCheckFailed(error.localizedDescription)
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        finishCheck(errorMessage: error?.localizedDescription)
    }
}

@MainActor
final class AppUpdater: NSObject {
    let status = UpdaterStatus()
    private let updaterDelegate: UpdaterDelegate
    private let controller: SPUStandardUpdaterController
    private let disabled: Bool

    init(
        disabled: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["OTO_SHOT"] != nil
            || ProcessInfo.processInfo.environment["OTO_SETTINGS_SHOT"] != nil
            || ProcessInfo.processInfo.arguments.contains("-OtoUITest")
    ) {
        self.disabled = disabled
        let delegate = UpdaterDelegate(status: self.status)
        self.updaterDelegate = delegate
        self.controller = SPUStandardUpdaterController(
            startingUpdater: !disabled,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        super.init()
        if disabled {
            self.controller.updater.automaticallyChecksForUpdates = false
        }
    }

    /// The button itself carries the state: "Checking for Updates…" while
    /// busy, a brief result ("Up to date", "Downloading update…"), then the
    /// action label again. There is deliberately no status row beside it.
    var buttonTitle: String {
        Self.buttonTitle(
            text: status.text,
            isBusy: status.isBusy,
            showingResult: status.showingResult
        )
    }

    nonisolated static func buttonTitle(text: String, isBusy: Bool, showingResult: Bool) -> String {
        if isBusy { return text }
        if showingResult, text != UpdaterStatus.idleText { return text }
        return "Check for Updates…"
    }

    var statusText: String { status.text }
    var isBusy: Bool { status.isBusy }

    var canCheckForUpdates: Bool {
        !disabled && controller.updater.canCheckForUpdates && !isBusy
    }

    func checkForUpdates() {
        guard !disabled, controller.updater.canCheckForUpdates, !isBusy else { return }
        status.set("Checking for Updates…", busy: true)
        controller.updater.checkForUpdates()
    }
}
