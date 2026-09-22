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
import QuartzCore

@MainActor
final class FlowBarPanel {
    private let panel: NSPanel
    private let content: PillContentView
    private(set) var pinnedSessionID: UUID?
    private(set) var pinnedScreen: NSScreen?
    /// Which positioning step resolved (1–4). Recorded for the 6B matrix:
    /// single-screen sign-off covers fallbacks only.
    private(set) var lastStep = 0
    private(set) var currentWidth: CGFloat = 0
    /// Vsync values-link state (fluid waves). Nil unless bars are live.
    private var valuesLink: CADisplayLink?
    private var liveSource: FlowBarModel?
    /// Test hook: display link active (bars rendering at vsync).
    var isLiveValues: Bool { valuesLink != nil }
    /// Drag-and-snap state (Phase 8). While true the controller renders
    /// content but never moves geometry — the finger owns the frame.
    private(set) var isDragging = false
    private var dragStartSlot = FlowBarPosition.bottom
    private var lastTickedSlot: FlowBarPosition?
    private var tickGate = SnapTickGate()
    private var landTask: Task<Void, Never>?
    private var topGhost: NSPanel?
    private var bottomGhost: NSPanel?
    private var topGhostView: SnapIndicatorView?
    private var bottomGhostView: SnapIndicatorView?

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
        // Layer-backed + clear all the way down: a non-layer hosting view
        // in a transparent panel can render a hairline window-shaped
        // backdrop (seen 2026-09-22). This kills it at the source.
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
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

    init(width: CGFloat) {
        content = PillContentView(frame: NSRect(x: 0, y: 0, width: width, height: VisualizerMath.pillHeight))
        panel = Self.makePanel(contentView: content, size: NSSize(width: width, height: VisualizerMath.pillHeight))
        currentWidth = width
        content.dragDelegate = self
    }

    /// Show (or re-pin) for a session. Same session → resize in place.
    /// The slot comes from the setting per poll, so flipping it in
    /// Settings moves the live pill (Phase 8).
    func show(sessionID: UUID?, displayID: CGDirectDisplayID?, width: CGFloat, position: FlowBarPosition) {
        if sessionID == pinnedSessionID, pinnedScreen != nil {
            resize(to: width, position: position)
            return
        }
        guard let (screen, step) = Self.resolveScreen(displayID: displayID) else { return }
        pinnedSessionID = sessionID
        pinnedScreen = screen
        lastStep = step
        setFrame(for: width, on: screen, position: position, animated: false)
        currentWidth = width
        // orderFront, never makeKeyAndOrderFront: showing must not
        // activate Oto or steal the target's focus.
        panel.orderFront(nil)
    }

    /// Animated width change on the PINNED screen (no re-resolution).
    func resize(to width: CGFloat, position: FlowBarPosition) {
        guard width != currentWidth, let screen = pinnedScreen else { return }
        setFrame(for: width, on: screen, position: position, animated: true)
        currentWidth = width
    }

    /// Re-slot a live pill (setting flip while visible). Width unchanged.
    func moveToSlot(_ position: FlowBarPosition, animated: Bool = true) {
        guard let screen = pinnedScreen else { return }
        setFrame(for: currentWidth, on: screen, position: position, animated: animated)
    }

    /// Push one poll snapshot into the layers: group switch (faded on the
    /// render server) → layout at the current width (guarded no-op) →
    /// value sets with implicit actions disabled. No hierarchy exists to
    /// rebuild — this is why v3 can't lag the v2 way.
    func render(
        visual: PillVisual, values: [Float],
        text: String?, centerText: Bool, reduceMotion: Bool, animated: Bool,
        liveValues: Bool = false
    ) {
        content.show(visual: visual, animated: animated)
        content.layout(width: currentWidth)
        content.update(values: values, text: text, centerText: centerText, reduceMotion: reduceMotion, liveValues: liveValues)
    }

    // MARK: - Vsync values loop (fluid waves)

    /// While a source is set, a display-vsync link pushes the latest
    /// sample to the bars every frame with implicit actions disabled —
    /// 1:1 motion at the display rate. The 150 ms controller poll keeps
    /// group switching + geometry and passes liveValues:true to render
    /// while the link owns transforms, so the two clocks never fight.
    /// Nil source stops the link. Link: `NSView.displayLink` (macOS
    /// spelling — `+displayLinkWithTarget:selector:` is iOS-only).
    func setLiveValues(_ source: FlowBarModel?) {
        guard source != nil else {
            valuesLink?.invalidate()
            valuesLink = nil
            liveSource = nil
            return
        }
        liveSource = source
        guard valuesLink == nil else { return }
        let link = content.displayLink(target: self, selector: #selector(pushLiveValues(_:)))
        link.add(to: .main, forMode: .common)
        valuesLink = link
    }

    @objc private func pushLiveValues(_ link: CADisplayLink) {
        guard let source = liveSource else { return }
        content.setLiveLevels(source.sample.values)
    }

    /// Render-server fade of the whole content (v5 liquid-quick vanish:
    /// 0.12s easeIn). Completion runs after the fade; the caller owns
    /// orderOut + generation guards.
    func fadeContentOut(duration: TimeInterval = 0.12) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            content.animator().alphaValue = 0
        }
    }

    /// Instant content restore (a new state preempts a mid-fade hide).
    func restoreContentAlpha() {
        content.alphaValue = 1
    }

    /// Order out + leave the content visible for next show.
    func hideNow() {
        setLiveValues(nil)
        panel.orderOut(nil)
        content.alphaValue = 1
    }

    func hide() {
        // Cancel-before-orderOut invariant (09 §2.2 class): tasks die in
        // the controller before this runs; orderOut is the last step.
        setLiveValues(nil)
        panel.orderOut(nil)
    }

    var isVisible: Bool { panel.isVisible }

    private func setFrame(for width: CGFloat, on screen: NSScreen, position: FlowBarPosition, animated: Bool) {
        let frame = FlowBarPosition.frame(width: width, on: screen.visibleFrame, position: position)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                // Liquid-quick (v6, v8b): easeOut over snapDuration — the
                // window lands fast with a soft settle, matched by the
                // bg-path morph in PillContentView.layout AND the land tick
                // below. One constant drives both, by design.
                // (Was 0.28, then 0.20: floaty.)
                context.duration = FlowBarPosition.snapDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    // MARK: - Drag and snap (Phase 8)

    /// Current pill frame, screen space. Used to seed the snap highlight.
    private var pillFrame: NSRect { panel.frame }

    private func ghostPanels() -> [(NSPanel, SnapIndicatorView, FlowBarPosition)] {
        if topGhost == nil {
            let view = SnapIndicatorView(frame: NSRect(
                x: 0, y: 0, width: currentWidth, height: VisualizerMath.pillHeight
            ))
            let ghost = Self.makePanel(
                contentView: view,
                size: NSSize(width: currentWidth, height: VisualizerMath.pillHeight)
            )
            ghost.ignoresMouseEvents = true
            topGhost = ghost
            topGhostView = view
        }
        if bottomGhost == nil {
            let view = SnapIndicatorView(frame: NSRect(
                x: 0, y: 0, width: currentWidth, height: VisualizerMath.pillHeight
            ))
            let ghost = Self.makePanel(
                contentView: view,
                size: NSSize(width: currentWidth, height: VisualizerMath.pillHeight)
            )
            ghost.ignoresMouseEvents = true
            bottomGhost = ghost
            bottomGhostView = view
        }
        guard let topGhost, let topGhostView, let bottomGhost, let bottomGhostView else {
            return []
        }
        return [(topGhost, topGhostView, .top), (bottomGhost, bottomGhostView, .bottom)]
    }

    @discardableResult
    private func highlightGhosts(centerY: CGFloat) -> FlowBarPosition {
        guard let screen = pinnedScreen else { return .bottom }
        let nearest = FlowBarPosition.nearest(
            dropCenterY: centerY, on: screen.visibleFrame
        )
        topGhostView?.highlighted = nearest == .top
        bottomGhostView?.highlighted = nearest == .bottom
        return nearest
    }

    /// Tick when the drag ENTERS a new slot (v8b F2): the detent thunk,
    /// synced to the same frame the ghost highlight swaps. Suppressed
    /// inside the refractory window — wiggle can't machine-gun.
    private func tickOnSlotEntry(_ nearest: FlowBarPosition) {
        guard nearest != lastTickedSlot else { return }
        lastTickedSlot = nearest
        guard SnapTickGate.shouldTick(&tickGate, now: ContinuousClock().now, slotChanged: true) else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(
            .levelChange, performanceTime: .default
        )
    }

    /// A new grab supersedes any pending land tick (v8b).
    func cancelSnapFeedback() {
        landTask?.cancel()
        landTask = nil
    }
}

extension FlowBarPanel: PillDragDelegate {
    func pillDragBegan() {
        guard !isDragging, let screen = pinnedScreen else { return }
        isDragging = true
        dragStartSlot = FlowBarPosition.current()
        cancelSnapFeedback()
        SnapTickGate.reset(&tickGate)
        lastTickedSlot = dragStartSlot
        // Ghosts at both slots, sized like the live pill; the slot under
        // the grab glows first — the user sees the choice immediately.
        for (ghost, _, position) in ghostPanels() {
            ghost.setFrame(
                FlowBarPosition.frame(
                    width: currentWidth, on: screen.visibleFrame, position: position
                ),
                display: true
            )
            ghost.alphaValue = 0
            ghost.orderFront(nil)
            ghost.animator().alphaValue = 1
        }
        highlightGhosts(centerY: pillFrame.midY)
        // Stay above the ghosts for the whole drag.
        panel.orderFront(nil)
    }

    func pillDragMoved(toOrigin screenOrigin: NSPoint) {
        guard isDragging else { return }
        panel.setFrame(
            NSRect(origin: screenOrigin, size: panel.frame.size),
            display: true
        )
        let nearest = highlightGhosts(
            centerY: screenOrigin.y + VisualizerMath.pillHeight / 2
        )
        tickOnSlotEntry(nearest)
    }

    func pillDragEnded(moved: Bool) {
        guard isDragging else { return }
        isDragging = false
        for (ghost, _, _) in ghostPanels() {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                ghost.animator().alphaValue = 0
            }, completionHandler: {
                ghost.orderOut(nil)
            })
        }
        guard moved, let screen = pinnedScreen else { return }
        let target = FlowBarPosition.nearest(
            dropCenterY: panel.frame.midY, on: screen.visibleFrame
        )
        setFrame(for: currentWidth, on: screen, position: target, animated: true)
        // Land tick on ARRIVAL (v8b F1): the glide above runs snapDuration,
        // so this fires exactly as the pill settles — never at finger lift.
        // Same-slot drops still tick: the placement registered, felt.
        landTask?.cancel()
        landTask = Task {
            try? await Task.sleep(
                nanoseconds: UInt64(FlowBarPosition.snapDuration * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            NSHapticFeedbackManager.defaultPerformer.perform(
                .alignment, performanceTime: .now
            )
        }
        if target != dragStartSlot {
            FlowBarPosition.save(target)
        }
    }
}

/// Drop-slot ghost: pill-sized rounded fill that says "release here".
/// Stroke + fill, no text — the shape IS the affordance.
final class SnapIndicatorView: NSView {
    var highlighted = false {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(
            roundedRect: rect, xRadius: VisualizerMath.pillHeight / 2,
            yRadius: VisualizerMath.pillHeight / 2
        )
        (highlighted
            ? NSColor.white.withAlphaComponent(0.30)
            : NSColor.white.withAlphaComponent(0.10)).setFill()
        path.fill()
        (highlighted
            ? NSColor.white.withAlphaComponent(0.75)
            : NSColor.white.withAlphaComponent(0.35)).setStroke()
        path.lineWidth = highlighted ? 2 : 1
        path.stroke()
    }
}
