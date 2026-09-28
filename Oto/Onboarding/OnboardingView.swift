//
//  OnboardingView.swift
//  Oto
//
//  Five-page first-run flow in a compact fixed window (620×480, content
//  column 480). No Skip anywhere: footer is dots + Back + Continue/Finish
//  only, and window-close never marks seen (the controller owns that).
//
//  Owns no services: dispatch/preparer/permissions arrive as params, like
//  Settings panes. The hold-key card reuses the exact Settings machinery
//  (`KeycapField`, `ShortcutRecorderModifier`, `KeyNames`, the dispatch
//  save gate) but applies immediately — there is no Done staging here, so
//  every capture/menu pick either saves or explains itself on the spot.
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
        VStack(spacing: 0) {
            pageBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            HStack {
                dots
                Spacer()
                if page > 0 {
                    Button("Back") { page -= 1 }
                        .buttonStyle(.link)
                }
                Button(page == Self.pageCount - 1 ? "Finish" : "Continue") {
                    advance()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
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

    // MARK: - Pager

    @ViewBuilder
    private var pageBody: some View {
        switch page {
        case 0: welcomePage
        case 1: featuresPage
        case 2: holdKeyPage
        case 3: permissionsPage
        default: readyPage
        }
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(0..<Self.pageCount, id: \.self) { index in
                Circle()
                    .fill(index == page ? Color.primary : Color.secondary.opacity(0.35))
                    .frame(width: 6, height: 6)
            }
        }
    }

    private func advance() {
        if page == Self.pageCount - 1 {
            onFinish()
        } else {
            page += 1
        }
    }

    // MARK: - Page 1: Welcome

    private var welcomePage: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Welcome to Oto")
                .font(.largeTitle)
                .bold()
            Text("Hold a key, speak in any app, release — your words appear where you were typing.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
            Text("Private by design: on-device Apple Speech. No account, no cloud, no recordings kept.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Page 2: Features

    private var featuresPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What Oto does for you")
                .font(.title2)
                .bold()
                .padding(.top, 36)
            featureRow(
                symbol: "keyboard",
                title: "Push to talk",
                subtitle: "Hold \(KeyNames.shortLabel(for: holdKind)) for quick bursts."
            )
            featureRow(
                symbol: "hand.tap",
                title: "Double-tap for hands-free",
                subtitle: "Tap-tap the same key for long talks. Press again to stop. No setup."
            )
            featureRow(
                symbol: "tray.full",
                title: "Never lose words",
                subtitle: "No text field? The catcher keeps your transcript — one click to copy."
            )
            Text("Works offline once speech is prepared.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 70)
    }

    private func featureRow(symbol: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Page 3: Hold key

    private var holdKeyPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your hold key")
                .font(.title2)
                .bold()
                .padding(.top, 28)
            Text("This is the key you'll hold while you talk. Keep it, or click the field and press a new one.")
                .foregroundStyle(.secondary)
                .font(.subheadline)

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

            // Sided modifier menu + presets note. The recorder above already
            // covers combos and bare modifiers; the menu is the sided picker.
            // (A Dictation-key-as-hold preset exists in Settings for
            // grandfathered configs; onboarding teaches the two live paths.)
            Menu {
                ForEach(KeyNames.holdOptions, id: \.code) { option in
                    Button(option.label) {
                        applyHold(kind: .modifierHold(keyCode: option.code))
                    }
                }
            } label: {
                Text("Hold key: \(KeyNames.holdMenuLabel(for: holdKind))")
            }
            .help("Choose which key to hold")

            if let holdMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(holdMessage)
                        .font(.caption)
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
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }

            // Derived, non-editable double-tap row: always the hold key,
            // whatever it is — the always-on path with zero setup. Bare fn
            // shows the system-owned caption (model policy, same as Settings).
            HStack(spacing: 4) {
                Text("Double tap")
                    .foregroundStyle(.secondary)
                ForEach(KeyNames.chips(for: holdKind), id: \.self) { chip in
                    Text(chip)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.quaternary, lineWidth: 1)
            )
            if case .modifierHold(let code) = holdKind, code == UInt16(kVK_Function) {
                Text("Double taps are handled by macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Hands-free toggle lives in Settings — empty until you add one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 70)
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions")
                .font(.title2)
                .bold()
                .padding(.top, 28)
            Text("Oto asks only when it needs them — right here, right now.")
                .foregroundStyle(.secondary)
                .font(.subheadline)

            permissionRow(
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
                title: "Speech recognition",
                status: speechText,
                actionTitle: nil,
                action: {}
            )
            Text("Global keys and insertion need Accessibility; combos alone work without it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 70)
    }

    private func permissionRow(title: String, status: String, actionTitle: String?, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let actionTitle {
                Button(actionTitle, action: action)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Get set up")
                .font(.title2)
                .bold()
                .padding(.top, 24)
            HStack(spacing: 8) {
                Button("Prepare offline speech") {
                    Task { await runPrepare() }
                }
                .disabled(isPreparing)
                Text(readinessText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let prepareFeedback {
                Text(prepareFeedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Try it — hold your key and speak into this field:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextEditor(text: $trialText)
                .frame(minHeight: 90)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary, lineWidth: 1)
                )
            Spacer()
        }
        .padding(.horizontal, 70)
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
