# Performance, resource, and model-latency audit

Status: **proposed — awaiting execute approval.** No code changed.
Method: source audit of the hot path via Xcode ACP (workspace open, scheme Oto,
destination My Mac) + clean baseline build (9.32s, 0 errors, 2026-10-13).
Apple-doc rule (AGENTS.md): all API claims below verified against the local
`MacOSX27.0.sdk` usage in the source, not memory.

## What was audited

Press-to-insert path, end to end:

```
HID key-down → DictationCoordinator.begin → audio.start (fresh AVAudioEngine)
→ speech.prepare (per-session SpeechTranscriber+SpeechAnalyzer)
→ [speaking] relay → AudioFeedBox → SpeechAnalyzer stream
→ finish: shouldSkipTranscription → speech.finish → pipeline
→ Auto Cleanup race (≤3s, prewarmed) → history? → isAlive
→ inserter.insert (clipboard + 4-event Cmd-V + restore) → success
```

Plus: AudioSpectrumAnalyzer (visualizer), FlowBarPanel (CALayer vsync loop),
LivePolishService (warm LanguageModelSession), AudioBufferRelay (bounded queue).

## Findings (verified, with locations)

### F1 — There is no measurement. Nothing is instrumented.
`AppleSpeechService.swift` has no `os_signpost`/signpost usage anywhere; neither
does the coordinator or insertion service. The codebase's own rule
(`07_APPLE_SPEECH_IMPLEMENTATION_PLAN.md` §89: "Measure the real post-setup
start latency before introducing any warm-session optimization") cannot be
followed today because no data exists. Any constant-tuning without this is a
guess, which the plan docs forbid.

### F2 — `speech.prepare()` runs the full construction sequence every session
`AppleSpeechService.swift:139-203`. Per key press:
1. `SpeechTranscriber.supportedLocales` (async system query)
2. `SpeechTranscriber.installedLocales` (async system query)
3. `AssetInventory.status(forModules:)` (async probe)
4. new `SpeechAnalyzer`, `bestAvailableAudioFormat`, `prepareToAnalyze(in:)`
5. `analyzer.start(inputSequence:)` — the actual engine warm-up

Steps 1–3 are state reads that change at human speed (OS updates, Settings
language change), not per-dictation speed. Step 4–5 is the genuinely expensive
part. The Yap-proven shape keeps a *bounded* warm analyzer; `07` plan §3.2
explicitly deferred that "pending measurement" — F1 is why.

### F3 — Insertion path is already well-tuned; little to win
`InsertionTimings` (RealTextInsertion.swift:55-74): prePaste 30ms,
verify-poll 5ms/300ms budget (fails closed, not ahead of the write), restore
100ms (async-reader window), reactivateSettle 120ms (paid only when target is
*not* active — line 109 skips it if already frontmost), keyStep 10ms × 4.
The write-verify is a poll, but succeeds on the first poll in the common case.
Recommend: measure, don't touch.

### F4 — Auto Cleanup is correctly shaped (prewarm during speech)
`DictationCoordinator.swift:304` calls `prewarmForSession()` at begin;
`LivePolishService.prewarm(job:)` builds one `LanguageModelSession` and calls
`session.prewarm()` while the user speaks. Race bounded to 3s
(`autoCleanupTimeout`), miss inserts raw invisibly. Token cap scales with input
size (`options(for:)`, temperature 0.2). This is the right architecture already.

### F5 — Resource usage is already minimal by construction
- No speech model is ever loaded into Oto's process — Apple owns asset
  lifetime; only a short-lived analyzer exists mid-session.
- `AudioBufferRelay` is bounded (125 buffers ≈ 2MB worst case).
- Silent sessions skip the loader entirely (`shouldSkipTranscription`).
- Visualizer: vDSP FFT on the actor pool, ~60Hz publish, CALayer transform loop
  with implicit actions disabled (`FlowBarPanel.setLiveValues`/`pushLiveValues`)
  — no per-frame SwiftUI re-render. Already the right pattern.
- One warm `LanguageModelSession` is held indefinitely across uses
  (`LivePolishService.warmSession`, single-slot, job-tagged) — the only
  unbounded-by-time retention found.

## Proposals (ranked by expected impact / risk)

### P1 (biggest win) — Instrument first, no behavior change
Add `os_signpost` intervals at:
1. `begin` → `.recording` (press-to-ready)
2. inside `prepare()`: step 2/3 (locale reads) vs step 4–5 (engine build)
3. `recording` → `speech.finish()` return (finalization)
4. `finishReturn` → insert success (insertion)
5. `streamCleanup` first token (model latency) and run total
Expose in a debug-only Diagnostics readout (there is already a Diagnostics
support file). Zero product risk; unblocks P2–P5 with real numbers.

### P2 — Warm-analyzer reuse (start latency)
Keep exactly one *prepared* analyzer after a session ends; reuse it on the next
`begin()`, revalidated cheaply (same resolved locale + `installedLocales` still
contains it). Invalidate on: idle timeout (measure; start ~60s), memory-pressure
notification, locale change, and any error path. Constraints from the codebase
that must survive: single active session, teardown serialized behind the
existing `teardownTask` chain, finish/cancel idempotent. If revalidation fails,
fall back to today's full prepare. 07 §3.2's condition ("measure first") is met
by P1.

### P3 — Cached locale resolution
Resolve locale against a snapshot refreshed at launch and on
`NSCurrentLocaleDidChange`/Settings-change notifications instead of awaiting
`supportedLocales` + `installedLocales` per session (two async system queries
removed from the press path; the probe stays as the cheap correctness check).

### P4 — Idle-release the warm polish session
Release `warmSession` after ~5 minutes idle (or on memory pressure) instead of
holding it for the app's lifetime. One system-shared model session per app is
cheap but not free; the next cleanup pays one session build (~ms) instead.

### P5 — Adaptive cleanup budget (model latency, long entries)
Today any length pays full generation within the 3s race. For long entries
(>~200 words) consider visibly skipping cleanup and inserting raw (documented in
Settings), or chunking. Only after P1 shows real first-token/latency
distributions by length.

### Explicitly NOT proposed
- Any change to insertion timings (F3 — device-matrix data only).
- Reusing a single `AVAudioEngine` across sessions (documented
  format-mismatch crash class in AppleAudioCapture.swift:10-26 — correctness
  wins over a sub-ms allocation).
- Bundling/downloading any model, or any PCC path (locked boundary).

## Verification

1. P1 ships alone first; capture press→ready, finalization, insertion, and
   cleanup-latency percentiles across the device matrix (plan 11) — including
   Bluetooth SCO bring-up per plan/bt-sco-flap.md.
2. P2 measured as the delta in press→ready with the same matrix; fail path
   exercised (stale asset, locale change, cancel mid-prepare).
3. P4 verified with memory sampling at idle before/after release.
4. Full suite: `xcodebuild test -scheme Oto -destination 'platform=macOS'`;
   TCC/shortcut validation stays in the packaged, signed app only.

## Open questions

- Warm-analyzer idle expiry: 60s vs 5 min — decide from P1 data on session
  spacing.
- Should the Diagnostics readout be always-available (release) or debug-only?
