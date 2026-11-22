# Pill v5 — true GPU chase, masksToBounds overflow kill, liquid-quick vanish — PLAN

Status: IMPLEMENTED (2026-09-22). Resumed interrupted v5 WIP (uncommitted diff on
4 files, broken tests). Scope: animation only (dots overflow + finishing
smoothness/quickness). Catcher deferred per user instruction.

## 1. Diagnosis (verified against current tree, not memory)

- **F1. Overflow persists despite `clipsToBounds = true`.** Root cause:
  `NSView.clipsToBounds` clips *subviews*, not *sublayers*. All pill
  artwork (bg, bars, chase dots, flash dots) are CALayers added directly to
  `layer`. Without `layer?.masksToBounds = true`, dying chase dots (9 dots,
  67px block) paint outside the 64-wide flash frame during the 116→64
  shrink. Fix is one line + test. (AppKit: NSView.clipsToBounds → subviews;
  CALayer.masksToBounds → sublayers. SDK 27.0, no deprecation.)
- **F2. WIP Timer is not GPU acceleration — it is worse.** Uncommitted diff
  adds a 60 Hz `Timer` firing on the main runloop, doing a `CATransaction`
  over 9 dots + recordDot every frame on the MainActor. v3's goal was *zero*
  MainActor work per frame; the Timer reintroduces 60 wakeups/s (vs 6.7
  before). True GPU path: `CAKeyframeAnimation` (chase) + `CABasicAnimation`
  (breathe) with `repeatCount = .infinity` — interpolated on the render
  server, zero per-frame CPU. Metal explicitly rejected: 8 bars + 9 dots is
  a compositing workload; CALayer is already GPU-composited via WindowServer.
  A raw Metal renderer adds a process, a shader pipeline, and complexity for
  zero measurable gain on this element count.
- **F3. Finishing feels slow because it is slow.** Flash hold 0.7/0.6s (WIP)
  + fade 0.15–0.18s + width 0.28s easeInEaseOut ≈ 1.0s end-to-end. User asks:
  after the loader, vanish "liquid quick buttery quick". Target <0.55s:
  flash hold 0.35/0.30s, content fade 0.12s easeIn, width 116→64 in 0.20s
  easeOut. Still perceivable (no pop), but snappy.
- **F4. Width vs bg-path mismatch judders.** `layout(width:)` snaps `bg.path`
  instantly while the panel frame animates over 0.28s → the pill silhouette
  jumps ahead of / behind the window. Fix: animate the path change in the
  same 0.20s transaction as the frame, so silhouette and window move as one.
- **F5. WIP broke tests (compile-red).** `render`/`update` dropped `tick:`,
  `spinnerAngle` deleted, but `PillLayersTests` (6 call sites) and
  `VisualizerMathTests.spinnerAdvancesEvenly` still reference the old API.
  Finish the migration coherently (update tests, keep legacy tick wrappers
  in VisualizerMath for API stability).

## 2. Exact changes

1. `PillLayers.swift`
   - `init`: add `layer?.masksToBounds = true` (F1, the actual overflow kill).
     Keep `clipsToBounds = true` (subviews: spinner, label).
   - Delete `phase`/`timer`/`frozenMotion`/`ensureTimer`/`stopTimer`/
     `tickPhase`/`refreshDynamic` entirely (F2).
   - Add `startChaseAnimation()` / `startBreatheAnimation()` /
     `stopMotionAnimations()` using CAKeyframe/CABasic with
     `repeatCount = .infinity`, `isRemovedOnCompletion = false`,
     per-dot `beginTime` phase offsets. `show(visual:)` starts/stops them;
     `update(values:text:centerText:reduceMotion:)` only sets bar transforms
     + label (data clock), never touches chase/breathe (motion clock).
     Reduce Motion: no animations, statics only.
   - `showOnly(_:animated:)`: unchanged semantics (instant kill on shrink).
   - Keep `update(values:text:centerText:reduceMotion:)` signature from WIP
     (no `tick`); update tests to match.
2. `FlowBarPanel.swift`
   - `fadeContentOut(duration: 0.12)` (was 0.18, WIP 0.15).
   - `setFrame` animated duration 0.28 → 0.20, timing `.easeOut` (was
     `.easeInEaseOut`) — quick land, no float.
   - `render`: wrap `content.layout` + `content.show` in a 0.20s
     CATransaction when animated so `bg.path` morphs with the window (F4).
3. `FlowBarController.swift`
   - `successFlashDuration` 0.7 → 0.35; `cancelledFlashDuration` 0.6 → 0.30.
   - Hide-task sleep 180ms → 140ms (matches 0.12 fade + margin).
   - Keep: shrink → `animated:false`, generation guard, route-first order.
4. `VisualizerMath.swift`
   - Keep `dotOpacityContinuous` + `breatheOpacityContinuous` (animation
     keyframe sources). Keep legacy `dotOpacity(index:tick:)` /
     `breatheOpacity(tick:)` wrappers (tests + stability). Delete
     `spinnerStep`/`spinnerAngle` (native spinner owns it now).
5. Tests
   - `PillLayersTests`: drop `tick:` args; `contentClips…` also asserts
     `layer?.masksToBounds == true`; new test: chase animation keys exist
     after `show(.dotsSpinner)` and are removed after `show(.flash)`;
     reduce-motion asserts no animation keys.
   - `VisualizerMathTests`: replace `spinnerAdvancesEvenly` with a
     continuous-chase test (fractional head glides, wraps, floor holds).

## 3. SDK 27.0 citations (re-verified via Xcode ACP before build)

- `CALayer.masksToBounds` (QuartzCore, non-deprecated) — sublayer clip.
- `CAKeyframeAnimation` repeatCount/beginTime phase offsets; `CABasicAnimation`
  autoreverses for breathe — render-server interpolation, no per-frame CPU.
- `NSAnimationContext` easeOut 0.20s frame animator (existing, only retimed).
- No new APIs, no availability gates, no Metal, no Swift 6.4 features —
  language mode 6.0 + MainActor shapes unchanged.

## 4. Verification

- `xcodebuild -scheme Oto -destination 'platform=macOS' build` clean, zero warnings (via Xcode ACP).
- `xcodebuild test -scheme Oto` full suite green (~215 tests).
- Grep gates: `spinnerAngle`/`spinnerStep` zero code hits; `Timer(` zero hits
  in `Oto/UI/FlowBar/`.
- Device matrix (user): record→stop — zero dot pixels outside silhouette;
  flash melts out <0.6s, no pop; rapid dictate-stop-dictate shows no ghost
  hide; motion eyes-judged buttery at 60 fps with zero MainActor per-frame work.
- Catcher: explicitly out of scope (later slice).

## 5. Risks / non-goals

- CAAnimation phase offsets use `CACurrentMediaTime()` — wall-clock in the
  view, but deterministic model values (`dotOpacityContinuous`) remain the
  test seam; animations are pixels only, state stays in the model.
- Prewarm/route-first (v4) untouched. Flash/message widths untouched.
- Open: none blocking.
