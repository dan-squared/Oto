//
//  PillLayersTests.swift
//  OtoTests
//
//  Slice 6B v3: the GPU pill's contracts. State→group mapping is pure;
//  group visibility is asserted on the layers headless (no window server
//  needed for CALayers); bar levels land on GPU transforms, not paths.
//

import AppKit
import QuartzCore
import Testing
@testable import Oto

@MainActor
struct PillLayersTests {
    @Test func statesMapToGroups() {
        #expect(PillVisual.forState(.hidden) == nil)
        #expect(PillVisual.forState(.preparing) == .dots)
        #expect(PillVisual.forState(.recording) == .bars)
        #expect(PillVisual.forState(.finalizing) == .dotsSpinner)
        #expect(PillVisual.forState(.inserting) == .dotsSpinner)
        #expect(PillVisual.forState(.successFlash) == .flash)
        #expect(PillVisual.forState(.cancelledFlash) == .flash)
        #expect(PillVisual.forState(.failure) == .message)
    }

    @Test func barsGroupShowsBarsOnly() {
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: 112, height: 32))
        pill.show(visual: .bars)
        pill.layout(width: 112)
        pill.update(values: [1, 0, 0, 0, 0, 0, 0, 0], tick: 0, text: nil, centerText: false, reduceMotion: false)
        #expect(pill.barOpacity(0) == 1)
        #expect(pill.dotOpacity() == 1)
        #expect(pill.chaseOpacity(0) == 0)
        #expect(pill.flashOpacity(0) == 0)
        // Level lands on the GPU transform (m22 = scaleY), not a rebuilt path.
        #expect(abs(pill.barScaleY(0) - 1) < 0.001)
        #expect(abs(pill.barScaleY(1) - 0.02) < 0.001)
    }

    @Test func dotsSpinnerShowsChaseAndNativeSpinner() {
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: 116, height: 32))
        pill.show(visual: .dotsSpinner)
        pill.layout(width: 116)
        pill.update(values: [], tick: 3, text: nil, centerText: false, reduceMotion: false)
        #expect(pill.chaseOpacity(3) > 0.99)
        #expect(!pill.spinnerHidden())
        #expect(pill.barOpacity(0) == 0)
    }

    @Test func dotsWithoutSpinnerHidesNativeSpinner() {
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: 116, height: 32))
        pill.show(visual: .dots)
        pill.layout(width: 116)
        pill.update(values: [], tick: 0, text: nil, centerText: false, reduceMotion: false)
        #expect(pill.spinnerHidden())
        #expect(pill.chaseOpacity(0) > 0.99)
    }

    @Test func messageShowsLabelOnly() {
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: 200, height: 32))
        pill.show(visual: .message)
        pill.layout(width: 200)
        pill.update(values: [], tick: 0, text: "No audio heard.", centerText: false, reduceMotion: false)
        #expect(pill.labelText() == "No audio heard.")
        #expect(pill.barOpacity(0) == 0)
        #expect(pill.spinnerHidden())
    }

    @Test func reduceMotionFreezesEverything() {
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: 112, height: 32))
        pill.show(visual: .bars)
        pill.layout(width: 112)
        pill.update(values: [1, 1, 1, 1, 1, 1, 1, 1], tick: 99, text: nil, centerText: false, reduceMotion: true)
        #expect(abs(pill.barScaleY(0) - 0.3) < 0.001)
        pill.show(visual: .dotsSpinner)
        pill.update(values: [], tick: 99, text: nil, centerText: false, reduceMotion: true)
        #expect(pill.spinnerHidden())
    }

    @Test func contentClipsSoOverflowIsImpossible() {
        // v4 F1a: whatever a transition does, no layer pixel escapes the
        // pill silhouette.
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: 64, height: 32))
        #expect(pill.clipsToBounds)
    }

    @Test func shrinkSwitchKillsOutgoingGroupInstantly() {
        // v4 F1b: 116→64 with dots still fading would paint chase dots
        // outside the constricted frame. Instant path: opacity 0 now,
        // incoming group still fades in.
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: 116, height: 32))
        pill.show(visual: .dotsSpinner)
        pill.layout(width: 116)
        pill.update(values: [], tick: 3, text: nil, centerText: false, reduceMotion: false)
        #expect(pill.chaseOpacity(3) > 0.99)
        pill.show(visual: .flash, animated: false)
        pill.layout(width: 64)
        #expect(pill.chaseOpacity(3) == 0)
        #expect(pill.flashOpacity(0) == 0.35)
    }
}
