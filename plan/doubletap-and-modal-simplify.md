# Modal simplify + double-tap-to-hands-free + all-modifier hold + validation popup

Status: PLAN ONLY. Nothing implemented. No open questions (all decided
below with rationale). Awaiting `execute`.

## 1. Goal

Four asks from live testing, one plan:

1. **Declutter the Shortcuts modal.** Fixed size, no scrollbar, no
   everything-dumped: status captions out of cards (summary row keeps the
   combined status), one short hint line only while recording, compact
   preset control, messages only when they fire.
2. **Plain language.** No "hotkey" anywhere user-facing; the modal answers
   "why two shortcuts" in its subtitle. Concise word list (§6.3).
3. **Double-tap Push-to-talk → hands-free.** Two quick taps on the hold
   shortcut start a hands-free session (next press stops it). Works on
   whatever the hold binding is — modifier, combo, any side.
4. **Hold accepts every modifier + invalid keys explain themselves.**
   The hold preset gains all sided modifiers; every recorder refusal shows
   a concise reason capsule naming the exact case.

## 2. Spec sources

- Reference screenshots (`.context/attachments/`, gitignored): summary row
  + Shortcuts modal shape — kept, decluttered, not redesigned.
- `Docs/START_HERE_PRODUCT.md`: native Settings only (kept); insertion
  honesty (kept — §5 proves no new success-lie).
- Current code: `Oto/Settings/ShortcutModal.swift` (built 2026-09-24,
  simplifies in place), `Oto/Services/ShortcutDispatch.swift`
  (route/begin guards — reused), `Oto/Coordinator/DictationCoordinator.swift`
  (`begin` terminal-guard, cancel-wins — reused, untouched),
  `Oto/Models/DictationState.swift:180-187` (`canCancel` covers
  starting/recording/finalizing/inserting — verified today),
  `Oto/Services/HIDEventMonitor.swift:460` (`ModifierHoldState.flag`
  covers all sided modifiers + fn — verified today),
  `Oto/UI/FlowBar/FlowBarPosition.swift:82-85` (`ContinuousClock.Instant`
  injection precedent — verified today).
- `plan/focus-and-settings-redo.md` (§6.3 modal, §6.4 KeyNames — extended,
  not replaced). The tap-vs-hold rejection in the old dual plan is
  explicitly superseded by §5 below (user-ordered, designed safely).

## 3. Facts verified against the local SDK today (never from memory)

- MacOSX27.0.sdk, Xcode 27.0. No new API adopted: `ContinuousClock`,
  `AXUIElement` set, SwiftUI `.sheet`/modifiers are all long-standing.
- `canCancel` = starting/recording/finalizing/inserting
  (`DictationState.swift:180-187`): cancel wins over in-flight finalize —
  the load-bearing guarantee for §5.
- `begin` requires `isTerminal` (`DictationCoordinator.swift:215`):
  a tap landing mid-finalize begins nothing (no micro-session pileup).
- `route(.begin)` overwrites `activeSessionID` only on non-nil return
  (`ShortcutDispatch.swift`): failed begins never clobber the live id.

## 4. Assumptions questioned

- **"Double-tap needs a disambiguation delay" — rejected.** Classic
  designs delay every hold start by 300 ms. Ours begins holds immediately
  (zero latency change) and confirms the double-tap on the *second
  release*: single taps, slow taps, and tap-then-hold behave exactly as
  today; only a confirmed quick-quick pattern converts — and conversion
  is cancel-best-effort + toggle, both idempotent, sequenced cancel-then-
  toggle in ONE Task (the toggle can never run ahead of the cancel and
  nil on a still-live micro).
- **"Conversion loses transcripts" — disproven by ordering.** At confirm
  time the first tap's micro-session is either non-terminal (cancel wins,
  discarded pre-insertion) or terminal-empty (silent-skip completed with
  nothing to keep — cancel no-ops). Insertion requires a speech round-trip
  far slower than the tap window; the residual risk (voice packed into a
  250 ms tap AND finalized inside 350 ms) is a device-matrix watch item,
  not a design hole.
- **"A real popover for errors" — rejected.** `NSPopover` steals focus
  (into the recorder's suspend/monitor context), races dismissal, and
  fights VoiceOver. An inline warning capsule under the field is
  glanceable, persistent, focus-safe, and unit-testable. Overridable only
  explicitly.
- **Thresholds are starting values, not truth:** press ≤ 250 ms counts as
  a tap, tap-to-tap gap ≤ 350 ms confirms. One constants site, pinned by
  tests, tuned by the matrix — same precedent as the silence gates.

## 5. Double-tap design (the core mechanism)

**Rule.** Hold-slot events feed a pure `DoubleTapTracker` (new, in
`ShortcutDispatch.swift` or models): `down(at:)` stamps, `up(at:)`
returns confirmed-true only when this press was tap-quick AND the
previous down was within gap. Gap is measured down-to-down (tap tempo);
stale pendings die by arithmetic (no timers — pure). Confirm on second
**release** (never on press): tap-then-hold stays a hold, slow patterns
stay taps.

**Dispatch wiring (hold slot, any kind — modifier, combo, either side).**
`receive(_:from:at:)` core takes an `Instant` (production passes
`.now`, tests inject): on hold-slot up with confirm-true → route the up
normally (it no-ops against the stale terminal id — the finish was
already consumed by the first tap), then convert. Conversion spins past
every begin routed before the confirm (begin-generation gate: down2's
begin id may not have landed yet — without the gate the toggle nils on
the live micro while cancel hits the stale id), then cancels the live
micro and toggles. The up's machine state stays consistent because
routing is never skipped.
Convergence in every order (proven against §3 guards):
- Micro non-terminal → cancel wins → discarded → hands-free begins.
- Micro terminal-empty → cancel no-ops → hands-free begins.
- Second down landing mid-finalize → `begin` nils (no micro pileup);
  the up is a no-op finish; confirm still converts cleanly.
- Taps during a foreign (hands-free) session: the tap's up finalizes
  that session via today's mode-agnostic finish (transcript KEPT —
  finalize, never cancel), then conversion starts a fresh hands-free.
  No path cancels a transcript-bearing session: conversion only ever
  cancels the tap's own micro id (finish never clears `activeSessionID`,
  so it is still the micro's at confirm time).

**Stopping.** Hands-free stops as today (its own press, or any third tap:
down3 begin-nils, up3 finish-finalizes). Nothing new to learn.

**Hands-free slot untouched** (down/down toggle already exists).

## 6. Exact file changes

### 6.1 `Oto/Models/ShortcutModels.swift` (+tracker; +staging untouched)

- ADD `DoubleTapTracker: Equatable, Sendable` — `downAt`,
  `pendingDownAt: Instant?`, `maxPressDuration = .milliseconds(250)`,
  `maxGap = .milliseconds(350)`; `mutating down(at:)`, `mutating
  up(at:) -> Bool`, `reset()`. `ContinuousClock.Instant` is `Sendable`;
  `Duration` comparisons are pure. Instant injection follows the
  `SnapTickGate` precedent.

### 6.2 `Oto/Services/ShortcutDispatch.swift` (tracker wiring only)

- ADD `holdTap = DoubleTapTracker()`; `receive(_:from:)` gains an
  `at:` core; `receiveForTests` keeps its shape + a deterministic
  `receiveForTests(_:from:at:)` variant. Confirm path:
  `cancelActiveSession()` (existing) then the hands-free `route(.begin)`
  Task (existing) — zero new coordinator calls, zero coordinator edits.
- Hands-free arm of the tracker: none (its machine already toggles).

### 6.3 Modal simplify + language (in-place in `ShortcutModal.swift`)

- Fixed content, **no `ScrollView`**: header (~title + new subtitle "Two
  ways to talk. Click a shortcut to change it."), two compact cards, footer.
  Target 560 × ~430; the matrix screenshot is the proof.
- Per card, exactly: title, one-line subtitle, keycap field, compact
  preset control (segmented, short labels), warning/status line ONLY when
  it fires (conflict+Swap, armed hint, or needs-permission — silence
  otherwise). Per-card polling captions deleted; combined status stays in
  the summary row.
- Word list (user-facing): "hotkey" → "shortcut" everywhere; preset
  "Custom combo" → "Custom"; status "Not received globally" → "Not
  detected yet"; "Requires Accessibility" kept (matches system Settings).
  `calibrationText` mapping updated deliberately (check pins first).
- Frameless rule restated (still no Form/GroupBox/List/panel in sheet).

### 6.4 All-modifier hold + validation capsule

- Hold preset "Hold key" gains a compact modifier menu (9 items, sided:
  fn, Left/Right Control/Option/Command/Shift → `kVK_` codes; all covered
  by the verified `flag(for:)`). Staging a modifier = `.modifierHold`
  kind. Chips show the glyph (`⌥` both sides — side lives in the menu
  label, documented); `KeyNames` gains sided menu labels + tests.
- Refusal capsule: inline warning capsule under the field (⚠ + one
  concise line), beep kept, shown for every case with its reason:
  modifier-only ("One key alone can't be a combination — bare keys live
  in presets"), plain letter ("Letters need a modifier, or they'd fire
  while you type"), bare Shift ("Shift alone never works"), reserved
  system ("Reserved by macOS on this version"), other-slot conflict
  ("Same as … — swap or pick another"), cleared ("Shortcuts turn off
  for both when you press Done"). Persistent until the next action.

### 6.5 Tests (all deterministic, no hardware)

- `DoubleTapTracker` pure tests (new file): quick-quick confirms; slow
  press clears; wide gap rejects; single tap silent; stale pending dies;
  pairs are non-overlapping (taps 1+2 confirm, tap 3 alone silent, taps
  3+4 confirm anew); thresholds pinned.
- Dispatch double-tap tests (fake coordinator, injected instants):
  gated-finish variant proves the micro is cancelled (0 inserts) and
  hands-free records; gates-open variant proves convergence (micro
  terminal-empty, hands-free records); slow pattern proves two ordinary
  hold sessions; tap-during-hands-free proves transcript kept + fresh
  hands-free begins.
- KeyNames sided labels + word-list changes; staging untouched (still
  green); `calibrationText` pin updates only if tests pin the old words.
- Existing suites unmodified, must stay green.

## 7. Verification steps

- `xcodebuild -scheme Oto -destination 'platform=macOS' build` green;
  `xcodebuild test -scheme Oto` full suite green twice.
- Device matrix (packaged/Xcode Run, console live):
  1. Fast double-tap hold → hands-free begins (second press stops); 0
     inserts from micros; trail shows cancel + begin.
  2. Slow taps → ordinary hold sessions, zero conversions.
  3. Tap-then-hold → normal hold insert (no false hands-free).
  4. Every sided modifier as hold incl. fn: hold works + double-tap works.
  5. Double-tap right after a real session → real transcript intact.
  6. Modal screenshot: fixed size, no scrollbar, sheet chrome exactly
     once; each refusal case shows its capsule line.
  7. Catcher re-run (dispatch changed → full re-run, not spot-check).

## 8. Risks / deferred decisions

- Thresholds are starting values (§4); the matrix tunes them.
- Residual micro-insert risk (§4) is a watch item with a near-zero window.
- Tap-then-hold after a foreign session inherits today's mode-agnostic
  finish (accepted behavior, matrix-blessed earlier).
- Out of scope (restated): alternate bindings per slot, per-app
  shortcuts, spoken triggers, `NSPopover` errors, `AXIsEditable`.
