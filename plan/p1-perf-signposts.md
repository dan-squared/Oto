# P1 — Perf signposts on the dictation hot path (hardened plan, v2)

Status: **implemented 2026-10-15 — build green, 526 unit tests pass (56 suites, incl. 6 new PerfTraceTests).**
Second-pass review of the half implementation: signpost placement + early-exit
pairing were correct; the isolation break (Fix-0), missing summary/ms capture
(Fix-1), missing polish span (Fix-2), and missing tests (Fix-3) are now done.
Pre-existing `SettingsUITests.testSettingsOpensAsOneNativeWindow` UI failure is
unrelated (Settings catcher-toggle assertion; P1 touches zero UI files).

## Goal

Answer with real numbers where the milliseconds go between pressing the hold key
and text landing in the target app. Prerequisite demanded by the codebase:
`Docs/OTO_REBUILD_PLAN/07_APPLE_SPEECH_IMPLEMENTATION_PLAN.md:89` —
"Measure the real post-setup start latency before introducing any warm-session
optimization". Unsatisfiable today because the partial landing doesn't compile,
and even fixed it lacks the summary line, the polish first-token span, and tests.

## Spec sources

- `Docs/START_HERE_PRODUCT.md`: coordinator owns state; views never start
  audio/insert; finish/cancel idempotent + mutually exclusive; identity re-check
  after every await; Apple Speech only; target captured at start.
- `Docs/OTO_REBUILD_PLAN/07_APPLE_SPEECH_IMPLEMENTATION_PLAN.md:87-89`
  (short-lived analyzer default; measure-before-warm rule), `:603`
  (sleep/wake invalidates any prepared session — P2 must honor).
- `Docs/OTO_REBUILD_PLAN/11_RELIABILITY_TEST_MATRIX.md` (device matrix for later).
- `plan/perf-latency-audit.md` (F1–F5, proposals P1–P5; P1 = instrument first).

## Facts verified against the local SDK (never from memory)

Checked 2026-10-15 on this Mac:

- SDK: `xcrun --sdk macosx --show-sdk-path` →
  `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk`.
  Xcode `27.0 (27A266a)`. Deployment target 27.0 per AGENTS.md.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` in `Oto.xcodeproj/project.pbxproj`
  (both configs). **Every unmarked type/member is MainActor-isolated.** This is
  the cause of the build break — not a source typo.
- Speech API (`.../Speech.framework/Modules/Speech.swiftmodule/arm64e-apple-macos.swiftinterface`):
  - `final public actor SpeechAnalyzer : Sendable` with `prepareToAnalyze(in:)`,
    `start(inputSequence:)`, `finalizeAndFinishThroughEndOfInput()`,
    `cancelAndFinishNow()`, `setModules(_:)`,
    `bestAvailableAudioFormat(compatibleWith:)` (+ `considering:` overload).
  - `SpeechTranscriber.supportedLocales` / `installedLocales` are
    `static var ... { get async }` — suspension points on the press path. Confirmed.
  - `AssetInventory.status(forModules:) async` confirmed.
  - Nothing documents re-`start()` after finalize/cancel or `results`
    re-iteration → P2 probe still required (recorded in P2 plan, not here).
- `os/signpost.h` exists in the SDK; `import os` already compiles in this
  target (`PerfTrace.swift` fails on isolation, not on missing symbols — i.e.
  `OSLog`/`OSSignpostID`/`os_signpost` resolve). P1 fix keeps `import os`.
- Current partial landing (verified by grep 2026-10-15):
  - `Oto/Support/PerfTrace.swift` (untracked) exists: 8 phases, `begin/end/ms`.
  - `AppleSpeechService.prepare/finish` has `localeResolve/assetProbe/engineWarm/finalizeAwait` signposts.
  - `DictationCoordinator` has `pressToReady` begin (in `begin()`), `closePressToReady()`,
    `finalizeAwait/cleanupRace/insert` begins/ends, plus `PERF pressToReady=` and `PERF insert=` log lines.
  - **Missing**: summary line, `cleanupFirstToken` span in `WritingPolishService`,
    any `PerfTraceTests`, `nonisolated` markings (the break).
  - `git status`: `M DictationCoordinator.swift`, `M AppleSpeechService.swift`,
    `?? Oto/Support/PerfTrace.swift` (+ unrelated onboarding edits — do not touch).

## Assumptions questioned

1. "Signposts are free" — true only when not captured; `begin/end` still cost an
   `OSSignpostID` + branch. Kept off the audio thread (we never touch `feed()`),
   so accepted. Assumption recorded, not hand-waved.
2. "Hand-rolled ms logs are enough" — rejected for aggregation (Instruments does
   percentiles); kept for at-a-glance Console reads. Both surfaces stay.
3. "Coordinator can time what the service does" — yes, but only wall-clock spans
   it already awaits. No plumbing of IDs across actors (rejected: signature churn
   for zero gain). Service times its internals; coordinator times its awaits.
4. "`ms()` rounding" — truncation (never round-up): a 1.9ms span reads "1ms",
   signpost carries exact duration. Pinned by test.

## Exact file changes (P1 completion — the ONLY files touched)

### Fix-0 (build break — must land first): `Oto/Support/PerfTrace.swift`

Root cause: enum inherits `MainActor` isolation; call sites live on
`actor AppleSpeechService` and `actor DictationCoordinator`. Fix: opt the whole
measurement layer out:

```swift
enum PerfTrace: Sendable {
    nonisolated static let log = OSLog(subsystem: "app.Oto", category: "perf")
    enum Phase: String, CaseIterable, Sendable { ... } // unchanged 8 cases
    nonisolated static func begin(_ phase: Phase) -> OSSignpostID { ... } // body unchanged
    nonisolated static func end(_ phase: Phase, _ id: OSSignpostID) { ... }
    nonisolated static func ms(_ elapsed: Duration) -> Int { ... } // body unchanged
}
```

Why this shape (not `nonisolated(unsafe)` statics, not per-site `await MainActor`):
follows the codebase precedent (`SpeechLocaleMatching.bestMatch` is
`nonisolated static`; `InsertionTimings` statics are `nonisolated static`).
No hop onto the MainActor from the realtime-adjacent speech actor, ever.
`OSSignpostID` is a value handle — safe to pass across actors as a `let`.

### Fix-1: coordinator summary + ms capture — `Oto/Coordinator/DictationCoordinator.swift`

Today only `pressToReady` and `insert` log ms; `finalizeAwait`/`cleanupRace`
open/close signposts with no numbers, and no single grep-able summary exists.
Add (all private state next to `pressToReadyID`, observation-only):

- `pressToReadyMs: Int?` set in `closePressToReady()`.
- `finalizeMs / cleanupMs / insertMs: Int?` — capture with
  `ContinuousClock().now` around the three existing awaits in `finalizeSession`
  (the `insertBeganAt` pattern already there is the template; replicate, don't
  redesign).
- One summary at the terminal insert path (after `restoreMedia`, before the
  `switch result`): `log.info("PERF pressToReady=\(x)ms finalize=\(y)ms cleanup=\(z)ms insert=\(w)ms")`.
- Silent-skip and empty-final terminal paths log a short summary too
  (`PERF pressToReady=… outcome=silent-skip|empty`), so every session ends with
  exactly one summary line even when later spans never run. Cancel path:
  `closePressToReady()` already runs; no summary (no session) — deliberate.
- Rule: nothing branches on these values. Grep gate: no `if.*Ms` in ship code.

### Fix-2: polish first-token span — `Oto/Services/WritingPolishService.swift`

`LivePolishService.streamCleanup`: add lock-guarded `streamStartAt/firstTokenAt`
(`Date`, alongside existing `lock`/`runStats`), stamp start on first call,
first-token on first non-empty chunk; on stream end emit
`PerfTrace.begin/end(.cleanupFirstToken)` around nothing (zero-duration marker
pair is wrong — instead: begin at stream start, end at first token) and keep
the existing `log.debug firstTokenMs/totalMs` line (already there). No signature
changes; `FakePolishService` untouched (fakes carry no timings — documented).

### Fix-3: tests — new `OtoTests/PerfTraceTests.swift` (Swift Testing, repo style)

- All `Phase.allCases` raw values distinct (Instruments filter contract).
- `ms()` contract: 0ms, 1ms boundary, 1500ms, truncation-not-rounding.
- Comment (not a fake test): signpost emission itself is not headless-testable.
- No TCC/hardware touches (pure tests only, like `SpeechLocaleMatchingTests`).

## Verification

1. `xcodebuild -scheme Oto -destination 'platform=macOS' build` — green
   (today: red; Fix-0 is the gate).
2. `xcodebuild test -scheme Oto -destination 'platform=macOS'` — full suite
   green (~50 files + 1 new). Existing `EscapeCancelTests`, stuck-states tests,
   `SpeechReadinessMappingTests`, `SpeechLocaleMatchingTests` unchanged.
3. Grep gates: `os_signpost` only in `PerfTrace.swift`; no ship-path branch on
   any `*Ms` value; `downloadAndInstall` still only in `SpeechAssetPreparer`.
4. Manual, packaged signed `.app` only (TCC/shortcuts invalid from raw
   executable): one hold-to-talk dictation in TextEdit → Console.app filter
   `subsystem:app.Oto category:perf` shows 7 intervals + one `PERF …` summary;
   one Esc-cancel → `pressToReady` closed, no summary, no hang.
5. Instruments: `os_signpost` "Dictation" intervals visible with phase names.

## Risks / deferred decisions

- Risk: wrong interval boundary (e.g. ending `pressToReady` before `.recording`
  renders). Mitigation: boundaries pinned to state transitions, not UI frames —
  `closePressToReady()` runs at preparation-complete AND on all three
  preparation-failure paths (mic deny, audio failure, prepare throw); idempotent
  by nil-ing the handle.
- Risk: `OSSignpostID(log:)` misuse across actors. Mitigation: IDs are created
  and closed on the same actor within one span; never stored beyond the span
  except `pressToReadyID` (explicitly lifecycle-managed).
- Deferred: NO UI surfacing (menu/Settings debug row) — Console/Instruments is
  the tool. Separate decision.
- Deferred: in-product percentiles/ring buffer — Instruments already aggregates.
- Deferred: everything touching insertion timings (device-matrix data only).

## Open questions

- None blocking. `PERF` line format is grep-able and free to evolve.
- Session-spacing + press→ready percentiles (the P2/P3 tuning inputs) can only
  be answered after this ships and runs on the matrix.
