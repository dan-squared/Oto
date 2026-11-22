# Phase 11 — stuck states (cancel race, duck slot, non-float silence gate)

## Goal

Close the three audit P0s where Oto looks alive but is dead: a
cancel→re-press teardown race that kills the new session's mic, a failed
media restore that wedges all future duck/restore pairs (stuck muted),
and a silence gate blind to non-float audio that eats voiced sessions as
"success." Each fix is small; each needs verification fakes alone
cannot fully provide (stated per item).

## Spec sources (canonical first)

- `Docs/START_HERE_PRODUCT.md`: finish/cancel idempotent and mutually
  exclusive; every async result checked against the active session ID;
  every uncertain result recoverable (the silence-gate item violates
  this directly — loss presented as clean success).
- Current code truth (read 2026-10-06):
  `DictationCoordinator.swift:194-213` (cancel flips terminal, then
  awaits shared teardowns), `:257-282` (begin accepted while terminal,
  preparation detached), `:284+` (`runPreparation`), `:369-377`
  (`shouldSkipTranscription`), `:54-62` (silence constants);
  `AppleAudioCapture.swift:96-113` (`noteBufferPeak` float-only),
  `:143-155` (unconditional teardown), `:190` (nil-format tap);
  `AppleSpeechService.swift:241-248` (cancel path);
  `MediaDuck.swift:137` (250 ms grace), `:155-199` (duck + absorb),
  `:201-217` (restore park), `:222-252` (finishRestore keeps slot on
  failure), `:106-118` (`MediaDucking` seam);
  `AudioCaptureService.swift:13-16` + `:45-56` (protocol + fake),
  `SpeechService.swift:14-16` + `:60-85` (protocol + fake);
  `MediaDuckTests.swift:20-69` (FakeHAL with failing-`setVolume`
  support already: uncontrolled/no-volume devices return false).

## Facts verified against the local SDK (never from memory)

- ACP connected this session: workspace `Oto.xcodeproj`, scheme `Oto`,
  dest `My Mac`. Toolchain Xcode 27.0 (27A266a), Swift 6.4,
  `MacOSX27.0.sdk`, deployment target 27.0.
- `int16ChannelData` is present and non-deprecated in
  `$SDK/.../AVFAudio.framework/Headers/AVAudioBuffer.h:154-162`
  (2-byte linear PCM accessor, same family as `floatChannelData`).
  The non-float peak path below uses documented API only.
- This plan adopts **zero new framework APIs** and changes **zero
  protocols**: the cancel fix is coordinator-local sequencing, the duck
  fix is branch logic, the peak fix is buffer-format handling. The
  "What's new" surface is therefore empty — stated so nobody
  re-researches it.

## Assumptions questioned

1. "Teardown must complete before cancel returns (responsiveness)."
   No — only the *state flip* must be synchronous (Escape → instant
   pill vanish). The teardown work can sequence behind the scenes;
   `begin()` stays accepted and preparation absorbs a millisecond-scale
   wait invisibly.
2. "A failed restore should keep retrying with the same owner." No —
   the owner is dead by construction (its session ended, else no new
   duck could arrive under the one-live-session invariant the
   coordinator upholds). Keeping the owner wedges; transferring it
   heals. Crash-safety (persisted flag + saved volume) is orthogonal
   and untouched.
3. "The silence gate needs the converter." No — peak is metadata, not
   audio: scan the native int16 planes in place with the same stride-4
   discipline, normalized to 0..1, same threshold. No conversion, no
   allocation, no lock changes on the realtime thread.

## Design (decisions + reasons)

**Item 1 — cancel/next-session race (P0-5). Recommended: coordinator-side
teardown chaining (NOT service epochs).**
- `cancel()` keeps its synchronous terminal flip (responsive UI), but
  the three teardown awaits move into a stored `teardownTask`, chained
  behind any prior teardown (`let prior = teardownTask; teardownTask =
  Task { await prior?.value; await audio.cancel(); await
  speech.cancel(); await restoreMedia(...) }`).
- `runPreparation()` awaits `teardownTask?.value` as its first step
  (captured handle; a *newer* teardown starting later belongs to a
  newer cancel, which already invalidated this session ID — the
  existing re-checks discard it).
- Why not service epochs: identical correctness would require
  session-ID parameters on 6+ protocol methods and ripple through
  every fake and dozens of call sites. Chaining is coordinator-local,
  protocol-free, and fakes-testable. Deadlock audit: teardown work
  never re-enters the coordinator (audio/speech/media sinks only), so
  the wait is one-directional by construction.
- The stale comment at `:201-205` (teardown "is the real services'
  responsibility") gets rewritten to describe the implemented design.

**Item 2 — duck slot adoption on failed restore (P0-6).**
- In `duck()`, after the same-session branch and before the nil guard:
  `if let holder = duckedSessionID, holder != sessionID` → adopt:
  `duckedSessionID = sessionID`, log, return WITHOUT touching the
  volume (already 0 from the dead session's duck) and WITHOUT touching
  `savedVolume`/`savedDevice`/crash-flag (they describe the pre-duck
  level this session must restore).
- Why adopt beats park-release: the saved baseline stays valid, the
  crash flag stays set throughout (kill-safe in every direction, as
  today), and the change is ~6 lines. B's `restore(B)` then parks and
  finishes normally; a second failure re-keeps the slot exactly as
  today (still retryable, still backstopped by `restoreIfCrashed`).
- Correctness relies on: one-live-session (coordinator-upheld;
  same-session re-duck already handled above this branch), and the
  existing device-fallback in `finishRestore` (dead ducked device →
  current default, already at `:232-236`).

**Item 3 — format-aware silence gate (P0-7).**
- `noteBufferPeak` branches on `buffer.format.commonFormat`: float
  (existing scan, unchanged) + int16 (`int16ChannelData`, peak/32768,
  same stride-4, same lock discipline). int32 and exotic formats stay
  as today (early-return) — documented gap, rare hardware.
- Threshold semantics unchanged (normalized 0..1 vs 0.01). No
  converter involvement, no allocation per buffer, no lock changes.

## Exact file changes

1. `Oto/Coordinator/DictationCoordinator.swift`
   - Add `private var teardownTask: Task<Void, Never>?`; `cancel()`
     moves its three awaits into the chained task (state flip stays
     inline); `runPreparation()` awaits the captured task first;
     rewrite the `:201-205` comment.
2. `Oto/Services/AppleAudioCapture.swift`
   - `noteBufferPeak`: int16 branch per Design. Nothing else changes
     (tap, teardown, debounce untouched).
3. `Oto/Services/MediaDuck.swift`
   - Adopt-branch in `duck()` per Design (+ log line). Nothing else
     changes (grace, absorb, finishRestore, flags untouched).
4. `Oto/Services/AudioCaptureService.swift` + `Oto/Services/SpeechService.swift`
   - Test-only gate hooks on the fakes (cancel/start suspension gates,
     `StreamGate` precedent from `FakePolishService`) for the ordering
     test. Production types untouched.
5. Tests (`OtoTests/`)
   - `DictationCoordinatorTests`: cancel→begin ordering — teardown
     parked on gates, begin accepted, B not recording until gates open;
     gates open → B records, A-side effects absent. Uses the new fake
     gates (fakes-testable, no hardware).
   - `MediaDuckTests`: failed-`setVolume` (uncontrolled device) →
     grace expiry → new session `duck()` adopts (no volume touch,
     slot transferred) → `restore()` parks → success path clears all.
     FakeHAL already fails on demand — no fake changes needed.
   - Audio peak tests (next to `RebuildDebounceTests` peak cases):
     synthetic int16 buffer (loud sine → peak ≈ amplitude; silence →
     0), float behavior byte-identical, int32 still early-returns
     (documented gap, pinned so it can't silently change).
6. No changes to protocols, project settings, entitlements, Docs, or
   any UI surface.

## Verification steps

- `xcodebuild -scheme Oto -destination 'platform=macOS' build` green.
- `xcodebuild test -scheme Oto` green (new tests + all existing pins,
  incl. cancel-wins, duck absorb/grace, sway/peak cases).
- ACP `RunSomeTests` on the touched suites.
- Live matrix (packaged app; items 1–2 need human timing, item 3 needs
  hardware):
  1. Rapid Escape→re-press mid-finalize ×10: every retry records live
     audio (no silent/dead sessions, no `noAudioCaptured` without cause).
  2. Unplug BT mid-duck (or force HAL failure): session ends → next
     session ducks mutes/restores correctly; volume never stuck at 0
     past one session; relaunch backstop untouched.
  3. Non-float USB/BT device long dictation: full transcript inserts,
     no silent-skip; float devices byte-identical behavior.
- Device-budget note: items 1–2 are reproducible on any Mac with fast
  fingers; item 3 strictly requires non-float hardware — without it,
  ship on the unit proof + a matrix IOU, and say so in the merge notes.

## Risks / deferred decisions

- Chaining adds one suspension before recording starts (prior teardown
  duration — engine stop + drop, milliseconds). Invisible against
  preparation latency (hundreds of ms); stated so the profiler isn't
  chased later.
- Adopt correctness leans on one-live-session; a future multi-session
  design must revisit the `duck()` branches (comment will say so).
- int32/exotic formats remain blind (documented, pinned). If a matrix
  device delivers int32, extend the branch — same 10-line shape.
- Deferred: service-epoch alternative (rejected: protocol churn for
  identical correctness), snapshot-restore for duck (rejected:
  retention questions), grace-length retune (P1-7 stays separate).

## Open questions (recommendations marked)

- Q1 Teardown-chaining vs service epochs? (Recommended: chaining —
  zero protocol churn, fakes-testable, deadlock-free by
  one-directionality.)
- Q2 Adopt-on-duck vs park-release on restore failure? (Recommended:
  adopt — baseline stays valid, crash-safety untouched, ~6 lines.)
- Q3 int16-only vs int16+int32 now? (Recommended: int16, pin the int32
  gap explicitly; extend on device evidence.)
