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

    func show(text: String, displayID: CGDirectDisplayID?) {
        self.text = text
        copied = false
        prewarm()
        refreshContent()
        guard let (screen, _) = FlowBarPanel.resolveScreen(displayID: displayID) else { return }
        let visible = screen.visibleFrame
        let endFrame = NSRect(
            x: visible.midX - Self.width / 2,
            y: visible.midY - Self.height / 2,
            width: Self.width, height: Self.height
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
        scheduleContentMask()
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
        self.text = text
        copied = false
        prewarm()
        refreshContent()
        guard let (screen, _) = FlowBarPanel.resolveScreen(displayID: displayID) else {
            show(text: text, displayID: displayID)
            return
        }
        let endFrame = Self.morphEndFrameAtSlot(visible: screen.visibleFrame, position: position)
        morphGeneration += 1
        let generation = morphGeneration
        panel?.setFrame(pillFrame, display: false)
        panel?.alphaValue = 0
        // orderFront, never key: the catcher never steals focus (v4 keeps
        // the 6C1 load-bearing call — editing lives in the optional
        // scratchpad, never here).
        panel?.orderFront(nil)
        scheduleContentMask()
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

    /// Rounded-rect mask path for the hosting layer (v6 variant B):
    /// clips EVERYTHING SwiftUI paints — including any opaque root
    /// background it resolves on render — to the card silhouette.
    /// Static geometry: hosting bounds never change (the panel frame
    /// animates, not the content), so one mask holds for life. Immune
    /// to re-renders by construction (the mask is ours, the paint is
    /// theirs). Pure geometry, unit-tested.
    nonisolated static func contentMaskPath() -> CGPath {
        CGPath(
            roundedRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil
        )
    }

    /// Apply the content mask on the next tick: the hosting layer is
    /// created by SwiftUI at first display, so masking must run AFTER
    /// orderFront — clearing at prewarm is a silent no-op on a nil
    /// layer (why variant A failed). Idempotent; safe to call twice.
    private func scheduleContentMask() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let layer = self.hosting?.layer else { return }
            let mask = CAShapeLayer()
            mask.path = Self.contentMaskPath()
            layer.mask = mask
        }
    }
    /// Slot-anchored 464×168 card (v6): the pill's own slot helper with
    /// card dimensions — same margins, clamp, and centering as the pill,
    /// so x matches exactly and growth is purely vertical. Height guard
    /// for pathological frames (real screens never hit it): keep the
    /// slot edge, shrink inward. Pure geometry, unit-tested.
    nonisolated static func morphEndFrameAtSlot(visible: NSRect, position: FlowBarPosition) -> NSRect {
        var frame = FlowBarPosition.frame(width: Self.width, height: Self.height, on: visible, position: position)
        if frame.height > visible.height {
            frame.size.height = visible.height
            if position == .top { frame.origin.y = visible.maxY - visible.height }
        }
        return frame
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Manual Copy primitive (same pasteboard discipline as history Copy).
    /// Never dismisses — the user may still need to find a textbox.
    func copy(pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
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
    var hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(.gray.opacity(configuration.isPressed ? 0.45 : 0.35), in: RoundedRectangle(cornerRadius: 8))
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
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .padding(.top, 14)
                    Spacer(minLength: 0)
                    HStack {
                        Spacer()
                        Button(controller.copied ? "Copied" : "Copy") {
                            controller.copy()
                        }
                        .buttonStyle(CatcherCopyStyle(hovering: copyHovering && !controller.copied))
                        .onHover { copyHovering = $0 }
                        .disabled(controller.copied)
                    }
                }
                .padding(20)
            }
            Button { controller.hide() } label: {
                Image(systemName: "xmark")
                    .font(.title3)
            }
            .buttonStyle(CatcherXStyle(base: palette.dim, hover: palette.ink, hovering: xHovering))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .onHover { xHovering = $0 }
            .padding(8)
        }
        .frame(
            width: NoTargetModalController.width,
            height: NoTargetModalController.height
        )
    }
}
