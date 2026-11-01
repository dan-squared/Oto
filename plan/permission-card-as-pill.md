# Mic card — the pill, expanded, in red

Status: implemented 2026-11-01 (user ask, with a screenshot of the old card:
*"instead of removing it make it look like the pill and make the colors look
native and make it rounded like the pill and make the button inside also a
pill and make it look like a pill expanded and we don't need to make it big
like that and … make it have the current pill finish and morph it"*).
Corrected the same day: **fixed red, not the user's pill colour** (*"make
sure it is red … it was a mistake to make it similar with the pill colour"*)
and **no warning icon** (*"remove the warning icon that is found on the
left, we don't need that"*).

This supersedes the look half of `plan/permission-denied-modal.md`. The
routing half (undetermined → system prompt, denied → System Settings, the
10 s auto-dismiss, no close button) is untouched.

## 1. What the old card was

A 60 pt rounded rectangle (r 16) filled with a fixed near-black, a red
`exclamationmark.circle`, a 12.5 pt semibold title, and a 36 pt beige
button (r 8) — a notification banner parked at the pill slot. It ignored
the pill's colour entirely and read as a different surface that happened
to appear where the pill lives.

## 2. What it is now

- **Capsule, 44 pt** — radius is exactly half the height, like the pill.
  Not 60: the ask was "we don't need to make it big like that", and a
  capsule reads as an expanded pill only while it stays near pill scale.
- **The pill's finish, in crimson.** The body is a real `NSGlassEffectView`
  (the pill's own hierarchy: frost hosting an ink view that carries the
  scrim and the horizontal five-stop ramp). The colour is fixed
  `PillColor.crimson` (`PermissionCardView.paletteColor`), *not* the
  setting: a permission failure that turns sky blue is decoration, and the
  first pass at "borrow the pill colour" was a mistake the user corrected
  the same day. The finish is borrowed; the colour is not.
- **No icon.** The words and the remedy are the whole message; the red
  glass and the inner pill carry the state. Title is white over the
  crimson ramp — legible at every brightness of the frost.
- **The action is concentric, not just inside.** 30 pt tall in a 44 pt
  capsule, inset 7 pt on every side, so its radius (15) is exactly the
  outer radius (22) minus the inset — Apple's concentric rule, and the
  reason it no longer reads as floating in a corner. The width is
  content-fitted and compact: text inset 18, title↔button gap 12, button
  inset 7. No reserved icon slot, no fixed width — both were tried on
  2026-11-01 and each produced a visible hole (left, then middle).
- **It morphs out of the pill.** On show, the card's layer is scaled to
  the pill's own rect (92.4 × 26.4 at the same slot) and animated to
  1 × 1 on `MorphCurve` (the catcher's 420 ms reference curve), anchored
  on the edge the pill shares with the card — top slot grows down, bottom
  slot grows up. A capsule at every scale means the shape morph is a pure
  scale: no radius interpolation, no window resize.

Repaint rule: `configure` repaints on every show, so a prewarmed card can
never keep stale text or a stale material state.

## 3. Exact changes

- `Oto/UI/FlowBar/PermissionModal.swift`: `height 60 → 44`, `cardRadius`
  and `buttonRadius` become half-height derived; `buttonHeight 36 → 30`;
  `glass`/`ink`/`ramp`/`capsule` layers; `applyAppearance` pins
  `PillColor.crimson`; `morph(from:card:position:)`; `show()` computes the
  pill rect and calls it.
- `OtoTests/FlowBar/PermissionModalTests.swift`: the concentric-formula
  assertion becomes the capsule invariant (both radii are half-height).

## 4. Verification

1. Build succeeds.
2. Full suite passes (625 + the replaced test).
3. On device (user): the card must read as the pill grown outward, in red, and the inner pill must stay legible for all five
   colours. Numbers only guarantee the capsule maths and the pale-button
   contrast; eyes judge the finish.

## 5. Deferred

- No glass (`NSGlassEffectView`) on the card yet: the ramp + scrim is the
  pill's *colour*, not its blur. Adding the real material is a separate
  decision (it costs a second glass view per show for a 10 s card).
- The 10 s auto-dismiss and the no-close-button rule are unchanged.
