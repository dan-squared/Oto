//
//  VisualizerMath.swift
//  Oto
//
//  Slice 6B: every motion number in the pill, pure and headless-tested.
//  Views own no constants; the analyzer owns no smoothing.
//
//  The voice wave is not a spectrum analyzer. One broadband loudness value
//  (RMS → dB → 0…1) is smoothed per display frame and shaped by a fixed
//  parabolic envelope plus a permanent, staggered 1 s ripple — the model the
//  reference pill actually uses. Loudness survives, the row reads as one
//  shape, and silence keeps micro-motion without a second idle animation.
//

import AppKit
import CoreGraphics
import Foundation

/// One visualizer frame. `level` is the smoothed broadband loudness 0…1
/// (0 == silence); `tick` advances once per analyzer publish (poll-path
/// bookkeeping only — the wave itself is a pure function of level + time).
struct BarSample: Equatable, Sendable {
    // Explicit nonisolated equality (FlowBarState.swift precedent).
    nonisolated static func == (lhs: BarSample, rhs: BarSample) -> Bool {
        lhs.level == rhs.level && lhs.tick == rhs.tick
    }

    let level: Float
    let tick: UInt64

    nonisolated static var silence: BarSample {
        BarSample(level: 0, tick: 0)
    }
}

enum VisualizerMath {
    // MARK: - Constants (the whole look, in one place)

    /// Ten thin capsule bars, no record dot (removed 2026-11-01: the pip
    /// sat in the soft end of the ramp and broke the gradient's symmetry).
    /// The row is the pill's only content, so the capsule hugs it.
    nonisolated static let barCount = 10
    /// Pill geometry (pt). Relaxed compact: 0.825× the v3 mini in every
    /// linear dimension (112×32=3584 → 92.4×26.4=2439). Count stays 10 —
    /// elements shrink, never vanish (v3 precedent).
    nonisolated static let pillHeight: CGFloat = 26.4
    /// Thin-bar system (elements shrink, count stays 10).
    nonisolated static let barWidth: CGFloat = 2.5
    nonisolated static let barPitch: CGFloat = 5.61
    /// Bar layer height: the tallest the artwork can ever render. Single
    /// geometry source (the layers build their paths from it).
    nonisolated static let barFullHeight: CGFloat = 16.5
    /// Chase dots (reference-proportioned).
    nonisolated static let chaseDot: CGFloat = 2.475
    nonisolated static let chasePitch: CGFloat = 6.6
    /// Native spinner footprint.
    nonisolated static let spinnerSize: CGFloat = 13.2
    /// Dots in the working chase.
    nonisolated static let dotCount = 9

    /// Dictation capsule width (pt). The bar row is the whole content now:
    /// 10 bars at pitch 5.61 = 56.1, inset 12.375 at each end — the side
    /// margin the old dot block used, so the row keeps its optical air and
    /// every bar sits inside the flat middle of the capsule (the caps are
    /// 13.2 wide). 56.1 + 2 × 12.375 = 80.85.
    nonisolated static var dictationWidth: CGFloat {
        CGFloat(barCount) * barPitch + 2 * dictationInset
    }

    /// Side inset of the bar row (pt) — the pill's breathing room.
    nonisolated static let dictationInset: CGFloat = 12.375

    /// Panel widths per pill case (pt). Width motion itself is owned by
    /// the AppKit frame animation; this table is the target.
    /// v6: preparing == recording — starting→recording resizes nothing,
    /// waves from frame one. v7: no failure arm — errors never reach the
    /// pill. (The v7 wide-pill auto-copy notice was removed: clipboard
    /// auto-copy stays silent, menu owns recovery.)
    /// `.message` shares the dictation width so the Copied notice is a
    /// re-render, never a resize.
    nonisolated static func panelWidth(for state: FlowBarState) -> CGFloat {
        switch state {
        case .hidden: 0
        case .preparing: dictationWidth
        case .recording: dictationWidth
        case .finalizing: 95.7
        case .inserting: 95.7
        case .message: dictationWidth
        }
    }

    // MARK: - Work pill (E2: expanding one-word capsule, no divider)

    /// Work-pill chrome (pt). Layout: [padding][text][gap][spinner][padding].
    /// The pill fits its text — the fixed table above never applies to work.
    nonisolated static let workPadding: CGFloat = 8.25
    nonisolated static let workSpinnerGap: CGFloat = 8
    /// Text slack: the text cell needs a few points beyond raw measure or
    /// it ellipsizes on exact fit. Counted in BOTH the width math and the
    /// label layout (single source) — exact-fit truncation can never recur.
    nonisolated static let workTextSlack: CGFloat = 6
    nonisolated static let workMaxWidth: CGFloat = 260

    /// Pill font for work text (matches the layer label).
    nonisolated static var workFont: NSFont { .systemFont(ofSize: 12) }

    /// Measured width of work text at the pill font. Pure over AppKit font
    /// metrics (headless-safe: no window needed) — unit-tested.
    nonisolated static func measureWorkText(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: workFont]).width
    }

    /// Dynamic work-pill width: measured text + slack + chrome, capped
    /// above only. NO minimum: the pill hugs content exactly (a minimum
    /// pads short labels with dead space — the reported defect — and the
    /// pill is non-interactive, so no tap-target floor applies).
    nonisolated static func workPillWidth(textWidth: CGFloat) -> CGFloat {
        let chrome = workPadding * 2 + workSpinnerGap
            + spinnerSize + workTextSlack
        return min(workMaxWidth, ceil(textWidth) + chrome)
    }

    // MARK: - Work shimmer (traveling shine on the work verb)

    /// Base text dim while the shine sweeps (screenshot style): the word
    /// stays legible, the band reads premium. Restored to full white the
    /// moment shimmer leaves. Starting value — eyes judge on device.
    nonisolated static let shineBaseAlpha: CGFloat = 0.45
    /// Shine velocity (pt/s). Duration scales with travel (below), so every
    /// verb sweeps at identical physics — Cleaning and Formalizing differ
    /// in time, never in speed.
    nonisolated static let shineVelocity: CGFloat = 100
    /// Bright-band floor (pt): narrow verbs still get a real sweep, never
    /// a sliver. Wider verbs scale the band with the word.
    nonisolated static let shineMinBand: CGFloat = 28

    /// Bright-band width for a label width. Pure — unit-tested.
    nonisolated static func shineBandWidth(forLabelWidth w: CGFloat) -> CGFloat {
        max(shineMinBand, w * 0.5)
    }

    /// Full sweep travel: the band starts fully left of the text and ends
    /// fully right, so it never pops at the edges. Pure — unit-tested.
    nonisolated static func shineTravel(forLabelWidth w: CGFloat) -> CGFloat {
        w + 2 * shineBandWidth(forLabelWidth: w)
    }

    /// Sweep duration for a label width (travel / velocity). Pure —
    /// unit-tested (constant velocity across verbs, not constant time).
    nonisolated static func shineDuration(forLabelWidth w: CGFloat) -> Double {
        Double(shineTravel(forLabelWidth: w) / shineVelocity)
    }

    // MARK: - Loudness (one broadband level, dB-mapped)

    /// RMS below this is silence (0). Re-centred 2026-11-01 (plan
    /// `pill-wave-sensitivity.md`): the old 45 dB window (-55…-10) put
    /// ordinary speech at level 0.55, i.e. ~8 of 15 pt of bar — the
    /// reported "not reactive, limited vertical distance". A 30 dB window
    /// puts normal speech at ~0.73 (≈11 pt) while the resting floor and a
    /// noisy room stay where they were. Measured against the reference's
    /// 21 frames: Oto's peak-to-pill ratio already exceeds the reference,
    /// so only the input calibration moves — never the geometry.
    nonisolated static let levelFloorDB: Float = -52
    nonisolated static let levelCeilingDB: Float = -22

    /// RMS amplitude → display level 0…1. Loudness is preserved: a whisper
    /// and a shout map to genuinely different levels (the old per-band
    /// normalization erased exactly this).
    nonisolated static func level(rms: Float) -> Float {
        guard rms > 0, rms.isFinite else { return 0 }
        let db = 20 * log10(rms)
        let normalized = (db - levelFloorDB) / (levelCeilingDB - levelFloorDB)
        return min(1, max(0, normalized))
    }

    /// Smoothing keepers (per 60 fps frame). Asymmetric by design: the wave
    /// must punch on a syllable and relax after it. 0.68 → 90 % in ~98 ms
    /// (attack), 0.82 → 90 % in ~200 ms (release). The reference is
    /// symmetric (0.85) plus a slew clamp; we deliberately trade that for
    /// perceived reactivity — see the plan's rejected alternatives.
    nonisolated static let attackKeeper: Float = 0.68
    nonisolated static let releaseKeeper: Float = 0.82

    /// One display-frame smoothing step toward `target`, frame-rate
    /// compensated. Rising targets use the attack keeper, falling targets
    /// the release keeper. `dt` is clamped by the caller
    /// (FlowBarModel.advance).
    nonisolated static func smoothLevel(current: Float, target: Float, dt: Double) -> Float {
        let clamped = min(1, max(0, target))
        let keeper = clamped > current ? attackKeeper : releaseKeeper
        let alpha = Float(1 - pow(Double(keeper), max(0, dt) * 60))
        return current + (clamped - current) * alpha
    }

    // MARK: - Bars (fixed envelope + permanent staggered ripple)

    /// Loudness gain: `max(1, gain × level)` scales the whole row, exactly
    /// like the reference. The floor of 1 is the resting size.
    nonisolated static let audioGain: Float = 5
    /// Ripple peak (1.5 at 40% of the cycle) — the loudest ripple frame.
    nonisolated static let ripplePeak: Float = 1.5
    /// Tallest a bar ever renders (pt). `barFullHeight` keeps the layer
    /// headroom; this is the visible maximum.
    nonisolated static let maxBarHeight: CGFloat = 15
    /// Per-bar ripple delay (s) — the traveling wave.
    nonisolated static let rippleStagger: Double = 0.1
    /// One ripple loop (s).
    nonisolated static let ripplePeriod: Double = 1.0

    /// Scale that puts the loudest, tallest ripple frame exactly on
    /// `maxBarHeight`: 15 / (16.5 × 5 × 1.5) ≈ 0.1212.
    nonisolated static var barScaleBase: Float {
        Float(maxBarHeight / (barFullHeight * CGFloat(audioGain) * CGFloat(ripplePeak)))
    }

    /// Fixed parabolic envelope: the row reads as ONE shape, not ten
    /// strangers. 0.995 at the centre, 0.578 at the edges.
    nonisolated static func envelope(index: Int, count: Int = barCount) -> Float {
        guard count > 1 else { return 1 }
        let h = abs(Float(count - 1) / 2 - Float(index))
        return max(0, 1 - h * h / 48)
    }

    /// Stagger multiplier for a bar: 0,1,2,3,4,-5,-4,-3,-2,-1 for 10 bars.
    /// The negative tail is why the peak travels instead of pulsing.
    nonisolated static func centerOffset(index: Int, count: Int = barCount) -> Int {
        let pivot = (count + 1) / 2
        return index < pivot ? index : index - count
    }

    /// Ripple keyframes: 1 → 1.2 (20%) → 1.5 (40%) → 1.1 (80%) → 1.3 (90%)
    /// → 1 (100%), eased per segment. Device-independent and pure.
    private struct RippleKeyframe: Sendable {
        let phase: Double
        let value: Float
    }

    private nonisolated static let rippleKeyframes: [RippleKeyframe] = [
        RippleKeyframe(phase: 0.0, value: 1.0),
        RippleKeyframe(phase: 0.2, value: 1.2),
        RippleKeyframe(phase: 0.4, value: 1.5),
        RippleKeyframe(phase: 0.8, value: 1.1),
        RippleKeyframe(phase: 0.9, value: 1.3),
        RippleKeyframe(phase: 1.0, value: 1.0),
    ]

    /// Ripple multiplier at `phase` (any value; wrapped). Smoothstep inside
    /// each segment approximates the reference's ease-in-out, so the wave
    /// accelerates and settles instead of ticking between keyframes.
    nonisolated static func ripple(phase: Double) -> Float {
        let p = phase - floor(phase)
        for i in 1..<rippleKeyframes.count {
            let lo = rippleKeyframes[i - 1]
            let hi = rippleKeyframes[i]
            guard p <= hi.phase else { continue }
            let span = hi.phase - lo.phase
            guard span > 0 else { return hi.value }
            let t = (p - lo.phase) / span
            let eased = t * t * (3 - 2 * t)
            return lo.value + (hi.value - lo.value) * Float(eased)
        }
        return 1
    }

    /// Bar scaleY for one frame: loudness × envelope × traveling ripple.
    /// Clamped to the layer (never taller than `barFullHeight`).
    nonisolated static func barScale(index: Int, level: Float, time: Double) -> Float {
        let offset = centerOffset(index: index)
        let rawPhase = time / ripplePeriod - rippleStagger * Double(offset)
        var phase = rawPhase.truncatingRemainder(dividingBy: 1)
        if phase < 0 { phase += 1 }
        let audio = max(1, audioGain * min(1, max(0, level)))
        let raw = barScaleBase * audio * envelope(index: index) * ripple(phase: phase)
        return min(1, max(0, raw))
    }

    /// Reduce Motion: one still, shaped row. No ripple, no display-link
    /// motion — the pill keeps its silhouette instead of going blank.
    nonisolated static let reducedMotionLevel: Float = 0.3

    /// Static shaped bar scale at `index` (Reduce Motion path).
    nonisolated static func staticScale(index: Int) -> Float {
        let audio = max(1, audioGain * reducedMotionLevel)
        let raw = barScaleBase * audio * envelope(index: index)
        return min(1, max(0, raw))
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

}
