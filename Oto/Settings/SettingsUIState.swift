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
    var prepareProgress: Double?
    var selectedLocaleIdentifier: String? = SpeechLocalePreference.selectedIdentifier()
    var supportedLocales: [Locale] = []
    var installedLocales: [Locale] = []
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
    typealias PrepareHandler = @Sendable (@escaping @Sendable (Double?) -> Void) async -> PrepareOutcome
    typealias NetworkConditionProvider = @Sendable () async -> NetworkPathCondition

    private let preparer: SpeechAssetPreparer
    private let permissions: PermissionsManager
    private let prepareHandler: PrepareHandler
    private let networkConditionProvider: NetworkConditionProvider
    private let stallHintDelayNanoseconds: UInt64
    private var speechRefreshTask: Task<Void, Never>?
    private var speechRefreshGeneration = 0
    private var prepareTask: Task<Void, Never>?
    private var prepareStallTask: Task<Void, Never>?
    private var prepareGeneration = 0
    private var prepareContinuation: CheckedContinuation<Void, Never>?

    init(
        preparer: SpeechAssetPreparer,
        permissions: PermissionsManager,
        prepareHandler: PrepareHandler? = nil,
        networkConditionProvider: NetworkConditionProvider? = nil,
        stallHintDelayNanoseconds: UInt64 = 15_000_000_000
    ) {
        self.preparer = preparer
        self.permissions = permissions
        self.prepareHandler = prepareHandler ?? { onProgress in
            await preparer.prepareDefaultWithOutcome(onProgress: onProgress)
        }
        self.networkConditionProvider = networkConditionProvider ?? {
            await preparer.currentNetworkCondition()
        }
        self.stallHintDelayNanoseconds = stallHintDelayNanoseconds
    }

    /// Refreshes permissions, microphones, and speech readiness without
    /// resetting existing values to `nil` (so revisiting never flashes
    /// "Checking…" while reopened/activated windows stay live).
    func ensureLoaded() {
        refreshPermissions()
        refreshMicrophones()
        refreshSpeechInBackground()
    }

    func refreshSpeechInBackground() {
        guard speechRefreshTask == nil else { return }
        startSpeechRefreshTask()
    }

    func refreshPermissions() {
        micPermission = permissions.microphoneStatus()
        axTrusted = AXIsProcessTrusted()
    }

    func refreshMicrophones() {
        inputDevices = MicrophoneSelector.inputDevices()
        defaultInputUID = MicrophoneSelector.defaultInputUID()
    }

    func selectLocale(_ identifier: String?) {
        guard !isPreparing else { return }
        let previous = selectedLocaleIdentifier
        SpeechLocalePreference.setSelectedIdentifier(identifier)
        selectedLocaleIdentifier = SpeechLocalePreference.selectedIdentifier()
        prepareFeedback = nil
        if selectedLocaleIdentifier != previous {
            speechReadiness = nil
        }
        restartSpeechRefreshInBackground()
    }

    func refreshSpeech() async {
        let task = restartSpeechRefreshTask()
        await task.value
    }

    private func restartSpeechRefreshInBackground() {
        _ = restartSpeechRefreshTask()
    }

    @discardableResult
    private func restartSpeechRefreshTask() -> Task<Void, Never> {
        speechRefreshTask?.cancel()
        speechRefreshTask = nil
        return startSpeechRefreshTask()
    }

    @discardableResult
    private func startSpeechRefreshTask() -> Task<Void, Never> {
        speechRefreshGeneration += 1
        let generation = speechRefreshGeneration
        let task = Task {
            defer {
                if self.speechRefreshGeneration == generation {
                    self.speechRefreshTask = nil
                }
            }
            await self.performSpeechRefresh(generation: generation)
        }
        speechRefreshTask = task
        return task
    }

    private func performSpeechRefresh(generation: Int) async {
        selectedLocaleIdentifier = SpeechLocalePreference.selectedIdentifier()
        let available = await preparer.availableLocales()
        guard !Task.isCancelled, generation == speechRefreshGeneration else { return }

        supportedLocales = SpeechLocalePreference.dedupedSortedLocales(available.supported)
        installedLocales = SpeechLocalePreference.dedupedSortedLocales(available.installed)

        let requested = SpeechLocalePreference.effectiveLocale()
        let report = await preparer.status(locale: requested)
        guard !Task.isCancelled, generation == speechRefreshGeneration else { return }

        let names = SpeechLocalePreference.displayNames(for: supportedLocales)
        if let resolved = report.resolved {
            let resolvedTag = resolved.identifier(.bcp47)
            languageText = names[resolvedTag] ?? SpeechLocalePreference.displayName(for: resolved)
        } else {
            languageText = SpeechLocalePreference.displayName(for: requested)
        }
        speechReadiness = report.readiness
    }

    func runPrepare() async {
        guard !isPreparing else { return }
        prepareGeneration += 1
        let generation = prepareGeneration
        let targetIdentifier = selectedLocaleIdentifier
        isPreparing = true
        prepareProgress = nil
        prepareFeedback = nil

        let constrainedNote = "Low Data Mode is on — macOS may pause speech downloads."
        let stallNote = "Waiting on macOS to start the download…"

        let condition = await networkConditionProvider()
        guard generation == prepareGeneration, isPreparing else { return }
        if condition == .constrained {
            prepareFeedback = constrainedNote
        }

        prepareStallTask?.cancel()
        if condition != .constrained && stallHintDelayNanoseconds > 0 {
            let delay = stallHintDelayNanoseconds
            prepareStallTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self,
                      self.prepareGeneration == generation,
                      self.isPreparing,
                      self.prepareProgress == nil,
                      self.prepareFeedback == nil
                else { return }
                self.prepareFeedback = stallNote
            }
        } else {
            prepareStallTask = nil
        }

        let handler = prepareHandler
        let task = Task { [weak self] in
            let outcome = await handler { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.prepareGeneration == generation,
                          self.isPreparing,
                          self.selectedLocaleIdentifier == targetIdentifier
                    else { return }
                    self.prepareProgress = progress
                    if let progress, progress > 0 {
                        self.prepareStallTask?.cancel()
                        self.prepareStallTask = nil
                        if self.prepareFeedback == constrainedNote || self.prepareFeedback == stallNote {
                            self.prepareFeedback = nil
                        }
                    }
                }
            }

            guard let self, self.prepareGeneration == generation else { return }
            self.prepareStallTask?.cancel()
            self.prepareStallTask = nil
            self.prepareTask = nil
            self.prepareProgress = nil
            self.isPreparing = false

            if !Task.isCancelled, self.selectedLocaleIdentifier == targetIdentifier {
                switch outcome {
                case .cancelled:
                    self.prepareFeedback = nil
                case .prepared, .alreadyPrepared, .failed:
                    self.prepareFeedback = outcome.summary
                }
            } else if self.selectedLocaleIdentifier == targetIdentifier {
                self.prepareFeedback = nil
            }

            // P3: preparing a language changes installed state — the press-path
            // snapshot must requery next time (success or failure; a failed
            // prepare changes nothing, and requerying once is harmless).
            LocaleSnapshotCache.shared.invalidate()
            await self.refreshSpeech()
            if self.prepareGeneration == generation {
                self.finishPrepareWaiter()
            }
        }
        prepareTask = task

        await withCheckedContinuation { continuation in
            if prepareGeneration != generation || !isPreparing {
                continuation.resume()
            } else {
                prepareContinuation = continuation
            }
        }
    }

    func cancelPrepare() {
        prepareGeneration += 1
        prepareStallTask?.cancel()
        prepareStallTask = nil
        prepareTask?.cancel()
        prepareTask = nil
        prepareProgress = nil
        prepareFeedback = nil
        isPreparing = false
        finishPrepareWaiter()
    }

    private func finishPrepareWaiter() {
        let continuation = prepareContinuation
        prepareContinuation = nil
        continuation?.resume()
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

    /// The colour behind `micActionText`: green allowed, amber denied,
    /// grey when not yet read (`nil`) or not yet asked.
    var micTone: OtoStatus.Tone {
        switch micPermission {
        case .granted: .ok
        case .notDetermined, nil: .idle
        case .denied: .warn
        }
    }

    var micDeniedGuidance: String? {
        micPermission == .denied
            ? "Allow it in System Settings → Privacy & Security → Microphone."
            : nil
    }

    /// Typed end-to-end: no dependency on Apple wording (the old compare
    /// read `errorDescription ?? "Ready"` output as a string).
    var speechReady: Bool { speechReadiness == .ready }

    var currentInputName: String {
        inputDevices.first(where: { $0.uid == defaultInputUID })?.name ?? "System default"
    }
}
