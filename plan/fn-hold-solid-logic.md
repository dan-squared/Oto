# fn-hold: solid temporal logic + closing polish (no suppression, no system mutation)

Status: IMPLEMENTED 2026-09-24 (commit on abu-dhabi). Build green;
366 tests: all green except 3 pre-existing environmental failures in
`RealTextInsertionTests` (otoFrontmost/focus-race/HID-post — fail
identically on the clean tree; need window-server focus/pasteboard).
Q1 resolved YES (hands-free fn gated with guidance). Device matrix
still requires a packaged/Xcode Run with live dictation — not runnable
headless. Nothing merged.

## 1. Verdict up front

- ACP Xcode: workspace `Oto.xcodeproj` open (scheme Oto, My Mac). No
  active launch session, so no fresh trail — analysis is code-level
  against the current fn path (`ShortcutDispatch.swift:419-498`).
- Do NOT consume fn, do NOT remap the system fn purpose while open.
  Full blocking requires swallowing the event (by definition suppresses
  native behavior); per-app fn-purpose mutation has no supported API,
  fights user settings, and persists across crashes. Keep temporal
  disambiguation + Right Option default + user-controlled Settings.
- The 250 ms confirm shape stays; this plan hardens its edges, closes
  observability gaps, and polishes modal close paths.

## 2. Diagnosed weaknesses (all verified in code, not assumed)

- F1. No trail lines: fn confirm/drop are silent. Coordinator begin log
  (`DictationCoordinator.swift:233`) carries mode + target, never trigger
  kind — an fn hold is indistinguishable from an Option hold in logs.
- F2. Combination-use blind spot: holding fn then clicking/typing (fn+key
  system gestures) still confirms at 250 ms — `receiveFnHold` never
  consults the HID layer's `usedInCombination`, which already tracks this
  per hold code (`HIDEventMonitor.swift:385-389`).
- F3. Hands-free + bare fn unresolved: a press toggles hands-free AND
  fires the system tap. No confirm logic can apply to an instant toggle.
- F4. Timer entanglement: confirm uses wall-clock `Task.sleep` inline —
  untestable timing; threshold logic deserves a pure core like
  `DoubleTapTracker`.
- F5. Modal close sloppiness: dead `invalidReason()` (`ShortcutModal.swift:251-255`);
  `presetKind(.combo)` "unreachable" fallback returns Right Option;
  `applyDone` success path doesn't clear prior messages (stale message
  risk); footer live while own card records (Reset mid-record vs armed
  recorder); sheet-ESC path with no listener relies on defaults.
- F6. Onset tradeoff undocumented: begin routes at confirm, so audio
  starts ~250 ms + preparation after physical press. Accept (single
  number shared with the tap constant; press-to-speak latency covers
  most of it) and matrix-test first-syllable capture — do NOT build
  pre-roll (breaks single-owner audio) and do NOT begin-early (reopens
  pill flash + engine churn per emoji tap).

## 3. Changes

1. `ShortcutDispatch.swift`
   - Extract pure `FnHoldConfirm` (down/up instants + threshold →
     `.pending/.confirmed/.dropped`); `receiveFnHold` keeps only the
     timer Task + routing. Unit-test the matrix (tap, hold, boundary,
     re-press, monitor-loss) without sleeps.
   - At confirm, consult HID combination-use for the fn code (new
     read-only accessor, e.g. `isInCombination(code:)`): set →
     drop silently (fn+click/typing is a system gesture).
   - Log confirm + drops at info (`fn hold confirmed`, `fn tap dropped
     (sub-threshold)`, `fn hold dropped (combination)`) — key metadata
     only. Trail decisiveness per repo standard.
   - Keep: pass-through untouched, machine pristine, `stop()`/
     Escape/monitor-loss disarm, refresh guard on `fnPendingDown`,
     fn excluded from `holdTap`, threshold 250 ms matrix-tuned.
2. Bare fn gated to the hold slot (§8 Q1): hands-free fn selection shows
   "fn taps belong to macOS — use Push to talk or a combination" and
   refuses to stage (recorder + preset paths).
3. `ShortcutModal.swift` polish: delete dead `invalidReason()`; replace
   the "unreachable" combo fallback with a precondition-gated path or
   explicit `.combo` passthrough comment + test pin; clear messages on
   applied saves; disable footer while either card records; document the
   sheet-ESC default after one verification run.
4. No coordinator/FlowBar/audio changes. No system-settings mutation.
   Hands-free fn behavior outside hold slot unchanged except the gate.

## 4. Verification

- Build + full suite green twice; new pure-matrix tests + dispatch tests
  (injected instants; sleeps only for Task firing, as today).
- Device matrix (packaged Run, console live): emoji tap ×N (zero Oto
  lines); sustained hold insert incl. first-syllable check; fn+click
  suppression; reconfig/Escape mid-press; fn double-tap (system only,
  no convert); hands-free fn refusal copy; modal close paths (✕/Done/
  ESC/reset-mid-record).
- If the matrix shows emoji firing on sustained hold (press-triggered
  system UI), bare fn is unusable without consuming — fallback stays
  fn+letter combo or another hold key. That outcome is evidence, not
  failure.

## 5. Risks / deferred

- Threshold is one fixed number; slow tappers' taps (>250 ms) will
  trigger Oto — accepted, calibration row proves real presses.
- Reconfig mid-press needs re-press (documented; Settings visits don't
  overlap live holds).
- Out of scope: pre-roll audio, per-app shortcuts, `AXIsEditable`,
  popover errors, alternate bindings.

## 6. Open questions

1. ~~Gate bare fn to hold slot?~~ YES (recommended) — an instant toggle
   cannot share a key with system taps; guidance copy included.
