# BT SCO bring-up flap: engine fights the link — plan (no code changed)

Status: PLANNING ONLY. Nothing implemented. Awaiting `execute`.

## 1. Goal

Stop Oto's audio engine from fighting Bluetooth SCO link bring-up, make
the class observable, and never again report "completed (empty)" when the
mic delivered zero audio. One package, three parts: debounce (the cure),
logging (the proof), fail-loud on zero audio (the honesty).

## 2. Evidence (device-proven 2026-09-21, not theory)

Session `523C250B`: begin 15:03:19.60 → prepared 15:03:19.96 → 7s of
speech → completed EMPTY. No audio error, no restart error anywhere.

Same second in the system log (`coreaudiod` BTAudioHALPlugin,
`bluetoothd` Handsfree, Jabra Elite 3):
- 15:03:19.868 `TriggerSCOAudio: IO Ongoing = No` → `Request eSCO
  creation` → `SCOStatus 0 → 1`, `HFP stream will start`, `Initiating SCO
  connection, codec 2`
- same second: `NO eSCO running while doing IO` → `Request eSCO creation`
  AGAIN → `Initiating SCO connection` AGAIN

Mechanism, end to end: our `engine.start()` at session begin kicks off a
COLD SCO voice-link bring-up; the link negotiates in bursts (mic dot
flickers with real signal gaps); every HAL reconfig along the way fires
our `handleConfigurationChange` → full teardown+rebuild with total
silence between → we amplify the flap; the transcriber gets fragments →
empty finals. Warm link (later attempts) works — exactly the user's
"third time it comes."

## 3. Spec sources / SDK facts

- `AppleAudioCapture.swift` (restart/teardown/config observer — read
  2026-09-21); `AudioBufferRelay.swift`; `AudioFeedBox`
  (`AppleSpeechService.swift`); coordinator finalize path.
- `AVAudioEngineConfigurationChange` notification semantics (existing
  observer design); macOS 27 SDK headers already verified for the audio
  path (S5 record §10).
- System-log timestamps above (coreaudiod pid 753, bluetoothd 595).

## 4. Assumptions questioned

- "Rebuild immediately on every change" — wrong for BT: during SCO
  bring-up, changes arrive as a flurry; each rebuild costs a silence
  gap and can re-trigger negotiation. Coalesce instead.
- "Debounce delays genuine healing" — accepted tradeoff, stated: a real
  device removal mid-session heals up to one window late (tap stays on
  the dead device meanwhile). Starting window 1.5s, tuned by matrix.
- "Log everything" — no: three low-volume lines (rebuild w/ format,
  converter-failure count, relay drops at finish). Rebuilds should be
  rare; if they're frequent, that's itself the signal.
- "Zero-audio → fail" changes product behavior (empty completion today)
  — explicit user decision required (Q3).

## 5. Exact file changes (on execute)

1. `Oto/Services/AppleAudioCapture.swift`
   - New `RebuildDebouncer` (small Sendable struct, unit-tested):
     `shouldRebuild(now:lastRebuild:pending:)`. `handleConfigurationChange`
     collapses flurries: cancel pending work, schedule ONE restart after
     1.5s quiet; immediate restart only if > window since last rebuild.
   - `stop()`/`teardown()` cancel pending rebuilds (no restart after stop).
   - `log.info` per rebuild with input format (rate/channels) + outcome;
     failure keeps the existing error line.
2. `Oto/Services/AppleSpeechService.swift` (`AudioFeedBox`)
   - Count converter failures (currently swallowed); expose count;
     `finish()` logs it. Silence becomes a number.
3. `Oto/Support/AudioBufferRelay.swift`
   - Count buffers delivered to the sink per attach window; `finish()`
     logs drops AND delivered (both numbers, every session — cheap).
4. Zero-audio fail-loud (needs Q3 yes):
   - `SpeechSessionError.noAudioCaptured`; `finish()` throws it when
     delivered == 0; coordinator maps to new `DictationFailure.noAudio`
     ("No audio reached the microphone — check your mic. Nothing was
     inserted."); menu copy via existing `lastSessionSummary` (add
     branch + status-copy test).
   - Tests: fake relay with zero delivery → throws; coordinator shows
     `.failed(_, .noAudio)` + recovery empty (nothing to keep — assert
     recoveryTranscript nil and clipboard untouched).
5. Unit tests: debouncer matrix (flurry→1 rebuild, spaced→2, stop
   cancels); converter-switch test exists (F1) — extend with failure
   counting; insertion tests untouched.

## 6. Verification

- `xcodebuild build` + `test` green (Swift 6 clean-build inventory).
- Device matrix (Jabra, COLD link — disconnect, reconnect, dictate
  immediately = the exact repro): indicator flicker ≤ window then
  stable; transcript complete on FIRST attempt; stream shows ≤1 rebuild
  with format line. Warm link + built-in mic regression unchanged.
  Genuine mid-session removal: heals ≤ window + error line present.
- Grep: `AVAudioEngineConfigurationChange` observers == 1 (no second
  path); no `Task.sleep` in restart path (debounce uses cancellable
  work, not blind sleep).

## 7. Risks / deferred

- 1.5s is a starting value from one trace, not a constant — matrix tunes.
- If BT bring-up flaps longer than the window repeatedly, residual gaps
  remain; the rebuild log line makes that visible instead of silent.
- installTap S5 migration stays deferred (§10) — unrelated path.
- No push until device sign-off (standing rule).

## 8. Open questions

1. Execute all three (recommended: debounce + logging + fail-loud)?
2. Or cure-only first (debounce + logging), fail-loud after device proof?
3. Confirm: zero-audio sessions must FAIL (recommended) vs keep
   completing empty?
