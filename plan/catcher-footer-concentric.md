# Catcher footer — buttons at the edge, one native step bigger

Status: implemented with this plan (user ask, 2026-11-01, with a screenshot of
the catcher: *"the copying cancel buttons are a bit upward, like we can move
them down to make them look cleaner and be concentric with the edge of the
catcher. And we could use a little bit bigger buttons, like a little bit, like
10 %, 5 % bigger."*).

Scope: the catcher's action row only. Morph, mask, palette and the card's
fill live in `plan/catcher-morph-parity.md` and are untouched here.
Press/hover motion is a separate, still-unapproved plan
(`plan/catcher-buttons-v7.md`).

## 1. What was actually wrong (measured, not guessed)

The screenshot is 952 × 412 at 2×, the card 464 pt wide → scale 1.987.

| measured | px | pt |
|---|---|---|
| Cancel plate | 132 × 48 | 66 × 24 |
| Copy plate | 111 × 48 | 55.5 × 24 |
| gap between plates | 21 | ~10 (spacing 10 ✓) |
| right inset (card edge → Copy) | 37 | 18.5 (padding 20 − antialias) |
| bottom inset (card edge → plate bottom) | 65 | **32.5** |

So the row was bottom-heavy by ~13 pt: the plate bottom sat 32.5 pt from the
card edge while the side inset was 20. Cause was structural, not a padding
typo — `HStack{…}.frame(minHeight: 52)` around a 24 pt button. The row was
52 tall, the button centred in it, so 14 pt of dead slack existed *below* the
button and the 20 pt card padding stacked on top of it: 20 + 14 = 34 ≈ the
32.5 measured.

Independently verified with `NSHostingView.fittingSize` on this macOS:
bordered `.regular` = 66 × 24, prominent `.regular` = 56 × 24; `.large` =
70 × 28 and 60 × 28. That is +6–7 % wide, +17 % tall.

## 2. Decision

**The row is exactly the button height, so bottom inset = side inset (20/20).**
`CatcherLayout.actionRowHeight = 28` replaces the 52 literal, and
`chromeHeight` is now *derived* from the same constants
(`cardPadding + textToActionsGap + actionRowHeight + cardPadding` = 86
instead of 110), so the card's height math and the view cannot drift apart —
the defect class the file's own comments already warn about.

**Size: `.controlSize(.large)`, the only native step.** The ask was "5–10 %
bigger, not too much". macOS offers regular (24) and large (28); there is no
26. +17 % height is a touch over the ask but reads as slightly chunkier, not
big, and it keeps the system button style the project requires — a custom
plate with hand-rolled padding would have been the only way to hit exactly
+8 %, at the cost of native hover/press/disabled behaviour. Recorded so a
later "too big" report retunes one constant, not the design.

Row slack above the buttons still comes from the `Spacer` when the card is at
its `minHeight` floor, which is correct: short cards keep the footer on the
bottom edge.

## 3. Exact changes

- `Oto/UI/Scratchpad/NoTargetModal.swift`: `CatcherLayout` gains
  `textToActionsGap = 18` and `actionRowHeight = 28` (with the measured
  provenance in the doc comment); `chromeHeight` derives from them; the view's
  `.frame(minHeight: 52)` → `.frame(minHeight: CatcherLayout.actionRowHeight)`
  and `.padding(.top, 18)` → the named gap.
- `Oto/UI/Theme/OtoControls.swift`: `OtoPill(large:)` documented with the
  measured 24 → 28 step (the catcher is its only caller).
- `OtoTests/FlowBar/NoTargetModalTests.swift`: the chrome assertion derives
  from those constants instead of copying `20 + 18 + 52 + 20`.

## 4. Verification

1. `xcodebuild -scheme Oto -destination 'platform=macOS' build` → BUILD
   SUCCEEDED.
2. `xcodebuild test … -only-testing:OtoTests` → 625 tests, 64 suites pass
   (after the two stale expectations this change invalidated were updated:
   the chrome literal here and the blue channel in `PillLayersTests`).
3. On device (user): the plate bottoms now sit the same 20 pt from the card
   edge as the side inset, and the row is ~17 % taller. Eyes are the judge of
   "cleaner"; the numbers only guarantee concentricity.

## 5. Deferred

- The `Copied` label is wider than `Copy`, so the Cancel plate shifts
  horizontally for a beat after a copy. Pre-existing; fixing it means a fixed
  width for the primary button, which is a separate decision.
