# Pill position sync (Settings selector vs live pill)

## Goal

Settings → General → Position selector and the live pill agree in both
directions, from fresh install onward: same default, and flipping the
selector while the pill is visible glides the live pill to the new slot.

## Spec sources (canonical first)

- `Oto/UI/FlowBar/FlowBarPosition.swift:30-36` — absent/unknown key → Top.
- `Oto/Settings/GeneralPane.swift:46` — `@AppStorage` default is Bottom.
- `Oto/UI/FlowBar/FlowBarController.swift:373-385` — reads
  `FlowBarPosition.current()` per poll; comment at
  `FlowBarPanel.swift:142-144` claims live-follow works.
- `Oto/UI/FlowBar/FlowBarPanel.swift:162-172` — `resize` early-returns
  when width is unchanged; `moveToSlot` ("Re-slot a live pill") exists
  but has zero callers.

## Facts verified against the local SDK (never from memory)

- Toolchain/SDK per pill-shimmer plan (Swift 6.4, SDK 27.0, deptarget
  27.0). No new APIs: fix is defaults-key + call-wiring only.
- `settingRoundTripsAndDefaultsToTop` already pins `current()` default
  Top on empty defaults — the Settings-side `.bottom` default was the
  unwitnessed half.

## Root causes (both confirmed in code, not suspected)

1. **Default mismatch (fresh installs).** `current()` falls back to Top;
   the `@AppStorage` selector falls back to Bottom. Fresh profile: pill
   at Top, Settings shows Bottom. They sync only after the user touches
   the selector once (first write wins everywhere).
2. **Live-follow broken.** Same-session `show()` → `resize(to:position:)`
   → `guard width != currentWidth` returns early, so a slot flip with
   unchanged width never moves the visible pill. `moveToSlot` was built
   for exactly this and never wired — the "moves the live pill" comment
   is aspirational, not actual. (Drag path unaffected: polls skip `show`
   while `isDragging`; land path saves + frames directly.)

## Assumptions questioned

1. "The selector drives the pill." Only at show time / on width change —
   verified against `resize`'s guard, not assumed from the comment.
2. "Fix the default by changing current() to Bottom." No — Top is the
   asked default with a pinned test; the selector is the outlier.
3. "`dragStartSlot = .bottom` initializer is a third default." No —
   placeholder overwritten from `current()` on every grab
   (`FlowBarPanel.swift:356`). Untouched.

## Design (decisions + reasons)

- Single source of truth: `FlowBarPosition.freshDefault = .top`;
  `current()` falls back to it (both absent + unknown branches) and
  `GeneralPane`'s `@AppStorage` default becomes it. One constant, two
  readers — the mismatch class dies structurally.
- Live-follow inside the panel (geometry owner): track
  `currentSlot` (set in `setFrame`, the single funnel all four paths —
  fresh show, resize, moveToSlot, drag land — already route through;
  cleared in `hideNow`/`hide` with the other pins). Same-session `show()`:
  `if position != currentSlot { moveToSlot(position) }` before the
  existing `resize` call. Post-drag consistency holds: land saves target
  + frames it, so the next poll compares equal and never jumps; mid-drag
  flips stay drag-wins (unchanged behavior).
- No controller change (it already passes fresh `current()` per poll),
  no modal changes (both read live).

## Exact file changes

1. `Oto/UI/FlowBar/FlowBarPosition.swift` — add `freshDefault`;
   `current()` uses it in both fallback branches.
2. `Oto/Settings/GeneralPane.swift:46` — default `.bottom` →
   `FlowBarPosition.freshDefault` + comment naming `current()` as twin.
3. `Oto/UI/FlowBar/FlowBarPanel.swift` — `currentSlot` field; set in
   `setFrame`; nil in `hideNow`/`hide`; same-session `show()` reslots
   on mismatch before `resize`.
4. `OtoTests/FlowBar/FlowBarPositionTests.swift` — extend
   `settingRoundTripsAndDefaultsToTop` (or new test):
   `freshDefault == .top` (pins the constant the pane reads).
   Panel reslot is not headless-testable (needs `NSScreen`; no panel
   tests exist) — covered by the live matrix below.

## Verification steps

- Build + unit suites green (Position + PillLayers).
- Live matrix (ACP launch, fresh `-OtoCleanSlate` profile): pill first
  shows Top AND Settings shows Top (was: Bottom). Flip to Bottom while
  pill visible → pill glides (was: stuck until width change). Drag to
  Bottom → Settings reads Bottom. Flip mid-drag → drag wins, no jump.
- Regression: rapid show/hide cycles, permission card + catcher modal
  slots follow (they read `current()` live — unchanged).

## Risks / deferred decisions

- `@AppStorage` default itself is unwitnessed by tests (reads
  `.standard`, no injection) — mitigated structurally (shared constant)
  + matrix item 1. Accepted.
- `moveToSlot` animates (0.15s snap glide) on every mismatch poll — by
  construction it fires once per flip (slot equality after), never per
  poll. Pinned by reasoning + matrix, not by test.

## Open questions

- None — both defects confirmed, fix is minimal and fully specified.

## Audit hardening (2026-10-05, no live verification available)

- Reslot tightened to a single `setFrame` per poll: the explicit
  `moveToSlot` now fires only when the width is constant (when the width
  moves, width-gated `resize()` lands the slot itself). Provably
  equivalent in all four width/slot combinations; removes one redundant
  overlapping glide.
