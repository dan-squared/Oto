//
//  VisualizerMath.swift
//  Oto
//
//  Slice 6B: every motion number in the pill, pure and headless-tested.
//  Views own no constants; the analyzer owns no smoothing. Realism comes
//  from real band data shaped here: fast attack / slow release (consonants
//  snap, vowels decay), a hard floor (bars never vanish), log-mapped band
//  levels, and a continuous chase/breathe curve sampled by the render-server
//  animations (the legacy tick wrappers pin the same curve at integer
//  phases — deterministic, no wall-clock in tests).
//

import CoreGraphics
import Foundation

/// One visualizer frame. Raw band levels 0…1 (count == barCount);
/// `tick` advances once per publish (analyzer → model smoothing clock).
/// Indeterminate motion (chase, breathe) ignores it — the pill's
/// render-server animations sample VisualizerMath's continuous curve, so
/// the loader stays alive with no audio and costs zero MainActor time.
struct BarSample: Equatable, Sendable {
    // Explicit nonisolated equality (FlowBarState.swift precedent).
    nonisolated static func == (lhs: BarSample, rhs: BarSample) -> Bool {
        lhs.values == rhs.values && lhs.tick == rhs.tick
    }

    let values: [Float]
    let tick: UInt64

    nonisolated static var silence: BarSample {
        BarSample(values: [Float](repeating: 0, count: VisualizerMath.barCount), tick: 0)
    }
}

enum VisualizerMath {
    // MARK: - Constants (the whole look, in one place)

    /// Reference pill (8 thin capsule bars + small red dot).
    nonisolated static let barCount = 8
    /// Consonants snap.
    nonisolated static let attack: Float = 0.55
    /// Vowels decay — the asymmetry that reads as "real".
    nonisolated static let release: Float = 0.12
    /// Bars never vanish (silence sits, never bounces — honest).
    nonisolated static let floor: Float = 0.10
    /// Pill geometry (pt). Mini v3: half the v2 area, reference-matched.
    nonisolated static let pillHeight: CGFloat = 32
    /// Thin-bar system (elements shrink, count stays 8).
    nonisolated static let barWidth: CGFloat = 3.5
    nonisolated static let barPitch: CGFloat = 8.5
    /// Small red dot, no ring.
    nonisolated static let recordDot: CGFloat = 8
    /// Chase dots (reference-proportioned).
    nonisolated static let chaseDot: CGFloat = 3
    nonisolated static let chasePitch: CGFloat = 8
    /// Native spinner footprint.
    nonisolated static let spinnerSize: CGFloat = 16
    /// Dots in the working chase.
    nonisolated static let dotCount = 9

    /// Panel widths per pill case (pt). Width motion itself is owned by
    /// the AppKit frame animation; this table is the target.
    /// v6: preparing == recording (112) — starting→recording resizes
    /// nothing, waves from frame one. No end-state widths: completion
    /// renders no pixels (vanish path owns the exit).
    nonisolated static func panelWidth(for state: FlowBarState) -> CGFloat {
        switch state {
        case .hidden: 0
        case .preparing: 112
        case .recording: 112
        case .finalizing: 116
        case .inserting: 116
        case .failure: 200
        }
    }

    // MARK: - Idle sway (v6: "waves move a bit")

    /// Voice-silence gate: display levels below this mean no voice, so the
    /// render-server sway owns the bars. First voice poll removes it.
    /// (Silence sits at `floor` = 0.10; voice clears 0.18 within 1–2 polls.)
    nonisolated static let swayThreshold: Float = 0.18
    /// Sway keyframe loop (scaleY): gentle drift near the floor, staggered
    /// per bar via beginTime. Peaks at 0.26 — alive, never shouty.
    nonisolated static let swayValues: [Double] = [0.10, 0.18, 0.26, 0.18, 0.10]
    nonisolated static let swayCycle: Double = 1.8
    nonisolated static let swayStagger: Double = 0.2

    // MARK: - Bar shaping

    /// One smoothing step toward target. Direction picks the coefficient:
    /// rising uses attack, falling uses release.
    nonisolated static func smoothStep(current: Float, target: Float) -> Float {
        let clamped = min(1, max(0, target))
        let rate = clamped > current ? attack : release
        return current + (clamped - current) * rate
    }

    /// Display mapping: floor lift, still 0…1.
    nonisolated static func displayValue(_ smoothed: Float) -> Float {
        floor + (1 - floor) * min(1, max(0, smoothed))
    }

    /// Log-spaced band edges (Hz) over [lowEdge, highEdge], count+1 points.
    /// Voice-weighted: log spacing spends bands where speech lives.
    nonisolated static func bandEdges(
        count: Int, lowEdge: Float = 80, highEdge: Float = 8000
    ) -> [Float] {
        precondition(count > 0)
        let low = log10(lowEdge)
        let high = log10(highEdge)
        return (0...count).map { i in
            pow(10, low + (high - low) * Float(i) / Float(count))
        }
    }

    /// Bin-power magnitudes → per-band energies (sum of mag²), then
    /// log-mapped to 0…1 display levels. `binHz` = sampleRate / fftSize.
    /// Total-zero (digital silence) maps to all-zero, never NaN.
    nonisolated static func bandLevels(
        magnitudes: [Float], edges: [Float], binHz: Float
    ) -> [Float] {
        let bandCount = edges.count - 1
        guard bandCount > 0, binHz > 0 else {
            return [Float](repeating: 0, count: max(0, edges.count - 1))
        }
        var energies = [Float](repeating: 0, count: bandCount)
        for (bin, mag) in magnitudes.enumerated() {
            let freq = Float(bin) * binHz
            for b in 0..<bandCount where freq >= edges[b] && freq < edges[b + 1] {
                energies[b] += mag * mag
                break
            }
        }
        let total = energies.reduce(0, +)
        guard total > 0 else { return [Float](repeating: 0, count: bandCount) }
        // log10(1 + 99e)/2: e=0→0, e=1→1, mid energies spread evenly.
        return energies.map { e in
            let normalized = e / total
            return log10(1 + 99 * normalized) / 2
        }
    }

    // MARK: - Indeterminate motion (display-link phase, no wall-clock)

    /// Dots-chase opacity: the head dot is brightest, tail falls off over
    /// ~3 dots. Head advances one dot per tick, wraps.
    nonisolated static func dotOpacity(index: Int, tick: UInt64, count: Int = dotCount) -> Double {
        dotOpacityContinuous(index: index, head: Double(tick % UInt64(count)), count: count)
    }

    /// Continuous chase head (fractional — display-link driven). The
    /// integer version above is one sample of this function.
    nonisolated static func dotOpacityContinuous(index: Int, head: Double, count: Int = dotCount) -> Double {
        guard count > 0 else { return 0.25 }
        var distance = abs(Double(index) - head)
        distance = min(distance, Double(count) - distance)
        return 0.25 + 0.75 * max(0, 1 - distance / 3)
    }

    /// Red-dot breathe opacity: 2 s period on the 60 fps display-link phase.
    nonisolated static func breatheOpacityContinuous(phase: Double) -> Double {
        0.55 + 0.45 * (0.5 + 0.5 * cos(phase * Double.pi * 2 / 120))
    }

    /// Legacy tick-based breathe (analyzer clock). Superseded by the
    /// display-link phase above; kept for API stability, unused by views.
    nonisolated static func breatheOpacity(tick: UInt64) -> Double {
        breatheOpacityContinuous(phase: Double(tick) * 4)
    }
}
