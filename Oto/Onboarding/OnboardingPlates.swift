//
//  OnboardingPlates.swift
//  Oto
//
//  The right side of each chapter. Every control here is the real one from
//  Settings — the recorder applies immediately, the permission rows grant for
//  real, Prepare downloads for real — so the chapter is a rehearsal of the
//  product, not a picture of it.
//

import ApplicationServices
import Carbon.HIToolbox
import Speech
import SwiftUI

/// What the first chapter shows while its rows are read: the Flow Bar pill,
/// the hands-free hint, or the catcher — one at a time, where the words are
/// pointing.
struct OnboardingFlowBarPreview: View {
    let row: Int

    var body: some View {
        OnboardingPreviewPlate(width: 390, height: 300) {
            VStack(spacing: 18) {
                Spacer(minLength: 0)
                switch self.row {
                case 0: self.listening
                case 1: self.handsFree
                default: self.catcher
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(duration: 0.34, bounce: 0), value: self.row)
        }
        .accessibilityHidden(true)
    }

    private var listening: some View {
        VStack(spacing: 18) {
            self.pill(title: "Listening…")
            self.field(text: "Your words land here.")
        }
    }

    private var handsFree: some View {
        VStack(spacing: 18) {
            self.pill(title: "Hands-free")
            HStack(spacing: 6) {
                ForEach(0..<2, id: \.self) { _ in
                    Text("⌥")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                Text("tap twice, talk, press again")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private var catcher: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "tray.full")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.8))
                Text("No text field")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
            }
            Text("Oto kept your words. Copy them anywhere.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            Text("Copy")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 14).frame(height: 28)
                .background(.white, in: Capsule())
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func pill(title: String) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 2.5) {
                ForEach(Array([8, 14, 22, 30, 22, 14, 8].enumerated()), id: \.offset) { _, height in
                    Capsule()
                        .fill(.white)
                        .frame(width: 2.5, height: CGFloat(height))
                }
            }
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 16).frame(height: 34)
        .background(.white.opacity(0.10), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }

    private func field(text: String) -> some View {
        HStack(spacing: 2) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
            Rectangle()
                .fill(.white.opacity(0.8))
                .frame(width: 1, height: 13)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        )
    }
}

/// The hold key, recorded for real.
struct OnboardingShortcutPlate: View {
    @ObservedObject var flow: OnboardingFlow

    var body: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: 14) {
                KeycapField(
                    chips: KeyNames.chips(for: self.flow.holdKind),
                    isRecording: self.flow.isRecording,
                    disabled: false,
                    emptyPlaceholder: "Click to record…",
                    trashHelp: "Oto always needs a hold key",
                    onArm: { self.flow.arm() },
                    onTrash: {
                        self.flow.holdMessage = "Oto needs a hold key — pick one."
                        self.flow.showSwap = false
                    },
                    recorder: ShortcutRecorderModifier(
                        isListening: Binding(
                            get: { self.flow.isRecording },
                            set: { self.flow.isRecording = $0 }
                        ),
                        onCapture: { modifiers, keyCode, conflicts in
                            self.flow.captureCombo(modifiers: modifiers, keyCode: keyCode, conflicts: conflicts)
                        },
                        onCaptureModifier: { code in self.flow.captureModifier(code: code) },
                        onClear: { self.flow.disarm() },
                        onCancel: { self.flow.disarm() },
                        onInvalid: { reason in self.flow.refuse(reason) }
                    )
                )

                // Sided modifier menu. The recorder above already covers
                // combos and bare modifiers; the menu is the sided picker.
                Menu {
                    ForEach(KeyNames.holdOptions, id: \.code) { option in
                        Button(option.label) {
                            self.flow.applyHold(kind: .modifierHold(keyCode: option.code))
                        }
                    }
                } label: {
                    Text("Hold key: \(KeyNames.holdMenuLabel(for: self.flow.holdKind))")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .menuStyle(.borderlessButton)
                .help("Choose which key to hold")

                if let message = self.flow.holdMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                        if self.flow.showSwap {
                            Spacer(minLength: 6)
                            Button("Swap") { self.flow.swapHoldAndHandsFree() }
                                .buttonStyle(.link)
                                .font(.system(size: 11.5))
                        }
                    }
                }

                Divider().overlay(.white.opacity(0.10))

                // Derived, non-editable double-tap row: always the hold key,
                // whatever it is — the always-on path with zero setup.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text("Double tap")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                        ForEach(KeyNames.chips(for: self.flow.holdKind), id: \.self) { chip in
                            OtoKey(text: chip)
                        }
                    }
                    if case .modifierHold(let code) = self.flow.holdKind, code == UInt16(kVK_Function) {
                        Text(SystemFnUsage.caption(for: self.flow.fnUsage))
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                    } else {
                        Text("An extra hands-free key lives in Settings.")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
        }
    }
}

/// The three grants, live.
struct OnboardingPermissionsPlate: View {
    @ObservedObject var flow: OnboardingFlow

    var body: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: 16) {
                self.row(
                    icon: "mic",
                    title: "Microphone",
                    status: self.micStatusText,
                    actionTitle: self.flow.uiState.micPermission == .notDetermined ? "Allow" : nil,
                    action: { self.flow.grantMicrophone() }
                )
                self.row(
                    icon: "accessibility",
                    title: "Accessibility",
                    status: self.flow.uiState.axTrusted ? "Allowed" : "Not allowed",
                    actionTitle: self.flow.uiState.axTrusted ? nil : "Open Settings",
                    action: { self.flow.openAccessibility() }
                )
                self.row(
                    icon: "checkmark.bubble",
                    title: "Speech recognition",
                    status: self.flow.uiState.speechText,
                    actionTitle: self.flow.uiState.speechPermission == .notDetermined ? "Allow" : nil,
                    guidance: self.flow.uiState.speechDeniedGuidance,
                    action: { self.flow.grantSpeech() }
                )
            }
        }
    }

    /// Onboarding's mic-denied copy keeps its guidance suffix; the shared
    /// model carries the bare status ("Denied") for the panes.
    private var micStatusText: String {
        self.flow.uiState.micPermission == .denied
            ? "Denied — allow it in System Settings."
            : self.flow.uiState.micText
    }

    private func row(
        icon: String,
        title: String,
        status: String,
        actionTitle: String?,
        guidance: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 22, height: 22, alignment: .top)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                Text(status)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.5))
                if let guidance {
                    Text(guidance)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 18, height: 18)
            }
        }
    }
}

/// Offline speech: readiness and the real download.
struct OnboardingSpeechPlate: View {
    @ObservedObject var flow: OnboardingFlow

    var body: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: 14) {
                if self.flow.uiState.readinessText == "Checking…" {
                    self.status(text: "Checking…", tone: .idle)
                } else if self.flow.uiState.speechReady {
                    HStack(spacing: 8) {
                        self.status(text: "Ready", tone: .ok)
                        Text(self.flow.uiState.languageText)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            self.status(text: "Not prepared yet", tone: .idle)
                            Text(self.flow.uiState.prepareFeedback ?? "Works offline once prepared.")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.55))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button(
                            self.flow.uiState.isPreparing ? "Preparing…" : "Prepare offline speech",
                            action: { self.flow.prepareSpeech() }
                        )
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .tint(.white)
                        .disabled(self.flow.uiState.isPreparing)
                    }
                }

                Text("Nothing is uploaded — the language model is downloaded once and runs on this Mac.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func status(text: String, tone: OtoStatus.Tone) -> some View {
        OtoStatus(text: text, tone: tone)
    }
}

/// The trial field. The same field the ready page used, on the chapter plate.
struct OnboardingTryPlate: View {
    @ObservedObject var flow: OnboardingFlow

    var body: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "text.cursor")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("Hold your key and speak")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.55))
                }
                TextEditor(text: self.$flow.trialText)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .scrollContentBackground(.hidden)
                    .frame(height: 150)
                    .padding(8)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    )
            }
        }
    }
}
