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

/// Display clamp: at most 50 words, suffixed when cut. Data never
/// truncates — recovery, clipboard, and history always keep the full
/// transcript; this shapes pixels only.
enum CatcherText: Sendable {
    nonisolated static let wordLimit = 50

    nonisolated static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    nonisolated static func isOverLimit(_ text: String) -> Bool {
        wordCount(text) > wordLimit
    }

    /// The over-limit pill latch: exactly this word, centered, padded.
    /// Long transcripts never reach pill pixels — recovery owns them.
    nonisolated static let overLimitMessage = "Copied"

    nonisolated static func displayWords(_ text: String, limit: Int = wordLimit) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > limit else { return text }
        return words.prefix(limit).joined(separator: " ") + "…"
    }
}

/// Card geometry: fixed 464pt width, computed height. Pure + unit-tested;
/// the controller supplies the screen-clamped max.
enum CatcherLayout: Sendable {
    /// Horizontal chrome: card padding both sides. No dismiss row exists
    /// (v6: Cancel lives in the footer), so no trailing reserve is needed
    /// and all three right edges align.
    nonisolated static let cardPadding: CGFloat = 20
    /// Text bottom → button top.
    nonisolated static let textToActionsGap: CGFloat = 18
    /// The footer's action row. It was 52 while `OtoPill(large:)` was a
    /// 24 pt `.regular` button: the extra 28 pt of slack pushed the row up
    /// and left ~33 pt under it against 20 pt at the sides (user, 2026-11-01:
    /// "the copying cancel buttons are a bit upward … make them …
    /// concentric with the edge of the catcher"). The row is now exactly the
    /// button height, so the bottom inset equals the side inset.
    /// 28 is the measured `.large` bordered/prominent fitting height
    /// (macOS 27, `NSHostingView.fittingSize`: regular 24 → large 28).
    nonisolated static let actionRowHeight: CGFloat = 28
    /// Vertical chrome: top pad + text→button gap + button row + bottom
    /// pad. Matches the view below by construction.
    nonisolated static let chromeHeight: CGFloat =
        cardPadding + textToActionsGap + actionRowHeight + cardPadding
    /// The Dynamic Type title3 SwiftUI renders — same system, no guessing.
    /// (A hardcoded size here caused the gap bug: measured tall, rendered
    /// short, Spacer ate the difference.)
    nonisolated static func transcriptFont() -> NSFont {
        NSFont.preferredFont(forTextStyle: .title3, options: [:])
    }

    nonisolated static func textWidth(cardWidth: CGFloat) -> CGFloat {
        cardWidth - 2 * cardPadding
    }

    nonisolated static func textHeight(for text: String, cardWidth: CGFloat) -> CGFloat {
        let font = Self.transcriptFont()
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
    /// Morph length (plan/catcher-morph-parity.md): the reference's own
    /// 420 ms, not a rounded 0.4 — the curve's tail (last 3 % of travel
    /// between 51.6 % and 67.3 % of the time) is where the "settles like
    /// liquid" read comes from, and cutting it short turns the same curve
    /// into a snap. Duration-only knob, by design.
    nonisolated static let morphDuration = 0.42
    /// The card's content fades in one beat into the morph, not at t=0:
    /// the reference holds a bare surface while the shape opens, so the eye
    /// tracks ONE continuous edge instead of two crossfading ones.
    nonisolated static let contentFadeDelay = 0.10
    nonisolated static let contentFadeDuration = 0.18

    private(set) var text = ""
    /// Full transcript behind the display-capped `text` above. Copy
    /// pastes this (never the capped string) — the card pixels stay
    /// capped, recovery never truncates.
    private(set) var fullText = ""
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
    private var surface: CatcherSurfaceView?
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
    /// The panel's content is the morph surface (masked card fill), with
    /// the SwiftUI card hosted inside it.
    func prewarm() {
        if panel == nil {
            log.info("catcher ready words=\(CatcherText.wordLimit) dynamic-height")
            let surface = CatcherSurfaceView(
                frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height)
            )
            surface.setCardColor(currentPalette.cardColor)
            let hosting = NSHostingView(rootView: NoTargetModalView(controller: self))
            surface.setContent(hosting)
            self.surface = surface
            self.hosting = hosting
            panel = FlowBarPanel.makeHostingPanel(
                contentView: surface,
                size: NSSize(width: Self.width, height: Self.height)
            )
        }
    }

    /// Card palette for the surface's fill: follows the *effective*
    /// appearance (the surface has no SwiftUI environment to read).
    private var currentPalette: CatcherPalette {
        CatcherPalette.current(NSApp.effectiveAppearance)
    }

    /// Swap content + clear any layer background SwiftUI resolved on its
    /// own (v6 variant A — clear only what EXISTS, never force-create).
    private func refreshContent() {
        hosting?.rootView = NoTargetModalView(controller: self)
        if let layer = hosting?.layer {
            layer.backgroundColor = NSColor.clear.cgColor
        }
    }

    /// Stores a transcript for display AND recovery: `text` stays the
    /// capped pixels (card height, logs), `fullText` keeps everything for
    /// Copy. Both entry points (`show`, `showFromPill`) funnel here so the
    /// morph path can never stay lossy while the plain path is fixed.
    private func store(_ text: String) {
        fullText = text
        self.text = CatcherText.displayWords(text)
    }

    func show(
        text: String,
        displayID: CGDirectDisplayID?,
        reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    ) {
        store(text)
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
        // A re-show supersedes any in-flight morph (its mask + task are
        // stale); the mask itself is reset below, before anything is shown.
        morphGeneration += 1
        surface?.setCardColor(currentPalette.cardColor)
        panel?.ignoresMouseEvents = false
        panel?.setFrame(startFrame, display: false)
        // Settled mask for the frame we are about to show: full card (it
        // tracks the 97 % → 100 % frame glide via layout()).
        surface?.showStatic(cardRadius: Self.cornerRadius)
        panel?.alphaValue = 0
        // orderFront, never key: focus must stay wherever the user had it.
        panel?.orderFront(nil)
        guard !reduceMotion else {
            panel?.setFrame(endFrame, display: true)
            panel?.alphaValue = 1
            surface?.showStatic(cardRadius: Self.cornerRadius)
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
        morphGeneration += 1
        panel?.ignoresMouseEvents = false
        panel?.orderOut(nil)
    }

    /// Grow out of the live pill frame IN PLACE at its slot.
    ///
    /// The panel jumps straight to its FINAL frame and never resizes; the
    /// only thing that moves is the surface's mask (see CatcherSurfaceView).
    /// That is the reference's recipe, and it is what fixes the old
    /// version's square-cornered sliver: window geometry can no longer race
    /// the mask, because the window's geometry is already final. The pill
    /// runs its own melt in parallel, so the two surfaces trade silhouettes
    /// at the same slot edge with no travel.
    ///
    /// Falls back to plain `show` when geometry is unavailable; instant
    /// under Reduce Motion (same gate as the pill).
    func showFromPill(
        pillFrame: NSRect,
        text: String,
        displayID: CGDirectDisplayID?,
        position: FlowBarPosition = FlowBarPosition.current(),
        reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    ) {
        store(text)
        copied = false
        // Invalidate any pending auto-close: a re-show owns a fresh second.
        copyGeneration += 1
        prewarm()
        refreshContent()
        guard let (screen, _) = FlowBarPanel.resolveScreen(displayID: displayID) else {
            show(text: text, displayID: displayID, reduceMotion: reduceMotion)
            return
        }
        guard let panel, let surface else {
            show(text: text, displayID: displayID, reduceMotion: reduceMotion)
            return
        }
        let height = cardHeight(for: self.text, visible: screen.visibleFrame)
        log.info("catcher morph words=\(CatcherText.wordCount(text)) display=\(CatcherText.wordCount(self.text)) size=\(Int(Self.width))x\(Int(height)) slot=\(position.rawValue)")
        self.cardHeight = height
        let endFrame = Self.morphEndFrameAtSlot(visible: screen.visibleFrame, position: position, height: height)
        morphGeneration += 1
        let generation = morphGeneration

        surface.setCardColor(currentPalette.cardColor)
        // Final frame FIRST: everything below is relative to it, and a
        // window that is already the card means the surface never resizes
        // mid-flight — the content is laid out once, at its final size,
        // exactly like the reference (which animates one element, not the
        // page).
        panel.setFrame(endFrame, display: false)
        panel.alphaValue = 1
        // The pill's rect in the surface's coordinates: the panel's origin
        // is the card's bottom-left, so a top-slot pill lands at the top.
        let localPill = NSRect(
            x: pillFrame.minX - endFrame.minX,
            y: pillFrame.minY - endFrame.minY,
            width: pillFrame.width, height: pillFrame.height
        )
        surface.beginMorph(from: localPill, position: position)
        // The shape opens before the words arrive (the reference fades its
        // content in ~100 ms into the morph). Under Reduce Motion the card
        // is simply there on the first frame.
        surface.setContentAlpha(reduceMotion ? 1 : 0)
        // Card-sized window, capsule-sized surface: without this the first
        // ~300 ms of the morph would swallow clicks in dead corners the
        // user cannot see yet.
        panel.ignoresMouseEvents = true
        // orderFront, never key: the catcher never steals focus (v4 keeps
        // the 6C1 load-bearing call — editing lives in the optional
        // scratchpad, never here).
        panel.orderFront(nil)

        guard !reduceMotion else {
            surface.finishMorph()
            surface.setContentAlpha(1)
            panel.ignoresMouseEvents = false
            return
        }

        surface.animateMorph(duration: Self.morphDuration)

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(Self.contentFadeDelay * 1000)))
            guard generation == self.morphGeneration, panel.isVisible else { return }
            surface.fadeContentIn(duration: Self.contentFadeDuration)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(Self.morphDuration * 1000)))
            guard generation == self.morphGeneration else { return }
            surface.finishMorph()
            panel.ignoresMouseEvents = false
        }
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
    /// Pure geometry, unit-tested. Delegates to MorphGeometry so the mask
    /// the card settles on and the mask it morphs to are built by one
    /// function — a card whose final radius disagreed with its animated one
    /// would tick at the end of every reveal.
    nonisolated static func contentMaskPath(size: CGSize) -> CGPath {
        MorphGeometry.path(
            NSRect(origin: .zero, size: size), radius: Self.cornerRadius
        )
    }

    /// NOTE: the old `scheduleContentMask` tick-tock is gone. The surface's
    /// mask now exists before orderFront (a CALayer we own, not a layer
    /// SwiftUI creates at first display), so there is nothing to wait for
    /// and no "mask silently skipped" failure mode left to retry.
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

    /// Manual Copy primitive (same clipboard rule as history Copy). Shows
    /// Copied briefly, then auto-closes: the user pressed Copy because the
    /// transcript is going somewhere now. Generation-guarded (audit): a second
    /// Copy (or a re-show) inside the window restarts the close instead of
    /// double-hiding or stranding Copied lit.
    private var copyGeneration = 0
    func copy(pasteboard: NSPasteboard = .general) {
        // Full transcript, never the capped display string (P0: long
        // dictations lost every word past 50 on Copy). Fallback guards a
        // copy-before-show that cannot happen through current callers.
        // Copy writes straight through (no overwrite confirm — removed
        // 2026-10-31); the primitive stays unit-testable with scratch boards.
        ClipboardWrite.text(fullText.isEmpty ? text : fullText, to: pasteboard)
        copied = true
        // VoiceOver announcement: the panel is never key (focus-steal
        // defense), so VO users get the confirmation announced instead of
        // finding it. Posted on the app element — no focus change.
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                NSAccessibility.NotificationUserInfoKey.announcement: "Copied recovery transcript",
                NSAccessibility.NotificationUserInfoKey.priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
        copyGeneration += 1
        let generation = copyGeneration
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, generation == self.copyGeneration else { return }
            self.copied = false
            self.hide()
        }
    }
}

struct NoTargetModalView: View {
    let controller: NoTargetModalController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // v6 surface: two stacked zones — words, then a bottom-pinned
        // Cancel + Copy footer. No ✕ row: dismissal is the ghost Cancel
        // pill. The Spacer between text and actions is load-bearing: it
        // pins the footer to the card bottom on short/empty cards.
        // Trailing edges (text, buttons) share the 20pt card inset.
        let palette = CatcherPalette.current(scheme)
        ZStack {
            ZStack {
                // No fill and no shadow here any more: CatcherSurfaceView
                // paints the card in a layer UNDER this view, so the
                // pill→card morph reveals ONE continuous surface. A SwiftUI
                // fill would fade in with the content (that is exactly the
                // old "whole card crossfades" look) instead of being wiped
                // on by the mask.
                Color.clear
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        if controller.text.isEmpty {
                            Text("Nothing to paste into.")
                                .font(.title3)
                                .foregroundStyle(palette.dim)
                        } else {
                            Text(controller.text)
                                .font(.title3)
                                .foregroundStyle(palette.transcript)
                                .accessibilityHint("Recovery transcript. Copy pastes the full text.")
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(alignment: .center, spacing: 10) {
                        Spacer()
                        OtoPill("Cancel", filled: false, large: true) {
                            controller.hide()
                        }
                        OtoPill(controller.copied ? "Copied" : "Copy", filled: true, large: true) {
                            controller.copy()
                        }
                        .disabled(controller.copied)
                    }
                    .frame(minHeight: CatcherLayout.actionRowHeight)
                    .padding(.top, CatcherLayout.textToActionsGap)
                }
                .padding(CatcherLayout.cardPadding)
            }
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
