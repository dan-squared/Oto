//
//  SettingsUIState.swift
//  Oto
//
//  Hoisted Settings UI state: speech readiness, permissions, and mic
//  devices load once and survive rail navigation. Panes previously owned
//  these as @State and reset them to "Checking…" on every visit (the mic
//  flash) while re-firing HAL enumeration and the async speech probe on
//  every open (the lag). Refresh policy: ensureLoaded() once per window
//  open; refreshPermissions() on every pane appear (synchronous, keeps
//  the grant-in-System-Settings flow live with no flash).
//

import ApplicationServices
import Foundation
import Speech
import SwiftUI

@Observable @MainActor
final class SettingsUIState {
    // Speech (moved verbatim from DictationPane).
    var readinessText = "Checking…"
    var languageText = "—"
    var prepareFeedback: String?
    var isPreparing = false
    // Permissions (moved verbatim from the panes).
    var micText = "Checking…"
    var axTrusted = false
    var speechText = "Checking…"
    // Mic devices (moved verbatim from DictationPane).
    var inputDevices: [AudioInputDevice] = []
    var defaultInputUID: String?
    // Sidebar column visibility (owned here so the split view, the
    // View-menu commands and the reopen control share one source; default
    // all-visible every launch). The type is NavigationSplitViewVisibility —
    // there is no NavigationSplitViewColumnVisibility in MacOSX27.0.sdk
    // (swiftinterface:27541) — and it is NOT an OptionSet, so membership is
    // derived in `sidebarVisible` below, never with `contains`.
    var columnVisibility: NavigationSplitViewVisibility = .all

    private let preparer: SpeechAssetPreparer
    private let permissions: PermissionsManager
    private var loaded = false

    init(preparer: SpeechAssetPreparer, permissions: PermissionsManager) {
        self.preparer = preparer
        self.permissions = permissions
    }

    /// Full refresh, once: permissions sync + devices + speech async.
    /// Later window opens no-op (values survive); actions refresh after
    /// acting. Never called per navigation — that was the flash.
    func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        refreshPermissions()
        refreshMicrophones()
        Task { await refreshSpeech() }
    }

    func refreshPermissions() {
        switch permissions.microphoneStatus() {
        case .granted:
            micText = "Allowed"
        case .denied:
            micText = "Denied"
        case .notDetermined:
            micText = "Not asked yet"
        }
        axTrusted = AXIsProcessTrusted()
        switch permissions.speechStatus() {
        case .authorized:
            speechText = "Allowed"
        case .denied, .restricted:
            speechText = "Not allowed"
        case .notDetermined:
            speechText = "Not asked yet"
        @unknown default:
            speechText = "Unknown"
        }
    }

    func refreshMicrophones() {
        inputDevices = MicrophoneSelector.inputDevices()
        defaultInputUID = MicrophoneSelector.defaultInputUID()
    }

    func refreshSpeech() async {
        let report = await preparer.status()
        if let tag = report.resolved?.identifier(.bcp47) {
            let systemTag = Locale.current.identifier(.bcp47)
            languageText = tag == systemTag
                ? tag
                : "\(systemTag) → engine uses \(tag)"
        } else {
            languageText = Locale.current.identifier(.bcp47)
        }
        readinessText = report.readiness.errorDescription ?? "Ready"
    }

    func runPrepare() async {
        isPreparing = true
        prepareFeedback = "Preparing…"
        prepareFeedback = await preparer.prepareDefault()
        isPreparing = false
        await refreshSpeech()
    }

    /// Just-in-time mic grant for the Allow buttons (moved from panes).
    /// Asks only on user gesture — never speculatively.
    func ensureMicrophoneGrant() async -> Bool {
        await permissions.ensureMicrophone()
    }

    /// Apple's blessed prompt: opens System Settings at the Accessibility
    /// page itself when untrusted, no-ops when trusted. Verified in the
    /// macOS 27 headers (10.9+); no raw Settings URLs.
    func requestAccessibilityPrompt() {
        _ = AXIsProcessTrustedWithOptions([
            PermissionsManager.axPromptKey: true,
        ] as CFDictionary)
    }

    /// Show/hide the sidebar column, animated in one place so the column
    /// and the detail reflow move together (an unanimated mutation reads as
    /// a snap). Idempotent: a repeat call does not re-animate.
    func setSidebar(_ visible: Bool) {
        let next: NavigationSplitViewVisibility = visible ? .all : .detailOnly
        guard next != columnVisibility else { return }
        withAnimation(OtoMotion.settle) { columnVisibility = next }
    }

    // MARK: - Derived (pure over stored strings — unit-tested)

    var micAllowed: Bool { micText == "Allowed" }

    /// True while the sidebar column is on screen. Pure over the stored
    /// visibility, so it is unit-tested; membership is equality because
    /// NavigationSplitViewVisibility is not an OptionSet.
    var sidebarVisible: Bool { columnVisibility != .detailOnly }

    var micTone: OtoStatus.Tone {
        micAllowed ? .ok : (micText == "Not asked yet" ? .idle : .warn)
    }

    var micDeniedGuidance: String? {
        micAllowed || micText == "Not asked yet"
            ? nil
            : "Allow it in System Settings → Privacy & Security → Microphone."
    }

    var speechTone: OtoStatus.Tone {
        switch speechText {
        case "Allowed": .ok
        case "Not asked yet", "Checking…", "Unknown": .idle
        default: .warn
        }
    }

    var speechReady: Bool { readinessText == "Ready" }

    var currentInputName: String {
        inputDevices.first(where: { $0.uid == defaultInputUID })?.name ?? "System default"
    }
}
