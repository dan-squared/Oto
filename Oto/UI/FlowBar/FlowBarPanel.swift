//
//  FlowBarPanel.swift
//  Oto
//
//  Slice 6B: the pill's NSPanel owner. Panels are AppKit-only (NSPanel
//  appears in NEITHER SwiftUI nor SwiftUICore swiftinterfaces — verified);
//  the bridge is NSHostingView (SwiftUI.NSHostingView, no AppKit header —
//  verified compiling). Width motion is owned HERE (AppKit frame animator):
//  SwiftUI content crossfades only, never resizes itself.
//
//  Positioning chain, pinned per session (never re-resolved mid-session):
//  target screen → mouse screen → main → origin-zero screen. Step 1 matches
//  on deviceDescription["NSScreenNumber"] — NSScreen.CGDirectDisplayID is
//  NS_REFINED_FOR_SWIFT with no Swift spelling (compile-proven 2026-09-22),
//  so the property path is unusable from Swift; the number technique is the
//  same one RealTargetCapture uses, hence consistent.
//

import AppKit
import SwiftUI

@MainActor
final class FlowBarPanel {
    nonisolated static let bottomMargin: CGFloat = 28

    private let panel: NSPanel
    private let hosting: NSHostingView<FlowBarView>
    private(set) var pinnedSessionID: UUID?
    private(set) var pinnedScreen: NSScreen?
    /// Which positioning step resolved (1–4). Recorded for the 6B matrix:
    /// single-screen sign-off covers fallbacks only.
    private(set) var lastStep = 0
    private(set) var currentWidth: CGFloat = 0

    // MARK: - Shared nonactivating recipe (pill + catcher modal)

    /// Borderless nonactivating floating panel. Never becomes key on click
    /// (focus-steal defense); buttons still click. Shared by the pill and
    /// the catcher modal — one recipe, no drift.
    static func makePanel(contentView: NSView, size: NSSize) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = contentView
        return panel
    }

    /// Positioning chain. Returns nil only when the session has no screens
    /// (headless) — the caller keeps the pill hidden, never fabricates one.
    static func resolveScreen(displayID: CGDirectDisplayID?) -> (NSScreen, Int)? {
        if let displayID {
            let match = NSScreen.screens.first { screen in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                    return false
                }
                return number.uint32Value == displayID
            }
            if let match { return (match, 1) }
        }
        let mouse = NSEvent.mouseLocation
        if let hovered = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return (hovered, 2)
        }
        if let main = NSScreen.main {
            return (main, 3)
        }
        if let origin = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first {
            return (origin, 4)
        }
        return nil
    }

    // MARK: - Pill instance

    init(model: FlowBarModel, controller: FlowBarController, width: CGFloat) {
        hosting = NSHostingView(rootView: FlowBarView(model: model, controller: controller, width: width))
        panel = Self.makePanel(contentView: hosting, size: NSSize(width: width, height: VisualizerMath.pillHeight))
        currentWidth = width
    }

    /// Show (or re-pin) for a session. Same session → resize in place.
    func show(sessionID: UUID?, displayID: CGDirectDisplayID?, width: CGFloat) {
        if sessionID == pinnedSessionID, pinnedScreen != nil {
            resize(to: width)
            return
        }
        guard let (screen, step) = Self.resolveScreen(displayID: displayID) else { return }
        pinnedSessionID = sessionID
        pinnedScreen = screen
        lastStep = step
        setFrame(for: width, on: screen, animated: false)
        currentWidth = width
        // orderFront, never makeKeyAndOrderFront: showing must not
        // activate Oto or steal the target's focus.
        panel.orderFront(nil)
    }

    /// Animated width change on the PINNED screen (no re-resolution).
    func resize(to width: CGFloat) {
        guard width != currentWidth, let screen = pinnedScreen else { return }
        setFrame(for: width, on: screen, animated: true)
        currentWidth = width
    }

    /// Refresh SwiftUI content width to match the frame (no animation —
    /// the frame animator below is the motion).
    func syncContentWidth(model: FlowBarModel, controller: FlowBarController) {
        hosting.rootView = FlowBarView(model: model, controller: controller, width: currentWidth)
    }

    func hide() {
        // Cancel-before-orderOut invariant (09 §2.2 class): tasks die in
        // the controller before this runs; orderOut is the last step.
        panel.orderOut(nil)
    }

    var isVisible: Bool { panel.isVisible }

    private func setFrame(for width: CGFloat, on screen: NSScreen, animated: Bool) {
        let visible = screen.visibleFrame
        let clamped = min(width, visible.width - 16)
        let x = max(visible.minX + 8, visible.midX - clamped / 2)
        let frame = NSRect(
            x: x, y: visible.minY + Self.bottomMargin,
            width: clamped, height: VisualizerMath.pillHeight
        )
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }
}
