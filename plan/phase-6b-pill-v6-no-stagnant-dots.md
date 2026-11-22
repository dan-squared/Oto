# Pill v6 — no stagnant dots at either end, waves from frame one, vanish after loader — PLAN

Status: WRITTEN + EXECUTED same turn (2026-09-22) — user ordered "fix these
things" explicitly for this scoped change. Catcher still deferred.

## 0. User's question, answered: is the constricted end state required?

**No.** It was a confirmation affordance (5 static dots, 64 wide), but the
text landing in the field IS the confirmation — the plan already recorded
this when the success gradient was cut ("put it on the text field"). After
the loader, the correct end is: 0.12s melt, gone. Nothing else. The
`succeeded` signal stays in the model (session identity) but renders no
pixels. Same for cancel: vanish, no monument.

Start side symmetric: `preparing` showed 9 chase dots with no spinner while
the pipeline armed — reads as a stall before the wave. Fix: `preparing`
renders the **bars** visual from frame one (floor + breathe + new idle
sway until the analyzer feeds voice). Dot → wave stutter gone by
construction: there is no dot state anymore outside the loader.

## 1. Exact changes

1. `FlowBarState.swift`
   - Delete `.successFlash` / `.cancelledFlash` cases (+ `==` arms).
   - `.completed` / `.cancelled` → `.hidden` (sessionID still passes
     through for routing identity; message stays nil).
2. `PillLayers.swift` (`PillVisual`)
   - Delete `.flash`; `.preparing` → `.bars`.
   - Delete `flashLayers` (init block, layout block, `showOnly` line,
     `flashOpacity` hook). Five fewer layers, forever.
   - `showOnly` animated fade 0.22 → 0.15 (buttery fast).
   - NEW idle sway ("waves move a bit"): per-bar `CAKeyframeAnimation` on
     `transform.scale.y`, values [0.10→0.26→0.10] (subtle, near-floor),
     1.8s cycle, `beginTime` staggered 0.2s/bar, infinite. Installed ONLY
     when `.bars` + voice-silent (`max(values) < 0.18`) + not reduce-motion;
     first voice poll removes it and the live model values show through.
     Data and sway never fight: sway animates presentation, model sets stay
     authoritative underneath. Folded into `stopMotionAnimations` so every
     group switch / detach kills it.
3. `VisualizerMath.swift`
   - `panelWidth(.preparing)` 116 → 112 (== recording: starting→recording
     resizes nothing, seamless). Delete `.successFlash`/`.cancelledFlash`
     arms. Add sway constants (`swayThreshold = 0.18`, keyframe table or
     sampler for tests).
4. `FlowBarController.swift`
   - Delete flash machinery: `successFlashDuration`,
     `cancelledFlashDuration`, `consumedFlashID`, `flashDeadline`,
     `flashSessionID` + both `switch` arms.
   - NEW vanish path in `syncPanel`: target `.hidden` + no notice + panel
     visible + no hide pending → `fadeContentOut()` (0.12s) +
     generation-guarded `hideNow` after 140ms. Panel already hidden →
     `hide()` (idempotent). Hidden→hidden polls never reschedule.
   - State-change block: cancel pending hide + restore alpha ONLY when the
     new target needs the panel (visible state or notice). Completed→idle
     (both hidden) lets the scheduled melt ride — no hide→reshow flicker.
   - `start()` prewarm width: `.recording` (112), not the deleted flash.
5. `FlowBarPanel.swift`
   - Resize animator 0.20 easeOut → 0.15 easeOut; bg-path morph in
     `PillContentView.layout` 0.20 → 0.15 (chrome and silhouette stay one).
6. Tests
   - `FlowBarStateTests`: completed/cancelled → `.hidden` (keep sessionID
     + no-text assertions; rename `successCarriesNoText` →
     `completionCarriesNoPixels`).
   - `PillLayersTests`: `statesMapToGroups` (preparing→bars, no flash);
     delete flash assertions; shrink test → vanish is controller-level,
     replace with `silentBarsSwayAndVoiceTakesOver` + `swayDiesOnGroupSwitch`
     + `reduceMotionKillsSway`.
   - `VisualizerMathTests`: widths (preparing 112, no flash arms) + sway
     curve test.
   - `FlowBarControllerTests`: completed → `.hidden` (was `.successFlash`).

## 2. What stays untouched

- Loader (dots+spinner, 116) during finalizing/inserting — the only dots
  left, and they mean real work. Chase cycle 1.35s kept.
- Poll 150ms (state truth), generation guard, route-first order, masksToBounds.
- Failure hold, notice/auto-copy, modal — all orthogonal.
- Analyzer arming (recording only): sway covers preparing honestly.

## 3. SDK 27.0

Zero new APIs: `transform.scale.y` key-path animation is classic Core
Animation; enum deletions are our own code. Verified by build, not memory.

## 4. Verification

- Xcode ACP `BuildProject` clean + `RunAllTests` green (~216).
- Grep gates: `successFlash|cancelledFlash|\.flash\b|flashLayers|spinnerAngle|Timer(` → zero hits in `Oto/` + `OtoTests/`.
- Device (user): cold start dictate — waves from the first frame, no dot
  prelude; stop — loader melts straight out, no mini-dots interlude;
  silence — bars breathe gently; voice — sway yields instantly.
