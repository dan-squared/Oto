# installTap NSException crash on device flap — plan (no code changed)

Status: PLANNING ONLY. Nothing implemented. Awaiting `execute`.

## 1. What died, exactly

`*** Terminating app due to uncaught exception
'com.apple.coreaudio.avfaudio', reason: 'Failed to create tap due to
format mismatch, <AVAudioFormat ...: 2 ch, 44100 Hz, Float32>'`

Backtrace (device, PID 19574, 15:46:24.8): `installTapOnBus:...error:block:`
(frame 4) ← our `installTap()` (5) ← `restart()` (6) ←
`rebuildForDeviceChange()` (7, the new debounce path) ←
`handleConfigurationChange()` (8-9) ← pending-rebuild Task (10-11).
Trigger: Bluetooth turned off mid-dictation; our scheduled rebuild fired
while the HAL was mid-flap.

## 2. Why nothing caught it

- The format we read (Jabra-era) no longer matches the live node
  (fallback device mid-flap). Our degenerate guard (`> 0`) passes —
  44.1k/2ch is valid, just STALE. TOCTOU between read and install.
- `installTap` raises NSException on mismatch — INCLUDING the `error:`
  variant (frame 4 proves it). Swift cannot catch NSException, so no
  do/catch in our code could ever hold it. Correction to §10: the S5
  throwing variant is backed by the same raiser — migration alone does
  NOT fix this class.
- Debounce did not cause it (the old immediate path has the identical
  race), but the delayed firing met the flap at its worst moment.

## 3. Fix (Swift-only, no project surgery) — REVISED on evidence

First instinct (double-read stability gate) was WRONG for this crash:
with BT-off flap steps seconds apart, two reads 20ms apart almost
always AGREE (both stale) — the gate would have passed and crashed
identically. The crash frame refines it: the raise is a MISMATCH
between OUR stale format and the live node. Remove our format from the
call — `installTap(..., format: nil)` uses the node's live format, and
with no caller-supplied format the mismatch class vanishes. Behavior
when stable is identical (nil == the hardware format we were
re-reading); the downstream converter already adapts arbitrary input.

Exact changes:
1. `AppleAudioCapture.installTap()`: pass `nil` format; keep a
   degenerate guard via `tapFormatUsable(_:)` (pure predicate:
   rate > 0, channels > 0) — a formatless node throws `EngineError`
   (catchable) before touching `installTap`.
2. Unit test: `tapFormatUsable` matrix (0Hz/0ch → false, valid → true).
   The HAL interaction itself is device-proven (BT-off killer test);
   stated plainly, not disguised.
3. Keep the debounce as-is (proven working: the rebuild lines in the
   log are exactly the new instrumentation earning its keep).

## 4. Verification

- Build + test green (Swift 6 clean inventory).
- Device matrix: BT off mid-dictation (the exact killer) → session
  fails clean with audio-capture message, APP STAYS ALIVE; cold-link
  and built-in regressions unchanged. Stream must show either a
  rebuild line or a clean failure — never silence, never termination.
- No push until sign-off (standing rule).

## 5. Deferred full closure (stated, not hidden)

A TOCTOU race can only be CLOSED by catching NSException, which needs a
tiny ObjC `@try/@catch` helper + bridging header (Swift cannot do it).
Recommend as follow-up hardening IF the stability gate ever proves
insufficient in the field — the gate reduces the window ~1000x at zero
project-surgery cost; the helper eliminates it at moderate setup cost.
Say the word and it becomes its own plan.
