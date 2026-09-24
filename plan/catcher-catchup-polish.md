# Catcher polish: spacing, vertical text flow, 100-word cap, Copied-close

Status: IMPLEMENTED 2026-09-24 (commit on abu-dhabi). Build green,
378 tests green twice running (4 new catcher tests; pins updated
deliberately). Device matrix (§9) still requires a packaged/Xcode Run
with live dictation + screenshots. Nothing merged.

Reference: `.context/attachments/ScSmPv/image.png` (current catcher —
truncated dots, cramped X, gray Copy), `.context/attachments/eRxkkB/image.png`
(spacing model only: caption insets, X ring padding, text-to-Copy rhythm —
copy spacing, never icons/text/elements).

## 1. Goal

Catcher shows full short transcripts as wrapped vertical text in a
well-padded card that grows away from the pill edge at fixed width;
long transcripts cap at 100 words display with auto-copy + Copied;
Copy shows "Copied" 1s then auto-closes; icons unchanged (pencil
removal excepted — explicitly ordered).

## 2. Layout + spacing (`NoTargetModalView`)

- Reserve the X zone: transcript block gets top-trailing inset so no
  first line ever runs under the X.
- X keeps its glyph, gains its own frame: 12pt padding all around plus
  bottom spacing to content; hit area becomes an invisible padded
  circle (`.contentShape(Circle().inset(by: -10))`) — modest expansion,
  stroke-only clicking ends.
- Vertical rhythm (from reference #2): caption zone → text ~14pt,
  text → Copy row ~18pt, card padding 20pt sides, Copy bottom-right
  with 16–20pt margins. Constants, screenshot-verified.
- Copy button: background adaptive — black on light, current gray on
  dark; white text both. New `CatcherPalette.copyBackground` field
  (dark≠light pin extended). Nothing else in the palette moves.

## 3. Text flow + dynamic height (fixed width, never)

- Delete `lineLimit(2)` + tail truncation: full text wraps, top-aligned,
  listed vertically.
- Height is computed, not fixed: pure `CatcherLayout.height(words:width:)`
  via AppKit bounding-rect metrics at fixed 464pt width; width NEVER
  changes. Min 168 (today), max = capped 100-word height clamped to
  visible-screen fraction.
- Growth direction from pill slot: top slot anchors top edge, grows
  downward; bottom slot anchors bottom edge, grows upward (pill as
  reference). `morphEndFrameAtSlot` gains a height param; plain `show`
  centers the computed size.
- Content mask recomputed per show (today's install-once assumed static
  geometry): same path function, parameterized by size, skip-if-same
  retained.

## 4. 100-word policy (display clamp only — data never truncates)

Amended during execution: over-limit renders in the PILL, not the
modal (user-ordered). RecoveryRouter is untouched; the controller
latches a 2.5s message pill (same size, re-render never resize) with
greedily-filled leading words + Copied, auto-copied whole transcript.
Root cause found en route: the SwiftUI view kept a hardcoded 168pt
frame, so taller panels compressed text into default truncation (the
dots) — the view now tracks a live controller height with a clipShape
backstop, which also retires the mismatch family behind the
outer-stroke report.

- Pure `CatcherText.displayWords(_:limit: 100)`: first 100 words +
  "…". `recoveryTranscript`, clipboard, and history always keep the
  FULL text — the cap is pixels, never data.
- ≤100 words: modal as §2–3, Copy → "Copied" 0.6s → auto-close (§5).
- >100 words: transcript auto-copied immediately; NO modal — the
  controller latches a 2.5s message pill at current size (greedy word
  fill + Copied, re-render never resize). Latch clears on any live
  session or deadline; stale latches cleared on silent/autoCopy routes.

## 5. Copy → Copied 0.6s → auto-close (explicit user override)

- Overrides the "Copy never dismisses" rule (user-tested flow wins):
  `copy()` sets Copied, writes clipboard, and after 0.6s hides the
  panel and resets state — one generation-guarded block (existing
  `copyGeneration` discipline extended: re-copy inside the window
  restarts the second, never double-hides).

## 6. Shortcut pencil removal

- Delete the pencil `Button` in `KeycapField`
  (`ShortcutModal.swift`); field-tap arming stays (the `onArm` field
  button is untouched). Trash, chips, recorder, presets untouched.

## 7. Exact file changes

- `Oto/UI/Scratchpad/NoTargetModal.swift`: layout/spacing constants,
  X hit frame, wrap + dynamic height plumbing, 100-word display clamp,
  copy auto-close, `show(autoCopied:)`, mask-per-size.
- `Oto/UI/Scratchpad/CatcherPalette.swift`: `copyBackground` field.
- `Oto/UI/FlowBar/FlowBarController.swift`: pass computed height into
  `show`/`showFromPill` (morph helper signature grows a height param).
- `Oto/Settings/ShortcutModal.swift`: pencil deletion only.
- No coordinator/insertion/recovery changes (full text preserved —
  state explicitly).

## 8. Tests (deterministic, no hardware)

- `CatcherLayout.height`: empty → min, short → fixed, 100 words →
  capped max, width constant across inputs.
- `displayWords`: ≤100 verbatim, >100 capped + "…", data untouched
  (recovery/clipboard paths unchanged — existing tests stay green).
- Copy auto-close: Copied set → 1.2s sleep → hidden + reset; re-copy
  inside window restarts (no double-hide).
- Mask/geometry tests updated deliberately (parameterized size,
  morph heights both slots, narrow-screen clamp).
- Existing suites untouched, must stay green.

## 9. Verification

- Build green; full suite green twice.
- Device matrix (screenshots required): short text wrapped both slots;
  X zone clear + expanded click area; 100-word growth direction per
  slot with fixed width; 101-word auto-copy + Copied + close; Copy →
  Copied 1s → close; light-theme black button; pencil gone, field-tap
  arming intact; catcher full re-run (insertion path untouched, but
  modal changed — full re-run, not spot-check).

## 10. Risks / deferred

- Height cap vs tiny screens: clamp keeps slot edge, shrinks inward
  (existing guard extended, never overflow).
- Over-limit auto-copy overwrites clipboard by design (same contract
  as catcher-off auto-copy); menu Copy/Retry remain.
- Out of scope: editable transcript (6C2), per-app shortcuts, notice
  system (stays deleted), icon/button redesign.
