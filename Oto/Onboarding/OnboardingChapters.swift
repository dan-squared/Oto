//
//  OnboardingChapters.swift
//  Oto
//
//  The frame every chapter shares: words at the top left, the chapter's film
//  frame — a rounded media panel — filling the right column, and one footer
//  that stays put from the first chapter to the last. Only what differs
//  between two chapters leaves and arrives, and it leaves sideways, so the
//  frame turns like a page rather than scrolling. There is no header: the
//  copy is the first thing on the page, the way the reference reads.
//

import SwiftUI

/// What a chapter says on its left: a tag, a title and a line. Every chapter
/// says it the same way, centred in the column — the frame carries the thing
/// itself on the right.
struct OnboardingChapterCopy {
    let tag: String
    let symbol: String
    let title: String
    let subtitle: String

    static func copy(for step: OnboardingStage.Step) -> OnboardingChapterCopy? {
        switch step {
        case .how:
            .init(
                tag: "What Oto does", symbol: "waveform", title: "Speak. It lands.",
                subtitle: "Oto turns your voice into text in whatever app you're in."
            )
        case .catcher:
            .init(
                tag: "Never lose words", symbol: "tray.full", title: "Nothing gets lost",
                subtitle: "No text field? The catcher keeps the transcript — one click to copy."
            )
        case .shortcut:
            .init(
                tag: "Your key", symbol: "keyboard", title: "Hold to talk",
                subtitle: "Hold this key while you talk — or click the field and press a new one."
            )
        case .permissions:
            .init(
                tag: "Permissions", symbol: "lock.shield", title: "Two grants",
                subtitle: "Oto asks only when it needs to, right here."
            )
        case .tryIt:
            .init(
                tag: "Try it", symbol: "text.cursor", title: "Say something",
                subtitle: "Hold your key and speak into the field. This is the whole product."
            )
        case .welcome,
             .handoff: nil
        }
    }
}

/// The frame every chapter shares: words at the top left, the chapter's film
/// frame on the right, and one footer that stays put from the first chapter to
/// the last.
struct OnboardingChaptersView: View {
    @ObservedObject var flow: OnboardingFlow

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let compact = size.width < 780 || size.height < 540
            let margin: CGFloat = compact ? 34 : 46
            let gap: CGFloat = compact ? 22 : 32
            let column: CGFloat = compact ? 238 : 310
            let inset: CGFloat = compact ? 22 : 30
            let corner: CGFloat = compact ? 20 : 24
            let step = self.stage.step
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: gap) {
                    ZStack(alignment: .topLeading) {
                        if let copy = OnboardingChapterCopy.copy(for: step) {
                            self.words(copy, compact: compact)
                                .id(step)
                                .transition(self.stage.turn(reduceMotion: self.reduceMotion))
                        }
                    }
                    .frame(width: column, alignment: .leading)

                    self.media(step: step, inset: inset, corner: corner)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.top, compact ? 38 : 50)
                .padding(.horizontal, margin)
                .padding(.bottom, compact ? 20 : 26)

                self.footer
                    .padding(.horizontal, margin)
                    .padding(.bottom, compact ? 22 : 30)
            }
            .frame(width: size.width, height: size.height)
        }
        .foregroundStyle(OnboardingTheme.ink)
        .animation(OnboardingStage.stepAnimation, value: self.stage.step)
    }

    // MARK: Private

    @ObservedObject private var stage = OnboardingStage.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The chapter's film frame: the panel that will hold its picture or its
    /// film. Until there is one, a gradient stands in — the thing itself, the
    /// real control, floats on it.
    private func media(step: OnboardingStage.Step, inset: CGFloat, corner: CGFloat) -> some View {
        ZStack {
            LinearGradient(
                colors: [OnboardingTheme.mediaTop, OnboardingTheme.mediaBottom],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            ZStack {
                // Replaced where it stands, not turned with the words: the
                // recorder and the cards are things being used, and a thing
                // in use does not go by.
                self.thing(for: step)
                    .id(step)
                    .transition(self.reduceMotion ? .opacity : self.stage.replacing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(inset)
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(OnboardingTheme.mediaEdge, lineWidth: 1)
        )
    }

    private var footer: some View {
        HStack(spacing: 12) {
            OnboardingGlassCircleButton(symbol: "chevron.left", action: self.flow.back)
                .opacity(self.flow.canGoBack ? 1 : 0)
                .disabled(!self.flow.canGoBack)
                .keyboardShortcut("[", modifiers: .command)
                .accessibilityLabel("Back")

            OnboardingContinueButton(title: self.flow.buttonTitle, action: self.flow.next)

            Spacer(minLength: 16)

            OnboardingProgressDashes(step: self.stage.step) {
                self.flow.jump(to: $0)
            }
        }
    }

    private func words(_ copy: OnboardingChapterCopy, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                OnboardingGlyph(name: copy.symbol, size: 13)
                Text(copy.tag).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10).frame(height: 24)
            .foregroundStyle(OnboardingTheme.tagIdleText)
            .background(OnboardingTheme.tagIdle, in: Capsule())
            Text(copy.title)
                .font(.system(size: compact ? 30 : 38, weight: .medium))
                .tracking(-1.0)
                .lineSpacing(-2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
                .accessibilityAddTraits(.isHeader)
            Text(copy.subtitle)
                .font(.system(size: compact ? 14 : 15))
                .foregroundStyle(OnboardingTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    @ViewBuilder
    private func thing(for step: OnboardingStage.Step) -> some View {
        switch step {
        case .how:
            OnboardingFlowBarPreview()
        case .catcher:
            OnboardingCatcherPlate()
        case .shortcut:
            OnboardingShortcutPlate(flow: self.flow)
        case .permissions:
            OnboardingPermissionsPlate(flow: self.flow)
        case .tryIt:
            OnboardingTryPlate(flow: self.flow)
        case .welcome,
             .handoff: Color.clear
        }
    }
}

/// A round button on the system's glass, the way the panel's own controls are;
/// bordered where there is no glass to be had.
struct OnboardingGlassCircleButton: View {
    let symbol: String
    var size: CGFloat = 28
    var action: () -> Void

    var body: some View {
        let label = Image(systemName: self.symbol)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: self.size, height: self.size)
        if #available(macOS 26.0, *) {
            Button(action: self.action) { label }
                .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
        } else {
            Button(action: self.action) { label }
                .buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large)
        }
    }
}

/// A chapter's mark: an SF Symbol on the dark stage.
struct OnboardingGlyph: View {
    let name: String
    var size: CGFloat

    var body: some View {
        Image(systemName: self.name)
            .font(.system(size: self.size * 0.9, weight: .medium))
            .frame(width: self.size, height: self.size)
    }
}

/// One dash per chapter. The current one is longer; the ones before it are
/// filled, the ones after it are not — the walk reads as a place, not a clock.
struct OnboardingProgressDashes: View {
    let step: OnboardingStage.Step
    var onSelect: (OnboardingStage.Step) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(OnboardingStage.Step.chapters, id: \.self) { chapter in
                let current = chapter == self.step
                let width: CGFloat = current ? 28 : 12
                let share: CGFloat = chapter <= self.step ? 1 : 0
                Capsule().fill(OnboardingTheme.dashTrack)
                    .frame(width: width, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(OnboardingTheme.dashFill).frame(width: width * share, height: 4)
                    }
                    .clipShape(Capsule())
                    .contentShape(Rectangle().inset(by: -6))
                    .onTapGesture { self.onSelect(chapter) }
            }
        }
        .animation(OnboardingStage.stepAnimation, value: self.step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Step \((OnboardingStage.Step.chapters.firstIndex(of: self.step) ?? 0) + 1) of \(OnboardingStage.Step.chapters.count)"
        )
    }
}

/// The quiet plate a chapter's card stands on.
struct OnboardingCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        self.content()
            .padding(20)
            .frame(maxWidth: 430, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(OnboardingTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(OnboardingTheme.cardEdge, lineWidth: 1)
            )
    }
}

/// A chapter's thing, scaled down only when the window is too small to hold it.
/// It stands on the media panel itself, so it brings no backdrop of its own.
struct OnboardingPreviewPlate<Content: View>: View {
    var width: CGFloat = 380
    var height: CGFloat = 300
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let scale = min(1, (proxy.size.width - 8) / self.width, (proxy.size.height - 8) / self.height)
            self.content()
                .frame(width: self.width, height: self.height)
                .scaleEffect(max(scale, 0.5))
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}
