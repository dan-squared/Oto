//
//  OnboardingChapters.swift
//  Oto
//
//  The frame every chapter shares: the page's own mark at the top left, the
//  words in the left column, a quiet surface on the right, and one footer
//  that stays put from the first chapter to the last. Only what differs
//  between two chapters leaves and arrives, and it leaves sideways, so the
//  frame turns like a page rather than scrolling.
//
//  The mark is also where the finish flight starts: it is the one piece of
//  the walk that exists again in the menu bar.
//

import SwiftUI

/// What a chapter says: a small pill that names it, and the title and line.
/// Every chapter says it the same way, centred in the column — the frame
/// carries the rest.
struct OnboardingChapterCopy {
    let tag: String
    let symbol: String
    let title: String
    let subtitle: String

    /// `holdLabel` is the live push-to-talk key ("Right ⌥"); the hands-free
    /// chapter names it so the reader never has to guess which key is theirs.
    static func copy(
        for step: OnboardingStage.Step,
        holdLabel: String? = nil
    ) -> OnboardingChapterCopy? {
        switch step {
        case .how:
            .init(
                tag: "What Oto does", symbol: "waveform",
                title: "Speak. It lands.",
                subtitle: "Your voice becomes text in whatever app you're in."
            )
        case .catcher:
            .init(
                tag: "Nothing lost", symbol: "tray.full",
                title: "Nowhere to paste?",
                subtitle: "Your words are kept, ready to copy."
            )
        case .intelligence:
            .init(
                tag: "Apple Intelligence", symbol: "sparkles",
                title: "Cleaned up as you speak",
                subtitle: "Filler words go. The meaning stays. All on this Mac."
            )
        case .dictionary:
            .init(
                tag: "Dictionary", symbol: "character.book.closed",
                title: "Your words, spelled right",
                subtitle: "Add a name or a phrase once, and Oto gets it right every time."
            )
        case .handsFree:
            .init(
                tag: "Hands-free", symbol: "hand.tap",
                title: "Double-tap, keep talking",
                subtitle: "Tap \(holdLabel ?? "your key") twice and Oto keeps listening until you tap again — no need to hold."
            )
        case .welcome,
             .handoff: nil
        }
    }
}

/// The chapter frame's numbers, derived only from the panel size. The view
/// draws the mark from these and the window controller starts the finish
/// flight from the same rect, so the two can never drift apart.
enum OnboardingChapterLayout {
    struct Metrics {
        var compact: Bool
        var leading: CGFloat
        var trailing: CGFloat
        var gap: CGFloat
        var column: CGFloat
        var inset: CGFloat
        var corner: CGFloat
        var vertical: CGFloat
        var markBox: CGFloat
    }

    static func metrics(in size: CGSize) -> Metrics {
        let compact = size.width < 780 || size.height < 540
        return Metrics(
            compact: compact,
            leading: compact ? 34 : 46,
            trailing: compact ? 18 : 24,
            gap: compact ? 22 : 32,
            column: compact ? 260 : 360,
            inset: compact ? 22 : 30,
            // The picture's frame echoes the window's own corner (measured
            // ~18 pt) instead of rounding past it, so the two curves nest.
            corner: compact ? 16 : 18,
            // Same air above and below the picture: the footer lives in the
            // words' column, so it never shortens the media panel.
            vertical: compact ? 20 : 28,
            markBox: compact ? 24 : 28
        )
    }

    /// The page mark: a square slot at the top left, and the mark's own aspect
    /// fitted inside it, so the drawn ink and the flying copy are the same
    /// size from the first frame.
    static func markRect(in size: CGSize) -> CGRect {
        let metrics = metrics(in: size)
        let box = CGRect(
            x: metrics.leading, y: metrics.vertical,
            width: metrics.markBox, height: metrics.markBox
        )
        let aspect: CGFloat = {
            guard let mark = OtoMarkSource.cropped, mark.size.height > 0 else { return 1 }
            return mark.size.width / mark.size.height
        }()
        let width = min(box.width, box.height * aspect)
        let height = width / max(aspect, 0.01)
        return CGRect(
            x: box.minX + (box.width - width) / 2,
            y: box.minY + (box.height - height) / 2,
            width: width, height: height
        )
    }
}

/// The frame every chapter shares: the page's mark, words on the left, a
/// quiet empty surface on the right, and one footer that stays put from the
/// first chapter to the last. The walk carries no pictures.
struct OnboardingChaptersView: View {
    @ObservedObject var flow: OnboardingFlow

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let metrics = OnboardingChapterLayout.metrics(in: size)
            let step = self.stage.step
            ZStack(alignment: .topLeading) {
                HStack(alignment: .top, spacing: metrics.gap) {
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer(minLength: 0)
                        if let copy = OnboardingChapterCopy.copy(
                            for: step,
                            holdLabel: KeyNames.shortLabel(for: self.flow.holdKind)
                        ) {
                            self.words(copy, compact: metrics.compact)
                                .id(step)
                                .transition(self.stage.turn(reduceMotion: self.reduceMotion))
                        }
                        Spacer(minLength: 0)
                        self.footer
                    }
                    .frame(width: metrics.column, alignment: .leading)

                    self.media(corner: metrics.corner)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .bottom) {
                            self.pageIndicator(compact: metrics.compact)
                                .padding(.bottom, metrics.compact ? 16 : 22)
                        }
                }
                .padding(.leading, metrics.leading)
                .padding(.trailing, metrics.trailing)
                .padding(.vertical, metrics.vertical)
                .frame(width: size.width, height: size.height)

                // The one mark on the page, and the finish flight's origin.
                // It leaves with the flight, exactly like Welcome's pair.
                if !self.stage.markInFlight {
                    self.pageMark(in: size)
                }
            }
            .animation(.easeOut(duration: 0.18), value: self.stage.markInFlight)
        }
        .foregroundStyle(OnboardingTheme.ink)
        .animation(OnboardingStage.stepAnimation, value: self.stage.step)
    }

    // MARK: Private

    @ObservedObject private var stage = OnboardingStage.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func pageMark(in size: CGSize) -> some View {
        let rect = OnboardingChapterLayout.markRect(in: size)
        return Group {
            if let mark = OtoMarkSource.cropped {
                // The asset is white bars; as a template it takes the stage's
                // ink, so it reads on a dark field and on paper alike.
                Image(nsImage: mark)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .foregroundStyle(OnboardingTheme.ink)
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .accessibilityHidden(true)
    }

    /// The page's place in the walk: one pill per chapter, the current one
    /// longer. Tapping one goes there — the same jump the old dashes allowed.
    private func pageIndicator(compact: Bool) -> some View {
        let steps = OnboardingStage.Step.chapters
        return HStack(spacing: compact ? 5 : 7) {
            ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                let current = step == self.stage.step
                Button {
                    self.flow.jump(to: step)
                } label: {
                    Capsule(style: .continuous)
                        .fill(OnboardingTheme.ink.opacity(current ? 0.82 : 0.22))
                        .frame(
                            width: current ? (compact ? 18 : 24) : (compact ? 5 : 6),
                            height: 4
                        )
                        .frame(height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Step \(index + 1) of \(steps.count)")
                .accessibilityAddTraits(current ? .isSelected : [])
            }
        }
        .animation(.spring(duration: 0.34, bounce: 0), value: self.stage.step)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Onboarding progress")
    }

    /// The chapter's frame on the right: a quiet, empty surface. The walk
    /// shows no pictures.
    private func media(corner: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [OnboardingTheme.mediaTop, OnboardingTheme.mediaBottom],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
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
}

/// A chapter's mark: an SF Symbol beside its tag, on the quiet pill above
/// the title.
struct OnboardingGlyph: View {
    let name: String
    var size: CGFloat

    var body: some View {
        Image(systemName: self.name)
            .font(.system(size: self.size * 0.9, weight: .medium))
            .frame(width: self.size, height: self.size)
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
