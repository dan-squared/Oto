# Pill work-text shimmer ("Cleaning / Polishing / Shortening / Formalizing")

## Goal

Traveling shine sweep across the work pill's verb while model work runs.
Same idea as the reference technique (gradient offset + text-shaped mask),
translated from SwiftUI to this pill's AppKit/CALayer renderer. Render
server only, zero per-frame MainActor work, same primitives as the shipped
chase/breathe/sway animations.

## Spec sources (canonical first)

- `Docs/START_HERE_PRODUCT.md`: Flow Bar is the only custom surface;
  reduced motion / transparency respected. NOTE: user explicitly waived
  the Reduce Motion constraint for this feature (2026-10-05) — shimmer
  installs regardless of `frozenMotion`. Recorded here so a later agent
  doesn't "fix" it back; the 5-line fallback shape is kept in Risks.
- `Oto/UI/FlowBar/PillLayers.swift:5-11` (zero-SwiftUI renderer contract),
  `:401-425` (`.work` joint layout — the single geometry site),
  `:269-285` (`ensureMotion` idempotent-install pattern),
  `:496-511` (`showOnly` group switch), `:334-339` (`stopMotionAnimations`
  teardown funnel), `:107-108` (two-level clip guarantee).
- `Oto/UI/FlowBar/VisualizerMath.swift:89-117` (work chrome constants,
  `measureWorkText`, `workPillWidth` — single source for widths).
- `Oto/UI/FlowBar/FlowBarState.swift:51-58` (`workPillText` — unchanged).
- Reference: `.context/attachments/aSoxTh/40325.png` (SwiftUI
  overlay-offset + `.mask(title)`; correct technique, wrong toolkit for
  this pill — hardcoded ±200/90px geometry, no SwiftUI in the renderer).

## Facts verified against the local SDK (never from memory)

- Toolchain: Xcode 27.0 (27A266a), Apple Swift 6.4
  (swiftlang-6.4.0.34.1), SDK MacOSX27.0.sdk, deployment target 27.0,
  `SWIFT_VERSION = 6.0` (Swift 6 language mode under the 6.4 toolchain —
  no project-setting change needed; new code written concurrency-clean).
- `CAGradientLayer` + `locations` present in
  `$SDK/System/Library/Frameworks/QuartzCore.framework/Headers/` —
  mask + `CABasicAnimation(keyPath: "position.x")` needs zero new APIs.
- Existing tests pin the contracts this must not break:
  `workShowsJointLabelDividerSpinner` (joint layout), `messageShowsLabelOnly`,
  `reduceMotionFreezesEverything` (bars/dotsSpinner only — `.work`
  untouched, so always-on shimmer needs no test update there).

## Assumptions questioned

1. "Paste the SwiftUI snippet." No — renderer is AppKit; `.mask()`
   becomes `CALayer.mask`, `.offset()` becomes a render-server position
   animation. Same idea, native primitives.
2. "Use CATextLayer for the shine shape." No — second text engine risks
   1px glyph mismatch vs the base `NSTextField`. Duplicate `NSTextField`
   keeps rendering identical by construction.
3. "Shimmer needs its own clock/timer." No — infinite `CAAnimation` on
   the render server, same as chase/breathe. No timers, no display link.
4. "Geometry can be constant." No — verbs range `Cleaning`..`Formalizing`;
   band + travel derive from the measured label frame every install.

## Design (decisions + reasons)

- Dim base label (`white @ shineBaseAlpha 0.45`) + full-bright overlay
  `NSTextField` (identical font/frame/string, AX-hidden, mouse-transparent
  like its sibling) whose `layer.mask` is a `CAGradientLayer` bright
  window (`clear → white → white → clear`). Animate mask `position.x`
  from `-B` to `labelW + B` (band center == mask x by construction),
  linear, `repeatCount = .infinity`, no autoreverse.
- Pure constants in `VisualizerMath` (test-locked, eyes tune values):
  `shineBandWidth(forLabelWidth:)` = max(28, w*0.5),
  `shineTravel` = w + 2B, `shineVelocity` = 100 pt/s,
  `shineDuration(forLabelWidth:)` = travel/velocity (constant velocity,
  not constant duration), `shineBaseAlpha` = 0.45.
- Lifecycle reuses existing funnels only: install (idempotent guard) in
  `update()` `.work` branch next to `label.stringValue` sync; removal in
  `stopMotionAnimations()` + `viewWillMove(toWindow: nil)` (via that
  funnel); visibility in `showOnly` (`shineLabel.isHidden = visual != .work`);
  base-color restore on removal (`.message` shares `label`).
- Scope: all work verbs (one visual, not per-word). `Copied` message pill
  stays static (confirmation ≠ working). Overlay never intercepts drag
  (pill is drag-to-move; overlay is display-only).
- Per explicit user instruction, shimmer installs regardless of
  `frozenMotion`. AX content unchanged (base label remains the source).

## Exact file changes

1. `Oto/UI/FlowBar/PillLayers.swift`
   - `shineLabel` (configured like `label`, AX-hidden) + `shineMask`
     (`CAGradientLayer`) + `shineKey = "oto.shine"` + `shineOn` flag,
     added as subview in `init` (hidden).
   - `installShine()` / `removeShine()` (restores base color, removes
     animation); install call in `update()` `.work` branch;
     `removeShine()` in `stopMotionAnimations()`; `shineLabel.isHidden`
     in `showOnly`.
   - Test hooks mirroring existing style: `shineHasAnimation()`,
     `shineOverlayText()`, `shineBaseAlphaNow()` (or color read).
2. `Oto/UI/FlowBar/VisualizerMath.swift` — the five pure
   shine constants/functions above, no behavior change to measuring code.
3. `OtoTests/FlowBar/PillLayersTests.swift` — `workVerbShimmers`
   (installed, overlay==base text+frame, base dimmed, survives repoll),
   `leavingWorkKillsShine` (no animation, base restored, overlay hidden),
   `shineScalesWithWidth` (duration ∝ travel; band floor holds).
4. No changes to `FlowBarState.swift`, `FlowBarController.swift`,
   runner/coordinator feeds, or project settings.

## Verification steps

- `xcodebuild -scheme Oto -destination 'platform=macOS' build` green.
- `xcodebuild test` / ACP `RunSomeTests` (PillLayers + FlowBarPosition
  suites) green, incl. all existing pins.
- Live matrix (ACP launch): trigger Auto Cleanup + each `Cmd+1/2/3`
  transform — full-word sweep, band fully enters/exits (no edge flash),
  spinner snug, `Cmd+Z` path untouched; rapid double-press → single sweep;
  leave `.work` → instantly static.
- Eyes-on tuning pass for velocity/band/alpha starting values.

## Risks / deferred decisions

- Aesthetic constants need one device pass (mechanism risk low, taste
  risk normal). Formulas pinned; values tunable.
- BUG FOUND ON DEVICE (2026-10-05): `CAGradientLayer` defaults to a
  VERTICAL gradient — the first build rendered a static horizontal stripe
  through the letters and the X sweep did nothing. Fixed by pinning
  `startPoint=(0,0.5)` / `endPoint=(1,0.5)` + a `shineGradientIsHorizontal`
  regression test (animation-existence checks alone cannot catch a
  wrong-direction gradient).
- AUDIT PATCHES (2026-10-05, no live verification available): explicit
  linear pacing (`shinePacing` shared instance + `shineSweepIsLinear`
  identity pin — duration math promises constant velocity); overlay font
  single-sourced via `VisualizerMath.workFont`; mouse-transparent
  `ShineLabel` subclass (hitTest → nil) so press-drag grabs starting on
  shimmering text behave exactly as on plain text.
- Reduce Motion bypass is explicit user direction (recorded 2026-10-05).
  If a beta tester complains, the fallback is: skip install when
  `frozenMotion` (5 lines in `update()` + extend
  `reduceMotionFreezesEverything` to `.work`). Not wired now.
- No prewarm-style cost: one label + one gradient layer, transient only.

## Open questions (recommendations marked)

- Q1 Constant velocity vs constant duration? (Recommended: velocity —
  same physics for every verb. Wired that way.)
- Q2 Base dimmed (screenshot style) vs full-white + additive band?
  (Recommended: dimmed 0.45 — reads premium, still legible.)
- Q3 Shimmer on `Copied` message pill? (Recommended: no.)
