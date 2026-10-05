//
//  PillLayers.swift
//  Oto
//
//  Slice 6B v5: the pill's GPU renderer. One layer-backed NSView, zero
//  SwiftUI: background + bars + dots are CALayers, the spinner is a native
//  NSProgressIndicator, text is a static NSTextField. Motion is two clocks:
//  DATA (bar levels, ~60 Hz vsync sets with actions disabled) and MOTION
//  (chase glide + red-dot breathe as infinite CAAnimations interpolating on
//  the render server — zero MainActor work per frame, no timers, no Metal).
//  Overflow is caged by masksToBounds (sublayers) + clipsToBounds (subviews).
//
//  Geometry: relaxed compact (92.4×26.4 recording). Elements shrink, count stays:
//  8 thin bars, 9 chase dots, 6.6px record dot with no ring.
//

import AppKit
import QuartzCore

/// Display-only work-verb label: a stock `NSTextField` label that is also
/// mouse-transparent. The shine overlay sits topmost over the base label;
/// returning nil from hit-testing lets every press fall through to the
/// base label / content view beneath, so the pill's press-drag grab works
/// starting on shimmering text exactly as it does on plain text. (Drag is
/// owned by `PillContentView.mouseDown`, the pill carries no buttons, and
/// the overlay is AX-hidden — nothing needs events on it, ever.)
private final class ShineLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Which layer group is visible. Maps 1:1 from FlowBarState (+ notice).
/// v6: no stagnant dots at either end — preparing renders bars (waves from
/// frame one), completion renders nothing (vanish path). Dots exist only
/// as the working loader (finalizing/inserting).
enum PillVisual: Equatable {
    case bars
    case dots
    case dotsSpinner
    case message
    /// E2 live-model work: joint label + divider + spinner layout at a
    /// measured dynamic width (`Cleanup` / preset name — one word max).
    /// Transient working state (preparing/recording family) — controller-latched from
    /// the work feed, never state-mapped (same as `.message`), never an
    /// end-state or error pixel (v6/v7 rules).
    case work

    /// Pill case → layer group. Nil renders nothing (hidden).
    /// v7: failures never reach the pill (concise menu status owns them).
    /// `.message` renders only the controller-latched over-limit Copied
    /// pill — same size as recording, so the switch is a re-render, never
    /// a resize.
    nonisolated static func forState(_ state: FlowBarState) -> PillVisual? {
        switch state {
        case .hidden: nil
        case .preparing: .bars
        case .recording: .bars
        case .finalizing, .inserting: .dotsSpinner
        case .message: .message
        }
    }
}

/// Drag source (Phase 8): the pill carries no buttons, so every
/// press-drag is a move. Origins are screen-space, grab-offset corrected.
@MainActor
protocol PillDragDelegate: AnyObject {
    func pillDragBegan()
    func pillDragMoved(toOrigin screenOrigin: NSPoint)
    func pillDragEnded(moved: Bool)
}

@MainActor
final class PillContentView: NSView {
    nonisolated static let barFullHeight: CGFloat = 16.5
    nonisolated static let padding: CGFloat = 8.25

    private let bg = CAShapeLayer()
    private let recordDot = CALayer()
    private var barLayers: [CAShapeLayer] = []
    private var chaseLayers: [CALayer] = []
    /// Native Apple spinner. Forced dark appearance so it always draws
    /// its light variant — the pill is near-black in both schemes, and
    /// the default appearance resolution can leave it dark-on-dark.
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    /// Shine-sweep overlay (work verbs only): full-bright duplicate of
    /// `label` — same construction, so text rendering and mouse-event
    /// behavior are identical by construction. Display-only: AX-hidden
    /// (the base label stays the single AX source) and alive only while
    /// the `.work` visual is up. A `CAGradientLayer` bright window masks
    /// it (see `shineMask`); the mask's position sweeps on the render
    /// server — zero per-frame MainActor work.
    private let shineLabel = ShineLabel(labelWithString: "")
    private let shineMask = CAGradientLayer()
    private var shineOn = false
    private var shineInstalledWidth: CGFloat = 0
    private var currentWidth: CGFloat = 0
    private var currentVisual: PillVisual?
    /// Render-server motion state (v5): the chase glide and the red-dot
    /// breathe are CAAnimations interpolating on the render server — zero
    /// per-frame MainActor work. `motionVisual` tracks which visual owns
    /// installed animations so the 150 ms poll never restarts them.
    /// Data (bar levels, label) and motion (chase/breathe) are independent
    /// clocks by design: the analyzer stops outside recording, but the
    /// loader must stay alive.
    private var motionVisual: PillVisual?
    private var frozenMotion = false
    /// Idle-sway state (v6): true while the render-server sway owns the
    /// bars (silent, unreduced motion). First voice kills it.
    private var swayOn = false
    weak var dragDelegate: PillDragDelegate?
    private var dragGrabOffset = NSSize.zero
    private var dragMoved = false
    nonisolated static let chaseKey = "oto.chase"
    nonisolated static let breatheKey = "oto.breathe"
    nonisolated static let swayKey = "oto.sway"
    /// Shine-sweep animation key (work verbs). Same render-server discipline
    /// as the chase/breathe/sway keys above — install-guarded, never poked
    /// per frame.
    nonisolated static let shineKey = "oto.shine"
    /// Sweep pacing: explicit linear. Duration math (travel/velocity)
    /// promises constant velocity, which only holds with linear pacing —
    /// never rely on the framework default. Shared instance (effectively
    /// immutable after creation; MainActor-confined like its owning view,
    /// since CAMediaTimingFunction is not Sendable) so tests can pin
    /// identity, not just behavior.
    static let shinePacing = CAMediaTimingFunction(name: .linear)
    /// One chase cycle: 9 dots at ~6.7 dots/s (the old tick feel, gliding).
    nonisolated static let chaseCycle: Double = 1.35

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Overflow is structurally impossible: nothing paints outside the
        // pill silhouette, whatever a transition does. TWO levels, because
        // they clip different things: clipsToBounds clips subviews
        // (spinner, label); masksToBounds clips sublayers (bg, bars, chase
        // and flash dots — all the artwork). v4 set only the first, which
        // is why dots still escaped the constricted frame. (v5 F1.)
        clipsToBounds = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor

        bg.fillColor = CGColor(red: 0.055, green: 0.055, blue: 0.065, alpha: 1)
        // No self-drawn shadow: with masksToBounds (overflow clip, v5 F1)
        // a sublayer shadow would be clipped invisible — and a same-layer
        // shadow is clipped with it (classic masksToBounds gotcha). The
        // drop shadow comes from the window (hasShadow, follows the pill
        // alpha via the WindowServer), which masksToBounds never touches.
        layer?.addSublayer(bg)

        recordDot.backgroundColor = NSColor.systemRed.cgColor
        recordDot.cornerRadius = VisualizerMath.recordDot / 2
        recordDot.bounds = CGRect(x: 0, y: 0, width: VisualizerMath.recordDot, height: VisualizerMath.recordDot)
        layer?.addSublayer(recordDot)

        let barPath = CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: VisualizerMath.barWidth, height: Self.barFullHeight),
            cornerWidth: VisualizerMath.barWidth / 2,
            cornerHeight: VisualizerMath.barWidth / 2, transform: nil
        )
        for _ in 0..<VisualizerMath.barCount {
            let bar = CAShapeLayer()
            bar.path = barPath
            bar.fillColor = NSColor.white.cgColor
            bar.bounds = CGRect(x: 0, y: 0, width: VisualizerMath.barWidth, height: Self.barFullHeight)
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            barLayers.append(bar)
            layer?.addSublayer(bar)
        }

        for _ in 0..<VisualizerMath.dotCount {
            let dot = CALayer()
            dot.backgroundColor = NSColor.white.cgColor
            dot.cornerRadius = VisualizerMath.chaseDot / 2
            dot.bounds = CGRect(x: 0, y: 0, width: VisualizerMath.chaseDot, height: VisualizerMath.chaseDot)
            chaseLayers.append(dot)
            layer?.addSublayer(dot)
        }

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.appearance = NSAppearance(named: .darkAqua)
        spinner.frame = CGRect(x: 0, y: 0, width: VisualizerMath.spinnerSize, height: VisualizerMath.spinnerSize)
        addSubview(spinner)

        label.textColor = .white
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)

        shineLabel.textColor = .white
        // Single-sourced with measurement (measureWorkText uses workFont):
        // a future size change moves base, overlay, and metrics together,
        // so the shine can never sit 1px off the glyphs.
        shineLabel.font = VisualizerMath.workFont
        shineLabel.lineBreakMode = .byTruncatingTail
        shineLabel.maximumNumberOfLines = 1
        // Explicit layer: the mask below needs a host layer even before
        // first paint (subviews of a layer-backed view normally get one,
        // but this is load-bearing — never implicit).
        shineLabel.wantsLayer = true
        // Display-only duplicate: never an AX element, never a drag or
        // click target beyond what the base label already is.
        shineLabel.setAccessibilityElement(false)
        shineLabel.isHidden = true
        addSubview(shineLabel)

        showOnly(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PillContentView has no nib")
    }

    // MARK: - Layout (width changes only — bg path + positions)

    func layout(width: CGFloat) {
        guard width != currentWidth else { return }
        currentWidth = width
        setFrameSize(NSSize(width: width, height: VisualizerMath.pillHeight))
        let h = VisualizerMath.pillHeight
        let newPath = CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: width, height: h),
            cornerWidth: h / 2, cornerHeight: h / 2, transform: nil
        )
        if bg.path != nil {
            // Liquid chrome (v5 F4, v6 retime): the silhouette morphs over
            // the same 0.15s easeOut as the window frame (FlowBarPanel.setFrame),
            // so pill and window move as one. First layout snaps (no path yet).
            // Element positions snap to the final geometry instantly — with
            // the outgoing group already dead (shrink) or fading in (growth),
            // the eye reads content-leading-chrome-following as liquid.
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            bg.path = newPath
            CATransaction.commit()
        } else {
            bg.path = newPath
        }
        let midY = h / 2

        // Recording block: dot + gap + bars, centered.
        let barsBlock = CGFloat(VisualizerMath.barCount) * VisualizerMath.barPitch
        let recordBlock = VisualizerMath.recordDot + 4.95 + barsBlock
        var x = (width - recordBlock) / 2
        recordDot.position = CGPoint(x: x + VisualizerMath.recordDot / 2, y: midY)
        x += VisualizerMath.recordDot + 4.95
        for (i, bar) in barLayers.enumerated() {
            bar.position = CGPoint(x: x + CGFloat(i) * VisualizerMath.barPitch + VisualizerMath.barPitch / 2, y: midY)
        }

        // Chase block: dots (+ spinner), centered.
        let dotsBlock = CGFloat(VisualizerMath.dotCount - 1) * VisualizerMath.chasePitch + VisualizerMath.chaseDot
        var dotsX = (width - dotsBlock) / 2
        if currentVisual == .dotsSpinner {
            dotsX = (width - (dotsBlock + 6.6 + VisualizerMath.spinnerSize)) / 2
        }
        for (i, dot) in chaseLayers.enumerated() {
            dot.position = CGPoint(x: dotsX + CGFloat(i) * VisualizerMath.chasePitch + VisualizerMath.chaseDot / 2, y: midY)
        }
        // Work positions its own spinner in update() (text-measured geometry);
        // the dots-block origin below never applies to it.
        if currentVisual != .work {
            spinner.setFrameOrigin(NSPoint(
                x: dotsX + dotsBlock + 6.6,
                y: midY - VisualizerMath.spinnerSize / 2
            ))
        }

        // Message label fills between padding.
        label.frame = CGRect(
            x: Self.padding, y: 0,
            width: max(0, width - Self.padding * 2), height: h
        )
    }

    // MARK: - Render (cheap property sets; fades ride the render server)

    /// Group switch with a render-server fade. Call before `layout(width:)`
    /// so centering (which depends on the visible group) is exact.
    /// `animated=false` kills the outgoing group instantly (no fade-out):
    /// used on shrink transitions, where a fading group would overflow the
    /// already-narrower frame (v4 F1b).
    func show(visual: PillVisual, animated: Bool = true) {
        if visual != currentVisual || !animated {
            // Stop render-server motion FIRST (an attached infinite opacity
            // animation would override the fade-out below and the dying
            // group would never leave) — EXCEPT dots ↔ dotsSpinner, which
            // share one wave: restarting it on preparing→finalizing would
            // visibly rewind mid-flight.
            let keepWave = animated && isChase(currentVisual) && isChase(visual)
            if !keepWave { stopMotionAnimations() }
            showOnly(visual, animated: animated)
            // Shine lives and dies with the work visual only (a sweep over
            // the Copied notice would teach "working" for a confirmation).
            if visual != .work { removeShine() }
            currentVisual = visual
        }
        ensureMotion(for: visual)
    }

    private func isChase(_ visual: PillVisual?) -> Bool {
        visual == .dots || visual == .dotsSpinner
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            stopMotionAnimations()
            removeShine()
        }
    }

    // MARK: - Render-server motion (v5: true GPU, zero per-frame CPU)

    /// Idempotent: installs the motion for `visual` unless it already runs.
    /// The poll calls `show` every 150 ms — restarting a CAAnimation there
    /// would rewind the wave 6.7×/s (visible stutter). The `motionVisual`
    /// guard makes re-entry free.
    private func ensureMotion(for visual: PillVisual?) {
        guard motionVisual != visual else { return }
        stopMotionAnimations()
        guard !frozenMotion else {
            motionVisual = visual
            return
        }
        switch visual {
        case .bars:
            startBreatheAnimation()
        case .dots, .dotsSpinner:
            startChaseAnimation()
        case .message, .work, .none:
            break
        }
        motionVisual = visual
    }

    /// Traveling brightness wave: every dot runs the SAME 12-sample pulse
    /// (sampled from VisualizerMath so pixels agree with the tested model),
    /// staggered by one dot-step via beginTime. At commit time the wave is
    /// already mid-flight — no spin-up pop. Interpolated on the render
    /// server at display refresh; the MainActor does nothing per frame.
    private func startChaseAnimation() {
        let cycle = Self.chaseCycle
        let step = cycle / Double(VisualizerMath.dotCount)
        let samples = 12
        let values: [NSNumber] = (0..<samples).map { j in
            NSNumber(value: VisualizerMath.dotOpacityContinuous(
                index: 0, head: Double(j) * Double(VisualizerMath.dotCount) / Double(samples)
            ))
        }
        let keyTimes: [NSNumber] = (0..<samples).map { j in
            NSNumber(value: Double(j) / Double(samples - 1))
        }
        let t0 = CACurrentMediaTime()
        for (i, dot) in chaseLayers.enumerated() {
            let anim = CAKeyframeAnimation(keyPath: "opacity")
            anim.values = values
            anim.keyTimes = keyTimes
            anim.duration = cycle
            anim.repeatCount = .infinity
            anim.isRemovedOnCompletion = false
            // Negative stagger: dot i is already i steps into its cycle,
            // so dot 0 is brightest and the tail falls off — instantly.
            anim.beginTime = t0 - Double(i) * step
            dot.opacity = 1
            dot.add(anim, forKey: Self.chaseKey)
        }
    }

    /// Red-dot breathe: 2 s period (1 s out, 1 s back), 1.0 ↔ 0.55 — the
    /// same range as VisualizerMath.breatheOpacityContinuous.
    private func startBreatheAnimation() {
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.55
        anim.duration = 1.0
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.isRemovedOnCompletion = false
        recordDot.opacity = 1
        recordDot.add(anim, forKey: Self.breatheKey)
    }

    private func stopMotionAnimations() {
        chaseLayers.forEach { $0.removeAnimation(forKey: Self.chaseKey) }
        recordDot.removeAnimation(forKey: Self.breatheKey)
        stopSway()
        motionVisual = nil
    }

    // MARK: - Idle sway (v6: "waves move a bit")

    /// Gentle bar drift while silent: every bar runs the same 5-sample loop
    /// near the floor, staggered 0.2s apart — alive at a glance, never
    /// shouty. The first voice poll removes it; live model values (kept
    /// current underneath) show through instantly. Pixels only: state and
    /// levels stay in the model, so tests assert presence, never frames.
    private func startSway() {
        guard !swayOn else { return }
        let values: [NSNumber] = VisualizerMath.swayValues.map { NSNumber(value: $0) }
        let keyTimes: [NSNumber] = values.indices.map {
            NSNumber(value: Double($0) / Double(values.count - 1))
        }
        let t0 = CACurrentMediaTime()
        for (i, bar) in barLayers.enumerated() {
            let anim = CAKeyframeAnimation(keyPath: "transform.scale.y")
            anim.values = values
            anim.keyTimes = keyTimes
            anim.duration = VisualizerMath.swayCycle
            anim.repeatCount = .infinity
            anim.isRemovedOnCompletion = false
            anim.beginTime = t0 - Double(i) * VisualizerMath.swayStagger
            bar.add(anim, forKey: Self.swayKey)
        }
        swayOn = true
    }

    private func stopSway() {
        guard swayOn else { return }
        barLayers.forEach { $0.removeAnimation(forKey: Self.swayKey) }
        swayOn = false
    }

    // MARK: - Work shimmer (traveling shine on the work verb)

    /// Installs the shine sweep over the current label content. Idempotent:
    /// repolls with identical text+frame are free — the wave is never
    /// restarted mid-flight (same discipline as `ensureMotion`). A text or
    /// width change reinstalls from scratch (rare: the work verb is fixed
    /// per run). Per explicit product direction (2026-10-05) this installs
    /// regardless of Reduce Motion; content accessibility is unchanged.
    private func installShine() {
        let text = label.stringValue
        let frame = label.frame
        guard !text.isEmpty, frame.width > 0, frame.height > 0 else { return }
        if shineOn, shineLabel.stringValue == text, shineInstalledWidth == frame.width {
            shineLabel.isHidden = false
            return
        }
        // (Re)install: kill the old sweep first so a text change never
        // stacks two waves.
        shineMask.removeAnimation(forKey: Self.shineKey)
        shineLabel.stringValue = text
        shineLabel.frame = frame
        shineLabel.isHidden = false
        label.textColor = NSColor.white.withAlphaComponent(VisualizerMath.shineBaseAlpha)
        // Bright window: soft band `band` wide at the gradient center.
        // The mask is oversized (label + one band each side) so the sweep
        // starts/ends fully off-text — no edge pops, ever. Direction is
        // EXPLICITLY horizontal: CAGradientLayer defaults to vertical
        // (top-to-bottom), which renders as a static stripe through the
        // letters and ignores the X sweep entirely (seen on device).
        let band = VisualizerMath.shineBandWidth(forLabelWidth: frame.width)
        let travelW = frame.width + 2 * band
        let halfFraction = (band / 2) / travelW
        shineMask.colors = [
            NSColor.clear.cgColor, NSColor.white.cgColor,
            NSColor.white.cgColor, NSColor.clear.cgColor,
        ]
        shineMask.startPoint = CGPoint(x: 0, y: 0.5)
        shineMask.endPoint = CGPoint(x: 1, y: 0.5)
        shineMask.locations = [
            NSNumber(value: 0.5 - halfFraction), NSNumber(value: 0.5),
            NSNumber(value: 0.5), NSNumber(value: 0.5 + halfFraction),
        ]
        shineMask.bounds = CGRect(x: 0, y: 0, width: travelW, height: frame.height)
        // Band center == mask x by construction (band sits at the gradient
        // center): sweep the center from fully-left to fully-right.
        let anim = CABasicAnimation(keyPath: "position.x")
        anim.fromValue = -band
        anim.toValue = frame.width + band
        anim.duration = VisualizerMath.shineDuration(forLabelWidth: frame.width)
        anim.timingFunction = Self.shinePacing
        anim.repeatCount = .infinity
        anim.isRemovedOnCompletion = false
        shineMask.position = CGPoint(x: frame.width + band, y: frame.height / 2)
        shineLabel.layer?.mask = shineMask
        shineMask.add(anim, forKey: Self.shineKey)
        shineOn = true
        shineInstalledWidth = frame.width
    }

    /// Tears down the sweep and restores the base label to full white.
    /// Safe when absent (guard) — called on every visual switch out of
    /// `.work` and on window teardown. Deliberately NOT called from
    /// `stopMotionAnimations()`: that funnel also runs per-poll under
    /// Reduce Motion, which would restart the wave 6.7×/s.
    private func removeShine() {
        guard shineOn else { return }
        shineMask.removeAnimation(forKey: Self.shineKey)
        shineLabel.layer?.mask = nil
        shineLabel.isHidden = true
        label.textColor = .white
        shineOn = false
        shineInstalledWidth = 0
    }

    /// Per-data-push values (voice clock, ≤30 Hz). Touches ONLY data-driven
    /// properties: bar scales + label text. Chase/breathe live on the render
    /// server (see above) and are never poked here — data rate and motion
    /// rate are independent clocks by design.
    func update(values: [Float], text: String?, centerText: Bool, reduceMotion: Bool, liveValues: Bool = false) {
        if reduceMotion != frozenMotion {
            frozenMotion = reduceMotion
            // Force motion re-evaluation on the freeze/unfreeze edge.
            motionVisual = nil
        }
        // Instant sets: label text + frozen statics (never glide).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if currentVisual == .message {
            if let text { label.stringValue = text }
            label.alignment = centerText ? .center : .left
            // Vertically center: an NSTextField draws from the top of a
            // tall frame, so fit the label to its text and center it in
            // the pill (same 92.4 width as dictation — re-render, no resize).
            label.sizeToFit()
            let h = VisualizerMath.pillHeight
            var f = label.frame
            f.size.width = min(f.size.width, max(0, currentWidth - Self.padding * 2))
            f.size.height = min(f.size.height, h)
            f.origin.x = centerText ? (currentWidth - f.size.width) / 2 : Self.padding
            f.origin.y = max(0, (h - f.size.height) / 2)
            label.frame = f
        } else if currentVisual == .work {
            // Joint layout: [padding][text][gap][spinner][padding], matching
            // VisualizerMath.workPillWidth chrome (same slack — single
            // source, exact-fit truncation can never recur).
            if let text { label.stringValue = text }
            label.alignment = .left
            label.sizeToFit()
            let h = VisualizerMath.pillHeight
            let measured = ceil(VisualizerMath.measureWorkText(label.stringValue))
                + VisualizerMath.workTextSlack
            let chromeTail = VisualizerMath.workPadding
                + VisualizerMath.workSpinnerGap
                + VisualizerMath.spinnerSize
                + VisualizerMath.workPadding
            let labelW = min(measured, max(0, currentWidth - chromeTail))
            let labelH = min(label.frame.size.height, h)
            label.frame = CGRect(
                x: VisualizerMath.workPadding, y: max(0, (h - labelH) / 2),
                width: labelW, height: labelH
            )
            spinner.setFrameOrigin(NSPoint(
                x: VisualizerMath.workPadding + labelW + VisualizerMath.workSpinnerGap,
                y: h / 2 - VisualizerMath.spinnerSize / 2
            ))
        }
        if reduceMotion {
            // Frozen: statics only, no animations (Reduce Motion contract).
            if currentVisual == .bars { recordDot.opacity = 1 }
            if currentVisual == .dots || currentVisual == .dotsSpinner {
                chaseLayers.forEach { $0.opacity = 0.6 }
            }
        }
        CATransaction.commit()
        if !reduceMotion {
            // Sway owns silent bars; voice (or leaving bars) evicts it —
            // BEFORE new transforms land, so the glide below starts from
            // unmasked model values, never from under the sway.
            if currentVisual == .bars {
                let silent = (values.max() ?? 0) < VisualizerMath.swayThreshold
                if silent { startSway() } else { stopSway() }
            } else {
                stopSway()
            }
        }
        if currentVisual == .bars, !liveValues {
            CATransaction.begin()
            if reduceMotion {
                CATransaction.setDisableActions(true)
            } else {
                // Buttery (v7): each poll's voice targets glide 0.12s
                // easeOut from current presentation. Without this the
                // 6.7Hz poll steps read as stiffness; attack/release still
                // shape the targets, so voice character is unchanged —
                // only the stepping is gone.
                // (Live display-link path skips this block entirely —
                // setLiveLevels below owns transforms at vsync.)
                CATransaction.setAnimationDuration(0.12)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            }
            for (i, bar) in barLayers.enumerated() {
                let level: CGFloat = if reduceMotion { 0.3 } else {
                    CGFloat(i < values.count ? values[i] : 0)
                }
                bar.transform = CATransform3DMakeScale(1, max(0.02, level), 1)
            }
            CATransaction.commit()
        }
        if reduceMotion {
            stopMotionAnimations()
            motionVisual = currentVisual
        } else {
            ensureMotion(for: currentVisual)
        }
        if currentVisual == .dotsSpinner || currentVisual == .work, !reduceMotion { spinner.startAnimation(nil) }
        else { spinner.stopAnimation(nil) }
        spinner.isHidden = reduceMotion || (currentVisual != .dotsSpinner && currentVisual != .work)
        // Shine sweep on the work verb (render-server wave; idempotent
        // across repolls — see installShine). Deliberately outside the
        // Reduce Motion gate per product direction (2026-10-05): whenever
        // the work visual is up, the verb shimmers.
        if currentVisual == .work {
            installShine()
        }
    }

    /// Vsync values path (display link owns delivery): instant 1:1 sets,
    /// no glide. At 60/120 Hz the data IS the motion — a 0.12s glide
    /// would smear it. Actions disabled, no allocation, MainActor-only.
    func setLiveLevels(_ values: [Float]) {
        guard currentVisual == .bars else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in barLayers.enumerated() {
            let level: CGFloat = i < values.count ? CGFloat(values[i]) : 0
            bar.transform = CATransform3DMakeScale(1, max(0.02, level), 1)
        }
        CATransaction.commit()
    }

    /// Group visibility with a render-server fade. Model values flip
    /// immediately (assertable headless); pixels interpolate on the GPU.
    /// v6: 0.15s — buttery fast, no float.
    private func showOnly(_ visual: PillVisual?, animated: Bool = true) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.15)
        } else {
            CATransaction.setDisableActions(true)
        }
        let barsOn = visual == .bars
        recordDot.opacity = barsOn ? recordDot.opacity : 0
        barLayers.forEach { $0.opacity = barsOn ? 1 : 0 }
        let dotsOn = visual == .dots || visual == .dotsSpinner
        chaseLayers.forEach { $0.opacity = dotsOn ? $0.opacity : 0 }
        CATransaction.commit()
        label.isHidden = visual != .message && visual != .work
        // Shine overlay tracks the base label's visibility exactly (the
        // sweep itself is installed/torn down separately).
        shineLabel.isHidden = visual != .work
        if visual != .dotsSpinner && visual != .work { spinner.stopAnimation(nil); spinner.isHidden = true }
    }

    // MARK: - Drag and snap (Phase 8)

    /// Nonactivating panel: without this, press-drag never reaches us.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0, let window else { return }
        // Grab-offset: the pill follows the finger, it never jumps.
        let mouse = NSEvent.mouseLocation
        dragGrabOffset = NSSize(
            width: mouse.x - window.frame.origin.x,
            height: mouse.y - window.frame.origin.y
        )
        dragMoved = false
        dragDelegate?.pillDragBegan()
    }

    override func mouseDragged(with event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        dragMoved = true
        dragDelegate?.pillDragMoved(toOrigin: NSPoint(
            x: mouse.x - dragGrabOffset.width,
            y: mouse.y - dragGrabOffset.height
        ))
    }

    override func mouseUp(with event: NSEvent) {
        dragDelegate?.pillDragEnded(moved: dragMoved)
        dragMoved = false
    }

    // MARK: - Test hooks (layer model values, no window needed)

    func barOpacity(_ i: Int) -> Float { barLayers[i].opacity }
    func dotOpacity() -> Float { recordDot.opacity }
    /// Work joint-layout frames (label, spinner) for the frame-containment
    /// test: the spinner must sit snug to the right edge (no dead space
    /// beyond padding) with the full label left of it.
    func workLayoutFrames() -> (label: CGRect, spinner: CGRect) {
        (label.frame, spinner.frame)
    }
    func chaseOpacity(_ i: Int) -> Float { chaseLayers[i].opacity }
    func barScaleY(_ i: Int) -> CGFloat { barLayers[i].transform.m22 }
    func spinnerHidden() -> Bool { spinner.isHidden }
    func labelText() -> String { label.stringValue }
    func chaseHasAnimation() -> Bool {
        chaseLayers.allSatisfy { $0.animation(forKey: Self.chaseKey) != nil }
    }
    /// Shine-sweep model values (headless-assertable like the chase hooks):
    /// sweep installed, overlay content/visibility/geometry, base dim.
    func shineHasAnimation() -> Bool {
        shineMask.animation(forKey: Self.shineKey) != nil
    }
    func shineOverlayText() -> String { shineLabel.stringValue }
    func shineOverlayHidden() -> Bool { shineLabel.isHidden }
    func shineOverlayFrame() -> CGRect { shineLabel.frame }
    func shineBaseAlpha() -> CGFloat { label.textColor?.alphaComponent ?? -1 }
    /// Gradient sweep direction: the band must travel horizontally. This
    /// pins the exact bug class that animation-existence checks cannot see
    /// (a vertical gradient renders a static stripe and ignores the sweep).
    func shineGradientIsHorizontal() -> Bool {
        shineMask.startPoint == CGPoint(x: 0, y: 0.5)
            && shineMask.endPoint == CGPoint(x: 1, y: 0.5)
    }
    /// Sweep pacing pin: the installed wave must carry the shared linear
    /// pacing (identity — same object, not merely equal behavior), or the
    /// constant-velocity promise in VisualizerMath silently breaks.
    func shineSweepIsLinear() -> Bool {
        (shineMask.animation(forKey: Self.shineKey) as? CABasicAnimation)?.timingFunction === Self.shinePacing
    }
    func chaseAnimationCount() -> Int {
        chaseLayers.filter { $0.animation(forKey: Self.chaseKey) != nil }.count
    }
    func chaseBeginTime(_ i: Int) -> TimeInterval {
        chaseLayers[i].animation(forKey: Self.chaseKey)?.beginTime ?? -1
    }
    func breatheHasAnimation() -> Bool {
        recordDot.animation(forKey: Self.breatheKey) != nil
    }
    func contentMaskedToBounds() -> Bool { layer?.masksToBounds == true }
    func swayHasAnimation() -> Bool {
        barLayers.allSatisfy { $0.animation(forKey: Self.swayKey) != nil }
    }
    func swayAnimationCount() -> Int {
        barLayers.filter { $0.animation(forKey: Self.swayKey) != nil }.count
    }
}
