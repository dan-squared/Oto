//
//  PillLayers.swift
//  Oto
//
//  Slice 6B v3: the pill's GPU renderer. One layer-backed NSView, zero
//  SwiftUI: background + bars + dots are CALayers (render-server
//  composited), the spinner is a native NSProgressIndicator, text is a
//  static NSTextField. The MainActor sets properties at ≤30 Hz; Core
//  Animation interpolates on the render server — no per-frame MainActor
//  work, no view-hierarchy diffs, no transparency stack (the v2 lag and
//  the hosting-view backdrop die together, by construction).
//
//  Geometry: mini (112×32 recording). Elements shrink, count stays:
//  8 thin bars, 9 chase dots, 8px record dot with no ring.
//

import AppKit
import QuartzCore

/// Which layer group is visible. Maps 1:1 from FlowBarState (+ notice).
enum PillVisual: Equatable {
    case bars
    case dots
    case dotsSpinner
    case flash
    case message

    /// Pill case → layer group. Nil renders nothing (hidden).
    nonisolated static func forState(_ state: FlowBarState) -> PillVisual? {
        switch state {
        case .hidden: nil
        case .preparing: .dots
        case .recording: .bars
        case .finalizing, .inserting: .dotsSpinner
        case .successFlash, .cancelledFlash: .flash
        case .failure: .message
        }
    }
}

@MainActor
final class PillContentView: NSView {
    nonisolated static let barFullHeight: CGFloat = 20
    nonisolated static let padding: CGFloat = 10

    private let bg = CAShapeLayer()
    private let recordDot = CALayer()
    private var barLayers: [CAShapeLayer] = []
    private var chaseLayers: [CALayer] = []
    private var flashLayers: [CALayer] = []
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private var currentWidth: CGFloat = 0
    private var currentVisual: PillVisual?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        bg.fillColor = CGColor(red: 0.055, green: 0.055, blue: 0.065, alpha: 1)
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

        for _ in 0..<5 {
            let dot = CALayer()
            dot.backgroundColor = NSColor.white.cgColor
            dot.cornerRadius = VisualizerMath.chaseDot / 2
            dot.bounds = CGRect(x: 0, y: 0, width: VisualizerMath.chaseDot, height: VisualizerMath.chaseDot)
            dot.opacity = 0.35
            flashLayers.append(dot)
            layer?.addSublayer(dot)
        }

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.frame = CGRect(x: 0, y: 0, width: VisualizerMath.spinnerSize, height: VisualizerMath.spinnerSize)
        addSubview(spinner)

        label.textColor = .white
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)

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
        bg.path = CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: width, height: h),
            cornerWidth: h / 2, cornerHeight: h / 2, transform: nil
        )
        let midY = h / 2

        // Recording block: dot + gap + bars, centered.
        let barsBlock = CGFloat(VisualizerMath.barCount) * VisualizerMath.barPitch
        let recordBlock = VisualizerMath.recordDot + 6 + barsBlock
        var x = (width - recordBlock) / 2
        recordDot.position = CGPoint(x: x + VisualizerMath.recordDot / 2, y: midY)
        x += VisualizerMath.recordDot + 6
        for (i, bar) in barLayers.enumerated() {
            bar.position = CGPoint(x: x + CGFloat(i) * VisualizerMath.barPitch + VisualizerMath.barPitch / 2, y: midY)
        }

        // Chase block: dots (+ spinner), centered.
        let dotsBlock = CGFloat(VisualizerMath.dotCount - 1) * VisualizerMath.chasePitch + VisualizerMath.chaseDot
        var dotsX = (width - dotsBlock) / 2
        if currentVisual == .dotsSpinner {
            dotsX = (width - (dotsBlock + 8 + VisualizerMath.spinnerSize)) / 2
        }
        for (i, dot) in chaseLayers.enumerated() {
            dot.position = CGPoint(x: dotsX + CGFloat(i) * VisualizerMath.chasePitch + VisualizerMath.chaseDot / 2, y: midY)
        }
        spinner.setFrameOrigin(NSPoint(
            x: dotsX + dotsBlock + 8,
            y: midY - VisualizerMath.spinnerSize / 2
        ))

        // Flash: 5 static dots, centered.
        let flashBlock = 4 * VisualizerMath.chasePitch + VisualizerMath.chaseDot
        let flashX = (width - flashBlock) / 2
        for (i, dot) in flashLayers.enumerated() {
            dot.position = CGPoint(x: flashX + CGFloat(i) * VisualizerMath.chasePitch + VisualizerMath.chaseDot / 2, y: midY)
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
    func show(visual: PillVisual) {
        if visual != currentVisual {
            showOnly(visual)
            currentVisual = visual
        }
    }

    /// Per-frame values. No implicit actions (already-smoothed model data);
    /// the spinner/visibility in `show` above carries the motion.
    func update(values: [Float], tick: UInt64, text: String?, centerText: Bool, reduceMotion: Bool) {
        let frozenTick: UInt64 = reduceMotion ? 0 : tick
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch currentVisual {
        case .bars:
            for (i, bar) in barLayers.enumerated() {
                let level: CGFloat = if reduceMotion { 0.3 } else {
                    CGFloat(i < values.count ? values[i] : 0)
                }
                bar.transform = CATransform3DMakeScale(1, max(0.02, level), 1)
            }
            recordDot.opacity = reduceMotion ? 1 : Float(VisualizerMath.breatheOpacity(tick: frozenTick))
        case .dots, .dotsSpinner, .flash, .none:
            for (i, dot) in chaseLayers.enumerated() {
                dot.opacity = reduceMotion ? 0.6 : Float(VisualizerMath.dotOpacity(index: i, tick: frozenTick))
            }
        case .message:
            if let text { label.stringValue = text }
            label.alignment = centerText ? .center : .left
        }
        CATransaction.commit()
        if currentVisual == .dotsSpinner, !reduceMotion { spinner.startAnimation(nil) }
        else { spinner.stopAnimation(nil) }
        spinner.isHidden = reduceMotion || currentVisual != .dotsSpinner
    }

    /// Group visibility with a render-server fade. Model values flip
    /// immediately (assertable headless); pixels interpolate on the GPU.
    private func showOnly(_ visual: PillVisual?) {        CATransaction.begin()
        CATransaction.setAnimationDuration(0.22)
        let barsOn = visual == .bars
        recordDot.opacity = barsOn ? recordDot.opacity : 0
        barLayers.forEach { $0.opacity = barsOn ? 1 : 0 }
        let dotsOn = visual == .dots || visual == .dotsSpinner
        chaseLayers.forEach { $0.opacity = dotsOn ? $0.opacity : 0 }
        flashLayers.forEach { $0.opacity = visual == .flash ? 0.35 : 0 }
        CATransaction.commit()
        label.isHidden = visual != .message
        if visual != .dotsSpinner { spinner.stopAnimation(nil); spinner.isHidden = true }
    }

    // MARK: - Test hooks (layer model values, no window needed)

    func barOpacity(_ i: Int) -> Float { barLayers[i].opacity }
    func dotOpacity() -> Float { recordDot.opacity }
    func chaseOpacity(_ i: Int) -> Float { chaseLayers[i].opacity }
    func flashOpacity(_ i: Int) -> Float { flashLayers[i].opacity }
    func barScaleY(_ i: Int) -> CGFloat { barLayers[i].transform.m22 }
    func spinnerHidden() -> Bool { spinner.isHidden }
    func labelText() -> String { label.stringValue }
}
