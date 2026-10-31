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
import SwiftUI

/// The one remedy a permission status has. Kept as a type so the row's single
/// control and its label can never disagree about whether there is an action.
enum PermissionAction: Equatable {
    /// Nothing left to do: render the readout.
    case none
    /// An in-product system prompt exists: ask.
    case allow
    /// Only System Settings can undo it: open the pane.
    case openSettings
}

@Observable @MainActor
final class SettingsUIState {
    // Speech readiness display (locale tags stay plain strings — display
    // only, no logic).
    var languageText = "—"
    var prepareFeedback: String?
    var isPreparing = false
    // Permissions (typed stored state; nil = not yet read, the honest
    // "Checking…"). Display strings are computed below in exactly one
    // place, so producers and consumers can never disagree on a literal
    // again — typo'd states are unrepresentable, not silent.
    var micPermission: PermissionsManager.MicrophoneStatus?
    var axTrusted = false
    var speechReadiness: SpeechReadiness?
    // Mic devices (moved verbatim from DictationPane).
    var inputDevices: [AudioInputDevice] = []
    var defaultInputUID: String?
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
        micPermission = permissions.microphoneStatus()
        axTrusted = AXIsProcessTrusted()
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
        speechReadiness = report.readiness
    }

    func runPrepare() async {
        isPreparing = true
        prepareFeedback = "Preparing…"
        prepareFeedback = await preparer.prepareDefault()
        // P3: preparing a language changes installed state — the press-path
        // snapshot must requery next time (success or failure; a failed
        // prepare changes nothing, and requerying once is harmless).
        LocaleSnapshotCache.shared.invalidate()
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

    // MARK: - Derived (pure over typed state — unit-tested)

    /// Display strings, derived in exactly one place with byte-identical
    /// copy. Views read these (unchanged call sites); logic below reads
    /// the typed state. Nil stored state renders the honest pendings.
    var micText: String {
        switch micPermission {
        case .granted: "Allowed"
        case .denied: "Denied"
        case .notDetermined: "Not asked yet"
        case nil: "Checking…"
        }
    }

    /// The pill's label where an action exists: the state where there is
    /// nothing to do, one word that invites the press where there is. A pill
    /// that says "Denied" does not look like a way out; "Allow" does, and the
    /// press still does the right thing per state (prompt or System Settings).
    var micActionText: String {
        switch micAction {
        case .none: micText
        case .allow, .openSettings: "Allow"
        }
    }

    /// Accessibility has no in-product prompt path from this row: pressing
    /// routes to the Privacy pane. One word, same as the mic.
    var axActionText: String { "Allow" }

    var readinessText: String {
        guard let readiness = speechReadiness else { return "Checking…" }
        return readiness.errorDescription ?? "Ready"
    }

    var micAllowed: Bool { micPermission == .granted }

    /// What the mic row's single control can do. `.none` still renders the
    /// readout ("Allowed", or "Checking…" before the first read) — a button
    /// never appears before the state is known.
    var micAction: PermissionAction {
        switch micPermission {
        case .granted: .none
        case .notDetermined: .allow
        case .denied: .openSettings
        case nil: .none
        }
    }

    /// The colour behind `micActionText`: green allowed, amber needs acting,
    /// grey before the first read.
    var micTone: OtoStatus.Tone {
        micAllowed ? .ok : (micPermission == .notDetermined ? .idle : .warn)
    }

    var micDeniedGuidance: String? {
        micAllowed || micPermission == .notDetermined
            ? nil
            : "Allow it in System Settings → Privacy & Security → Microphone."
    }

    /// Typed end-to-end: no dependency on Apple wording (the old compare
    /// read `errorDescription ?? "Ready"` output as a string).
    var speechReady: Bool { speechReadiness == .ready }

    var currentInputName: String {
        inputDevices.first(where: { $0.uid == defaultInputUID })?.name ?? "System default"
    }
}
