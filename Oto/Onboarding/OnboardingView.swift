//
//  OnboardingView.swift
//  Oto
//
//  Five-page first-run flow, dressed like the reference welcome: ground
//  canvas, 520 column, 26pt page titles, Big capsule footer (dots + Back +
//  Continue/Finish — no Skip), asymmetric slide transitions. Owns no
//  services: dispatch/preparer/permissions arrive as params. The hold-key
//  card reuses the Settings machinery and applies immediately.
//

import ApplicationServices
import Carbon.HIToolbox
import Speech
import SwiftUI

struct OnboardingView: View {
    private static let pageCount = 5

    let dispatch: ShortcutDispatch
    let preparer: SpeechAssetPreparer
    let permissions: PermissionsManager
    let onFinish: () -> Void

    @State private var page = 0
    @State private var forward = true

    // Hold-key card state. `holdKind` mirrors the live config after every
    // apply (single source stays in dispatch); messages are local.
    @State private var holdKind: ShortcutTrigger.Kind = .modifierHold(keyCode: UInt16(kVK_RightOption))
    @State private var isRecording = false
    @State private var holdMessage: String?
    @State private var showSwap = false

    // Permissions page state (DictationPane patterns, copied verbatim).
    @State private var micText = "Checking…"
    @State private var axTrusted = false
    @State private var speechText = "Checking…"

    // Ready page state.
    @State private var readinessText = "Checking…"
    @State private var languageText = "—"
    @State private var prepareFeedback: String?
    @State private var isPreparing = false
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
            refreshPermissions()
            await refreshSpeech()
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
                    .buttonStyle(.plain)
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
                Text("Hold a key, speak in any app, release — your words appear where you were typing. Private by design: on-device Apple Speech. No account, no cloud, no recordings kept.")
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
                subtitle: "No text field? The catcher keeps your transcript — one click to copy."
            )
        }
    }

    private func featureRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(OtoPalette.muted)
                .frame(width: 28)
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
                "This is the key you'll hold while you talk. Keep it, or click the field and press a new one."
            )
            VStack(alignment: .leading, spacing: 14) {
                KeycapField(
                    chips: KeyNames.chips(for: holdKind),
                    isRecording: isRecording,
                    disabled: false,
                    emptyPlaceholder: "Click to record…",
                    trashHelp: "Oto always needs a hold key",
                    onArm: {
                        dispatch.setSuspended(true)
                        isRecording = true
                    },
                    onTrash: {
                        holdMessage = "Oto needs a hold key to listen — pick one instead."
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
                    Text("Double taps are handled by macOS.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(OtoPalette.muted)
                } else {
                    Text("Hands-free toggle lives in Settings — empty until you add one.")
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
            holdMessage = "Same as your Hands-free shortcut — pick a different one or swap."
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
                "Oto asks only when it needs them — right here, right now."
            )
            VStack(alignment: .leading, spacing: 14) {
                permissionRow(
                    icon: "mic",
                    title: "Microphone",
                    status: micText,
                    actionTitle: micText == "Allowed" ? nil : "Allow microphone access",
                    action: {
                        Task {
                            _ = await permissions.ensureMicrophone()
                            refreshPermissions()
                        }
                    }
                )
                permissionRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    status: axTrusted ? "Allowed" : "Not allowed",
                    actionTitle: axTrusted ? nil : "Open Accessibility settings",
                    action: {
                        requestAccessibilityPrompt()
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            refreshPermissions()
                        }
                    }
                )
                permissionRow(
                    icon: "checkmark",
                    title: "Speech recognition",
                    status: speechText,
                    actionTitle: nil,
                    action: {}
                )
            }
        }
    }

    private func permissionRow(icon: String, title: String, status: String, actionTitle: String?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(OtoPalette.muted)
                .frame(width: 28)
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
                OtoPill(actionTitle, action: action)
            } else if status == "Allowed" {
                Image(systemName: "checkmark")
                    .font(.system(size: 14))
                    .foregroundStyle(OtoPalette.ink)
            }
        }
    }

    private func refreshPermissions() {
        switch permissions.microphoneStatus() {
        case .granted:
            micText = "Allowed"
        case .denied:
            micText = "Denied — allow in System Settings → Privacy & Security → Microphone."
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

    /// Apple's blessed prompt: opens System Settings at the Accessibility
    /// page itself when untrusted, no-ops when trusted. Same call as
    /// DictationPane — one blessed path, never duplicated logic.
    private func requestAccessibilityPrompt() {
        _ = AXIsProcessTrustedWithOptions([
            PermissionsManager.axPromptKey: true,
        ] as CFDictionary)
    }

    // MARK: - Page 5: Ready + try it

    private var readyPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading(
                "Get set up.",
                "Prepare offline speech once, then try it right here."
            )
            HStack(spacing: 12) {
                OtoBig(isPreparing ? "Preparing…" : "Prepare offline speech") {
                    Task { await runPrepare() }
                }
                .disabled(isPreparing)
                if isPreparing {
                    Text(readinessText)
                        .font(.system(size: 13))
                        .foregroundStyle(OtoPalette.muted)
                }
            }
            if let prepareFeedback {
                Text(prepareFeedback)
                    .font(.system(size: 13))
                    .foregroundStyle(OtoPalette.muted)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Try it — hold your key and speak into this field:")
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

    private func refreshSpeech() async {
        let report = await preparer.status()
        if let tag = report.resolved?.identifier(.bcp47) {
            let systemTag = Locale.current.identifier(.bcp47)
            languageText = tag == systemTag
                ? tag
                : "\(systemTag) → engine uses \(tag)"
        } else {
            languageText = Locale.current.identifier(.bcp47)
        }
        readinessText = report.readiness.errorDescription ?? "Ready (\(languageText))"
    }

    private func runPrepare() async {
        isPreparing = true
        prepareFeedback = "Preparing…"
        prepareFeedback = await preparer.prepareDefault()
        isPreparing = false
        await refreshSpeech()
    }
}
