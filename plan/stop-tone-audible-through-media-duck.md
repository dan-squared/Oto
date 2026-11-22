# Stop tone audible through the media duck

Status: planning finished — waiting for "execute".

## 1. Goal

The stop tone (`end_record.caf`, played at release) must be heard every time a
session stops, including when the media duck muted the output during recording.
Today it is audible only on sessions that never ducked — which is exactly the
user report: "it is working, but only if I'm not talking; if I'm talking, it
fails."

No change to when the cue fires (release) or which cue fires (stop, then error
on a later failure). This plan fixes only why the release tone is silent.

## 2. Evidence

Code, current tree:

- `DictationCoordinator.finalizeSession` (line ~526) does
  `await audio.stop()` → `await restoreMedia(...)` → `announce(.stopped)`.
  It assumes `restoreMedia` returns with the output audible.
- `MediaDuck.restore` (line ~212) does **not** restore. It parks a task for
  `restoreGraceNanoseconds = 250_000_000` and returns immediately; the HAL
  volume is still 0 when it returns.
- Every terminal path calls `restoreMedia` again, which cancels and re-parks
  the pending task, so the volume lands ≥ 250 ms after the *terminal* state,
  not after the stop.
- `end_record.caf` is 0.427 s (`afinfo`). The cue therefore starts at volume 0
  and is either swallowed whole or begins abruptly ~250 ms in — a click, not a
  tone.

Log evidence (`.context/attachments/AX9CcK/…txt`):

- Sessions with `ducked <id>` always print `restored <id>` after
  `speech finished` / `focus …`, i.e. 250 ms+ later.
- Sessions with no `ducked` line (quick taps released inside the start-tone
  lead) are the ones where the tone was heard.
- Speaking makes a session long enough to duck; a silent tap often does not.
  That is the reported split.

Why the test suite did not catch it: `FeedbackSoundsTests.LoggingDuck` records
`.restored` synchronously, so the ordering test passes against a duck that
restores immediately. The fake is more honest than the real class.

## 3. Root cause

The duck's restore is asynchronous by design (a 250 ms grace window to absorb a
follow-on duck and avoid a volume pump). The cue code treats it as
synchronous. A cue played inside that window plays into a zeroed virtual main
volume.

The grace was introduced before cue feedback existed (`plan/recorder-modifiers-
stutter-keynames.md` §6.2: "every clean restore lands ≤250 ms later —
documented, imperceptible"). It is imperceptible for media resuming; it is
fatal for a 0.43 s tone.

Also worth recording: with the start tone enabled, the grace cannot absorb a
real follow-on duck anyway. A duck happens at press + press→ready (~130 ms) +
start-tone lead (~454 ms) ≈ press + 584 ms. For it to land inside the 250 ms
grace, the next press would have to precede the previous stop. So the
anti-pump promise only holds in the unit test's synthetic shape, while its
cost — a delayed restore — is paid on every session.

Timing proof (sounds on, the default):

- A stops at t = 0. A's restore lands at t = 250 ms.
- B can only start after A reaches a terminal state (`begin` requires
  `state.isTerminal`), so B's press is at t ≥ 0.
- B's duck is at press + 130 ms + 454 ms ≈ t ≥ 584 ms.
- Absorption needs B's duck before A's restore: t + 584 < 250 → t < −334 ms.
  Impossible.

With sounds off (`toneLead == .zero`), B's duck is at press + ~130 ms, so only
a press within ~120 ms of A's terminal absorbs. That is the entire production
value of the grace, and it exists only for people who turned feedback off.

The start-tone lead (§10.2 of `plan/dictation-feedback-sounds.md`) post-dates
the grace, so the grace was meaningful when it was written and was silently
defeated by the lead afterwards.

Latent bug this also fixes: because A's restore is parked, a B pressed inside
the 250 ms starts its 454 ms start tone at volume 0 and only becomes audible
when A's restore fires — up to 250 ms of the start tone is missing. An
immediate restore makes both tones honest.

## 4. Options

**A. Play the cue when the parked restore lands.**
The duck would expose a completion; the coordinator announces after it. Correct
but late: ≥250 ms after release, and on a successful insert the terminal
re-park pushes it further. Rejected — the whole point of the change was the
native release feel.

**B. Add `restoreNow(sessionID:)`, use it at stop, keep the parked `restore`
for cancel and other terminals.**
Works, small diff, keeps the grace machinery. But it leaves two restore
flavours with a footgun: the default one is still "returns before the volume is
back", so the next agent can re-break the cue by calling the wrong one.
Acceptable fallback if the grace must be preserved.

**C. Retire the park: `restore` performs the HAL set before returning
(recommended).**
- The duck then brackets the capture exactly: duck at recording start, restore
  when `audio.stop()` returns. That is the same rule the tones follow.
- `await restoreMedia` means "the output is audible again", so the cue
  invariant is structural, not a comment.
- Media resumes at release instead of 250 ms after the terminal state — better
  for the common case, and the crash flag clears at stop.
- Removes the parked task, the absorb/unpark branches, and the
  restore-after-new-duck hazard (a parked restore firing mid-session).
- Cost: a follow-on session within the grace now re-mutes the media instead of
  staying muted through the gap. That pump is a brief media resume, masked by
  the 0.43 s stop tone and by the fact that the next start tone deliberately
  plays over full-volume media anyway. Given §3, this is a promise the grace
  was not actually keeping.

Rejected: playing the cue before the restore (muted), ducking per-app (macOS
has no per-app output volume; `vmvc` is the only supported control), and
shortening the grace (same conflict, less deterministic).

## 4.1 Why dictation is not affected

The change moves the restore from "250 ms after the terminal state" to
"immediately after `audio.stop()`". It does not move the duck, and it cannot
let media into a transcript:

- `AppleAudioCapture.stop()` → `teardown()` removes the tap, stops the engine
  and drops it (`engine = AVAudioEngine()`), releasing the input device.
  `removeTap` guarantees no further tap callbacks after it returns.
- Only then does `finalizeSession` call `restoreMedia`. There is no live
  capture path left for resumed media to enter.
- `speech.finish()` runs after the restore and only drains the buffers that
  were captured before the stop; output audio cannot join that stream.
- The duck itself (when the mic is muted) is unchanged: recording start +
  start-tone lead. Only the *unmute* moves, and it moves to after capture.
- Crash safety improves: the crash flag clears at stop instead of at
  terminal + 250 ms, so the window in which a kill could leave the user muted
  gets shorter, not longer.
- A failed restore keeps its slot and the next duck adopts it, exactly as
  today (`failedRestoreAdoptsNextDuck`), so no new stuck-muted path.

The only user-visible difference is when media comes back, and the only cost
is the ultra-fast double-tap with sounds off described above.

## 5. Exact changes

### 5.1 `Oto/Services/MediaDuck.swift`

- Delete `restoreGraceNanoseconds`, `restoringSessionID`, `restoreTask`.
- `restore(sessionID:)`: keep the ownership guards, then
  `await finishRestore(sessionID: sessionID)` directly.
- `duck(sessionID:)`: delete the same-session "unpark" branch and the
  `restoringSessionID != nil` absorb branch. Keep the stale-owner adoption
  (a failed restore keeps its slot; the next duck adopts it — the stuck-muted
  fix, `failedRestoreAdoptsNextDuck`).
- `finishRestore`: drop the task/session bookkeeping; keep the saved
  volume/device logic, the verified-success clear, and the failure log.
- Update the class and protocol docs: restore returns only after the HAL set
  succeeds or fails; there is no grace window. Note why: a cue played at stop
  must be audible.

### 5.2 `Oto/Coordinator/DictationCoordinator.swift`

Comment only, in `finalizeSession`: `restoreMedia` now returns with the volume
back, so the cue is audible; terminal restores remain as idempotent defense in
depth. No behavior change.

### 5.3 `OtoTests/MediaDuckTests.swift`

- `restoreReturnsSavedAndDoubleRestoreIsSafe`: drop the park assertions and the
  350 ms sleep; assert the volume is set by the time `restore` returns, the
  flag is cleared, and a second restore is a no-op.
- `restoreGraceAbsorbsNextDuck` → rename to `duckAfterRestoreMutesAgain`: after
  a restore, a new duck writes 0 again, saves the restored level, and its own
  restore returns that level. Pins the new contract (media resumes, then
  re-mutes).
- `failedRestoreAdoptsNextDuck`, `restorePrefersDuckedDevice`,
  `restoreFallsBackToCurrentDefault`, `foreignRestoreLeavesOwnerDucked`,
  `transientRestoreFailureRetries`: remove the 350 ms sleeps (no longer
  needed); expectations unchanged.
- Add `restoreReturnsOnlyAfterTheVolumeIsBack`: FakeHAL asserts the last set
  call is visible immediately after `await duck.restore(...)` — the regression
  guard for the cue.

### 5.4 `OtoTests/FeedbackSoundsTests.swift`

No expectation changes: `LoggingDuck` is already synchronous, which is now the
real contract. Keep the ordering test `[.ducked, .restored, .cue(.stopped),
.cue(.failed)]`; it finally describes the shipping class rather than an
idealised fake.

### 5.5 Plan record

- `plan/dictation-feedback-sounds.md` §10.5: one short note — the stop cue
  exposed the duck's 250 ms grace; restore is now immediate; the grace and its
  anti-pump claim were retired for the reasons in §3.

## 6. Verification

1. `xcodebuild -scheme Oto -destination 'platform=macOS' build`.
2. `xcodebuild test … -only-testing:OtoTests/MediaDuckTests`.
3. `xcodebuild test … -only-testing:OtoTests/FeedbackSoundsTests`.
4. Full `OtoTests` (the duck is used by coordinator tests through fakes; the
   real class is only exercised by MediaDuckTests).
5. Packaged, signed `.app`, by ear:
   - music playing, speak a phrase, release → stop tone at release, music
     resumes immediately, transcript lands clean (no bleed).
   - 5 repeats, including one where the app is slow to insert.
   - rapid tap → speak → release: tone every time.
   - toggle sounds off → no tone, media still resumes at stop.
   - Esc cancel → silence, media resumes.
6. Confirm no `restore set failed` in Console.

## 7. Risks and deferred decisions

- A follow-on session inside the old grace now lets media play briefly between
  sessions. Accepted (see §4 C); if it ever sounds wrong, the correct fix is a
  cue-aware restore (play the cue, then re-park), not a silent delay.
- Removing the park is a deliberate contract change; the plan and class docs
  must say so, or a future agent will reintroduce it.
- Unrelated to this fix: the log's `chars=0` sessions are short taps
  (`delivered=3–5` buffers, finalize ~40 ms) — too little audio to transcribe,
  not a failure path. No change proposed here.
- The stop tone still mixes with resumed media at release; that is the same
  trade as the start tone, which deliberately plays over full-volume media.

## 8. Open questions

- None blocking. Confirm the complaint is the missing/clicked release tone when
  speaking (this plan), not something else in the same log.
