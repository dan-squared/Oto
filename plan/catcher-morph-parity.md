# Pill → catcher: the morph the reference actually does

Status: implemented 2026-11-01 (see §10 for the shipped recipe and the two
headless probes that verified it). §4's shadow question was dissolved by
keeping the panel at its final frame; §8's deferred items still stand.

User ask (2026-11-01): *"I noticed another feature on Whisper. The pill
morphs into the catcher. The transition in the animation of the morph is
super, super smooth. Can you see how it works from the code and implement
it here?"*

## 1. What the reference does (extracted from the asar)

Source: `.context/reference/whisperflow/asar/.webpack/renderer/status/index.js`
(CSS module around offset 704 000; `--spring-easing` at `:root`).

| thing | reference value |
|---|---|
| duration | `--pill-morph-duration: 420ms` |
| properties | `width, height, border-radius, transform` all on the same 420 ms curve; `background-color`/`border-color` 220 ms ease; `box-shadow` 300 ms ease |
| origin | `transform-origin: bottom center`; the *slot* keeps its edge, `--pill-center-shift` compensates the centre |
| easing | `--spring-easing: linear(0, 0.005, 0.019 1.8%, 0.079 3.9%, 0.476 13.5%, 0.663 19.1%, 0.738 22%, 0.8 25.1%, 0.852 28.4%, 0.894 32%, 0.928 36%, 0.953 40.5%, 0.972 45.6%, 0.985 51.6%, 0.997 67.3%, 1)` |
| content | outgoing content `opacity .08s ease`; **incoming** `opacity .18s ease .1s` — the shape leads, the words follow |
| sizes | rest 30×6 r6 → mini 416×48 r16 → card 416×80 r322 |

Two properties of that curve matter:

1. it is **not** a spring with overshoot — no sample exceeds 1;
2. it is nearly a **step**: 8 % of the value by 3.9 % of the time, 48 % by
   13.5 %, 74 % by 22 %, then a long asymptotic settle. Everything
   perceptually happens in the first fifth, and the remaining 300 ms is
   the soft landing.

A single cubic Bézier cannot express that. Best fit over the 0–100 % grid
is `cubic-bezier(0.10, 0.61, 0.20, 0.99)` with an SSE of 0.40 and a
**+0.146 error at t=0.05** — it would double the apparent speed of the
first two frames and lose the settle. So we do not approximate: we sample
the reference's own stops.

## 2. What Oto does today, and why it does not read as one object

`NoTargetModalController.showFromPill` (`NoTargetModal.swift:221-264`):

1. `panel.setFrame(pillFrame)` then `panel.alphaValue = 0`, `orderFront`;
2. `NSAnimationContext` 0.18 s `.easeOut` animating **the window frame**
   from 92.4 × 26.4 to 464 × h **and** the window alpha 0 → 1;
3. the rounded mask (`cornerRadius 22`) is installed only after
   `orderFront`, at the final size (`scheduleContentMask`).

Three concrete defects, all visible when you know to look:

- **The surface fades in.** The reference keeps the surface opaque from
  frame one and only fades the *content*. Ours dissolves a rectangle over
  a melting pill: two objects cross-dissolving, not one growing.
- **Square-cornered sliver at t=0.** The window at the pill frame is a
  92.4 × 26.4 *rectangle*; SwiftUI's rounded card lives inside it, and its
  corners are outside the visible window. The first frames are a hard-cornered
  slice of the card, not a capsule.
- **The radius never animates.** 22 is installed in one shot; the pill's
  13.2 is never part of the transition.
- Plus the duration: 0.18 s is less than half the reference's 420 ms, which
  is what makes the reference feel like a material relaxing rather than a
  window resizing.

What is already right and stays: the slot anchoring (`FlowBarPosition.frame`
puts the pill's top edge on the card's top edge for `.top`, bottom on
bottom for `.bottom`, both centred in x — the same "origin edge" the
reference uses), and the pill's own melt (0.12 s fade + hide at 0.14 s),
which is now completely covered by the card from t=0.

## 3. The design: one surface, inside a final-size window

The reason the reference is smooth is that **one element** changes size.
Oto has two windows, so we stop animating windows and animate a **surface
view** instead:

```
panel  (frame = END frame, set once, never animated)
└── CatcherSurfaceView        (frame animates: pill rect → panel bounds,
    │                          cornerRadius 13.2 → 22, clipped)
    └── NSHostingView          (frame = 464 × cardHeight, always; the
                                surface clips it while it is smaller)
```

- The window goes to the **final** frame immediately (before `orderFront`),
  so there is no window animation at all, no clipping sliver, and the
  content is laid out at its final size from the first frame (no reflow —
  the SwiftUI root already carries a fixed `.frame(width: 464, height: …)`,
  `NoTargetModal.swift:434-437`).
- The surface's `bounds`/`position`/`cornerRadius` animate on
  `CAKeyframeAnimation` built from the reference's own 16 stops (values =
  the sample list, `keyTimes` = the percentages, `calculationMode = .linear`
  between them, matching CSS `linear()` exactly). Render-server driven:
  zero per-frame Swift work.
- The hosting view is a child of the surface, sized to the card and
  **centred** inside it (`x = (surfaceW - 464)/2`), so as the surface grows
  the card is revealed symmetrically — which is what the reference's
  fixed-width, clipped content does.
- Content fade: `hosting.alphaValue` 0 → 1 over 0.18 s, starting after
  100 ms, on `.easeOut`; the surface is opaque from t=0. The card's own
  fill moves out of SwiftUI into the surface layer so the two can fade
  independently (one palette source: `CatcherPalette.cardCGColor(for:)`).
- Reduce Motion: set the surface to the end rect, alpha 1, radius 22,
  instantly (same gate as today).

Geometry is pure and cheap, so it gets a value type:

```
MorphGeometry.surfaceRect(pill: NSRect, card: NSRect, position:, progress:) -> NSRect
```
interpolates width/height/x and keeps the **slot edge fixed**
(`.top` → `maxY` constant, `.bottom` → `minY` constant), and
`MorphGeometry.radius(from: 13.2, to: 22, progress:)`.

## 4. The shadow question (probe before wiring)

Today the card's shadow is the **window's** (`hasShadow = true`); the
SwiftUI `.shadow(...)` is clipped away by the later `.clipShape`
(`NoTargetModal.swift:403, 440`), so the window shadow is the only one.

With the window at the final size from t=0, the system shadow is computed
from window content that starts small. Two candidate recipes:

| | recipe | risk |
|---|---|---|
| **S1** | keep `hasShadow = true`; let the system shadow follow the growing content | the WindowServer may cache a 464-wide shadow for the first frames (a visible rectangle) |
| **S2** | `hasShadow = false`; draw the shadow on the surface layer with `shadowPath` updated per keyframe; hand back to the window shadow on completion | needs margin outside the surface, or the shadow clips at the window edge; the hand-off may flicker |

Probe first: a throwaway panel in `.context/glass-probe/` that runs both
recipes over a screenshot-backed desktop, captures frames at 0/60/120/240/420 ms.
Acceptance: no rectangle-shaped shadow in the first 120 ms, and no visible
seam at the hand-off. S1 is the default if it passes (fewer moving parts).

## 5. Timings (recorded, so they are not re-litigated)

| beat | value |
|---|---|
| shape | 420 ms, reference curve |
| content in | 180 ms `.easeOut`, delay 100 ms |
| content out | not applicable (the pill window hides underneath; 80 ms equivalent is the pill's existing 120 ms fade) |
| radius | 13.2 → 22 on the same 420 ms curve |
| reduce motion | 0 ms |

## 6. Exact file changes

1. **New** `Oto/UI/Scratchpad/MorphCurve.swift`
   - `enum MorphCurve`: the 16 reference stops as `[(t, v)]`;
     `value(at:)`, `keyTimes`, `values(samples:)`, `radius(from:to:at:)`.
     Pure, `nonisolated`, no AppKit — testable headless later.
2. **New** `Oto/UI/Scratchpad/CatcherSurfaceView.swift`
   - Layer-backed `NSView`: card fill (from `CatcherPalette`), `cornerRadius`,
     `masksToBounds`, `clipsToBounds`, shadow per §4, and
     `animate(from:to:radiusFrom:radiusTo:duration:)` installing the
     keyframe animations, plus `applyFinal()` (idempotent).
3. `Oto/UI/Scratchpad/NoTargetModal.swift`
   - `showFromPill`: compute `endFrame` as today → `panel.setFrame(endFrame)`,
     `alphaValue = 1` → show the surface at the pill rect (in window
     coordinates: `pillFrame.offsetBy(-endFrame.origin)`) → `orderFront` →
     animate surface + delayed content fade, both behind the existing
     `morphGeneration` guard.
   - `scheduleContentMask`: the hosting mask becomes the surface's own
     clip; keep the size guard, drop the retry dance if the surface owns it.
   - `prewarm()`: panel built at the largest needed frame; `hasShadow`
     per §4.
   - `morphDuration: 0.18 → 0.42` (single constant, as the file already
     promises).
   - `show(_:)` (no-pill path): unchanged in behaviour, but it must also
     put the surface at the card rect before ordering front, or the first
     frame is a full-size card fading in (today's behaviour) that now
     contradicts the new surface.
4. `Oto/UI/Scratchpad/NoTargetModalView.swift` (same file, bottom)
   - remove the `RoundedRectangle(cornerRadius: 22).fill(...)` background
     and its `.shadow`; keep `Color.clear` + `.clipShape` for belt-and-braces.
5. `Oto/UI/FlowBar/FlowBarController.swift`
   - no logic change: `frameForMorph` and the route are unchanged. The pill
     stays on its existing 0.14 s melt, now fully hidden behind the card.

Tests (deferred): `MorphCurve` monotonic + endpoints, `surfaceRect`
edge-anchoring for both slots, radius endpoints, and the ordering invariants
(surface never exceeds the panel frame).

## 7. Verification (no test run, per user)

1. `xcodebuild -scheme Oto -destination 'platform=macOS' build`.
2. Package + run; dictate with no target app so the catcher routes; watch
   the transition at full speed and in a 0.25× screen recording:
   - no square corners at t=0;
   - the shape never flashes;
   - text arrives after the shape, not with it;
   - the shadow never shows a 464-wide rectangle;
   - Cancel/Copy are clickable immediately after 420 ms.
3. Both slots (Top and Bottom): the anchored edge stays put, growth is
   one-directional.
4. Reduce Motion: instant card, no animation.

## 8. Risks / deferred

- **Click-through**: during the morph the surface is smaller than the
  window, so a click in the transparent margin lands on the panel. The
  window is `up to 372 pt` wider than the surface for ~200 ms. Mitigation:
  `panel.ignoresMouseEvents = true` for the morph, `false` at completion.
  (The window is exactly the card size after the morph, so no permanent
  dead zone — unlike a margin-based shadow recipe.)
- **Mid-morph re-route**: the existing `morphGeneration` guard covers it;
  a new show must reset `ignoresMouseEvents`.
- **Shadow** (§4) is the one unresolved technical detail.
- Deferred: the reference also animates the label's `top` from the mini
  position to the card position; we only fade. Revisit if the fade still
  reads as "content appears" rather than "content settles".
- Deferred: the catcher gaining the red-glass treatment (plan
  `pill-red-glass.md` §10.3).

## 9. Open questions

1. 420 ms as-is, or 320 ms for a utility surface that appears dozens of
   times a day? (Reference value proposed; duration-only retune later.)
2. S1 or S2 for the shadow if the probe is ambiguous?

---

## 10. Implemented + verification results (2026-11-01)

Shipped as planned, with one simplification that removed the §4 shadow
question entirely: **the panel takes its final frame on the first frame** and
the only animated property is the mask. Because the window is card-sized
from t=0, the WindowServer's shadow is the card's shadow for the whole
transition — nothing is ever shaped like a 464-wide rectangle, and the
window never resizes (so no per-frame AppKit or SwiftUI layout either).

Files:

- `Oto/UI/Scratchpad/MorphCurve.swift` — the reference's 16 `linear()`
  stops (CSS percentage-spreading rule applied: the two leading points share
  0–1.8 %, so 0 % and 0.6 %), `value(at:)`, `keyTimes`, plus
  `MorphGeometry.rect/radius/path`.
- `Oto/UI/Scratchpad/CatcherSurface.swift` — container with a `fill` layer
  and a `reveal` `CAShapeLayer` used as `layer.mask`; `beginMorph`,
  `animateMorph`, `finishMorph`, `showStatic`, `fadeContentIn`.
- `NoTargetModal.swift` — `showFromPill` rewritten (final frame, mask morph,
  100 ms delayed content fade, `ignoresMouseEvents` for the morph);
  `show()` now sets a static full-card mask; `scheduleContentMask` deleted
  (the mask is a layer we own, so there is nothing to wait for);
  `morphDuration 0.42`. The SwiftUI card's fill + shadow removed — the
  surface paints the card, otherwise the card would crossfade with the
  content instead of being wiped on.

Verification actually performed (headless, since `screencapture` is denied to
the agent shell on this Mac):

1. **Mask clips hosted subviews** — probe: a layer-backed container with
   `layer.mask` = capsule, child `NSView` filling the bounds → alpha inside
   the capsule 1.0, outside 0.0, sublayer present in the layer tree. The
   load-bearing assumption holds.
2. **CA accepts CGPath keyframes and interpolates them exactly** — probe
   freezes the animation clock (`layer.speed = 0`, `timeOffset = t·0.42`)
   and reads `mask.presentation()?.path?.boundingBox` at
   t = 0, 0.05, 0.15, 0.30, 0.55, 0.90, 1.0 → matches
   `MorphGeometry.rect(progress: MorphCurve.value(at: t))` to the tenth of a
   point at every sample (e.g. t = 0.15 → 287.9 × 117.7 predicted and
   measured). So the pacing and the geometry are both the reference's, and
   the earlier wall-clock readings that looked "ahead of schedule" were
   `asyncAfter` jitter on a busy main thread, not a curve error.

Still needs eyes on device (§7's items 2–4), which is the user's call.
