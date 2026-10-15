# Audio `throwing -10877` per-session pair — diagnosis plan (no code changed)

Status: **Phase A landed 2026-10-15 — build green, 534/534 unit tests pass. Awaiting hardware (Phase B).**
Implementation notes (deviations from §Exact changes, both safer):
- Spans live in a separate TEMP `AudioStepTrace` enum, NOT new `PerfTrace`
  phases — the pinned 8-phase vocabulary and its count test stay untouched.
- `OSLog` has no `.info` (that's `Logger`): the helper carries both, signposts
  on the `OSLog`, the `AUDIOSTEP …ms` line on the `Logger`.
- Also landed alongside (user request, same change): Dock default OFF
  (`isShown()` absent-key → false; explicit values still win on upgrade),
  tests repinned, reversal recorded in plan/phase-5-dock-visibility.md §9.

## Goal

Attribute the twice-per-session `throwing -10877` lines in the device log,
decide whether they cost real press-to-ready milliseconds, and remove them
only if they are ours. Success is attribution first, silence second, speed
only if measurement proves it.

## Spec sources

- `Docs/START_HERE_PRODUCT.md`: one coordinator owns state; audio callbacks do
  no UI work; queues bounded; Apple Speech only.
- `plan/perf-latency-audit.md` F5 + P1: pressToReady CONTAINS `audio.start()`
  (coordinator `runPreparation`: mic → `audio.start()` → `speech.prepare()`),
  so audio-side waste bills directly to the number P2 couldn't delete.
- `plan/installtap-crash.md` (PID 19574): `installTap` mismatch raises an
  UNCAUGHTABLE NSException — the mitigations in `restart()` (fresh engine per
  start, nil-format tap, degenerate guard, drop-and-rebuild on stop,
  config-change debounce) are load-bearing and must survive this work intact.
- `plan/s5-audiotap.md`, `plan/buffer-size.md` (tap shape constraints).

## Facts verified against the local SDK / source (never from memory)

Checked 2026-10-15 on this Mac (MacOSX27.0.sdk, Xcode 27.0):

- `-10877 = kAudioUnitErr_InvalidElement`
  (`AudioToolbox.framework/Headers/AUComponent.h:835`). Not a format error —
  an element/bus that doesn't exist.
- The literal `throwing` appears NOWHERE in `Oto/` executable code (grep: one
  hit, a comment in `AppleAudioCapture.swift:200`). The lines are Apple's own
  internal exception logging (AVAudioEngine/HAL catching + logging), not ours.
- `restart()` (`AppleAudioCapture.swift:142-160`) runs per `start()`, in order:
  1. `removeConfigObserver()` (ours, safe),
  2. `engine.stop()` — on a FRESH, never-started engine,
  3. `engine = AVAudioEngine()` (fresh),
  4. `input.removeTap(onBus: 0)` — on a FRESH node with no tap installed,
  5. `installTap()` (nil format, guarded),
  6. `engine.prepare()`,
  7. `engine.start()` (HAL negotiation).
- Steps 2 and 4 are defensive guards against crash classes (stale observer /
  stale tap). Steps 2/4 execute unconditionally on every session, including
  when there is nothing to stop or remove. The pair cadence (exactly 2 per
  session, then success) fits either our two redundant guards OR engine-start
  internal probing — static reading cannot distinguish; Phase B does.

## Assumptions questioned

1. "`removeTap` on a tapless node is a safe no-op" — UNVERIFIED, suspect #1.
   If AVAudioNode raises InvalidElement for a missing tap, one throw per
   session is our own guard line.
2. "`stop()` on a fresh engine is free" — UNVERIFIED, suspect #2.
3. "It's engine.start() negotiation, untouchable Apple internals" — the live
   alternative hypothesis. If Phase B lands here, the outcome is documented
   wontfix (log hygiene only), not a fix.
4. "Removing the throws saves real milliseconds" — EXPLICITLY NOT PROMISED.
   Guard calls are cheap; the cost may live inside `engine.start()`, which we
   cannot and will not touch. Expected value: clean logs + exact
   pressToReady attribution. Any ms recovered is a bonus, reported honestly.

## Exact changes (phased)

### Phase A — attribute (headless-executable)

Temporary per-step signposts in `restart()` (all lines marked TEMP, removed in
Phase C either way): `audioStop`, `audioRemoveTap`, `audioInstallTap`,
`audioPrepare`, `audioEngineStart` — begin/end around steps 2/4/5/6/7 above,
reusing `PerfTrace` (no new vocabulary file). Plus a debug log line per step
with `PerfTrace.ms`. No behavior change: guards still execute unconditionally.

- Build green, full unit suite green before handing over.

### Phase B — measure (hardware, packaged signed app, ~5 minutes, user-run)

Three hold-to-talk dictations into TextEdit; paste the `audio*` + `PERF` lines.
Decision table (no judgment calls, read it off the log):

| Observation | Verdict | Phase C |
|---|---|---|
| Pair sits inside `audioRemoveTap` and/or `audioStop` spans | Ours: redundant guards | Fix C1 |
| Pair sits inside `audioEngineStart`, guards clean | Apple negotiation | Close as wontfix, remove spans |
| Pair split across guard + start | Mixed | Fix C1 for our half, document Apple's |

### Phase C1 — fix, only if Phase B convicts our guards

Track explicit state so guards fire only when armed (sketch, exact diff at
implementation):

```swift
private var tapInstalled = false   // set true after installTap succeeds
private var engineWasStarted = false
// restart(): engine.stop() only if engineWasStarted; removeTap only if tapInstalled
// teardown(): reset both; config-change rebuild path sets them through restart()
```

What MUST survive byte-identical in behavior: fresh engine per `start()`,
nil-format tap, `tapFormatUsable` degenerate guard, drop-and-rebuild on stop,
debounce policy + its unit tests, realtime-thread discipline (no logging,
no actor touches in the tap closure).

- New unit tests: guard-state machine (fresh → no stop/removeTap calls
  observable via subclass/hook counting; post-install → both fire; teardown →
  reset). HAL interaction itself stays device-proven, stated plainly.
- Grep gates: `os_signpost` emission still only via `PerfTrace`; TEMP spans
  gone; no NSException-class change (format arg stays nil).

## Verification

1. `xcodebuild -scheme Oto -destination 'platform=macOS' build` green.
2. `xcodebuild test -scheme Oto -destination 'platform=macOS'` full suite green
   (existing audio/relay/debounce tests + new guard-state tests).
3. Hardware: throws gone from the log (our-half), `pressToReady` delta read
   off three fresh dictations (expect small-or-zero — report the number, don't
   round it up to a win).
4. Killer regression (from installtap-crash.md §4): BT off mid-dictation →
   clean audio-capture failure, app stays alive. Non-negotiable.
5. TCC/shortcut validation stays in the packaged signed app only.

## Risks / deferred decisions

- Risk: touching `restart()` near the PID-19574 crash class. Mitigation:
  guards are ADDED (state-tracked), never removed; fresh-engine discipline
  untouched; BT-flap killer test mandatory before any push.
- Risk: misattribution → wasted fix. Mitigation: Phase C1 is gated on Phase B
  data; Apple-negotiation outcome closes the workstream with documentation.
- Deferred (named, not hidden): `_NSDetectedLayoutRecursion` FlowBar warning
  (UI workstream), `task name port` AX failure on pid 603 (permissions/AX
  workstream), P3 daily-driver proof + its arming decision, P4/P5 (parked).

## Open questions

- Which step logs the pair — answered by Phase B, blocking nothing else.
- Millisecond cost of the pair — answered by Phase B; the plan promises no
  number in advance.
