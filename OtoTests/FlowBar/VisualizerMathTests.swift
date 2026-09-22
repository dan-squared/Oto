//
//  VisualizerMathTests.swift
//  OtoTests
//
//  Slice 6B: the motion numbers. Attack snaps, release decays, silence
//  floors, chase head is brightest, spinner steps evenly, widths match the
//  compact table, bands are log-spaced and silence-safe.
//

import Foundation
import Testing
@testable import Oto

@MainActor
struct VisualizerMathTests {
    @Test func attackSnapsFasterThanRelease() {
        // Rising: 55% of the gap in one step.
        #expect(abs(VisualizerMath.smoothStep(current: 0, target: 1) - 0.55) < 0.001)
        // Falling: 12% of the gap — vowels visibly decay.
        #expect(abs(VisualizerMath.smoothStep(current: 1, target: 0) - 0.88) < 0.001)
    }

    @Test func targetsClamp() {
        #expect(VisualizerMath.smoothStep(current: 0.5, target: 5) <= 1)
        #expect(VisualizerMath.smoothStep(current: 0.5, target: -5) >= 0)
    }

    @Test func displayLiftsToFloor() {
        #expect(abs(VisualizerMath.displayValue(0) - VisualizerMath.floor) < 0.0001)
        #expect(abs(VisualizerMath.displayValue(1) - 1) < 0.0001)
    }

    @Test func bandEdgesAreLogSpacedVoiceWeighted() {
        let edges = VisualizerMath.bandEdges(count: 10)
        #expect(edges.count == 11)
        #expect(abs(edges.first! - 80) < 0.001)
        #expect(abs(edges.last! - 8000) < 1)
        // Log spacing: constant ratio between consecutive edges.
        let ratio = edges[1] / edges[0]
        for i in 1..<edges.count - 1 {
            #expect(abs(edges[i + 1] / edges[i] - ratio) < 0.0001)
        }
        // Voice weighting: first band is narrow (80–127 Hz), last is wide.
        #expect(edges[1] - edges[0] < edges.last! - edges[edges.count - 2])
    }

    @Test func silenceMapsToZerosNeverNaN() {
        let zeros = [Float](repeating: 0, count: 256)
        let levels = VisualizerMath.bandLevels(
            magnitudes: zeros, edges: VisualizerMath.bandEdges(count: 8), binHz: 31.25
        )
        #expect(levels.count == 8)
        #expect(levels.allSatisfy { $0 == 0 && !$0.isNaN })
    }

    @Test func singleToneDominatesOneBand() {
        // All energy in bin 14 (≈440 Hz @ 31.25 Hz/bin): band 2
        // (253–450 Hz at 8 bands) must own it, neighbors stay near zero.
        var mags = [Float](repeating: 0, count: 256)
        mags[14] = 1
        let levels = VisualizerMath.bandLevels(
            magnitudes: mags, edges: VisualizerMath.bandEdges(count: 8), binHz: 31.25
        )
        #expect(argmax(levels) == 2)
        #expect(levels[2] > 0.9)
    }

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

    @Test func breatheSpansFullRangeOnTwoSecondPeriod() {
        // Phase 0 → 1.0 (peak), phase 60 (half of 120-frame 2 s period) →
        // 0.55 (trough). Same range the CABasicAnimation interpolates.
        #expect(abs(VisualizerMath.breatheOpacityContinuous(phase: 0) - 1.0) < 0.001)
        #expect(abs(VisualizerMath.breatheOpacityContinuous(phase: 60) - 0.55) < 0.001)
    }

    @Test func widthsAreMini() {
        #expect(VisualizerMath.panelWidth(for: .recording) == 112)
        #expect(VisualizerMath.panelWidth(for: .preparing) == 116)
        #expect(VisualizerMath.panelWidth(for: .finalizing) == 116)
        #expect(VisualizerMath.panelWidth(for: .inserting) == 116)
        #expect(VisualizerMath.panelWidth(for: .successFlash) == 64)
        #expect(VisualizerMath.panelWidth(for: .cancelledFlash) == 64)
        #expect(VisualizerMath.panelWidth(for: .failure) == 200)
        #expect(VisualizerMath.panelWidth(for: .hidden) == 0)
        // Mini v3: half the v2 area (152×44=6688 → 112×32=3584).
        #expect(VisualizerMath.panelWidth(for: .recording) <= 116)
        #expect(VisualizerMath.pillHeight == 32)
        // Elements shrink, count stays.
        #expect(VisualizerMath.barCount == 8)
        #expect(VisualizerMath.barWidth == 3.5)
        #expect(VisualizerMath.recordDot == 8)
    }
}
