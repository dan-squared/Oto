//
//  VisualizerMath.swift
//  Oto
//
//  Slice 6B: every motion number in the pill, pure and headless-tested.
//  Views own no constants; the analyzer owns no smoothing. Realism comes
//  from real band data shaped here: fast attack / slow release (consonants
//  snap, vowels decay), a hard floor (bars never vanish), log-mapped band
//  levels, and deterministic chase/spinner phases off the sample tick.
//

import CoreGraphics
import Foundation

/// One visualizer frame. Raw band levels 0…1 (count == barCount);
/// `tick` advances once per publish and drives all indeterminate motion
/// (dots chase, spinner, breathe) — deterministic, no wall-clock in views.
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

    /// Matches the reference pill (10 capsule bars).
    nonisolated static let barCount = 10
    /// Consonants snap.
    nonisolated static let attack: Float = 0.55
    /// Vowels decay — the asymmetry that reads as "real".
    nonisolated static let release: Float = 0.12
    /// Bars never vanish (silence sits, never bounces — honest).
    nonisolated static let floor: Float = 0.10
    /// Pill geometry (pt). Compact per "little, not big".
    nonisolated static let pillHeight: CGFloat = 60
    /// Dots in the working chase.
    nonisolated static let dotCount = 9
    /// Spinner step per tick: 60° @ ~6.7 ticks/s ≈ 0.9 s/rev.
    nonisolated static let spinnerStep = Double.pi / 3

    /// Panel widths per pill case (pt). Width motion itself is owned by
    /// the AppKit frame animation; this table is the target.
    nonisolated static func panelWidth(for state: FlowBarState) -> CGFloat {
        switch state {
        case .hidden: 0
        case .preparing: 208
        case .recording: 232
        case .finalizing: 208
        case .inserting: 208
        case .successFlash: 128
        case .cancelledFlash: 128
        case .failure: 280
        }
    }

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

    // MARK: - Indeterminate motion (all f(tick), no wall-clock)

    /// Dots-chase opacity: the head dot is brightest, tail falls off over
    /// ~3 dots. Head advances one dot per tick, wraps.
    nonisolated static func dotOpacity(index: Int, tick: UInt64, count: Int = dotCount) -> Double {
        guard count > 0 else { return 0.25 }
        let head = Int(tick % UInt64(count))
        var distance = abs(index - head)
        distance = min(distance, count - distance)
        return 0.25 + 0.75 * max(0, 1 - Double(distance) / 3)
    }

    /// Spinner angle (radians) for a tick.
    nonisolated static func spinnerAngle(tick: UInt64) -> Double {
        Double(tick) * spinnerStep
    }

    /// Red-dot breathe opacity: 2 s period at ~6.7 ticks/s.
    nonisolated static func breatheOpacity(tick: UInt64) -> Double {
        0.55 + 0.45 * (0.5 + 0.5 * cos(Double(tick) * Double.pi / 6.7))
    }
}
