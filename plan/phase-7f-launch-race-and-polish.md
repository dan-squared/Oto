# Phase 7f: launch-registration race, pill top, cleanup cards, one-word labels

> Follow-up to 7d+7e (shipped, uncommitted) from live testing with the
> Intelligence screenshot: (1) transform shortcuts dead on launch until a
> shortcut is changed + reapplied, (2) pill must default to top, (3) Auto
> Cleanup None/Light/Medium should be cards, not a segmented row,
> (4) pill text still truncates + must be 1 word max.

## Diagnosis (the launch bug — race, not registration)

> Registration at launch is sound (Carbon monitors install in
> `TransformDispatch.start()`; reapply succeeding proves it). The failure is
> the stale-config double-fire, FlAKY by scheduling: with Push-to-talk =
> Right ⌥ (stale stored hold, never a default) + transforms on Opt+digits,
> every Opt press fires BOTH the HID hold path (flagsChanged → queued async
> emit → `route(.begin)` → Task → `beginHold`) and the Carbon combo path
> (direct → Task → transform). Whichever Task runs second loses: hold-begin
> landing first makes `dictationLive` true → the transform is IGNORED
> ("doesn't work on launch"); combo landing first strands a mic-live hold
> session (release is swallowed by combination-use). Reapplying (changing
> Push-to-talk to Right ⌘) removes the overlap, which is why it "fixes" it.
> The screenshot's audit warnings were correct output for a stale input.

## Goal

- Transforms fire deterministically on EVERY launch with ANY stored config:
  settle window → cancel fresh hold micro-session → recheck → suspend
  dictation keys for the run → replace → resume. A same-family hold can no
  longer suppress or strand; a real (old) session still vetoes.
- Pill defaults to top (absent/unknown key ⇒ `.top`; stored `.bottom`
  preserved — drag choice is never overridden).
- Auto Cleanup picker becomes three selectable cards (name + one-line
  description each), selected card visibly distinct, full keyboard +
  VoiceOver path, no custom toggles.
- Pill labels are 1 word max: `Cleanup` / preset display name (`Polish`,
  `Concise`, `Professional`). Shorter labels also shrink every work width,
  retiring the truncation class (frame-containment test now pins the new
  longest label, `Professional`).

## Spec sources

- 7d/7e plans (design record — untouched); user screenshots (stale Right ⌥
  hold + warnings; generic settings wireframe — direction only, no design
  to copy).
- Code facts verified by reading: `HotkeyTransitionState.step` (begin on
  first non-repeat down), `ModifierHotkeyMonitor` (Carbon redelivers → repeat
  normalization), `ShortcutDispatch.route` (one Task per gesture; finish
  targets `activeSessionID` regardless of slot), `DictationState.canCancel`
  (starting/recording cancellable), `FlowBarPosition.current` (absent ⇒
  bottom — the line that moves), `setSuspended` (cancels active session;
  idle-safe), `SessionContext.startedAt` (`ContinuousClock.Instant`).
- Local SDK truth: unchanged (no new APIs; `Duration` comparison already
  used in dispatch).

## Assumptions questioned

- *"Fix by blocking stale configs at load."* Rejected: silent behavior
  change under stored data (the 7e load-advisory rule stands — name, never
  rewrite). The race fix makes stale configs WORK instead.
- *"Fix by delaying hold-begin until combos resolve."* Rejected: taxes EVERY
  dictation start (the product's founding immediacy) to serve transforms.
  The 100 ms settle taxes only transform presses (seconds-long model jobs —
  invisible).
- *"Suspending dictation keys during transforms strands Escape-cancel."*
  Accepted cost, bounded: Escape rides the dead tap for ≤6 s; second-press
  serializes (documented in code).

## Exact file changes

1. `DictationCoordinator`: `cancelFreshHoldMicroSession(olderThan:
   Duration = .seconds(1))` — cancels only hold-interaction sessions in
   starting/recording younger than the bound; everything else untouched
   (hands-free, old, finalizing/inserting). Lossless by construction
   (pre-insertion cancel discards nothing).
2. `TransformRunner`: replace fire-forget `run` + `current` with
   `execute(preset:) async` (dispatch serializes now; cancellation points
   already present + structured race).
3. `TransformDispatch`: `receive` becomes settle (100 ms) → cancel fresh
   micro → recheck live → suspend dictation keys → `await
   runner.execute` → gen-guarded resume (`transformGeneration`; stale
   tasks never resume early). New closures:
   `cancelFreshMicroSession: @Sendable () async -> Void`,
   `setDictationSuspended: (Bool) -> Void`. `comboSettle` constant (100 ms).
   Test hook `fireForTests(_:)`.
4. `OtoApp`: wire the two closures (`coordinator.cancelFreshHoldMicroSession()`,
   `dispatch.setSuspended`); nothing else moves.
5. `FlowBarPosition.current`: absent/unknown ⇒ `.top`. Stored values
   untouched. Position test updated.
6. `IntelligencePane`: Auto Cleanup segmented → three button cards
   (title + description; selected = accent border + checkmark row state;
   `.accessibilityAddTraits(.isSelected)` + label per card). Example
   triplet + microcopy stay below. No new controls, no custom toggles.
7. `FlowBarState.workPillText`: `.cleaningUp` → `"Cleanup"`, presets keep
   `displayName` (already single words). Width/caption tests updated
   (`Professional` is the new longest label).
8. Tests: runner tests call `execute`; serial-cancel + suspend-scope +
   live-veto move to dispatch-level tests (fakes + hooks); coordinator
   fresh-micro tests (fresh cancels / zero-threshold keeps / hands-free
   untouched); gate/width/pill tests updated to one-word labels; position
   default test flips to top.

## Verification

- [ ] Build green; full unit green (UI smoke excluded — proven
  pre-existing failure).
- [ ] New/updated tests green isolated: dispatch serial + suspend balance
  + live veto, fresh-micro trio, cards render (no window — state-driven),
  one-word width pins.
- [ ] Matrix (user, clean + STALE configs): with Push-to-talk Right ⌥
  (stale!) + Opt+1: transform fires every press, no stranded recording
  (menu status returns to idle, no pill stuck); then Reset/switch hold to
  Right ⌘: identical behavior, zero warnings; pill sits top on first
  launch; cards select with one tap; pill shows `Cleanup`/`Polish`/
  `Concise`/`Professional`, never `…`.

## Risks

- 100 ms settle on every transform press (invisible against model latency;
  pinned constant, matrix can't feel it).
- Dictation keys dead during a transform run (≤6 s, only when idle at
  press; recording presses still veto first — never interrupts).
- Stored conflicting configs now WORK instead of warning-only: the audit
  rows still show (honest), but the urgency drops — intended (frictionless
  beats scolding).
