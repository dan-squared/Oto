# Phase 8b — snap haptics that feel magnetic, not late — PLAN ONLY

Status: IMPLEMENTED (2026-09-22) — user confirmed trackpad + gave go.

## 0. Verdict: what the user is feeling is correct (two root causes)

SDK truth (`MacOSX27.0.sdk`, `AppKit/NSHapticFeedback.h`, stable since
10.11 — quoted, not remembered):

- Patterns: `Alignment` = "guides, best fit"; `LevelChange` = "discrete
  pressure zones… NSMultiLevelAcceleratorButtons" (the detent thunk).
- Timing: `Default` (= DrawCompleted), `Now` (immediate), `DrawCompleted`
  (sync to next draw pass).
- Apple's rule, verbatim: feedback "should occur with something on screen
  such as the appearance of an alignment guide."
- Suppression is by design: "Force Touch trackpads will not perform the
  feedback if the user isn't currently touching"; performer follows the
  input device (mouse = silent, no software can change that).

Against that, the shipped code violates Apple's own rule twice:

- **F1. The tick is 150ms early.** It fires at mouse-up; the visual snap
  lands after the 0.15s glide. Cause and effect feel separated — that is
  the "not accurate" sensation, structurally, not subjectively.
- **F2. One weak tick for a two-phase event.** A real snap is grab (detent
  thunk as the dragged thing ENTERS the zone) + land (tick on arrival).
  We play a single `.alignment` — the subtlest pattern — at release, with
  zero feedback during the drag. No threshold-cross tick = no magnetism.

## 1. Fix design (standard snap haptics)

- **Threshold-cross → `.levelChange`, `.default`.** During drag, when the
  nearest slot CHANGES, tick immediately (DrawCompleted syncs it to the
  same frame the ghost highlight swaps — tick and glow coincide).
  Edge-triggered + 100ms refractory gate (`SnapTickGate`, pure,
  headless-tested) so boundary wiggle can't machine-gun.
- **Drop → `.alignment` on ARRIVAL, not on release.** Start the 0.15s
  glide, schedule the tick 150ms later (single `snapDuration` constant
  drives both — animation and tick can never drift apart). Cancelled if a
  new drag begins. `.now` at fire time (we ARE the moment).
- **Grab and no-move drops stay silent** (iOS rule: no tick for entering
  the zone you're already in).
- Unchanged: ghost visuals, slots, setting, vanish interplay (a drop that
  immediately melts still ticks — placement registered), Reduce Motion
  (haptics aren't motion), mouse-silence (Apple, not us).

## 2. Exact changes (on `go`)

1. `FlowBarPosition.swift` — add `snapDuration = 0.15`, `tickRefractory =
   0.1`; add nonisolated `SnapTickGate` struct (`shouldTick(now:slotChanged:)`,
   `reset()`).
2. `FlowBarPanel.swift` — `lastTickedSlot` + `tickGate` + cancellable
   `landTask`; began seeds (no tick); moved edge-ticks `.levelChange`;
   ended(moved:) glides + schedules `.alignment` land tick; began cancels
   a pending land tick.
3. Tests — `SnapTickGate`: first change ticks; repeat inside 100ms doesn't;
   after window does; no-change never ticks; reset re-arms. Suite stays 222+ green.
4. Grep gates: no new APIs (all three calls already-imported AppKit).

## 3. Verification (device — the user is the instrument)

1. Slow drag bottom→top: tick lands EXACTLY as the top ghost lights.
2. Release: second tick EXACTLY as the pill settles, not at finger lift.
3. Wiggle on the middle line: discrete ticks, never a buzz.
4. Click without drag: silence. 5. External mouse: silence (expected).
6. Prerequisite question for the user: test on the built-in trackpad —
   if the "inaccurate" report came from a mouse, no software fix exists.

## 4. Risks / non-goals

- Land tick vs 150ms sleep drift: same constant, same queue — bounded by
  the runloop, imperceptible.
- No audio tick fallback (out of scope; visuals already carry mouse users).
- Open: none blocking. One confirm on build: `.levelChange` strength on
  the user's exact hardware (only hands judge).
