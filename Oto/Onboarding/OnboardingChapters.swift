//
//  OnboardingChapters.swift
//  Oto
//
//  The frame every chapter shares, under the header that never moves: words
//  on the left, the thing itself on the right, and one footer that stays put
//  from the first chapter to the last. Ported from Firstlight — only what
//  differs between two chapters leaves and arrives, and it leaves sideways,
//  so the frame turns like a page rather than scrolling.
//

import SwiftUI

/// What a chapter says on its left: a tag, a title, a line, and — where the
/// chapter shows rather than asks — the rows its right side walks through.
struct OnboardingChapterCopy {
    struct Row: Identifiable {
        let symbol: String
        let title: String
        let detail: String

        var id: String { self.title }
    }

    let tag: String
    let symbol: String
    let title: String
    let subtitle: String
    var rows: [Row] = []

    static func copy(for step: OnboardingStage.Step) -> OnboardingChapterCopy? {
        switch step {
        case .how:
            .init(
                tag: "What Oto does", symbol: "waveform", title: "Speak. It lands.",
                subtitle: "Oto turns your voice into text in whatever app you're in.",
                rows: [
                    .init(
                        symbol: "keyboard", title: "Push to talk",
                        detail: "Hold your key for quick bursts. Release, and the words land where you type."
                    ),
                    .init(
                        symbol: "hand.tap", title: "Hands-free",
                        detail: "Double-tap the same key for long talks. Press again to stop."
                    ),
                    .init(
                        symbol: "tray.full", title: "Never lose words",
                        detail: "No text field? The catcher keeps the transcript — one click to copy."
                    ),
                ]
            )
        case .shortcut:
            .init(
                tag: "Your key", symbol: "keyboard", title: "Hold to talk",
                subtitle: "Hold this key while you talk — or click the field and press a new one."
            )
        case .permissions:
            .init(
                tag: "Permissions", symbol: "lock.shield", title: "Three grants",
                subtitle: "Oto asks only when needed — here and now."
            )
        case .speech:
            .init(
                tag: "Speech", symbol: "arrow.down.circle", title: "Works offline",
                subtitle: "One download, and your words never leave this Mac."
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

/// The frame every chapter shares: words on the left, the thing itself on the
/// right, and one footer that stays put from the first chapter to the last.
struct OnboardingChaptersView: View {
    @ObservedObject var flow: OnboardingFlow

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let compact = size.width < 900 || size.height < 600
            let margin: CGFloat = compact ? 52 : 88
            let gap: CGFloat = compact ? 24 : 48
            let left: CGFloat = compact ? 250 : 340
            let step = self.stage.step
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: gap) {
                    ZStack(alignment: .topLeading) {
                        if let copy = OnboardingChapterCopy.copy(for: step) {
                            self.words(copy, step: step, compact: compact)
                                .id(step)
                                .transition(self.stage.turn(reduceMotion: self.reduceMotion))
                        }
                    }
                    .frame(width: left, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: step.rows > 0 ? .top : .center)

                    ZStack {
                        // Replaced where it stands, not turned with the words:
                        // the recorder and the cards are things being used,
                        // and a thing in use does not go by.
                        self.thing(for: step)
                            .id(step)
                            .transition(self.reduceMotion ? .opacity : self.stage.replacing)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.top, compact ? 84 : 100)
                .padding(.horizontal, margin)
                .padding(.bottom, 12)

                self.footer
                    .padding(.horizontal, margin - 16)
                    .padding(.bottom, compact ? 20 : 28)
            }
            .frame(width: size.width, height: size.height)
        }
        .foregroundStyle(.white)
        .animation(OnboardingStage.stepAnimation, value: self.stage.step)
    }

    // MARK: Private

    @ObservedObject private var stage = OnboardingStage.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var footer: some View {
        HStack(spacing: 14) {
            OnboardingGlassCircleButton(symbol: "chevron.left", action: self.flow.back)
                .opacity(self.flow.canGoBack ? 1 : 0)
                .disabled(!self.flow.canGoBack)
                .keyboardShortcut("[", modifiers: .command)
                .accessibilityLabel("Back")

            OnboardingProgressDashes(step: self.stage.step, row: self.stage.row, dwell: self.stage.dwell) {
                self.flow.jump(to: $0)
            }

            Spacer(minLength: 12)

            OnboardingContinueButton(title: self.flow.buttonTitle, action: self.flow.next)
        }
    }

    private func words(_ copy: OnboardingChapterCopy, step: OnboardingStage.Step, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                OnboardingGlyph(name: copy.symbol, size: 13)
                Text(copy.tag).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10).frame(height: 24)
            .foregroundStyle(copy.rows.isEmpty ? Color.white.opacity(0.7) : Color.white)
            .background(
                copy.rows.isEmpty ? Color.white.opacity(0.08) : Color.white.opacity(0.16),
                in: Capsule()
            )
            Text(copy.title)
                .font(.system(size: compact ? 30 : 40, weight: .medium))
                .tracking(-1.0)
                .lineSpacing(-2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
                .accessibilityAddTraits(.isHeader)
            Text(copy.subtitle)
                .font(.system(size: compact ? 14 : 15))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            if !copy.rows.isEmpty {
                OnboardingChapterRows(
                    rows: copy.rows, open: self.stage.row,
                    // A list is read at a glance; a form takes a moment.
                    dwell: 5,
                    onOpen: { self.stage.open(row: $0) },
                    onElapsed: {
                        // The outgoing chapter stays mounted while it fades.
                        // Its last dwell must not advance a row in the new one.
                        guard self.stage.step == step else { return }
                        // The clock opens the next row and stops at the last:
                        // leaving a chapter is the reader's decision.
                        if self.stage.row < copy.rows.count - 1 { self.stage.open(row: self.stage.row + 1) }
                    }
                )
                .padding(.top, 18)
                .padding(.leading, -12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func thing(for step: OnboardingStage.Step) -> some View {
        switch step {
        case .how:
            OnboardingFlowBarPreview(row: self.stage.row)
        case .shortcut:
            OnboardingShortcutPlate(flow: self.flow)
        case .permissions:
            OnboardingPermissionsPlate(flow: self.flow)
        case .speech:
            OnboardingSpeechPlate(flow: self.flow)
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

/// One dash per chapter. The current one is longer, and a chapter with rows
/// fills its dash as its rows are read: each row's share fills over the time
/// the row stays open, so the dash is the clock.
struct OnboardingProgressDashes: View {
    let step: OnboardingStage.Step
    let row: Int
    /// How far the open row's dwell has run, 0 to 1.
    var dwell: CGFloat = 1
    var onSelect: (OnboardingStage.Step) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(OnboardingStage.Step.chapters, id: \.self) { chapter in
                let current = chapter == self.step
                let width: CGFloat = current ? (chapter.rows > 0 ? 42 : 28) : 12
                let share: CGFloat = chapter < self.step ? 1 : !current ? 0 :
                    chapter.rows > 0 ? (CGFloat(self.row) + self.dwell) / CGFloat(chapter.rows) : 1
                Capsule().fill(.white.opacity(0.18))
                    .frame(width: width, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.92)).frame(width: width * share, height: 4)
                    }
                    .clipShape(Capsule())
                    .contentShape(Rectangle().inset(by: -6))
                    .onTapGesture { self.onSelect(chapter) }
            }
        }
        .animation(OnboardingStage.stepAnimation, value: self.step)
        .animation(OnboardingStage.stepAnimation, value: self.row)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Step \((OnboardingStage.Step.chapters.firstIndex(of: self.step) ?? 0) + 1) of \(OnboardingStage.Step.chapters.count)"
        )
    }
}

/// The rows of a showing chapter. One is open; its surface is a single shape
/// that travels between the rows rather than one drawn per row. A clock opens
/// the next row; the pointer over the rows holds it.
struct OnboardingChapterRows: View {
    let rows: [OnboardingChapterCopy.Row]
    let open: Int
    /// How long a row stays open before the clock opens the next.
    var dwell: Double = 5
    var onOpen: (Int) -> Void
    var onElapsed: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(self.rows.enumerated()), id: \.element.id) { index, row in
                let isOpen = index == self.open
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 10) {
                        OnboardingGlyph(name: row.symbol, size: 18)
                            .foregroundStyle(Color.white.opacity(0.8))
                            .frame(width: 20)
                        Text(row.title).font(.system(size: 14, weight: .medium))
                    }
                    if isOpen {
                        Text(row.detail)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 30)
                            .transition(.opacity.combined(with: .offset(y: -4)))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if isOpen {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.white.opacity(0.07))
                            .matchedGeometryEffect(id: "open", in: self.surface)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { self.onOpen(index) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(isOpen ? [.isButton, .isSelected] : .isButton)
            }
        }
        .onHover { self.hovering = $0 }
        .onChange(of: self.open, initial: true) { self.restart() }
        .onChange(of: self.hovering) { _, held in held ? self.hold() : self.resume() }
        .onDisappear { self.clock?.cancel() }
    }

    @Namespace private var surface
    @ObservedObject private var stage = OnboardingStage.shared
    @State private var hovering = false
    /// How much of the dwell had passed when the clock last started.
    @State private var banked: Double = 0
    @State private var startedAt = Date()
    @State private var clock: Task<Void, Never>?

    private func restart() {
        self.banked = 0
        self.set(progress: 0)
        if !self.hovering { self.resume() }
    }

    private func hold() {
        self.clock?.cancel()
        self.banked = min(self.dwell, self.banked + Date().timeIntervalSince(self.startedAt))
        self.set(progress: self.banked / self.dwell)
    }

    /// The last row runs its clock too, so the dash fills to the end as it is
    /// read; whether anything opens after it is the caller's to say.
    private func resume() {
        self.clock?.cancel()
        let left = max(self.dwell - self.banked, 0)
        self.startedAt = Date()
        withAnimation(.linear(duration: left)) { self.stage.dwell = 1 }
        self.clock = Task {
            try? await Task.sleep(for: .seconds(left))
            guard !Task.isCancelled else { return }
            self.onElapsed()
        }
    }

    /// Without an animation, which also stops the one in flight where it is.
    private func set(progress: Double) {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { self.stage.dwell = progress }
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
                    .fill(.white.opacity(0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            )
    }
}

/// A quiet plate the popover stands on, scaled down only when the window is
/// too small to hold it.
struct OnboardingPreviewPlate<Content: View>: View {
    var width: CGFloat = 380
    var height: CGFloat = 300
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let scale = min(1, (proxy.size.width - 32) / self.width, (proxy.size.height - 32) / self.height)
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.04))
                self.content()
                    .frame(width: self.width, height: self.height)
                    .scaleEffect(max(scale, 0.5))
            }
        }
    }
}
