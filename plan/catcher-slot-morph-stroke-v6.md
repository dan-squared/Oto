# Catcher v6 — slot-anchored morph + stroke kill — PLAN ONLY

Status: PLANNING ONLY. Nothing implemented. Awaiting `execute`.
Scope: catcher presentation ONLY (position, morph, frame artifact).
Divert logic, router, palette, retention, settings: untouched and
unquestioned (the catcher FIRES now — this is pure feel + pixels).

## 1. The three reports, with mechanisms

Screenshots confirm all three (card centered mid-screen, crisp black
rect outline at window bounds, minimal UI otherwise correct).

- **R1. Stroke rectangle frame.** Mechanism (analyzed, not guessed):
  the shared recipe (`FlowBarPanel.makePanel`) forces
  `contentView.wantsLayer = true` — correct for the pill's plain
  CALayer `NSView` (that's the twice-fixed v2 hairline), but the
  modal's content is an `NSHostingView`, whose layers SwiftUI manages
  itself. Forcing the layer invites SwiftUI to resolve a default
  opaque root background (black in dark mode) at window bounds —
  exactly the crisp rect OUTSIDE the rounded card in both shots.
  The v4 reflow + rootView reassignment re-exposed it on a path the
  v2 fix never covered. Fix = separate recipe (§4.1), decided by
  screenshot matrix between two variants (§4.4).
- **R2. Not the pill morphing + slow/rigid.** Mechanism: the end
  frame was screen-CENTERED while the pill lives at top/bottom
  slot — a ~300pt travel + scale reads as two disconnected events
  (pill melts THERE, card fades in HERE), never as one surface
  becoming the other. Travel is what feels slow and rigid, not the
  0.22s itself. Fix = grow in place (§4.2).
- **R3. Catcher must live at the pill slot.** Accepted as specified:
  end frame = `FlowBarPosition.frame(width:464, height:168, on:,
  position: FlowBarPosition.current())` — same helper, same
  margins (12/28), same clamp/center math as the pill. Pill x is
  centered ⇒ card x is centered ⇒ identical x: top slot grows
  downward from the pill's top edge, bottom slot upward from its
  bottom edge. Pure anchored growth, zero travel, lineage literal.

## 2. Animation research (latest SDK, asked for — outcome)

- Cross-`NSWindow` `matchedGeometryEffect`: still impossible (v2 F3
  stands — no SDK change alters window boundaries).
- Vehicle stays AppKit animator (`NSAnimationContext` + `.animator()`
  + `CAMediaTimingFunction(.easeOut)`): the same render-server path
  as pill land/ghost fade/modal show — all building clean on
  MacOSX27.0.sdk, which IS the currency verification. No new
  primitive adopted because none applies to panel geometry.
- Springs considered, rejected: `CASpringAnimation` on window
  frames overshoots — wrong language for utility chrome; the
  codebase speaks one motion dialect (quick easeOut settles) and
  the catcher joins it, shorter (0.22 → 0.18, matching the modal's
  original show timing).
- SwiftUI-side: content needs no separate animation (panel alpha
  ramp covers it); `.transition`/spring content choreography adds
  moving parts to a surface whose whole point is instant
  legibility. `animationBehavior = .none` already stops AppKit
  fighting our curves (inherited from the shared recipe).
- Net research result: the win is GEOMETRIC (in-place growth) +
  recipe (hosting layers), not a new API. Recorded so nobody
  re-researches or gold-plates with springs.

## 3. Spec sources

- User screenshots (2) + directives (slot position, stroke kill,
  true morph, fast): primary.
- `FlowBarPosition.frame` (slot math, margins, clamp — reused, not
  re-derived); `FlowBarPanel.makePanel` (recipe being split);
  `NoTargetModal.showFromPill` (morph being re-anchored);
  v4 §§3-5 (UI/palette/retention — untouched).

## 4. Exact file changes

1. `Oto/UI/FlowBar/FlowBarPanel.swift` — NEW `makeHostingPanel(
   contentView:size:)`: panel clear/opaque/shadow/level/behavior
   IDENTICAL to `makePanel`, except it does NOT force `wantsLayer`
   (SwiftUI owns hosting-layer policy) and never touches layer
   backgrounds. `makePanel` itself UNTOUCHED (pill + permission
   modal keep their proven path — no collateral).
2. `Oto/UI/Scratchpad/NoTargetModal.swift` —
   a. `prewarm` uses `makeHostingPanel`; after EVERY `rootView`
      assignment, post-hoc clear IF a layer exists (never
      force-create): variant-A ordering.
   b. End frame: slot-anchored via `FlowBarPosition.frame(464,
      168, on:visible, position:)`; new `position:` parameter on
      `showFromPill` defaulting to `FlowBarPosition.current()`
      (explicit + testable). Centered `morphEndFrame` deleted,
      replaced by `morphEndFrameAtSlot(visible:position:)` (pure).
   c. Duration 0.22 → 0.18 `.easeOut`; RM instant, generation
      guard, nonactivating recipe, fallback plain show: unchanged.
3. `Oto/UI/FlowBar/FlowBarController.swift` — route passes
   `FlowBarPosition.current()` into `showFromPill` (one argument;
   pill-frame snapshot logic unchanged).
4. Tests — `morphEndFrameAtSlot` units (top grows down from pill
   top edge: y = maxY−168−12; bottom grows up: y = minY+28;
   x centered like pill; small-screen clamp); palette/nonactivating/
   retention/router/divert pins untouched. Stroke + morph-feel are
   screenshot-matrix (stated, not faked — headless tests cannot
   see compositor pixels).
5. Variant B (fallback, built ONLY if matrix keeps the frame):
   A + `hosting.layer?.backgroundColor = clear` post-orderFront
   + `masksToBounds` audit on the hosting chain. One-line
   amendment here before building it — never speculative code.

## 5. Verification steps

- Build clean zero warnings; new tests green; full suite green
  TWICE; gates (unwraps, banned, hardcoded fills, pill/permission
  pixels byte-identical — recipe split proven by suite + shots).
- Device screenshot matrix (packaged `.app`, user sends shots —
  the established loop): variant-A card dark + light × top slot +
  bottom slot → stroke gone? morph reads as grow-in-place?
  <0.25s feel, no hitch repeated? RM instant? small-screen clamp?
  One divert re-confirm row (logic untouched). Verdict per shot
  before any variant-B work.
- Then merge (green twice + this matrix + the §2 divert matrix
  already banked).

## 6. Risks

- Variant A insufficient (SwiftUI paints opaque regardless):
  variant B queued, same matrix decides — two rounds max, then
  the nuclear option (CALayer-drawn card, pill-style) is specced,
  not started.
- Slot card overlapping menu-bar/dock content beneath: same
  margins as the pill (12/28) + floating level — identical
  citizenship to the proven pill, no new occlusion class.
- Bottom-slot card vs autocomplete popups: transient overlap
  while visible only; ✕/Copy dismiss — matrix row, not a blocker.

## 7. Open questions — none. `execute` builds §4.
