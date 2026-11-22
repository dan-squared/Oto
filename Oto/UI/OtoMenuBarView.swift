//
//  OtoMenuBarView.swift
//  Oto
//
//  Created by Daniel Girma on 19/09/2026.
//

import AppKit
import SwiftUI

/// Production menu: entry points only. Recovery (copy / retry) belongs to
/// the catcher and auto-copy — duplicating it here meant a second home for
/// the same decision, and the Escape / status rows described internals the
/// person cannot act on. Live session state belongs to the Flow Bar.
///
/// One exception: a failed last session is a durable, readable status. The
/// pill notice fades after a few seconds; the menu keeps the failure text
/// and one row to act on it until the next session starts.
struct OtoMenuBarView: View {
    let coordinator: DictationCoordinator
    let onboarding: OnboardingWindowController
    let settings: OtoSettingsWindowController
    let updater: AppUpdater

    @State private var lastSummary = ""

    var body: some View {
        // Slice B undo: REMOVED (2026-10-06) — the OS owns undo; History's
        // Undo AI edit + Copy is the single raw-recovery path.
        if lastSummary.hasPrefix("failed:") {
            Text(lastSummary)
            Button("Open Settings…") {
                settings.show()
            }
            Divider()
        }
        // Onboarding stays while the first-run flow is being refined: it is
        // the only way to reach the walkthrough on demand. Until the walk is
        // finished the entry says what it does — continue, not start over.
        Button(OnboardingStore.shouldShow() ? "Continue setup…" : "Show onboarding…") {
            onboarding.show()
        }
        // The button itself changes label (Checking… / Up to date / error);
        // there is intentionally no second row under it.
        Button(updater.buttonTitle) {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
        Button("Settings…") {
            settings.show()
        }
        Divider()
        Button("Quit Oto") {
            NSApplication.shared.terminate(nil)
        }
        .task {
            await refreshStatus()
        }
        // Opening the menu activates the app; that is the natural moment to
        // re-read the coordinator's one-shot summary (no polling timer).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await self.refreshStatus() }
        }
    }

    @MainActor
    private func refreshStatus() async {
        lastSummary = await coordinator.lastSessionSummary()
    }
}
