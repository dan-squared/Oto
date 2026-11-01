//
//  PillLayersTests.swift
//  OtoTests
//
//  Slice 6B v8: the GPU pill's contracts. State→group mapping is pure;
//  group visibility is asserted on the layers headless (no window server
//  needed for CALayers); loudness and ripple land on GPU transforms, not
//  paths; the artwork lives inside the glass's content view; Reduce
//  Transparency swaps the chrome for the solid fallback.
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
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: VisualizerMath.dictationWidth, height: 26.4))
        pill.show(visual: .bars)
        pill.layout(width: VisualizerMath.dictationWidth)
        pill.update(level: 1, time: 0.8, text: nil, centerText: false, reduceMotion: false)
        #expect(pill.barOpacity(0) == 1)
        #expect(pill.chaseOpacity(0) == 0)
        // Loudness lands on the GPU transform (m22 = scaleY), not a
        // rebuilt path. Centre bar at the ripple peak is near the maximum;
        // the edge bar stays shorter (the envelope shapes one row).
        #expect(pill.barScaleY(4) > 0.8)
        #expect(pill.barScaleY(0) < pill.barScaleY(4))
        // No record dot: the row is the whole recording state, and the
        // only render-server motion is the loader's chase.
        #expect(!pill.chaseHasAnimation())
    }

    @Test func silenceKeepsTheRowAlive() {
        // Noise is the wave: `max(1, gain × level)` floors the row, the
        // permanent ripple keeps it moving. The pill never goes blank —
        // this replaces the old idle sway with ONE motion model.
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: VisualizerMath.dictationWidth, height: 26.4))
        pill.show(visual: .bars)
        pill.layout(width: VisualizerMath.dictationWidth)
        pill.update(level: 0, time: 0.3, text: nil, centerText: false, reduceMotion: false)
        let silent = (0..<VisualizerMath.barCount).map { pill.barScaleY($0) }
        #expect(silent.allSatisfy { $0 > 0.05 })
        // Staggered phases: the row is not symmetric at any instant (a
        // mirror-image row would pulse instead of travel).
        #expect(silent[0] != silent[VisualizerMath.barCount - 1])
        // Same level, later frame: the ripple has moved.
        pill.update(level: 0, time: 0.55, text: nil, centerText: false, reduceMotion: false)
        let later = (0..<VisualizerMath.barCount).map { pill.barScaleY($0) }
        #expect(later != silent)
    }

    @Test func louderVoiceRaisesTheRow() {
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: VisualizerMath.dictationWidth, height: 26.4))
        pill.show(visual: .bars)
        pill.layout(width: VisualizerMath.dictationWidth)
        pill.update(level: 0.1, time: 0.8, text: nil, centerText: false, reduceMotion: false)
        let quiet = pill.barScaleY(4)
        pill.update(level: 0.9, time: 0.8, text: nil, centerText: false, reduceMotion: false)
        #expect(pill.barScaleY(4) > quiet)
    }

    @Test func liveLevelsMoveEveryFrame() {
        // Vsync path: the display link owns transforms while bars show.
        // Time alone changes the shape — no data tick required.
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: VisualizerMath.dictationWidth, height: 26.4))
        pill.show(visual: .bars)
        pill.layout(width: VisualizerMath.dictationWidth)
        pill.update(level: 0.4, time: 0.1, text: nil, centerText: false, reduceMotion: false)
        pill.setLiveLevels(level: 0.4, time: 0.2)
        let first = pill.barScaleY(2)
        pill.setLiveLevels(level: 0.4, time: 0.3)
        #expect(pill.barScaleY(2) != first)
        // Frozen motion ignores the live path entirely.
        pill.update(level: 0.4, time: 0.3, text: nil, centerText: false, reduceMotion: true)
        let frozen = pill.barScaleY(2)
        pill.setLiveLevels(level: 1, time: 9.5)
        #expect(pill.barScaleY(2) == frozen)
    }

    @Test func dotsSpinnerShowsChaseAndNativeSpinner() {
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: 95.7, height: 26.4))
        pill.show(visual: .dotsSpinner)
        pill.layout(width: 95.7)
        pill.update(level: 0, time: 0.3, text: nil, centerText: false, reduceMotion: false)
        // Pixels glide on the render server (v5); the model holds 1 under
        // the wave. Presence + full coverage is the contract.
        #expect(pill.chaseHasAnimation())
        #expect(pill.chaseAnimationCount() == VisualizerMath.dotCount)
        #expect(!pill.spinnerHidden())
        #expect(pill.barOpacity(0) == 0)
    }

    @Test func dotsWithoutSpinnerHidesNativeSpinner() {
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: 95.7, height: 26.4))
        pill.show(visual: .dots)
        pill.layout(width: 95.7)
        pill.update(level: 0, time: 0.3, text: nil, centerText: false, reduceMotion: false)
        #expect(pill.spinnerHidden())
        #expect(pill.chaseHasAnimation())
    }

    @Test func repollNeverRestartsTheWave() {
        // v5 stutter guard: the 150 ms poll re-calls show/update with the
        // same visual 6.7×/s. Restarting the CAAnimation there would rewind
        // the wave every poll. beginTime must survive a repoll untouched.
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: 95.7, height: 26.4))
        pill.show(visual: .dotsSpinner)
        pill.layout(width: 95.7)
        pill.update(level: 0, time: 0.3, text: nil, centerText: false, reduceMotion: false)
        let t1 = pill.chaseBeginTime(3)
        pill.show(visual: .dotsSpinner)
        pill.update(level: 0, time: 0.6, text: nil, centerText: false, reduceMotion: false)
        #expect(pill.chaseBeginTime(3) == t1)
    }

    @Test func messageShowsLabelOnly() {
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: 165, height: 26.4))
        pill.show(visual: .message)
        pill.layout(width: 165)
        pill.update(level: 0, time: 0.3, text: "No audio heard.", centerText: false, reduceMotion: false)
        #expect(pill.labelText() == "No audio heard.")
        #expect(pill.barOpacity(0) == 0)
        #expect(pill.spinnerHidden())
        #expect(!pill.chaseHasAnimation())
    }

    @Test func reduceMotionFreezesEverything() {
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: VisualizerMath.dictationWidth, height: 26.4))
        pill.show(visual: .bars)
        pill.layout(width: VisualizerMath.dictationWidth)
        pill.update(level: 1, time: 0.8, text: nil, centerText: false, reduceMotion: true)
        // Static, but still SHAPED: no ripple, envelope intact, never blank.
        #expect(abs(pill.barScaleY(4) - CGFloat(VisualizerMath.staticScale(index: 4))) < 0.001)
        #expect(abs(pill.barScaleY(0) - CGFloat(VisualizerMath.staticScale(index: 0))) < 0.001)
        #expect(pill.barScaleY(4) > pill.barScaleY(0))
        #expect(pill.barScaleY(0) > 0)
        pill.show(visual: .dotsSpinner)
        pill.update(level: 0, time: 0.3, text: nil, centerText: false, reduceMotion: true)
        #expect(pill.spinnerHidden())
        #expect(!pill.chaseHasAnimation())
    }

    @Test func overflowIsCagedByCapsuleNotByABoxClip() {
        // v3: the pill no longer clips to its bounding rect — a box clip cuts
        // the material's own edge exactly where the capsule touches the
        // bounds (the "it is clipped" report). Overflow is caged one level
        // down instead: `ink` carries a CAPSULE mask, so no group can paint
        // outside the silhouette while nothing rectangular chops the glass.
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: 52.8, height: 26.4))
        pill.layout(width: 52.8)
        #expect(!pill.clipsToBounds)
        #expect(!pill.contentMaskedToBounds())
        #expect(pill.inkMaskIsCapsule())
    }

    @Test func shrinkSwitchKillsOutgoingGroupInstantly() {
        // v4 F1b outlives v6's flash deletion: any animated=false switch
        // must zero the outgoing group AND remove its render-server wave,
        // so no animation overrides the kill. Loader → message exercises
        // the same path the old loader → flash did.
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: 95.7, height: 26.4))
        pill.show(visual: .dotsSpinner)
        pill.layout(width: 95.7)
        pill.update(level: 0, time: 0.3, text: nil, centerText: false, reduceMotion: false)
        #expect(pill.chaseHasAnimation())
        pill.show(visual: .message, animated: false)
        pill.layout(width: 165)
        #expect(!pill.chaseHasAnimation())
        #expect(pill.chaseOpacity(3) == 0)
        #expect(pill.labelText() == "")
    }

    @Test func glassCapsuleHostsTheArtwork() {
        // AppKit only guarantees the glass CONTENT view inside the effect:
        // every drawing layer must be a descendant of `ink`, never a
        // sibling layered underneath the glass.
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: VisualizerMath.dictationWidth, height: 26.4))
        pill.layout(width: VisualizerMath.dictationWidth)
        #expect(pill.glassVisible())
        #expect(pill.glassIsCapsule())
        #expect(pill.inkFillsGlass())
        #expect(pill.artworkIsInsideInk())
        #expect(abs(pill.scrimOpacity() - Float(PillChrome.scrimAlpha)) < 0.001)
        // Chrome rule (v3): nothing stroked on the silhouette — the rim is a
        // gradient, so it can feather into the body instead of drawing a line.
        #expect(pill.chromeHasNoStrokedOutline())
    }

    @Test func reduceTransparencyFallsBackToSolidScrim() {
        // Same silhouette, same bars: the glass hides, the scrim goes solid.
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: VisualizerMath.dictationWidth, height: 26.4))
        pill.reduceTransparencyProvider = { true }
        pill.show(visual: .bars)
        pill.layout(width: VisualizerMath.dictationWidth)
        pill.update(level: 0.5, time: 0.3, text: nil, centerText: false, reduceMotion: false)
        #expect(!pill.glassVisible())
        #expect(abs(pill.scrimOpacity() - 1) < 0.001)
        // …and flips back live when the setting changes between polls.
        pill.reduceTransparencyProvider = { false }
        pill.update(level: 0.5, time: 0.6, text: nil, centerText: false, reduceMotion: false)
        #expect(pill.glassVisible())
        #expect(abs(pill.scrimOpacity() - Float(PillChrome.scrimAlpha)) < 0.001)
    }

    @Test func colourChoiceReachesTheRampAndFrost() {
        // The Settings key is written from another window; the pill reads it
        // per render. Assert the wiring, not the taste: the ramp's waist is
        // the chosen hue, the frost tint follows, the veil is that hue
        // darkened, and graphite leaves the material untinted.
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: VisualizerMath.dictationWidth, height: 26.4))
        var colour: PillColor = .graphite
        pill.colorProvider = { colour }
        pill.reduceTransparencyProvider = { false }
        pill.show(visual: .bars)
        pill.layout(width: VisualizerMath.dictationWidth)
        pill.update(level: 0.5, time: 0.3, text: nil, centerText: false, reduceMotion: false)
        #expect(pill.rampStopCount() == 9)
        #expect(pill.frostTint() == nil)
        #expect(abs(pill.rampWaistAlpha() - PillPalette.waistAlpha) < 0.001)

        colour = .ocean
        pill.update(level: 0.5, time: 0.6, text: nil, centerText: false, reduceMotion: false)
        let waist = pill.rampWaistColor()
        #expect(waist != nil)
        // Hue family, not a copied literal: the waist is the chosen
        // colour's own base (the palette was re-hued to the user's sky
        // blue on 2026-11-01, so any hard-coded channel is stale by
        // design). Blue must still dominate and beat red.
        let oceanBase = PillColor.ocean.base.usingColorSpace(.sRGB)!
        #expect(abs(waist!.blueComponent - oceanBase.blueComponent) < 0.02)
        #expect(abs(waist!.greenComponent - oceanBase.greenComponent) < 0.02)
        #expect(waist!.blueComponent > waist!.redComponent)
        #expect(pill.frostTint() != nil)
        #expect(pill.veilColor() != nil)

        // Same colour again: a repoll must not touch the ramp (the guard is
        // what keeps a 150 ms poll from restarting the crossfade).
        let steady = pill.rampWaistColor()
        pill.update(level: 0.5, time: 0.9, text: nil, centerText: false, reduceMotion: false)
        #expect(pill.rampWaistColor() == steady)
    }

    @Test func workShowsJointLabelDividerSpinner() {
        // E2 work visual: full-word verb left, native spinner snug right
        // (no divider, no dead space beyond padding, never truncated).
        // Longest verb pins the fit.
        let text = "Formalizing"
        let width = VisualizerMath.workPillWidth(textWidth: VisualizerMath.measureWorkText(text))
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: width, height: 26.4))
        pill.show(visual: .work)
        pill.layout(width: width)
        pill.update(level: 0, time: 0.3, text: text, centerText: false, reduceMotion: false)
        #expect(pill.labelText() == text)
        #expect(!pill.spinnerHidden())
        #expect(pill.barOpacity(0) == 0)
        #expect(!pill.chaseHasAnimation())
        // Frame containment: label inside, spinner snug to the right edge.
        let frames = pill.workLayoutFrames()
        #expect(frames.label.minX >= 0)
        #expect(frames.spinner.maxX <= width)
        #expect(width - frames.spinner.maxX <= VisualizerMath.workPadding + 1)
        #expect(frames.spinner.minX >= frames.label.maxX)
        #expect(frames.label.height <= VisualizerMath.pillHeight)
        // Leaving work kills the joint group like every other switch.
        pill.show(visual: .message, animated: false)
        #expect(pill.spinnerHidden())
    }

    @Test func workVerbShimmers() {
        // Shine sweep on the work verb: bright overlay duplicates the base
        // text+frame, base dims, wave installed — and repolls never restart
        // it mid-flight.
        let text = "Formalizing"
        let width = VisualizerMath.workPillWidth(textWidth: VisualizerMath.measureWorkText(text))
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: width, height: 26.4))
        pill.show(visual: .work)
        pill.layout(width: width)
        pill.update(level: 0, time: 0.3, text: text, centerText: false, reduceMotion: false)
        #expect(pill.shineHasAnimation())
        #expect(pill.shineOverlayText() == text)
        #expect(!pill.shineOverlayHidden())
        #expect(pill.shineOverlayFrame() == pill.workLayoutFrames().label)
        #expect(pill.shineGradientIsHorizontal())
        #expect(pill.shineSweepIsLinear())
        #expect(abs(pill.shineBaseAlpha() - VisualizerMath.shineBaseAlpha) < 0.001)
        // Repoll with identical content: still exactly the installed wave.
        pill.update(level: 0, time: 0.6, text: text, centerText: false, reduceMotion: false)
        #expect(pill.shineHasAnimation())
        #expect(pill.shineOverlayText() == text)
    }

    @Test func leavingWorkKillsShine() {
        // Leaving .work tears down the sweep AND restores the base label to
        // full white (the Copied notice shares the label — it must never
        // inherit the dim).
        let text = "Polishing"
        let width = VisualizerMath.workPillWidth(textWidth: VisualizerMath.measureWorkText(text))
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: width, height: 26.4))
        pill.show(visual: .work)
        pill.layout(width: width)
        pill.update(level: 0, time: 0.3, text: text, centerText: false, reduceMotion: false)
        #expect(pill.shineHasAnimation())
        pill.show(visual: .message, animated: false)
        pill.layout(width: 165)
        pill.update(level: 0, time: 0.6, text: "No audio heard.", centerText: false, reduceMotion: false)
        #expect(!pill.shineHasAnimation())
        #expect(pill.shineOverlayHidden())
        #expect(abs(pill.shineBaseAlpha() - 1.0) < 0.001)
    }

    @Test func messageNeverShimmers() {
        // The Copied notice is a confirmation, not working state — no sweep.
        let pill = PillContentView(frame: NSRect(x: 0, y: 0, width: 165, height: 26.4))
        pill.show(visual: .message)
        pill.layout(width: 165)
        pill.update(level: 0, time: 0.3, text: "No audio heard.", centerText: false, reduceMotion: false)
        #expect(!pill.shineHasAnimation())
        #expect(pill.shineOverlayHidden())
    }
}
