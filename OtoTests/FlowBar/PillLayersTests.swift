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
        // v6: preparing renders bars — waves from frame one, no dot prelude.
        #expect(PillVisual.forState(.preparing) == .bars)
        #expect(PillVisual.forState(.recording) == .bars)
        #expect(PillVisual.forState(.finalizing) == .dotsSpinner)
        #expect(PillVisual.forState(.inserting) == .dotsSpinner)
        // v6: completion renders nothing (vanish path) — no flash case exists.
        // v7: failures never reach the pill — no failure case exists.
    }

    @Test func barsGroupShowsBarsOnly() {
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: 84, height: 24))
        pill.show(visual: .bars)
        pill.layout(width: 84)
        pill.update(values: [1, 0, 0, 0, 0, 0, 0, 0], text: nil, centerText: false, reduceMotion: false)
        #expect(pill.barOpacity(0) == 1)
        #expect(pill.dotOpacity() == 1)
        #expect(pill.chaseOpacity(0) == 0)
        // Level lands on the GPU transform (m22 = scaleY), not a rebuilt path.
        #expect(abs(pill.barScaleY(0) - 1) < 0.001)
        #expect(abs(pill.barScaleY(1) - 0.02) < 0.001)
        // Breathe rides the render server (v5), not the data tick.
        #expect(pill.breatheHasAnimation())
        #expect(!pill.chaseHasAnimation())
        // Voice present: no idle sway (v6).
        #expect(!pill.swayHasAnimation())
    }

    @Test func silentBarsSwayAndVoiceTakesOver() {
        // v6 "waves move a bit" (v7: from the raised floor): silence sways
        // gently on the render server; the first voice poll evicts it and
        // live values show through.
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: 84, height: 24))
        pill.show(visual: .bars)
        pill.layout(width: 84)
        pill.update(
            values: [Float](repeating: VisualizerMath.floor, count: VisualizerMath.barCount),
            text: nil, centerText: false, reduceMotion: false
        )
        #expect(pill.swayHasAnimation())
        #expect(pill.swayAnimationCount() == VisualizerMath.barCount)
        pill.update(
            values: [0.9, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2],
            text: nil, centerText: false, reduceMotion: false
        )
        #expect(!pill.swayHasAnimation())
        #expect(abs(pill.barScaleY(0) - 0.9) < 0.001)
    }

    @Test func swayDiesOnGroupSwitch() {
        // Leaving bars kills the sway with everything else — a dying wave
        // must never outlive its group (same overflow class as v4 F1b).
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: 84, height: 24))
        pill.show(visual: .bars)
        pill.layout(width: 84)
        pill.update(
            values: [Float](repeating: 0.10, count: VisualizerMath.barCount),
            text: nil, centerText: false, reduceMotion: false
        )
        #expect(pill.swayHasAnimation())
        pill.show(visual: .dotsSpinner, animated: false)
        #expect(!pill.swayHasAnimation())
        #expect(!pill.breatheHasAnimation())
    }

    @Test func dotsSpinnerShowsChaseAndNativeSpinner() {
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: 87, height: 24))
        pill.show(visual: .dotsSpinner)
        pill.layout(width: 87)
        pill.update(values: [], text: nil, centerText: false, reduceMotion: false)
        // Pixels glide on the render server (v5); the model holds 1 under
        // the wave. Presence + full coverage is the contract.
        #expect(pill.chaseHasAnimation())
        #expect(pill.chaseAnimationCount() == VisualizerMath.dotCount)
        #expect(!pill.spinnerHidden())
        #expect(pill.barOpacity(0) == 0)
    }

    @Test func dotsWithoutSpinnerHidesNativeSpinner() {
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: 87, height: 24))
        pill.show(visual: .dots)
        pill.layout(width: 87)
        pill.update(values: [], text: nil, centerText: false, reduceMotion: false)
        #expect(pill.spinnerHidden())
        #expect(pill.chaseHasAnimation())
    }

    @Test func repollNeverRestartsTheWave() {
        // v5 stutter guard: the 150 ms poll re-calls show/update with the
        // same visual 6.7×/s. Restarting the CAAnimation there would rewind
        // the wave every poll. beginTime must survive a repoll untouched.
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: 87, height: 24))
        pill.show(visual: .dotsSpinner)
        pill.layout(width: 87)
        pill.update(values: [], text: nil, centerText: false, reduceMotion: false)
        let t1 = pill.chaseBeginTime(3)
        pill.show(visual: .dotsSpinner)
        pill.update(values: [], text: nil, centerText: false, reduceMotion: false)
        #expect(pill.chaseBeginTime(3) == t1)
    }

    @Test func messageShowsLabelOnly() {
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
        pill.show(visual: .message)
        pill.layout(width: 150)
        pill.update(values: [], text: "No audio heard.", centerText: false, reduceMotion: false)
        #expect(pill.labelText() == "No audio heard.")
        #expect(pill.barOpacity(0) == 0)
        #expect(pill.spinnerHidden())
        #expect(!pill.chaseHasAnimation())
        #expect(!pill.breatheHasAnimation())
    }

    @Test func reduceMotionFreezesEverything() {
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: 84, height: 24))
        pill.show(visual: .bars)
        pill.layout(width: 84)
        pill.update(values: [1, 1, 1, 1, 1, 1, 1, 1], text: nil, centerText: false, reduceMotion: true)
        #expect(abs(pill.barScaleY(0) - 0.3) < 0.001)
        #expect(!pill.breatheHasAnimation())
        #expect(!pill.swayHasAnimation())
        pill.show(visual: .dotsSpinner)
        pill.update(values: [], text: nil, centerText: false, reduceMotion: true)
        #expect(pill.spinnerHidden())
        #expect(!pill.chaseHasAnimation())
    }

    @Test func contentClipsSoOverflowIsImpossible() {
        // v4 set clipsToBounds (subviews); v5 adds masksToBounds (sublayers
        // — all the artwork). The second is the one that actually cages the
        // dots; assert both so neither regresses.
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: 48, height: 24))
        #expect(pill.clipsToBounds)
        #expect(pill.contentMaskedToBounds())
    }

    @Test func shrinkSwitchKillsOutgoingGroupInstantly() {
        // v4 F1b outlives v6's flash deletion: any animated=false switch
        // must zero the outgoing group AND remove its render-server wave,
        // so no animation overrides the kill. Loader → message exercises
        // the same path the old loader → flash did.
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: 87, height: 24))
        pill.show(visual: .dotsSpinner)
        pill.layout(width: 87)
        pill.update(values: [], text: nil, centerText: false, reduceMotion: false)
        #expect(pill.chaseHasAnimation())
        pill.show(visual: .message, animated: false)
        pill.layout(width: 150)
        #expect(!pill.chaseHasAnimation())
        #expect(pill.chaseOpacity(3) == 0)
        #expect(pill.labelText() == "")
    }
}
