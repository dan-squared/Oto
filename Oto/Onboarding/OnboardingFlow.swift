//
//  OnboardingFlow.swift
//  Oto
//
//  Everything the chapters do. Ported from Firstlight's flow, but with Oto's
//  content and Oto's real services: the recorder applies immediately, the
//  permission rows grant for real, and the speech chapter prepares for real.
//  The flow owns the step machine's moves so the views stay declarative.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class OnboardingFlow: ObservableObject {
    let dispatch: ShortcutDispatch
    let uiState: SettingsUIState
    let onFinish: () -> Void

    // Hold-key card state. `holdKind` mirrors the live config after every
    // apply (single source stays in dispatch); messages are local.
    @Published private(set) var holdKind: ShortcutTrigger.Kind
    @Published var isRecording = false
    @Published var holdMessage: String?
    @Published var showSwap = false
    @Published private(set) var fnUsage = SystemFnUsage.unknown

    // Try-it field. Owned here so it survives a chapter transition.
    @Published var trialText = ""

    init(dispatch: ShortcutDispatch, uiState: SettingsUIState, onFinish: @escaping () -> Void) {
        self.dispatch = dispatch
        self.uiState = uiState
        self.onFinish = onFinish
        self.holdKind = dispatch.configuration.hold.kind
    }

    var stage: OnboardingStage { .shared }

    var canGoBack: Bool {
        self.stage.step != .welcome && self.stage.step != .handoff
    }

    /// The one pill's label. The last chapter finishes; everything before it
    /// continues.
    var buttonTitle: String {
        switch self.stage.step {
        case .welcome: "Continue"
        case .how: self.stage.row < OnboardingStage.Step.how.rows - 1 ? "Next" : "Continue"
        case .shortcut, .permissions, .speech: "Continue"
        case .tryIt, .handoff: "Finish"
        }
    }

    /// A chapter that shows walks its rows before it leaves: Continue opens
    /// the next one, so nobody has to find the rows to see them.
    func next() {
        let step = self.stage.step
        switch step {
        case .welcome:
            self.stage.advance(to: .how)
        case .how:
            if self.stage.row < step.rows - 1 {
                self.stage.open(row: self.stage.row + 1)
            } else {
                self.stage.advance(to: .shortcut)
            }
        case .shortcut:
            self.stage.advance(to: .permissions)
        case .permissions:
            self.stage.advance(to: .speech)
        case .speech:
            self.stage.advance(to: .tryIt)
        case .tryIt:
            self.finish()
        case .handoff:
            break
        }
    }

    func back() {
        switch self.stage.step {
        case .welcome:
            break
        case .how:
            self.stage.advance(to: .welcome)
        case .shortcut:
            self.stage.advance(to: .how, row: OnboardingStage.Step.how.rows - 1)
        case .permissions:
            self.stage.advance(to: .shortcut)
        case .speech:
            self.stage.advance(to: .permissions)
        case .tryIt:
            self.stage.advance(to: .speech)
        case .handoff:
            self.stage.advance(to: .tryIt)
        }
    }

    func jump(to step: OnboardingStage.Step) {
        guard step.isChapter else { return }
        self.stage.advance(to: step)
    }

    /// The window controller owns what finishing looks like (the mark flies
    /// to the menu bar); the flow only says the reader asked for it.
    func finish() {
        self.dispatch.setSuspended(false)
        self.isRecording = false
        self.onFinish()
    }

    // MARK: - The hold key

    /// Loads the live state once the window exists: never duplicated, only read.
    func load() {
        self.holdKind = self.dispatch.configuration.hold.kind
        self.fnUsage = SystemFnUsage.read()
        self.uiState.refreshPermissions()
        Task { await self.uiState.refreshSpeech() }
    }

    /// Toggle: clicking an armed field disarms it, so a recording can never
    /// get stuck with no way out.
    func arm() {
        if self.isRecording {
            self.dispatch.setSuspended(false)
            self.isRecording = false
        } else {
            self.dispatch.setSuspended(true)
            self.isRecording = true
        }
    }

    func disarm() {
        self.dispatch.setSuspended(false)
        self.isRecording = false
    }

    /// Immediate-apply save: the gate either saves (or no-ops on equality) or
    /// refuses without saving — `.blocked` always keeps the old binding, so
    /// the message + Swap path can never strand an empty slot.
    func applyHold(kind: ShortcutTrigger.Kind) {
        let result = self.dispatch.updateHoldTrigger(
            ShortcutTrigger(kind: kind, interaction: .holdToTalk)
        )
        self.holdKind = self.dispatch.configuration.hold.kind
        if result == .blocked {
            self.holdMessage = "Same as Hands-free — pick another or swap."
            self.showSwap = true
        } else {
            self.holdMessage = nil
            self.showSwap = false
        }
    }

    func swapHoldAndHandsFree() {
        self.dispatch.swapHoldAndHandsFree()
        self.holdKind = self.dispatch.configuration.hold.kind
        self.holdMessage = nil
        self.showSwap = false
    }

    func captureCombo(modifiers: UInt32, keyCode: UInt32, conflicts: [RecorderConflict]) {
        self.dispatch.setSuspended(false)
        self.isRecording = false
        if ShortcutRecorderConflicts.blocksSaving(conflicts) {
            self.holdMessage = ShortcutRecorderConflicts.describe(conflicts)
            self.showSwap = false
            return
        }
        self.applyHold(kind: .combo(modifiers: modifiers, keyCode: keyCode))
        if self.holdMessage == nil, !conflicts.isEmpty {
            self.holdMessage = ShortcutRecorderConflicts.describe(conflicts)
        }
    }

    func captureModifier(code: UInt16) {
        self.dispatch.setSuspended(false)
        self.isRecording = false
        self.applyHold(kind: .modifierHold(keyCode: code))
    }

    func refuse(_ reason: RecorderInvalidReason) {
        NSSound.beep()
        self.holdMessage = reason.message
        self.showSwap = false
    }

    // MARK: - Permissions and speech

    func grantMicrophone() {
        Task {
            _ = await self.uiState.ensureMicrophoneGrant()
            self.uiState.refreshPermissions()
        }
    }

    func openAccessibility() {
        self.uiState.requestAccessibilityPrompt()
        Task {
            try? await Task.sleep(for: .seconds(2))
            self.uiState.refreshPermissions()
        }
    }

    func grantSpeech() {
        Task {
            _ = await self.uiState.ensureSpeechGrant()
            self.uiState.refreshPermissions()
        }
    }

    func prepareSpeech() {
        Task { await self.uiState.runPrepare() }
    }
}
