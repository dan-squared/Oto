# fn double-tap convert without architecture change (v2 — no caveats)

Status: PLAN ONLY. Nothing implemented. Awaiting `execute`.

Supersedes v1: the `.none`-only gate and the stop-then-hold
two-gesture compromise are gone. Design below works under every fn
setting with behavior identical to the reference (Hex) the user
verified, with one evidence-driven exception row decided by the
matrix, not upfront.

## 0. Why this works (verified in code, never assumed)

- Detection is pure observation. fn keyDown/keyUp already reach
  `receiveFnHold` with instants (`ShortcutDispatch.swift:480-522`);
  `DoubleTapTracker` (`ShortcutModels.swift:316-355`) times edges
  with zero new coordinator calls at convert time (existing
  `convertDoubleTapToHandsFree()` reused verbatim, generation gate
  included). No new taps, no Carbon changes, no consumption —
  never-consume stands.
- One tempo everywhere: `FnHoldConfirm.threshold` is ALIASED to
  `DoubleTapTracker.maxPressDuration` (250 ms,
  `ShortcutModels.swift:364`) — tap/hold boundary is a single
  number; fn reuses both, nothing new to tune.
- Hands-free sessions have NO coordinator-internal death:
  `DictationCoordinator` contains no auto-finish / max-duration /
  silence-timeout (verified by grep) — sessions end only through
  toggle, Escape, or cancel, i.e. exactly the paths this plan
  hooks. Flag staleness residual: ~zero.
- Rapid toggle is proven safe by the NORMAL path: stop-then-restart
  via the hands-free key (F5,F5) already exercises
  `toggleHandsFree()` re-entrancy daily (`DictationCoordinator.swift:114-124`
  self-resolves live→finish+insert, dead→begin). The fn stop path
  rides the identical call.

## 1. Exact behavior (every setting, no asterisks)

- Two sub-threshold fn taps (≤250 ms presses, ≤350 ms down-to-down
  gap — the shared constants) → hands-free starts. Same tempo as
  every other key's double-tap.
- Next fn DOWN while converted-live → stop WITH insertion, and the
  still-held press seamlessly arms a fresh hold: release quickly =
  pure stop; keep holding = stop-then-talk in ONE gesture. Single
  Task, toggle first, confirm-wait second (toggle re-entrancy per
  §0 — no overlap machinery beyond the existing generation gate).
- Tap-then-hold (second press sustains) → ordinary confirmed hold,
  byte-identical to today. Single taps still drop silently.
  fn+key/mouse mid-gesture → combination drop via the existing
  `hidMonitor.isInCombination` check (never convert a system
  gesture); tracker resets.
- Escape stops (existing path + flag clear). Hands-free key stops
  (existing toggle; flag cleared as the user takes over).
- System coexistence is Hex-identical: macOS also sees the taps
  (nothing is consumed, ever). Under Emoji/Input settings the
  system UI may appear alongside — the Phase C captions already
  disclose who owns quick taps. The matrix OBSERVES each setting
  (§3); only observed corruption scopes a row out (see R1).

## 2. Exact file changes

1. `Oto/Services/ShortcutDispatch.swift`
   - Beside `fnHold`: a `DoubleTapTracker` (`fnTap`; shared
     `holdTap` untouched) + `convertedByFnTap: Bool`.
   - `receiveFnHold` `.keyDown`: if `convertedByFnTap` → single
     sequenced Task: `await coordinator.toggleHandsFree()`, clear
     flag, then confirm-wait this press (still down + configured +
     not combination → `route(.begin, .holdToTalk)`); else today's
     confirm arming unchanged. Record down instant for the tracker.
   - `receiveFnHold` `.keyUp`: if the stop-hold Task confirmed →
     `route(.finish)` (normal hold finish); else if two quick taps
     complete (`fnTap.up`) → `convertDoubleTapToHandsFree()` +
     flag set; else today's drop/finish routing unchanged.
     Combination active at any edge → `fnTap.reset()`, existing
     drop path.
   - Flag clearing: `receiveEscape`, hands-free-slot keyDown while
     set, `route(.finish, mode: .handsFree)`.
   - Doc comments updated (`receiveFnHold` "never feeds" claim,
     convert comment); NO behavior gating on `SystemFnUsage`, NO
     new coordinator calls, NO new thresholds.
2. Copy: `.none` caption rewritten (double-tap fn works when free);
   all other captions byte-identical unless the matrix forces the
   R1 row (wording then, with evidence).
3. Tests (time-injected `receive(_:from:at:)`, existing precedents):
   convert pair; gap expiry; sustain→hold; combination veto;
   stop-tap inserts + clears; stop-then-hold single gesture
   (down stops, sustain begins, up finishes — one session each,
   transcript kept); Escape / hands-free-key / finish-route
   clears; down2-begin race covered by the reused conversion.
   Caption pin for the new `.none` line; `.unknown` literal
   untouched.

## 3. Verification

- Build green; full suite green twice (proven flakes excepted).
- Device matrix, packaged Run, PER fn setting (Emoji, Dictation,
  Input, Nothing): double-tap starts (pill); single tap silent;
  hold talks; tap-then-hold holds; next tap stops WITH transcript
  inserted; hold-after-stop talks in one gesture; Escape stops.
  Record the SYSTEM side per setting (does Emoji pop? does Apple
  Dictation start?).
- Catcher re-run (dispatch touched → full re-run).

## 4. Risks (each closed or evidence-bound)

- **R1 Apple-Dictation double-transcribe.** The one setting where
  coexistence could corrupt (two live transcribers, ducking
  undefined). NOT scoped out upfront: the matrix observes it; if
  corrupt, that single row becomes drop-with-caption (wording from
  the observed message), everything else ships. Evidence decides.
- **R2 stop/hold Task interleaving.** Sequenced single Task +
  proven toggle re-entrancy (§0); the test battery scripts
  down-stop-up, down-stop-hold-up, and Escape-mid Task. No new
  generation machinery.
- **R3 flag vs. foreign finishes.** Closed by §0's grep (no
  internal death) + clears on all three known end-paths.
- **R4 tempo drift.** Impossible by construction — shared struct,
  shared constants, aliased threshold.
- Out of scope: tap-stream engine, consumption, Carbon, 241,
  per-app behavior, alternate bindings.
