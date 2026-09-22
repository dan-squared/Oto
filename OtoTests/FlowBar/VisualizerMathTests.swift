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
            magnitudes: zeros, edges: VisualizerMath.bandEdges(count: 10), binHz: 31.25
        )
        #expect(levels.count == 10)
        #expect(levels.allSatisfy { $0 == 0 && !$0.isNaN })
    }

    @Test func singleToneDominatesOneBand() {
        // All energy in bin 14 (≈440 Hz @ 31.25 Hz/bin): band 3
        // (318–505 Hz) must own it, neighbors stay near zero.
        var mags = [Float](repeating: 0, count: 256)
        mags[14] = 1
        let levels = VisualizerMath.bandLevels(
            magnitudes: mags, edges: VisualizerMath.bandEdges(count: 10), binHz: 31.25
        )
        #expect(argmax(levels) == 3)
        #expect(levels[3] > 0.9)
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

    @Test func spinnerAdvancesEvenly() {
        let a0 = VisualizerMath.spinnerAngle(tick: 0)
        let a1 = VisualizerMath.spinnerAngle(tick: 1)
        let a2 = VisualizerMath.spinnerAngle(tick: 2)
        #expect(abs((a1 - a0) - (a2 - a1)) < 0.000001)
        #expect(abs((a1 - a0) - Double.pi / 3) < 0.000001)
    }

    @Test func widthsAreCompact() {
        #expect(VisualizerMath.panelWidth(for: .recording) == 232)
        #expect(VisualizerMath.panelWidth(for: .preparing) == 208)
        #expect(VisualizerMath.panelWidth(for: .finalizing) == 208)
        #expect(VisualizerMath.panelWidth(for: .inserting) == 208)
        #expect(VisualizerMath.panelWidth(for: .successFlash) == 128)
        #expect(VisualizerMath.panelWidth(for: .cancelledFlash) == 128)
        #expect(VisualizerMath.panelWidth(for: .failure) == 280)
        #expect(VisualizerMath.panelWidth(for: .hidden) == 0)
        // "Little, not big": nothing exceeds the old minimum's neighborhood.
        for state: [FlowBarState] in [[.recording], [.failure]] {
            #expect(VisualizerMath.panelWidth(for: state[0]) <= 280)
        }
    }
}
