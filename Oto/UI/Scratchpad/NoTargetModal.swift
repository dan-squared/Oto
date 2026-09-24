//
//  NoTargetModal.swift
//  Oto
//
//  Slice 6C1: the "dictated with nowhere to paste" catcher. Display-only
//  (the references show transcript + Copy, no editor — editing stays
//  6C2-if-wanted). Nonactivating panel, never steals focus: the taught
//  flow is click-a-textbox → ⌘V, which breaks if this surface takes key
//  status. Copy never dismisses (the user may need to find a textbox
//  first); ✕ closes the view only — text survives in recovery + history.
//

import AppKit
import os
import QuartzCore
import SwiftUI

/// Kill-switch setting. Default ON (the modal is the discovery path for
/// the #1 new-user dead end); OFF → auto-copy path. Absent key means ON
/// so a fresh install teaches the flow.
enum NoTargetModalSettings {
    nonisolated static let key = "app.Oto.noTargetModal"

    nonisolated static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }
}

/// Display clamp: at most 100 words, suffixed when cut. Data never
/// truncates — recovery, clipboard, and history always keep the full
/// transcript; this shapes pixels only.
enum CatcherText: Sendable {
    nonisolated static let wordLimit = 100

    nonisolated static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    nonisolated static func isOverLimit(_ text: String) -> Bool {
        wordCount(text) > wordLimit
    }

    nonisolated static func displayWords(_ text: String, limit: Int = wordLimit) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > limit else { return text }
        return words.prefix(limit).joined(separator: " ") + "…"
    }

    /// Pill-sized display for over-limit transcripts: leading words
    /// greedily filled to fit, suffixed with Copied. Single line that
    /// never overflows the current pill width — the switch from dictation
    /// visuals is a re-render, never a resize. Pure + unit-tested.
    nonisolated static func pillWords(
        _ text: String,
        maxWidth: CGFloat = 76,
        fontSize: CGFloat = 11
    ) -> String {
        let font = NSFont.systemFont(ofSize: fontSize)
        func fits(_ s: String) -> Bool {
            (s as NSString).boundingRect(
                with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin],
                attributes: [.font: font]
            ).width <= maxWidth
        }
        let suffix = "… Copied"
        guard fits(suffix) else { return "Copied" }
        var words: [String] = []
        for word in text.split(whereSeparator: \.isWhitespace) {
            let candidate = (words + [String(word)]).joined(separator: " ") + suffix
            guard fits(candidate) else { break }
            words.append(String(word))
        }
        guard !words.isEmpty else { return "Copied" }
        return words.joined(separator: " ") + suffix
    }
}

/// Card geometry: fixed 464pt width, computed height. Pure + unit-tested;
/// the controller supplies the screen-clamped max.
enum CatcherLayout: Sendable {
    /// Horizontal chrome: card padding both sides. The X zone reserve
    /// keeps first lines clear of the overlaid dismiss control.
    nonisolated static let cardPadding: CGFloat = 20
    nonisolated static let xZoneReserve: CGFloat = 56
    /// Vertical chrome: top pad + text top + text→button gap + button
    /// row + bottom pad. Matches the view below by construction.
    nonisolated static let chromeHeight: CGFloat = 20 + 18 + 18 + 44 + 20
    /// SwiftUI `.title3` point size backing the transcript Text.
    nonisolated static let textPointSize: CGFloat = 20

    nonisolated static func textWidth(cardWidth: CGFloat) -> CGFloat {
        cardWidth - 2 * cardPadding - xZoneReserve
    }

    nonisolated static func textHeight(for text: String, cardWidth: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: textPointSize)
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: textWidth(cardWidth: cardWidth), height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return ceil(rect.height)
    }

    /// Total card height for display text, clamped to [minHeight, maxHeight].
    nonisolated static func height(for text: String, cardWidth: CGFloat, minHeight: CGFloat, maxHeight: CGFloat) -> CGFloat {
        min(max(minHeight, chromeHeight + textHeight(for: text, cardWidth: cardWidth)), maxHeight)
    }
}

@Observable @MainActor
final class NoTargetModalController {
    nonisolated static let width: CGFloat = 464
    nonisolated static let height: CGFloat = 168
    nonisolated static let cornerRadius: CGFloat = 22
    /// Morph gesture length (v6): 0.18s easeOut, matching the modal's
    /// original show timing and the motion family. The matrix judges
    /// fast-vs-laggy; retune is duration-only, never a redesign.
    nonisolated static let morphDuration = 0.18

    private(set) var text = ""
    private(set) var copied = false
    /// Live card height for the SwiftUI view frame. Set on every show
    /// BEFORE refreshContent, so content and panel never disagree (a stale
    /// fixed frame compresses text into default truncation — the dots bug
    /// class). Starts at the minimum.
    private(set) var cardHeight: CGFloat = height
    /// Build-identity + geometry trail: every catcher appearance logs
    /// words, size, and mode, so a screenshot without a matching line is
    /// stale by construction (never chase ghosts again).
    private let log = Logger(subsystem: "app.Oto", category: "catcher")
    private var panel: NSPanel?
    private var hosting: NSHostingView<NoTargetModalView>?
    /// Morph generation: a re-fired route supersedes a mid-morph one
    /// (pill-melt cancel precedent).
    private var morphGeneration = 0
    /// Internal for tests: prewarm stability.
    var hasPanel: Bool { panel != nil }
    /// Internal for tests: the focus-steal defense pin (nonactivating
    /// recipe retained through the v4 reflow).
    var isNonactivating: Bool { panel?.styleMask.contains(.nonactivatingPanel) ?? false }

    /// Build panel + hosting once, off the transition path (v4 F3b).
    /// Never orders front — pure construction cost moved to launch.
    /// Uses the hosting recipe (v6 stroke kill — AppKit never forces
    /// hosting layers).
    func prewarm() {
        if panel == nil {
            log.info("catcher ready (dynamic height, 100-word cap)")
            let hosting = NSHostingView(rootView: NoTargetModalView(controller: self))
            self.hosting = hosting
            panel = FlowBarPanel.makeHostingPanel(
                contentView: hosting,
                size: NSSize(width: Self.width, height: Self.height)
            )
        }
    }

    /// Swap content + clear any layer background SwiftUI resolved on its
    /// own (v6 variant A — clear only what EXISTS, never force-create).
    private func refreshContent() {
        hosting?.rootView = NoTargetModalView(controller: self)
        if let layer = hosting?.layer {
            layer.backgroundColor = NSColor.clear.cgColor
        }
    }

    func show(
        text: String,
        displayID: CGDirectDisplayID?,
        reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    ) {
        self.text = CatcherText.displayWords(text)
        copied = false
        // Invalidate any pending auto-close: a re-show owns a fresh second.
        copyGeneration += 1
        prewarm()
        refreshContent()
        guard let (screen, _) = FlowBarPanel.resolveScreen(displayID: displayID) else { return }
        let visible = screen.visibleFrame
        let height = cardHeight(for: self.text, visible: visible)
        log.info("catcher show words=\(CatcherText.wordCount(text)) display=\(CatcherText.wordCount(self.text)) size=\(Int(Self.width))x\(Int(height))")
        self.cardHeight = height
        let endFrame = NSRect(
            x: visible.midX - Self.width / 2,
            y: visible.midY - height / 2,
            width: Self.width, height: height
        )
        // Soft land (v4 F3): start 3% small + transparent, ease out to
        // full in 0.18s. Quick (no travel, no bounce) yet buttery.
        let startFrame = NSRect(
            x: endFrame.midX - endFrame.width * 0.485,
            y: endFrame.midY - endFrame.height * 0.485,
            width: endFrame.width * 0.97, height: endFrame.height * 0.97
        )
        panel?.setFrame(startFrame, display: false)
        panel?.alphaValue = 0
        // orderFront, never key: focus must stay wherever the user had it.
        panel?.orderFront(nil)
        scheduleContentMask(size: NSSize(width: Self.width, height: height))
        guard !reduceMotion else {
            panel?.setFrame(endFrame, display: true)
            panel?.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel?.animator().setFrame(endFrame, display: true)
            panel?.animator().alphaValue = 1
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Grow out of the live pill frame IN PLACE at its slot (v6 morph).
    /// Same x as the pill (both centered): top slot grows downward from
    /// the pill's top edge, bottom slot upward from its bottom edge —
    /// zero travel, so it reads as one surface becoming the other. One
    /// 0.18s easeOut animator gesture while the pill runs its existing
    /// melt in parallel. Falls back to plain `show` when geometry is
    /// unavailable; instant under Reduce Motion (same gate as the pill).
    /// Snapshot and orderFront are adjacent MainActor statements (no
    /// suspension between), so the origin race cannot interleave.
    func showFromPill(
        pillFrame: NSRect,
        text: String,
        displayID: CGDirectDisplayID?,
        position: FlowBarPosition = FlowBarPosition.current(),
        reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    ) {
        self.text = CatcherText.displayWords(text)
        copied = false
        // Invalidate any pending auto-close: a re-show owns a fresh second.
        copyGeneration += 1
        prewarm()
        refreshContent()
        guard let (screen, _) = FlowBarPanel.resolveScreen(displayID: displayID) else {
            show(text: text, displayID: displayID, reduceMotion: reduceMotion)
            return
        }
        let height = cardHeight(for: self.text, visible: screen.visibleFrame)
        log.info("catcher show words=\(CatcherText.wordCount(text)) display=\(CatcherText.wordCount(self.text)) size=\(Int(Self.width))x\(Int(height))")
        self.cardHeight = height
        let endFrame = Self.morphEndFrameAtSlot(visible: screen.visibleFrame, position: position, height: height)
        morphGeneration += 1
        let generation = morphGeneration
        panel?.setFrame(pillFrame, display: false)
        panel?.alphaValue = 0
        // orderFront, never key: the catcher never steals focus (v4 keeps
        // the 6C1 load-bearing call — editing lives in the optional
        // scratchpad, never here).
        panel?.orderFront(nil)
        scheduleContentMask(size: NSSize(width: Self.width, height: height))
        guard !reduceMotion else {
            panel?.setFrame(endFrame, display: true)
            panel?.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.morphDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel?.animator().setFrame(endFrame, display: true)
            panel?.animator().alphaValue = 1
        }, completionHandler: {
            guard generation == self.morphGeneration else { return }
        })
    }

    /// Card height for display text on a screen: fixed width, measured
    /// text, clamped to a screen fraction so tiny displays never overflow.
    private func cardHeight(for display: String, visible: NSRect) -> CGFloat {
        CatcherLayout.height(
            for: display,
            cardWidth: Self.width,
            minHeight: Self.height,
            maxHeight: max(visible.height * 0.6, Self.height)
        )
    }

    /// Rounded-rect mask path for the hosting layer (v6 variant B):
    /// clips EVERYTHING SwiftUI paints — including any opaque root
    /// background it resolves on render — to the card silhouette.
    /// Sized per show (heights vary now): pass the live card size.
    /// Pure geometry, unit-tested.
    nonisolated static func contentMaskPath(size: CGSize) -> CGPath {
        CGPath(
            roundedRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil
        )
    }

    /// Apply the content mask on the next tick: the hosting layer is
    /// created by SwiftUI at first display, so masking must run AFTER
    /// orderFront — clearing at prewarm is a silent no-op on a nil
    /// layer (why variant A failed). Retries twice when the layer
    /// isn't ready yet (audit: single-shot scheduling never recovers);
    /// skips when the installed mask already matches this size.
    /// Idempotent.
    private var lastMaskSize: CGSize?
    private func scheduleContentMask(size: CGSize, attempts: Int = 3) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let layer = self.hosting?.layer else {
                if attempts > 1 {
                    self.scheduleContentMask(size: size, attempts: attempts - 1)
                } else {
                    self.log.error("catcher mask skipped (no hosting layer)")
                }
                return
            }
            guard self.lastMaskSize != size else { return }
            let mask = CAShapeLayer()
            mask.path = Self.contentMaskPath(size: size)
            layer.mask = mask
            self.lastMaskSize = size
            self.log.debug("catcher mask installed \(Int(size.width))x\(Int(size.height))")
        }
    }
    /// Slot-anchored card (v6): the pill's own slot helper with card
    /// dimensions — same margins, clamp, and centering as the pill, so x
    /// matches exactly and growth is purely vertical. Width FLOOR at full
    /// card size (audit F1): a squeezed frame amputates the trailing Copy
    /// button silently; edge overflow on tiny screens is explicit and
    /// visible instead. Height comes from measured text (v8: grows away
    /// from the pill edge — top grows down, bottom grows up); the guard
    /// below only shrinks pathological frames, keeping the slot edge.
    /// Pure geometry, unit-tested.
    nonisolated static func morphEndFrameAtSlot(visible: NSRect, position: FlowBarPosition, height: CGFloat) -> NSRect {
        var frame = FlowBarPosition.frame(width: Self.width, height: height, on: visible, position: position)
        if frame.width < Self.width {
            frame.size.width = Self.width
            frame.origin.x = visible.midX - Self.width / 2
        }
        if frame.height > visible.height {
            frame.size.height = visible.height
            if position == .top { frame.origin.y = visible.maxY - visible.height }
        }
        // Pathological rooms: X overflow stays explicit (audit F1), but a
        // card must never park itself off-screen vertically — clamp into
        // visible, slot edge preferred, visibility required.
        if frame.maxY > visible.maxY {
            frame.origin.y = visible.maxY - frame.height
        }
        if frame.minY < visible.minY {
            frame.origin.y = visible.minY
        }
        return frame
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Manual Copy primitive (same pasteboard discipline as history Copy).
    /// Shows Copied for 1s, then auto-closes: the user pressed Copy
    /// because the transcript is going somewhere now. Generation-guarded
    /// (audit): a second Copy (or a re-show) inside the window restarts
    /// the close instead of double-hiding or stranding Copied lit.
    private var copyGeneration = 0
    func copy(pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copied = true
        copyGeneration += 1
        let generation = copyGeneration
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, generation == self.copyGeneration else { return }
            self.copied = false
            self.hide()
        }
    }
}

/// ✕ press/hover response (v7: bouncy on click ONLY, never resize on
/// hover). Hover brightens dim→ink (0.12s easeOut); click squishes to
/// 0.88 on a quick spring with one visible rebound, then back.
struct CatcherXStyle: ButtonStyle {
    var base: Color
    var hover: Color
    var hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering ? hover : base)
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(
                .spring(response: 0.22, dampingFraction: 0.5),
                value: configuration.isPressed
            )
    }
}

/// Copy press/hover response (v7): rest pixels identical to the system
/// `.bordered` gray button — only motion is custom. Hover squishes to
/// 0.97 (springs back on leave), click to 0.92 with one rebound.
/// Disabled ("Copied") passes through with the same look.
struct CatcherCopyStyle: ButtonStyle {
    var background: Color
    var hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(background.opacity(configuration.isPressed ? 1.0 : 0.9), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.92 : hovering ? 0.97 : 1.0)
            .animation(
                .spring(response: 0.28, dampingFraction: 0.55),
                value: hovering
            )
            .animation(
                .spring(response: 0.28, dampingFraction: 0.55),
                value: configuration.isPressed
            )
    }
}

struct NoTargetModalView: View {
    let controller: NoTargetModalController
    @Environment(\.colorScheme) private var scheme
    /// ✕ hover state (v7: brighten only — never resize on hover).
    @State private var xHovering = false
    /// Copy hover state (v7: subtle spring squish, bounces back).
    @State private var copyHovering = false

    var body: some View {
        // v4 minimal surface (reference minus logo/hint/circled-X):
        // plain ✕ overlaid top-trailing (never consumes layout — the
        // transcript + Copy own the full 464×168), dictated words,
        // Copy. Everything renders through the adaptive palette.
        let palette = CatcherPalette.current(scheme)
        ZStack(alignment: .topTrailing) {
            ZStack {
                // Explicit clear root: the hosting view must paint nothing
                // behind the card (the pill's v2 frame bug class — never again).
                Color.clear
                RoundedRectangle(cornerRadius: NoTargetModalController.cornerRadius)
                    .fill(palette.card)
                    .shadow(color: .black.opacity(palette.shadowOpacity), radius: 22, y: 6)
                VStack(alignment: .leading, spacing: 0) {
                    Text(controller.text)
                        .font(.title3)
                        .foregroundStyle(palette.transcript)
                        .padding(.top, 18)
                        .padding(.trailing, CatcherLayout.xZoneReserve)
                    Spacer(minLength: 0)
                    HStack {
                        Spacer()
                        Button(controller.copied ? "Copied" : "Copy") {
                            controller.copy()
                        }
                        .buttonStyle(CatcherCopyStyle(
                            background: palette.copyBackground,
                            hovering: copyHovering && !controller.copied
                        ))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .onHover { copyHovering = $0 }
                        .disabled(controller.copied)
                    }
                    .padding(.top, 18)
                }
                .padding(20)
            }
            Button { controller.hide() } label: {
                Image(systemName: "xmark")
                    .font(.title3)
            }
            .buttonStyle(CatcherXStyle(base: palette.dim, hover: palette.ink, hovering: xHovering))
            .accessibilityLabel("Dismiss")
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Circle().inset(by: -10))
            .onHover { xHovering = $0 }
            .padding(16)
        }
        .frame(
            width: NoTargetModalController.width,
            height: controller.cardHeight
        )
        // Belt-and-braces with the layer mask: content can never paint
        // outside the card even if a mask install ever lags a resize.
        .clipShape(RoundedRectangle(cornerRadius: NoTargetModalController.cornerRadius))
    }
}
