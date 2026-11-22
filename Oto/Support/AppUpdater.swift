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

/// Sparkle calls the delegate from its own queue; hop to the main actor before
/// touching observable state.
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    let status: UpdaterStatus

    init(status: UpdaterStatus) {
        self.status = status
    }

    private func report(_ text: String, busy: Bool = false) {
        Task { @MainActor in status.set(text, busy: busy) }
    }

    // MARK: Testable status transitions

    func markUpToDate() { report("Up to date") }
    func markFound(_ version: String) { report("Update \(version) found") }
    func markDownloading() { report("Downloading update…", busy: true) }
    func markDownloaded() { report("Update downloaded — ready to install") }
    func markDownloadFailed(_ reason: String) { report("Download failed: \(reason)") }
    func markCheckFailed(_ reason: String) { report("Update check failed: \(reason)") }

    func finishCheck(errorMessage: String?) {
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

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) { markUpToDate() }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        markFound(item.displayVersionString)
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        markDownloading()
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        markDownloaded()
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        markDownloadFailed(error.localizedDescription)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        markCheckFailed(error.localizedDescription)
    }

    func updater(
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
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private let disabled: Bool

    init(
        disabled: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["OTO_SHOT"] != nil
            || ProcessInfo.processInfo.arguments.contains("-OtoUITest")
    ) {
        self.disabled = disabled
        self.controller = SPUStandardUpdaterController(
            startingUpdater: !disabled,
            updaterDelegate: UpdaterDelegate(status: self.status),
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
