//
//  OnboardingView.swift
//  Oto
//
//  Five-page first-run flow, dressed like the reference welcome: ground
//  canvas, 520 column, 26pt page titles, Big capsule footer (dots + Back +
//  Continue/Finish — no Skip), asymmetric slide transitions. Owns no
//  services: dispatch and the shared SettingsUIState arrive as params
//  (permissions/speech state live in the hoisted model, never duplicated
//  here — the mic-flash fix). The hold-key card reuses the Settings
//  machinery and applies immediately.
//

import ApplicationServices
import Carbon.HIToolbox
import Speech
import SwiftUI

struct OnboardingView: View {
    private static let pageCount = 5

    let dispatch: ShortcutDispatch
    let uiState: SettingsUIState
    let onFinish: () -> Void

    @State private var page = 0
    @State private var forward = true

    // Hold-key card state. `holdKind` mirrors the live config after every
    // apply (single source stays in dispatch); messages are local.
    @State private var holdKind: ShortcutTrigger.Kind = ShortcutTrigger.defaultHoldToTalk().kind
    @State private var fnUsage = SystemFnUsage.unknown
    @State private var isRecording = false
    @State private var holdMessage: String?
    @State private var showSwap = false

    // Ready page state (trial text only — readiness and permissions
    // render from the shared model).
    @State private var trialText = ""

    var body: some View {
        ZStack {
            OtoPalette.ground.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                ZStack {
                    switch page {
                    case 0: welcomePage
                    case 1: featuresPage
                    case 2: holdKeyPage
                    case 3: permissionsPage
                    default: readyPage
                    }
                }
                .frame(maxWidth: 520)
                .id(page)
                .transition(.asymmetric(
                    insertion: .offset(x: forward ? 40 : -40).combined(with: .opacity),
                    removal: .offset(x: forward ? -40 : 40).combined(with: .opacity)
                ))
                Spacer(minLength: 0)
                foot
            }
            .padding(40)
        }
        .animation(OtoMotion.glide, value: page)
        .frame(width: 620, height: 480)
        .task {
            holdKind = dispatch.configuration.hold.kind
            fnUsage = SystemFnUsage.read()
            // Slow state is hoisted (same model Settings uses) — read it,
            // never duplicate it. Speech/mac state loads once per window
            // open via ensureLoaded; the panes own that call, this only
            // re-reads the fast permission surface and the speech report.
            uiState.refreshPermissions()
            await uiState.refreshSpeech()
        }
        .onDisappear {
            // Safety: an armed recording suspends global shortcuts — never
            // leave them suspended behind a closed window. Idempotent.
            dispatch.setSuspended(false)
        }
    }

    // MARK: - the bottom edge

    private var foot: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(0..<Self.pageCount, id: \.self) { i in
                    Circle()
                        .fill(i == page ? OtoPalette.ink : OtoPalette.faint.opacity(0.6))
                        .frame(width: 6, height: 6)
                }
            }
            Spacer()
            if page > 0 {
                Button("Back") { forward = false; page -= 1 }
                    .buttonStyle(OtoBounce())
                    .font(.system(size: 13))
                    .foregroundStyle(OtoPalette.muted)
            }
            OtoBig(page == Self.pageCount - 1 ? "Finish" : "Continue") {
                advance()
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: 520)
    }

    private func advance() {
        if page == Self.pageCount - 1 {
            onFinish()
        } else {
            forward = true
            page += 1
        }
    }

    // MARK: - Page 1: Welcome

    private var welcomePage: some View {
        VStack(spacing: 22) {
            Image(systemName: "waveform")
                .font(.system(size: 40))
                .foregroundStyle(OtoPalette.ink)
            VStack(spacing: 10) {
                Text("Welcome to Oto")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(OtoPalette.ink)
                Text("Hold a key, speak anywhere, release — your words land where you type. Private: on-device speech, no account, no cloud.")
                    .font(.system(size: 14.5))
                    .foregroundStyle(OtoPalette.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 400)
            }
        }
    }

    // MARK: - Page 2: Features

    private var featuresPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading(
                "What Oto does for you.",
                "Three things, each one press away. Everything else lives in Settings."
            )
            featureRow(
                icon: "keyboard",
                title: "Push to talk",
                subtitle: "Hold \(KeyNames.shortLabel(for: holdKind)) for quick bursts."
            )
            featureRow(
                icon: "hand.tap",
                title: "Double-tap for hands-free",
                subtitle: "Tap-tap the same key for long talks. Press again to stop. No setup."
            )
            featureRow(
                icon: "tray.full",
                title: "Never lose words",
                subtitle: "No text field? The catcher keeps it — one click to copy."
            )
        }
    }

    private func featureRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(OtoPalette.muted)
                .frame(width: 28, height: 28, alignment: .top)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(OtoPalette.ink)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(OtoPalette.muted)
            }
        }
    }

    private func heading(_ title: String, _ line: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(OtoPalette.ink)
            Text(line)
                .font(.system(size: 14))
                .foregroundStyle(OtoPalette.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Page 3: Hold key

    private var holdKeyPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading(
                "Your hold key.",
                "Hold this key while you talk — or click the field and press a new one."
            )
            VStack(alignment: .leading, spacing: 14) {
                KeycapField(
                    chips: KeyNames.chips(for: holdKind),
                    isRecording: isRecording,
                    disabled: false,
                    emptyPlaceholder: "Click to record…",
                    trashHelp: "Oto always needs a hold key",
                    onArm: {
                        // Toggle: clicking an armed field disarms it, so a
                        // recording can never get stuck with no way out.
                        if isRecording {
                            dispatch.setSuspended(false)
                            isRecording = false
                        } else {
                            dispatch.setSuspended(true)
                            isRecording = true
                        }
                    },
                    onTrash: {
                        holdMessage = "Oto needs a hold key — pick one."
                        showSwap = false
                    },
                    recorder: ShortcutRecorderModifier(
                        isListening: $isRecording,
                        onCapture: { modifiers, keyCode, conflicts in
                            captureCombo(modifiers: modifiers, keyCode: keyCode, conflicts: conflicts)
                        },
                        onCaptureModifier: { code in
                            captureModifier(code: code)
                        },
                        onClear: {
                            dispatch.setSuspended(false)
                            isRecording = false
                        },
                        onCancel: {
                            dispatch.setSuspended(false)
                            isRecording = false
                        },
                        onInvalid: { reason in
                            NSSound.beep()
                            holdMessage = reason.message
                            showSwap = false
                        }
                    )
                )

                // Sided modifier menu. The recorder above already covers
                // combos and bare modifiers; the menu is the sided picker.
                Menu {
                    ForEach(KeyNames.holdOptions, id: \.code) { option in
                        Button(option.label) {
                            applyHold(kind: .modifierHold(keyCode: option.code))
                        }
                    }
                } label: {
                    Text("Hold key: \(KeyNames.holdMenuLabel(for: holdKind))")
                        .font(.system(size: 13))
                        .foregroundStyle(OtoPalette.ink)
                }
                .help("Choose which key to hold")
            }

            if let holdMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .frame(width: 16, height: 16)
                    Text(holdMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(OtoPalette.muted)
                    if showSwap {
                        Spacer()
                        Button("Swap") {
                            dispatch.swapHoldAndHandsFree()
                            holdKind = dispatch.configuration.hold.kind
                            self.holdMessage = nil
                            showSwap = false
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            // Derived, non-editable double-tap row: always the hold key,
            // whatever it is — the always-on path with zero setup. Bare fn
            // shows the system-owned caption (model policy, same as Settings).
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("Double tap")
                        .font(.system(size: 13))
                        .foregroundStyle(OtoPalette.muted)
                    ForEach(KeyNames.chips(for: holdKind), id: \.self) { chip in
                        OtoKey(text: chip)
                    }
                }
                if case .modifierHold(let code) = holdKind, code == UInt16(kVK_Function) {
                    Text(SystemFnUsage.caption(for: fnUsage))
                        .font(.system(size: 11.5))
                        .foregroundStyle(OtoPalette.muted)
                } else {
                    Text("An extra hands-free key lives in Settings.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(OtoPalette.muted)
                }
            }
        }
    }

    /// Immediate-apply save: the gate either saves (or no-ops on equality)
    /// or refuses without saving — `.blocked` always keeps the old binding,
    /// so the message + Swap path below can never strand an empty slot.
    private func applyHold(kind: ShortcutTrigger.Kind) {
        let result = dispatch.updateHoldTrigger(
            ShortcutTrigger(kind: kind, interaction: .holdToTalk)
        )
        holdKind = dispatch.configuration.hold.kind
        if result == .blocked {
            holdMessage = "Same as Hands-free — pick another or swap."
            showSwap = true
        } else {
            holdMessage = nil
            showSwap = false
        }
    }

    private func captureCombo(modifiers: UInt32, keyCode: UInt32, conflicts: [RecorderConflict]) {
        dispatch.setSuspended(false)
        isRecording = false
        if ShortcutRecorderConflicts.blocksSaving(conflicts) {
            holdMessage = ShortcutRecorderConflicts.describe(conflicts)
            showSwap = false
            return
        }
        applyHold(kind: .combo(modifiers: modifiers, keyCode: keyCode))
        if holdMessage == nil, !conflicts.isEmpty {
            holdMessage = ShortcutRecorderConflicts.describe(conflicts)
        }
    }

    private func captureModifier(code: UInt16) {
        dispatch.setSuspended(false)
        isRecording = false
        applyHold(kind: .modifierHold(keyCode: code))
    }

    // MARK: - Page 4: Permissions

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading(
                "Permissions.",
                "Oto asks only when needed — here and now."
            )
            VStack(alignment: .leading, spacing: 14) {
                permissionRow(
                    icon: "mic",
                    title: "Microphone",
                    status: micStatusText,
                    actionTitle: uiState.micAllowed ? nil : "Allow microphone access",
                    action: {
                        Task {
                            _ = await uiState.ensureMicrophoneGrant()
                            uiState.refreshPermissions()
                        }
                    }
                )
                permissionRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    status: uiState.axTrusted ? "Allowed" : "Not allowed",
                    actionTitle: uiState.axTrusted ? nil : "Open Accessibility settings",
                    action: {
                        uiState.requestAccessibilityPrompt()
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            uiState.refreshPermissions()
                        }
                    }
                )
                permissionRow(
                    icon: "checkmark",
                    title: "Speech recognition",
                    status: uiState.speechText,
                    actionTitle: uiState.speechAllowed ? nil : "Allow speech recognition",
                    action: {
                        Task {
                            _ = await uiState.ensureSpeechGrant()
                            uiState.refreshPermissions()
                        }
                    }
                )
            }
        }
    }

    /// Onboarding's mic-denied copy keeps its guidance suffix; the shared
    /// model carries the bare status ("Denied") for the panes.
    private var micStatusText: String {
        uiState.micPermission == .denied ? "Denied — allow it in System Settings." : uiState.micText
    }

    private func permissionRow(icon: String, title: String, status: String, actionTitle: String?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(OtoPalette.muted)
                .frame(width: 28, height: 28, alignment: .top)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(OtoPalette.ink)
                Text(status)
                    .font(.system(size: 11.5))
                    .foregroundStyle(OtoPalette.faint)
            }
            Spacer()
            if let actionTitle {
                OtoBig(actionTitle, act: action)
            } else if status == "Allowed" {
                // Intentional display-string compare (not typed state): the
                // strings are derived in exactly one tested place
                // (SettingsUIState), and threading a Bool through would
                // churn all three call sites for zero behavior change.
                Image(systemName: "checkmark")
                    .font(.system(size: 14))
                    .foregroundStyle(OtoPalette.ink)
                    .frame(width: 18, height: 18)
            }
        }
    }

    // MARK: - Page 5: Ready + try it

    private var readyPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading(
                "Get set up.",
                "Try it below, then press Finish."
            )
            if uiState.readinessText == "Checking…" {
                OtoStatus(text: "Checking…", tone: .idle)
            } else if uiState.speechReady {
                HStack(spacing: 8) {
                    OtoStatus(text: "Ready", tone: .ok)
                    Text(uiState.languageText)
                        .font(.system(size: 13))
                        .foregroundStyle(OtoPalette.muted)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        OtoStatus(text: "Not prepared yet", tone: .idle)
                        Text(uiState.prepareFeedback ?? "Works offline once prepared.")
                            .font(.system(size: 13))
                            .foregroundStyle(OtoPalette.muted)
                    }
                    OtoBig(uiState.isPreparing ? "Preparing…" : "Prepare offline speech") {
                        Task { await uiState.runPrepare() }
                    }
                    .disabled(uiState.isPreparing)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Hold your key and speak into this field:")
                    .font(.system(size: 13))
                    .foregroundStyle(OtoPalette.muted)
                TextEditor(text: $trialText)
                    .font(.system(size: 13))
                    .foregroundStyle(OtoPalette.ink)
                    .frame(minHeight: 80)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(OtoPalette.hairline, lineWidth: 1)
                    )
            }
        }
    }
}
