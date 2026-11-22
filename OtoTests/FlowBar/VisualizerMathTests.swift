//
//  VisualizerMathTests.swift
//  OtoTests
//
//  Slice 6B: the motion numbers. Loudness maps dB → 0…1 honestly, the
//  smoothing step is frame-rate compensated, the envelope shapes one row,
//  the ripple is periodic and staggered, bar scales stay inside the layer,
//  chase head is brightest, spinner steps evenly, widths match the compact
//  table.
//

import Foundation
import Testing
@testable import Oto

@MainActor
struct VisualizerMathTests {
    // MARK: - Loudness (one broadband level)

    @Test func levelMapsTheDBRangeLinearly() {
        // The two calibration constants are the contract: floor → 0,
        // ceiling → 1, midpoint → 0.5. RMS is dB-referred to full scale.
        #expect(VisualizerMath.level(rms: 0) == 0)
        #expect(abs(VisualizerMath.level(rms: decibels(VisualizerMath.levelFloorDB)) - 0) < 0.0001)
        #expect(abs(VisualizerMath.level(rms: decibels(VisualizerMath.levelCeilingDB)) - 1) < 0.0001)
        #expect(abs(VisualizerMath.level(rms: decibels(
            (VisualizerMath.levelFloorDB + VisualizerMath.levelCeilingDB) / 2
        )) - 0.5) < 0.0001)
        // Below the floor and above the ceiling clamp — never overflow.
        #expect(VisualizerMath.level(rms: decibels(VisualizerMath.levelFloorDB - 20)) == 0)
        #expect(VisualizerMath.level(rms: decibels(VisualizerMath.levelCeilingDB + 20)) == 1)
    }

    @Test func levelRisesWithLoudness() {
        // Loudness survives: this is exactly what the old per-band
        // normalization erased.
        let quiet = VisualizerMath.level(rms: decibels(-40))
        let normal = VisualizerMath.level(rms: decibels(-30))
        let loud = VisualizerMath.level(rms: decibels(-20))
        #expect(quiet < normal)
        #expect(normal < loud)
    }

    @Test func levelNeverReturnsNaN() {
        #expect(VisualizerMath.level(rms: -1) == 0)
        #expect(VisualizerMath.level(rms: .nan) == 0)
        // Non-finite input is treated as silence, never propagated.
        #expect(VisualizerMath.level(rms: .infinity) == 0)
    }

    @Test func smoothingIsFrameRateIndependent() {
        // One 1/60 s step equals two 1/120 s steps: the alpha is an
        // exponential in dt, so 60 and 120 Hz displays settle identically.
        let once = VisualizerMath.smoothLevel(current: 0, target: 1, dt: 1.0 / 60)
        var twice = VisualizerMath.smoothLevel(current: 0, target: 1, dt: 1.0 / 120)
        twice = VisualizerMath.smoothLevel(current: twice, target: 1, dt: 1.0 / 120)
        #expect(abs(once - twice) < 0.0001)
        // Asymmetric by design (plan/pill-wave-sensitivity.md): a rising
        // target moves by (1 − attackKeeper) per 60 fps frame, a falling one
        // by (1 − releaseKeeper) — asserted against the constants so a
        // recalibration can't leave this test asserting yesterday's value.
        #expect(abs(once - (1 - VisualizerMath.attackKeeper)) < 0.0001)
        // Single-pole: always inside the gap, never overshoots.
        #expect(VisualizerMath.smoothLevel(current: 0.5, target: 5, dt: 1.0 / 60) <= 1)
        #expect(VisualizerMath.smoothLevel(current: 0.5, target: -5, dt: 1.0 / 60) >= 0)
        // Rising and falling share one time constant per direction and a
        // bigger dt moves further.
        let slow = VisualizerMath.smoothLevel(current: 0, target: 1, dt: 0.01)
        let fast = VisualizerMath.smoothLevel(current: 0, target: 1, dt: 0.05)
        #expect(fast > slow)
        #expect(abs(VisualizerMath.smoothLevel(current: 1, target: 0, dt: 1.0 / 60)
            - VisualizerMath.releaseKeeper) < 0.0001)
        // Release is slower than attack: the wave punches, then relaxes.
        #expect(VisualizerMath.releaseKeeper > VisualizerMath.attackKeeper)
    }

    // MARK: - Envelope and ripple

    @Test func envelopeIsParabolicAndMirrored() {
        // The reference's max(0, 1 - h²/48): 0.995 centre, 0.578 edges for
        // ten bars, symmetric, monotonic toward the centre.
        #expect(abs(VisualizerMath.envelope(index: 4) - 0.995) < 0.001)
        #expect(abs(VisualizerMath.envelope(index: 5) - 0.995) < 0.001)
        #expect(abs(VisualizerMath.envelope(index: 0) - 0.578125) < 0.0001)
        #expect(abs(VisualizerMath.envelope(index: 9) - 0.578125) < 0.0001)
        for i in 0..<(VisualizerMath.barCount / 2 - 1) {
            #expect(
                abs(VisualizerMath.envelope(index: i)
                    - VisualizerMath.envelope(index: VisualizerMath.barCount - 1 - i)) < 0.0001
            )
            #expect(VisualizerMath.envelope(index: i + 1) > VisualizerMath.envelope(index: i))
        }
        // The two centre bars are equal — the plateau of the parabola.
        #expect(VisualizerMath.envelope(index: 5) == VisualizerMath.envelope(index: 4))
        // Degenerate shapes stay safe.
        #expect(VisualizerMath.envelope(index: 0, count: 1) == 1)
        #expect(VisualizerMath.envelope(index: 0, count: 0) == 1)
    }

    @Test func staggerMakesThePeakTravel() {
        // 0,1,2,3,4,-5,-4,-3,-2,-1 — the negative tail is the traveling
        // wave (a symmetric 0…5 stagger would pulse instead).
        let offsets = (0..<VisualizerMath.barCount).map {
            VisualizerMath.centerOffset(index: $0)
        }
        #expect(offsets == [0, 1, 2, 3, 4, -5, -4, -3, -2, -1])
    }

    @Test func rippleHitsItsKeyframesAndRepeats() {
        // The CSS keyframes, exactly: 1 → 1.2 → 1.5 → 1.1 → 1.3 → 1.
        #expect(abs(VisualizerMath.ripple(phase: 0) - 1.0) < 0.0001)
        #expect(abs(VisualizerMath.ripple(phase: 0.2) - 1.2) < 0.0001)
        #expect(abs(VisualizerMath.ripple(phase: 0.4) - 1.5) < 0.0001)
        #expect(abs(VisualizerMath.ripple(phase: 0.8) - 1.1) < 0.0001)
        #expect(abs(VisualizerMath.ripple(phase: 0.9) - 1.3) < 0.0001)
        #expect(abs(VisualizerMath.ripple(phase: 1.0) - 1.0) < 0.0001)
        // 1 s loop: wrapped and offset phases agree.
        #expect(abs(VisualizerMath.ripple(phase: 0.35) - VisualizerMath.ripple(phase: 3.35)) < 0.0001)
        #expect(abs(VisualizerMath.ripple(phase: 0.35) - VisualizerMath.ripple(phase: -0.65)) < 0.0001)
        // Eased, not stepped: mid-segment sits between its keyframes.
        #expect(VisualizerMath.ripple(phase: 0.3999) < 1.5)
        #expect(VisualizerMath.ripple(phase: 0.1) > 1.05)
    }

    // MARK: - Bar scales

    @Test func silenceKeepsAnAliveShapedRow() {
        // `max(1, gain × level)` floors the row at the resting size: the
        // pill is never blank, and silence still ripples.
        let heights = (0..<VisualizerMath.barCount).map { i in
            CGFloat(VisualizerMath.barScale(index: i, level: 0, time: 0.3))
                * VisualizerMath.barFullHeight
        }
        #expect(heights.allSatisfy { $0 > 1.0 })
        #expect(heights.allSatisfy { $0 < 4.0 })
    }

    @Test func loudestRippleFrameLandsOnMaxBarHeight() {
        // Loudest level, centre bar, ripple peak (40% of its cycle):
        // exactly maxBarHeight, and never taller than the layer.
        // Bar 4 has stagger 4 → phase = t - 0.4; at t = 0.8 the phase is 0.4.
        let scale = VisualizerMath.barScale(index: 4, level: 1, time: 0.8)
        let height = CGFloat(scale) * VisualizerMath.barFullHeight
        #expect(abs(height - VisualizerMath.maxBarHeight) < 0.1)
        #expect(abs(VisualizerMath.ripple(phase: 0.4) - VisualizerMath.ripplePeak) < 0.0001)
    }

    @Test func everyScaleStaysInsideTheLayer() {
        for i in 0..<VisualizerMath.barCount {
            for level in stride(from: Float(0), through: 1, by: 0.1) {
                for time in stride(from: 0.0, through: 2.0, by: 0.05) {
                    let scale = VisualizerMath.barScale(index: i, level: level, time: time)
                    #expect(scale >= 0)
                    #expect(scale <= 1)
                    #expect(!scale.isNaN)
                }
            }
        }
    }

    @Test func louderIsTallerAcrossTheWholeRow() {
        // Loudness scales the row (not just spectral tilt): every bar's
        // quiet-frame height is below its own loud-frame height.
        for i in 0..<VisualizerMath.barCount {
            let quiet = VisualizerMath.barScale(index: i, level: 0.1, time: 0.8)
            let loud = VisualizerMath.barScale(index: i, level: 0.9, time: 0.8)
            #expect(loud > quiet)
        }
    }

    @Test func reduceMotionHoldsOneStillShapedRow() {
        // No ripple, no display-link motion — but the silhouette survives
        // (never a blank pill), and the envelope still shapes it.
        let centre = VisualizerMath.staticScale(index: 4)
        let edge = VisualizerMath.staticScale(index: 0)
        #expect(centre > edge)
        #expect(edge > 0)
        #expect(centre <= 1)
    }

    // MARK: - Chase (render-server motion)

    @Test func chaseHeadIsBrightestAndWraps() {
        let bright = VisualizerMath.dotOpacity(index: 4, tick: 4)
        #expect(bright > 0.99)
        #expect(VisualizerMath.dotOpacity(index: 0, tick: 4) < bright)
        // Same phase one full cycle later.
        #expect(VisualizerMath.dotOpacity(index: 2, tick: 2) == VisualizerMath.dotOpacity(index: 2, tick: 11))
        // Floor: tail never vanishes.
        #expect(VisualizerMath.dotOpacity(index: 0, tick: 4) >= 0.25)
    }

    @Test func chaseGlidesContinuouslyAndWraps() {
        // v5: the render-server wave samples this curve. Fractional head —
        // dot 0 peaks at head 0, rests at 0.25 mid-cycle, wraps (head 8.5
        // is 0.5 away, nearly bright again).
        #expect(VisualizerMath.dotOpacityContinuous(index: 0, head: 0) > 0.99)
        #expect(abs(VisualizerMath.dotOpacityContinuous(index: 0, head: 4.5) - 0.25) < 0.001)
        #expect(VisualizerMath.dotOpacityContinuous(index: 0, head: 8.5) > 0.8)
        // Legacy tick wrapper agrees with the integer head.
        #expect(VisualizerMath.dotOpacity(index: 2, tick: 2)
            == VisualizerMath.dotOpacityContinuous(index: 2, head: 2))
        #expect(VisualizerMath.dotOpacity(index: 2, tick: 2)
            == VisualizerMath.dotOpacity(index: 2, tick: 11))
    }

    // MARK: - Geometry and shimmer

    @Test func widthsAreMini() {
        // 2026-11-01: the record dot is gone, so the capsule hugs the bar
        // row — 10 × 5.61 = 56.1 plus 12.375 of air at each end.
        #expect(VisualizerMath.panelWidth(for: .recording) == 80.85)
        #expect(VisualizerMath.dictationWidth == 80.85)
        // v6: preparing == recording — waves from frame one, zero resize.
        #expect(VisualizerMath.panelWidth(for: .preparing) == 80.85)
        #expect(VisualizerMath.panelWidth(for: .finalizing) == 95.7)
        #expect(VisualizerMath.panelWidth(for: .inserting) == 95.7)
        #expect(VisualizerMath.panelWidth(for: .hidden) == 0)
        // Over-limit Copied pill renders at current pill size: switching
        // from dictation visuals is a re-render, never a resize.
        #expect(VisualizerMath.panelWidth(for: .message) == 80.85)
        // v7: no failure arm (errors never reach the pill). The v7 wide
        // auto-copy notice is removed: clipboard auto-copy stays silent.
        #expect(VisualizerMath.panelWidth(for: .recording) <= 95.7)
        #expect(VisualizerMath.pillHeight == 26.4)
        // Elements shrink, count stays.
        #expect(VisualizerMath.barCount == 10)
        #expect(VisualizerMath.barWidth == 2.5)
        // Geometry is single-sourced now: the layer height lives here.
        #expect(VisualizerMath.barFullHeight == 16.5)
        #expect(VisualizerMath.maxBarHeight < VisualizerMath.barFullHeight)
    }

    @Test func shineScalesWithWidthAtConstantVelocity() {
        // Narrow verbs still get a real sweep (floor); wider verbs scale
        // the band. Duration is travel/velocity — constant physics for
        // Cleaning..Formalizing, never constant time.
        let narrow = VisualizerMath.shineBandWidth(forLabelWidth: 20)
        #expect(narrow == VisualizerMath.shineMinBand)
        let wide = VisualizerMath.shineBandWidth(forLabelWidth: 120)
        #expect(wide == 60)
        #expect(VisualizerMath.shineTravel(forLabelWidth: 60)
            == 60 + 2 * VisualizerMath.shineBandWidth(forLabelWidth: 60))
        let d60 = VisualizerMath.shineDuration(forLabelWidth: 60)
        let d120 = VisualizerMath.shineDuration(forLabelWidth: 120)
        #expect(d120 > d60)
        // Constant velocity: duration/travel identical across widths.
        let v60 = 60 + 2 * VisualizerMath.shineBandWidth(forLabelWidth: 60)
        let v120 = 120 + 2 * VisualizerMath.shineBandWidth(forLabelWidth: 120)
        #expect(abs(d60 / Double(v60) - d120 / Double(v120)) < 0.000_001)
        #expect(VisualizerMath.shineBaseAlpha == 0.45)
    }

    // MARK: - Helpers

    /// Linear RMS amplitude for a dBFS value: dB = 20 log10(rms).
    private func decibels(_ db: Float) -> Float {
        pow(10, db / 20)
    }
}
