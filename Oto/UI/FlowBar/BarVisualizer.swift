//
//  BarVisualizer.swift
//  Oto
//
//  Slice 6B: the pill's Canvas. Dumb by design — every number arrives as
//  parameters (values already smoothed by the model, tick already gated by
//  Reduce Motion upstream). Redraws only when BarSample changes (≤30 Hz).
//  No TimelineView (policy ban, 09 §2.2).
//

import SwiftUI

/// What the Canvas draws. Views pick the mode from FlowBarState; the math
/// for every mode lives in VisualizerMath.
enum VisualizerMode: Equatable {
    case bars
    case dots
    case dotsSpinner
    case flash
    case failureDot
    case staticMark
}

struct BarVisualizer: View {
    let mode: VisualizerMode
    let values: [Float]
    let tick: UInt64
    let handsFree: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Canvas { context, size in
            switch mode {
            case .bars:
                drawBars(in: &context, size: size)
            case .dots:
                drawDots(in: &context, size: size, spinner: false)
            case .dotsSpinner:
                drawDots(in: &context, size: size, spinner: true)
            case .flash:
                drawDots(in: &context, size: size, spinner: false, dim: 0.35)
            case .failureDot:
                drawDot(in: &context, size: size, color: .orange)
            case .staticMark:
                drawStaticMark(in: &context, size: size)
            }
        }
    }

    // MARK: - Bars (recording: red dot + live voice bars)

    private func drawBars(in context: inout GraphicsContext, size: CGSize) {
        let count = VisualizerMath.barCount
        // Small dot (reference-proportioned) + thin bars with airy gaps
        // (bar ≈ half the slot — the reference airiness).
        let dotDiameter: CGFloat = 10
        let gapFraction: CGFloat = 0.5
        // Left red dot (breathe frozen upstream under Reduce Motion).
        let dotOpacity = reduceMotion ? 1 : VisualizerMath.breatheOpacity(tick: tick)
        let dotRect = CGRect(
            x: 0, y: (size.height - dotDiameter) / 2,
            width: dotDiameter, height: dotDiameter
        )
        context.opacity = dotOpacity
        context.fill(Capsule().path(in: dotRect), with: .color(.red))
        if handsFree {
            context.opacity = 0.6
            context.stroke(
                Capsule().path(in: dotRect.insetBy(dx: -4, dy: -4)),
                with: .color(.red), lineWidth: 1.5
            )
        }
        context.opacity = 1
        // Voice bars fill the remainder.
        let barsOrigin = dotDiameter + 10
        let barsWidth = max(0, size.width - barsOrigin)
        let slot = barsWidth / CGFloat(count)
        let barWidth = max(2, slot * (1 - gapFraction))
        for i in 0..<count {
            let level = i < values.count ? CGFloat(values[i]) : 0
            let height = max(3, level * size.height)
            let rect = CGRect(
                x: barsOrigin + CGFloat(i) * slot + (slot - barWidth) / 2,
                y: (size.height - height) / 2,
                width: barWidth, height: height
            )
            context.fill(Capsule().path(in: rect), with: .color(.white))
        }
    }

    // MARK: - Dots chase + spinner (working)

    private func drawDots(
        in context: inout GraphicsContext, size: CGSize, spinner: Bool, dim: Double = 1
    ) {
        let count = VisualizerMath.dotCount
        let dotDiameter: CGFloat = 4
        let pitch: CGFloat = 11
        let total = CGFloat(count - 1) * pitch + dotDiameter
        var origin = (size.width - total) / 2
        if spinner { origin -= 10 }
        let y = (size.height - dotDiameter) / 2
        for i in 0..<count {
            let opacity = (reduceMotion ? 0.6 : VisualizerMath.dotOpacity(index: i, tick: tick)) * dim
            let rect = CGRect(x: origin + CGFloat(i) * pitch, y: y, width: dotDiameter, height: dotDiameter)
            context.opacity = opacity
            context.fill(Capsule().path(in: rect), with: .color(.white))
        }
        context.opacity = 1
        if spinner { drawSpinner(in: &context, size: size) }
    }

    /// 8-spoke macOS-style spinner (the img1 mark), rotated by tick.
    private func drawSpinner(in context: inout GraphicsContext, size: CGSize) {
        let spokes = 8
        let radius: CGFloat = 11
        let center = CGPoint(x: size.width - 20, y: size.height / 2)
        let baseAngle = reduceMotion ? 0 : VisualizerMath.spinnerAngle(tick: tick)
        for s in 0..<spokes {
            let angle = baseAngle + Double(s) * Double.pi * 2 / Double(spokes)
            // Trailing spokes fade (comet tail sells rotation at 7 fps).
            let fade = 1 - Double(s) / Double(spokes)
            let p1 = CGPoint(
                x: center.x + cos(angle) * (radius - 5),
                y: center.y + sin(angle) * (radius - 5)
            )
            let p2 = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            var path = Path()
            path.move(to: p1)
            path.addLine(to: p2)
            context.opacity = 0.25 + 0.75 * fade
            context.stroke(path, with: .color(.white), lineWidth: 2)
        }
        context.opacity = 1
    }

    // MARK: - Small marks

    private func drawDot(in context: inout GraphicsContext, size: CGSize, color: Color) {
        let diameter: CGFloat = 10
        let rect = CGRect(
            x: 16, y: (size.height - diameter) / 2,
            width: diameter, height: diameter
        )
        context.fill(Capsule().path(in: rect), with: .color(color))
    }

    /// Static waveform mark (catcher modal header). Fixed arch, no motion.
    private func drawStaticMark(in context: inout GraphicsContext, size: CGSize) {
        let levels: [CGFloat] = [0.45, 0.7, 1.0, 0.7, 0.45]
        let barWidth: CGFloat = 3
        let pitch: CGFloat = 6
        let total = CGFloat(levels.count - 1) * pitch + barWidth
        let origin = (size.width - total) / 2
        for (i, level) in levels.enumerated() {
            let height = max(3, level * size.height)
            let rect = CGRect(
                x: origin + CGFloat(i) * pitch,
                y: (size.height - height) / 2,
                width: barWidth, height: height
            )
            context.fill(Capsule().path(in: rect), with: .color(.white))
        }
    }
}
