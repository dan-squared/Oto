# Silent sessions skip the loader — plan

## Goal

When no voice was captured, the pill melts straight out of bars on
release — the dotsSpinner "working" loader never appears. Sessions with
any voice are untouched (full finalizing → inserting → vanish path).

## My product take (asked)

**Yes, good decision.** The loader promises "working on your words" —
with no words it is noise, and the most common silent sessions are
accidental triggers, exactly where UI restraint pays off. Two caveats,
both handled below: (1) the skip must trigger only on *true* silence —
quiet speech must never silently die, so the threshold is conservative
*and* duration-guarded; (2) only true silence can skip. "Transcribed but
pipeline-empty" stays on the loader path because its emptiness is
knowable only after transcription runs.

**Difficulty: medium, not hard.** Bounded to three services-layer files
plus fakes/tests — zero view changes (the pill never hears about it:
projection goes recording → hidden, the existing vanish path melts the
bars out). No SDK research needed; the only real risk is threshold
tuning, which is a device test, not code.

## Spec sources

- User request (this session).
- `Docs/START_HERE_PRODUCT.md` canonical on conflict.
- Current code: `finalizeSession` (`DictationCoordinator.swift:281`),
  tap 4096 (`AppleAudioCapture.swift:151`), relay
  (`AudioBufferRelay.swift`), `PillVisual.forState`
  (`PillLayers.swift:34` — finalizing/inserting → dotsSpinner),
  projection completed/cancelled/failed → hidden
  (`FlowBarState.swift:95-119`), `FakeAudioCapture`
  (`AudioCaptureService.swift:19`).

## Facts verified in the repo (never from memory)

- **The loader-on-silence is structural:** release → `.finalizing`
  → pill shows dotsSpinner (`PillVisual.forState`) → `speech.finish()`
  runs over the whole buffer (takes noticeable time even silent) →
  empty result → `.completed` (silent vanish) or
  `.failed(.noAudioCaptured)` (menu status). Voicelessness is knowable
  only *after* `finish()` returns — so skipping the loader requires a
  capture-time voice signal, not a transcription-time one.
- **The signal has a clean home:** every tap buffer already flows
  through the relay (`handler?(buffer)` → relay, `installTap` realtime
  thread never touches actor state — `AppleAudioCapture.swift:133-153`).
  A lock-guarded session peak in the relay follows the
  `SpectrumFeedBox` precedent (lock-shaped, @unchecked Sendable) and
  keeps view-layer levels out of session fate (the FlowBarModel-signal
  alternative is rejected below).
- **Empty-after-pipeline stays:** `guard !clean.isEmpty`
  (`DictationCoordinator.swift:309`) can only run after transcription —
  that path keeps the loader by necessity. Only the true-silence gate
  below skips.
- **Cancel/finish idempotence is unaffected:** the gate sits inside
  `finalizeSession` after the existing identity re-checks; cancel still
  wins everywhere upstream.

## Assumptions questioned

- "Read voice presence from FlowBarModel.sample" — rejected: inverts
  the architecture (view-layer signal driving session fate) and the
  model smooths/couples/floor-lifts levels, so it can't answer "was
  there voice" cleanly. Capture-time peak in the relay is raw truth.
- "Skip transcription whenever peak is low" — rejected without guards:
  a 150 ms "yes" may have no buffer processed yet, and whispers live
  near the noise floor. Gate = peak below threshold AND recording
  longer than 500 ms. Short sessions always take the full path.
- "Threshold from memory" — rejected: starting point peak < 0.01
  (−40 dBFS; speech peaks ~0.1–0.5, mic idle noise ~0.001–0.003),
  confirmed or adjusted once against the built-in mic + BT on device.
  Tests pin whatever ships.
- No new surfaces: the skip lands on `.completed` (silent vanish, same
  as pipeline-empty today). No toast, no menu row, no pill message
  (v7 surfaces contract stands).

## Exact file changes

1. `AudioBufferRelay.swift` (or the relay owner — confirm file layout
   at implementation): `sessionPeak: Float` (lock-guarded, reset on
   arm/start) updated per received buffer with the buffer's peak
   absolute sample (stride-4 scan keeps it ~free at 4096 frames);
   `takeSessionPeak()` read-once accessor. Realtime thread touches
   only the lock + Float (SpectrumFeedBox precedent).
2. `AudioCaptureService.swift`: protocol gains
   `sessionPeakAmplitude() async -> Float`; `FakeAudioCapture` gains a
   scriptable `stubPeak: Float` (default loud, so every existing test
   keeps the full path; silent tests set ~0).
3. `DictationCoordinator.swift` (`finalizeSession`, after
   `audio.stop()` + identity re-check, before `speech.finish()`):
   if `recordingDuration > 500 ms && peak < 0.01` → skip transcription
   entirely → `currentSessionID = nil; state = .completed(context)`
   (log "completed (silent, loader skipped)"). Everything else —
   cancel-wins, noAudioCaptured catch, empty-final, history, target
   checks — untouched and still reachable (short/quiet sessions,
   device died mid-session, pipeline-empty).
   Duration source: `context` start timestamp (confirm field exists;
   else record `recordingBeganAt` on the recording transition —
   one stored Date, no behavior change).
4. Tests: fake-silent long session → `.completed`, `speech.finish`
   never called (new); fake-silent short session → full path, loader
   states still visited (new); fake-loud → unchanged (existing suite
   covers); threshold + duration constants pinned; relay peak unit
   tests (silence → ~0, tone → >threshold, reset on arm).

## Verification steps

- `xcodebuild -scheme Oto -destination 'platform=macOS' build` clean
  + full suite green (new pins incl.).
- Grep gates: no view/panel/model edits (this change is
  services + coordinator only); no new force unwraps; no NSEvent
  monitors.
- Packaged signed `.app` only: hold 2 s in silence → release → bars
  melt out, zero loader frames; hold + "yes" → full loader path;
  whisper test → full path (never silently completed); BT mic repeat
  of the silence case (threshold re-check).
- Threshold confirmation on device (built-in + BT if handy); one
  retune pass max before pinning.

## Risks / deferred

- Threshold too hot → quiet speech silently completes with no
  insertion and no error. Mitigations: conservative 0.01 start,
  500 ms duration guard, device matrix incl. whisper + BT before
  sign-off. If in doubt, ship 0.005.
- `speech.finish()` never running for silent sessions means the
  `.noAudioCaptured` failure path goes quiet in practice — intended
  (nothing to report, nothing lost); the catch stays for real device
  failures.
- Pipeline-empty (transcribed-then-empty) keeps the loader —
  documented limitation, not a second workstream.

## Open questions

1. Threshold 0.01 + 500 ms guard as the starting point — good, or do
   you want it even more conservative (0.005) for the first build?
2. Silent-skip lands on `.completed` (indistinguishable from
   pipeline-empty in history/menu). Fine, or should the log/status
   reason name it (it already will in Console; menu `lastSessionSummary`
   could stay as-is)?
