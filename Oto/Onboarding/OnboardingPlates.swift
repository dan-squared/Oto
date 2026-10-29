//
//  OnboardingPlates.swift
//  Oto
//
//  The right side of each chapter. Every control here is the real one from
//  Settings — the recorder applies immediately and the permission rows grant
//  for real — so the chapter is a rehearsal of the product, not a picture of
//  it. The on-device model downloads in the background from the permissions
//  chapter, so readiness never needs a chapter of its own.
//

import ApplicationServices
import Carbon.HIToolbox
import Speech
import SwiftUI

/// What the first chapter shows while its rows are read: the Flow Bar pill,
/// or the hands-free hint — one at a time, where the words are pointing.
struct OnboardingFlowBarPreview: View {
    let row: Int
    /// The live hold key, so the preview teaches the real gesture.
    var chips: [String] = []

    var body: some View {
        OnboardingPreviewPlate(width: 390, height: 300) {
            VStack(spacing: 18) {
                Spacer(minLength: 0)
                switch self.row {
                case 0: self.listening
                default: self.handsFree
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
            HStack(spacing: 8) {
                // The key twice, as one capsule: the gesture is the repetition.
                let chips = self.chips.isEmpty ? ["⌥"] : self.chips
                OtoShortcutPill(chips: chips + chips, compact: true)
                Text("tap twice, talk, press again")
                    .font(.system(size: 12))
                    .foregroundStyle(OnboardingTheme.muted)
            }
        }
    }

    private func pill(title: String) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 2.5) {
                ForEach(Array([8, 14, 22, 30, 22, 14, 8].enumerated()), id: \.offset) { _, height in
                    Capsule()
                        .fill(OnboardingTheme.ink)
                        .frame(width: 2.5, height: CGFloat(height))
                }
            }
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(OnboardingTheme.ink)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 16).frame(height: 34)
        .background(OnboardingTheme.card, in: Capsule())
        .overlay(Capsule().strokeBorder(OnboardingTheme.fieldEdge, lineWidth: 1))
    }

    private func field(text: String) -> some View {
        HStack(spacing: 2) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(OnboardingTheme.muted)
            Rectangle()
                .fill(OnboardingTheme.ink.opacity(0.8))
                .frame(width: 1, height: 13)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(OnboardingTheme.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(OnboardingTheme.divider, lineWidth: 1)
        )
    }
}

/// The catcher, given the room to be read: the card that keeps the words when
/// there is nowhere to paste them. Built from the real card's palette, so it
/// is the thing itself and not a picture of it.
struct OnboardingCatcherPlate: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = CatcherPalette.current(self.scheme)
        OnboardingPreviewPlate(width: 390, height: 300) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "tray.full")
                            .font(.system(size: 13))
                            .foregroundStyle(palette.dim)
                        Text("No text field")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(palette.ink)
                        Spacer(minLength: 8)
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(palette.dim)
                    }
                    Text("Oto kept your words. Copy them anywhere.")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.transcript)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Copy")
                        .font(.system(size: 12, weight: .semibold))
                        // Both palettes put a dark fill behind the label: a
                        // grey card in Dark Mode, solid ink in Light Mode.
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 28)
                        .background(palette.copyBackground, in: Capsule())
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(OnboardingTheme.cardEdge, lineWidth: 1)
                )
                .shadow(color: .black.opacity(palette.shadowOpacity), radius: 18, y: 8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 30)
        }
        .accessibilityHidden(true)
    }
}

/// The hold key, recorded for real — the Settings recorder, glass and glow and
/// all, opened from the same field the Settings row uses.
struct OnboardingShortcutPlate: View {
    @ObservedObject var flow: OnboardingFlow

    @State private var recorderShown = false

    var body: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Text("Push to talk")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OnboardingTheme.ink)
                    Spacer(minLength: 12)
                    OtoShortcutField(
                        chips: KeyNames.chips(for: self.flow.holdKind),
                        recordLabel: "Record push-to-talk key",
                        onRecord: { self.recorderShown = true }
                    )
                    .help("Click to record a shortcut")
                    .popover(isPresented: self.$recorderShown, arrowEdge: .top) {
                        ShortcutCapturePopover(
                            dispatch: self.flow.dispatch,
                            slot: .hold,
                            onChange: { self.flow.reloadHold() },
                            onClose: {
                                self.recorderShown = false
                                self.flow.reloadHold()
                            }
                        )
                    }
                }

                Divider().overlay(OnboardingTheme.divider)

                // Derived, non-editable double-tap row: always the hold key,
                // whatever it is — the always-on path with zero setup.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text("Double tap")
                            .font(.system(size: 12))
                            .foregroundStyle(OnboardingTheme.muted)
                        OtoShortcutPill(
                            chips: KeyNames.chips(for: self.flow.holdKind),
                            compact: true
                        )
                        Text("for hands-free")
                            .font(.system(size: 12))
                            .foregroundStyle(OnboardingTheme.muted)
                    }
                    Text(self.caption)
                        .font(.system(size: 11))
                        .foregroundStyle(OnboardingTheme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var caption: String {
        if case .modifierHold(let code) = self.flow.holdKind, code == UInt16(kVK_Function) {
            return SystemFnUsage.caption(for: self.flow.fnUsage)
        }
        return "An extra hands-free key lives in Settings."
    }
}

/// The three grants, live. One control per row, exactly as in Settings: the
/// pill is the button wherever a grant or a Settings trip exists. A denial is
/// a route to System Settings, never a dead end — and never a second button
/// stacked under the status.
struct OnboardingPermissionsPlate: View {
    @ObservedObject var flow: OnboardingFlow

    var body: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: 16) {
                self.row(
                    icon: "mic",
                    title: "Microphone",
                    status: self.flow.uiState.micText,
                    tone: self.flow.uiState.micTone,
                    action: self.flow.uiState.micAction,
                    guidance: self.flow.uiState.micDeniedGuidance,
                    run: { self.micAction() }
                )
                self.row(
                    icon: "accessibility",
                    title: "Accessibility",
                    status: self.flow.uiState.axTrusted ? "Allowed" : "Not allowed",
                    tone: self.flow.uiState.axTrusted ? .ok : .warn,
                    action: self.flow.uiState.axTrusted ? .none : .openSettings,
                    guidance: self.flow.uiState.axTrusted
                        ? nil
                        : "Needed to type into other apps. Turn Oto on in the list.",
                    run: { self.flow.openAccessibility() }
                )
                self.row(
                    icon: "checkmark.bubble",
                    title: "Speech recognition",
                    status: self.flow.uiState.speechText,
                    tone: self.flow.uiState.speechTone,
                    action: self.flow.uiState.speechAction,
                    guidance: self.flow.uiState.speechDeniedGuidance,
                    run: { self.speechAction() }
                )
            }
        }
        // No speech chapter: the model downloads here, in the background,
        // so "Try it" on the next chapter is not the first time Oto needs it.
        .task { self.flow.prepareSpeechInBackground() }
    }

    private func micAction() {
        switch self.flow.uiState.micAction {
        case .openSettings: self.flow.openMicrophoneSettings()
        case .allow: self.flow.grantMicrophone()
        case .none: break
        }
    }

    private func speechAction() {
        switch self.flow.uiState.speechAction {
        case .openSettings: self.flow.openSpeechSettings()
        case .allow: self.flow.grantSpeech()
        case .none: break
        }
    }

    private func row(
        icon: String,
        title: String,
        status: String,
        tone: OtoStatus.Tone,
        action: PermissionAction,
        guidance: String?,
        run: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(OnboardingTheme.muted)
                .frame(width: 22, height: 22, alignment: .top)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OnboardingTheme.ink)
                if let guidance {
                    Text(guidance)
                        .font(.system(size: 11.5))
                        .foregroundStyle(OnboardingTheme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            // One control: the state itself is the button where a remedy
            // exists, and a readout where there is nothing left to do.
            if action == .none {
                OtoStatus(text: status, tone: tone, fill: OnboardingTheme.tagIdle)
            } else {
                OtoStatusAction(
                    text: status,
                    tone: tone,
                    help: action == .allow ? "Ask for access" : "Open System Settings",
                    fill: OnboardingTheme.tagIdle,
                    hoverFill: OnboardingTheme.tagActive,
                    action: run
                )
            }
        }
    }
}

/// The trial field: the same place the words land, at the size of a field
/// rather than a page.
struct OnboardingTryPlate: View {
    @ObservedObject var flow: OnboardingFlow

    var body: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "text.cursor")
                        .font(.system(size: 11))
                        .foregroundStyle(OnboardingTheme.muted)
                    Text("Hold your key and speak")
                        .font(.system(size: 11.5))
                        .foregroundStyle(OnboardingTheme.muted)
                }
                ZStack(alignment: .topLeading) {
                    if self.flow.trialText.isEmpty {
                        Text("Your words land here.")
                            .font(.system(size: 13))
                            .foregroundStyle(OnboardingTheme.faint)
                            .padding(.horizontal, 13)
                            .padding(.top, 9)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: self.$flow.trialText)
                        .font(.system(size: 13))
                        .foregroundStyle(OnboardingTheme.ink)
                        .scrollContentBackground(.hidden)
                        .frame(height: 92)
                        .padding(8)
                        .background(OnboardingTheme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(OnboardingTheme.fieldEdge, lineWidth: 1)
                        )
                }
            }
        }
    }
}
