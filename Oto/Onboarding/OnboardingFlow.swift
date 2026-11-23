//
//  OnboardingFlow.swift
//  Oto
//
//  Everything the chapters do. Ported from Firstlight's flow, but with Oto's
//  content and Oto's real services: the last chapter is where dictation
//  becomes real, and the system's own Accessibility and microphone dialogs do
//  the asking. The flow owns the step machine's moves so the views stay
//  declarative.
//

import AppKit
import SwiftUI

/// What is still missing before the last chapter can finish. The order is
/// the product order: the global key needs Accessibility, then dictation
/// needs the microphone.
enum OnboardingPermissionBlocker: Equatable, Sendable {
    case accessibility
    case microphone
}

@Observable @MainActor
final class OnboardingFlow {
    let dispatch: ShortcutDispatch
    let uiState: SettingsUIState
    let onFinish: () -> Void

    // Hold-key label state: mirrors the live config, so the hands-free chapter
    // can name the key the person actually taps.
    private(set) var holdKind: ShortcutTrigger.Kind
    /// Observed so the Continue pill relabels the moment a grant lands;
    /// the typed state still lives in `uiState` (one source of truth).
    private(set) var permissionBlocker: OnboardingPermissionBlocker?

    /// One-shot flags per walk: returning to the last chapter never re-prompts.
    private var speechPrepared = false
    private var axPrompted = false
    private var micPrompted = false
    private var preparationTask: Task<Void, Never>?
    private var micPromptTask: Task<Void, Never>?

    /// Pure gate table, pinned by test. `nil` mic is "Checking…" — never a
    /// grant, so Finish cannot complete before the first permission read.
    nonisolated static func blocker(
        axTrusted: Bool,
        mic: PermissionsManager.MicrophoneStatus?
    ) -> OnboardingPermissionBlocker? {
        if !axTrusted { return .accessibility }
        if mic != .granted { return .microphone }
        return nil
    }

    /// Re-read the shared typed state into the observed gate. Called on
    /// load, on every grant attempt, and when the window comes back from
    /// System Settings.
    func refreshPermissionGate() {
        // UI tests and capture probes cannot grant TCC; they keep the plain
        // Finish pill so the walkthrough can be driven end to end.
        self.permissionBlocker = Self.suppressesNativePrompts
            ? nil
            : Self.blocker(
                axTrusted: self.uiState.axTrusted,
                mic: self.uiState.micPermission
            )
    }

    init(dispatch: ShortcutDispatch, uiState: SettingsUIState, onFinish: @escaping () -> Void) {
        self.dispatch = dispatch
        self.uiState = uiState
        self.onFinish = onFinish
        self.holdKind = dispatch.configuration.hold.kind
    }

    var stage: OnboardingStage { .shared }

    /// The last chapter. What finishing looks like after it is the window
    /// controller's business.
    var isLastChapter: Bool { self.stage.step == OnboardingStage.Step.chapters.last }

    var canGoBack: Bool {
        self.stage.step != .welcome && self.stage.step != .handoff
    }

    /// The one pill's label. The last chapter finishes; everything before it
    /// continues.
    var buttonTitle: String {
        switch self.stage.step {
        case .welcome, .how, .catcher, .intelligence, .dictionary: "Continue"
        case .handsFree, .handoff:
            switch self.permissionBlocker {
            case .accessibility: "Enable Accessibility"
            case .microphone: "Allow Microphone"
            case nil: "Finish"
            }
        }
    }

    /// One chapter, one move: Continue goes to the next.
    func next() {
        switch self.stage.step {
        case .welcome:
            self.stage.advance(to: .how)
        case .how:
            self.stage.advance(to: .catcher)
        case .catcher:
            self.stage.advance(to: .intelligence)
        case .intelligence:
            self.stage.advance(to: .dictionary)
        case .dictionary:
            self.stage.advance(to: .handsFree)
        case .handsFree:
            // A missing grant is not a reason to end the walk: the pill
            // becomes the next ask, using Apple's own prompt/settings path.
            switch self.permissionBlocker {
            case .accessibility:
                self.uiState.requestAccessibilityPrompt()
                self.uiState.refreshPermissions()
                self.refreshPermissionGate()
            case .microphone:
                self.uiState.refreshPermissions()
                if self.uiState.micPermission == .denied {
                    SettingsLinkOpener.open(MicSettingsLink.candidates())
                    self.refreshPermissionGate()
                } else {
                    self.micPromptTask?.cancel()
                    self.micPromptTask = Task {
                        _ = await self.uiState.ensureMicrophoneGrant()
                        guard !Task.isCancelled else { return }
                        self.uiState.refreshPermissions()
                        self.refreshPermissionGate()
                        self.dispatch.refreshAvailability()
                    }
                }
            case nil:
                self.finish()
            }
        case .handoff:
            break
        }
    }

    func back() {
        self.cancelPendingPrompts()
        switch self.stage.step {
        case .welcome:
            break
        case .how:
            self.stage.advance(to: .welcome)
        case .catcher:
            self.stage.advance(to: .how)
        case .intelligence:
            self.stage.advance(to: .catcher)
        case .dictionary:
            self.stage.advance(to: .intelligence)
        case .handsFree:
            self.stage.advance(to: .dictionary)
        case .handoff:
            self.stage.advance(to: .handsFree)
        }
    }

    func jump(to step: OnboardingStage.Step) {
        guard step.isChapter else { return }
        if step != OnboardingStage.Step.chapters.last {
            self.cancelPendingPrompts()
        }
        self.stage.advance(to: step)
    }

    /// The window controller owns what finishing looks like (the mark flies
    /// to the menu bar); the flow only says the reader asked for it.
    func finish() {
        self.disarm()
        self.onFinish()
    }

    // MARK: - The hold key

    /// Loads the live state once the window exists: never duplicated, only read.
    func load() {
        self.holdKind = self.dispatch.configuration.hold.kind
        self.uiState.refreshPermissions()
        self.refreshPermissionGate()
        Task { await self.uiState.refreshSpeech() }
    }

    /// Nothing of the flow is listening; dispatch is live again. Called when
    /// the window goes and when the recorder closes.
    func disarm() {
        self.cancelPendingPrompts()
        self.dispatch.setSuspended(false)
    }

    // MARK: - The last chapter

    /// Schedules last-chapter preparation after the step transition spring
    /// settles, cancelling any prior pending arrival or prompt task if the
    /// reader navigated away.
    func scheduleLastChapterPreparation() {
        self.cancelPendingPrompts()
        guard self.isLastChapter else { return }
        self.preparationTask = Task {
            await OnboardingStage.arrival()
            guard !Task.isCancelled, self.isLastChapter else { return }
            self.prepareDictation()
        }
    }

    /// The last chapter is where dictation becomes real, so this is where the
    /// system asks for what it needs — sequentially, in the order the product
    /// needs it: Accessibility first, then the microphone once Accessibility is
    /// granted (never racing a microphone dialog on top of an open AX dialog).
    /// Idempotent per walk — Back → Continue never re-prompts.
    func prepareDictation() {
        guard self.isLastChapter else { return }
        self.uiState.refreshPermissions()
        self.refreshPermissionGate()
        if !self.speechPrepared {
            self.speechPrepared = true
            self.prepareSpeechInBackground()
        }
        guard !Self.suppressesNativePrompts else { return }
        if !self.uiState.axTrusted {
            if !self.axPrompted {
                self.axPrompted = true
                self.uiState.requestAccessibilityPrompt()
            }
            self.dispatch.refreshAvailability()
            return
        }
        // Accessibility is trusted: start the tap now, and only prompt the
        // microphone if undetermined (never racing an open AX modal).
        self.dispatch.refreshAvailability()
        guard !self.micPrompted, self.uiState.micPermission == .notDetermined else { return }
        self.micPrompted = true
        self.micPromptTask?.cancel()
        self.micPromptTask = Task {
            guard !Task.isCancelled, self.isLastChapter else { return }
            _ = await self.uiState.ensureMicrophoneGrant()
            guard !Task.isCancelled else { return }
            self.uiState.refreshPermissions()
            self.refreshPermissionGate()
            self.dispatch.refreshAvailability()
        }
    }

    private func cancelPendingPrompts() {
        self.preparationTask?.cancel()
        self.preparationTask = nil
        self.micPromptTask?.cancel()
        self.micPromptTask = nil
    }

    /// Screenshot probes, unit tests and the UI test must never hang behind a
    /// TCC dialog. `XCTestConfigurationFilePath` stays active for unit tests;
    /// `OTO_SHOT` and `-OtoUITest` are DEBUG-only so Release builds can never
    /// bypass permission gates via environment or launch flags.
    private static var suppressesNativePrompts: Bool {
        let info = ProcessInfo.processInfo
        if info.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        #if DEBUG
        return info.environment["OTO_SHOT"] != nil
            || info.arguments.contains("-OtoUITest")
        #else
        return false
        #endif
    }

    /// There is no speech chapter any more, so a fresh Mac can reach the last
    /// chapter before the on-device model exists. The last chapter is the
    /// point where the flow knows the reader is about to dictate, so the
    /// download starts there — silently, no UI, no chapter. `runPrepare()` is
    /// idempotent and a no-op once the language is ready.
    func prepareSpeechInBackground() {
        guard !self.uiState.speechReady, !self.uiState.isPreparing else { return }
        Task { await self.uiState.runPrepare() }
    }
}
