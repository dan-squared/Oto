# Phase 1 — Prove one fake end-to-end session (EXECUTED + VERIFIED 2026-09-19)

Status: COMPLETE. `BuildProject` green, `RunAllTests`: 17/17 passed
(14 new `DictationCoordinatorTests` + 3 template tests), zero warnings.
Approved answers applied: fakes beside protocols, DEBUG menu items as
the fake shortcut. Deviation from plan: none in behavior; `startedAt`
uses doc-verbatim `ContinuousClock.Instant` (not `Date()`).

## 1. Goal (from `Docs/START_HERE_PRODUCT.md` Phase 1)

Prove the full coordinator-owned path with every external boundary faked:

```text
fake shortcut → coordinator → fake transcript → target capture → insertion boundary
```

Test finish, cancel, repeated stop, app switching, and insertion
failure BEFORE any real audio exists. No `AVAudioEngine`, no
`SpeechAnalyzer`, no global hotkeys, no real paste, no history, no
dictionary, no Flow Bar in this phase (those are Phases 2–6).

## 2. Spec sources (all read for this plan)

- `Docs/START_HERE_PRODUCT.md` — Phase 1 scope; `DictationState` enum;
  session-ID checks; finish/cancel idempotent + mutually exclusive.
- `Docs/OTO_REBUILD_PLAN/02_RECORDING_WORKFLOWS.md` — session timeline,
  `SessionContext`/`TargetApplication` shapes, hold-to-talk rules 1–5,
  finish/cancel code contract (§Finish and cancel rules), recovery table,
  "only the coordinator may move between states".
- `Docs/OTO_REBUILD_PLAN/08_ENGINEERING_PLAYBOOK.md` + `15_` (via prior
  analysis) — actor-owned coordinator, no lock across `await`, narrow
  protocol seams, fakes for clock/audio/speech/target/insertion.
- `Docs/OTO_REBUILD_PLAN/04_TESTING_AND_FUTURE_AGENT_HANDOFF.md` +
  `11_RELIABILITY_TEST_MATRIX.md` (via prior analysis) — coordinator
  unit matrix: single session, repeat handling, finish/cancel race-once,
  stale-final ignored, no insert/save of empty text.
- Yap reference (`/private/tmp/yap-reference`, assessed in
  `plan/yap-reference-status.md`) — seam shapes only:
  `RecordingCoordinator.swift` (protocol-injected session/injector/
  history/hud), `DictationSession.swift` (capture-first ordering,
  resolve-then-attach), `TextInjector.swift` (`captureTarget()` before
  UI, `deliver()` outcome). Oto's contract is STRICTER than Yap's
  (session IDs, `finishRequested`, richer states, no history yet) —
  where they differ, our docs win.

## 3. Facts verified (not assumed)

- Yap's `DictationSessioning` protocol (`start()`/`stop() -> String`)
  validates our seam approach: coordinator depends on protocols, fakes
  in tests. We adopt the shape, not the code.
- Yap captures the injection target BEFORE showing UI
  (`injector.captureTarget()` first line of `startRecording`) —
  confirms `02` §Session context ("capture before showing the Flow
  Bar… never substitute the current frontmost app").
- Yap checks empty-after-cleanup before inserting — confirms `02`
  `finalizing → empty text → completed(no insertion)`.
- Oto target is `Oto` (app), tests target `OtoTests` (unit). MCP has
  test tools (`RunAllTests`-family) plus `BuildProject`; verification
  stays inside Xcode like Phase 0.
- Swift default actor isolation is `MainActor` in this project; the
  coordinator will be an explicit `actor` (spec playbook), so state
  reads in tests are `await`ed. No `@Observable` on the coordinator in
  this phase (no observing UI yet).

## 4. Assumptions questioned

1. **"Include history/dictionary now because Yap does."** REJECTED.
   Yap saves history inside `stopRecording`; Oto spec puts opt-in
   history and dictionary in Phase 6. Including them now would bake
   persistence into the coordinator before the storage boundaries
   exist. Phase 1 records nothing.
2. **"Real target capture now."** REJECTED. Capturing the real
   frontmost app (`NSWorkspace`) in Phase 1 would couple tests to
   machine state. `TargetCaptureService` ships as protocol + fake;
   the fake returns a stub target AND can simulate "user switched
   apps mid-session" so tests prove the captured (not current) target
   is used. Real capture lands with insertion (Phase 4).
3. **"Yap-style `@MainActor @Observable` coordinator."** REJECTED.
   Our spec demands an actor with session-ID guards and no lock across
   `await`. Richer states (`starting/finalizing/inserting/completed/
   cancelled/failed`) replace Yap's 4-state enum.
4. **"Yap's two-step Escape cancel."** REJECTED. Our `02` hands-free
   rule: Escape always cancels. Single-step cancel.
5. **"Wire the menu-bar UI to coordinator state."** REJECTED for this
   phase. The only UI addition is two DEBUG-only menu items
   ("Simulate Hold (down/up)", "Simulate Cancel") that call into the
   coordinator — the "fake shortcut". They are marked Phase-1-only and
   die in Phase 3 when the real shortcut monitor lands. No state
   display, no Flow Bar.
6. **"Move `OtoApp.swift` into `App/` now."** ACCEPTED but minimal:
   create the spec tree dirs and place new files there; move
   `OtoApp.swift` → `Oto/App/OtoApp.swift` and views into `Oto/UI/`.
   Filesystem moves only (synchronized groups auto-update). `Item.swift`
   stays until `PreferencesStore` exists (unchanged rule).
7. **`startedAt` clock.** `Date()` is enough for Phase 1 (durations are
   not asserted). Injected-clock seam deferred to Phase 6 profiling;
   logged, not built.

## 5. Planned changes (execute only on approval)

New files (spec tree):

- `Oto/Models/DictationState.swift` — `DictationState` enum
  (`idle/starting/recording/finalizing/inserting/completed/cancelled/
  failed`), `InteractionMode` (`holdToTalk/handsFree`),
  `SessionContext` (id/startedAt/target/interaction),
  `TargetApplication` (bundleID/pid/windowID),
  `DictationFailure` (engineCapture/speechPreparation/insertion/
  targetGone/cancelledByUser), `InsertionResult`
  (`inserted/recoverableFailure(reason:)`) — all `Sendable` value types.
- `Oto/Models/Transcript.swift` — `Transcript(rawText:)` value type;
  empty check after trimming (mirrors Yap's empty-guard lesson).
- `Oto/Services/AudioCaptureService.swift` — `AudioCaptureServing`
  protocol (`start/stop/cancel`) + `FakeAudioCapture` (scriptable
  latency/failure, records calls for assertions).
- `Oto/Services/SpeechService.swift` — `SpeechServing` protocol
  (`prepare/finish/cancel`, finals only) + `FakeSpeechService`
  (scripted final text/partials/prepare-failure/never-finishing).
- `Oto/Services/TargetCaptureService.swift` — `TargetCapturing`
  protocol (`capture() -> TargetApplication`, `isAlive(_:)`) + fake
  (stub target, scriptable "target died" / "frontmost changed").
- `Oto/Services/TextInsertionService.swift` — `TextInserting`
  protocol (`insert(_:into:) -> InsertionResult`) + fake (records
  text+target, scriptable failure/secure-field).
- `Oto/Services/TranscriptPipeline.swift` — `process(_:)`:
  trim → empty-check only. Deterministic dictionary/cleanup is Phase 6;
  the seam exists so Phase 6 slots in without touching the coordinator.
- `Oto/Coordinator/DictationCoordinator.swift` — actor implementing
  the `02` finish/cancel contract verbatim: session-ID guards before
  AND after every `await`, `finishRequested` when finish arrives
  during `starting`, mutually exclusive idempotent terminal paths,
  stale results discarded, empty final → `completed` without insert,
  insertion failure → `failed` + preserved `recoveryTranscript`.
  Hold-to-talk AND hands-free intents (`begin/finishToggle/cancel`)
  on the same implementation (no second recording path).
- `OtoTests/DictationCoordinatorTests.swift` — Swift Testing suite
  (see §6).
- Moves: `Oto/OtoApp.swift` → `Oto/App/OtoApp.swift`;
  `Oto/UI/*` stays; `Oto/Item.swift` stays (unused).

Modified files:

- `Oto/UI/OtoMenuBarView.swift` — add DEBUG section with
  hold-simulate + cancel-simulate items (Phase-1-only, clearly marked).

Explicitly NOT touched: entitlements, Info.plist, Settings UI,
`SettingsWindowAccessor`, Flow Bar, any real audio/speech/shortcut API.

## 6. Verification (all through Xcode MCP)

- `BuildProject` green, zero warnings from new files.
- New `OtoTests` suite, every case deterministic (no sleeps, no
  machine state):

| # | Case | Proves |
|---|------|--------|
| 1 | hold begin → finish → inserted into captured target | happy path, target captured at start |
| 2 | finish during `starting` → completes when preparation lands | `finishRequested`, release-during-prep ≠ cancel |
| 3 | cancel during recording → no insert, state cancelled | cancel path, mutually exclusive |
| 4 | finish then cancel (and reverse) → exactly one terminal state | idempotent, race-once |
| 5 | second begin during active session → rejected/ignored | 1 gesture = ≤1 session |
| 6 | stale session ID (late final after cancel) → discarded | session-ID guards after `await` |
| 7 | empty/whitespace final → completed, inserter never called | no insert of empty |
| 8 | insertion failure → failed + `recoveryTranscript` preserved | recoverable failure, no false success |
| 9 | frontmost changes mid-session → insert still targets captured app | never paste into new frontmost |
| 10 | target dies before insert → failed + transcript preserved | target-or-recovery |
| 11 | hands-free toggle → begin, second toggle → finish+insert | same pipeline, no second implementation |
| 12 | repeated stop/cancel ×N → stable idle, no crash/leak | repeated-stop tolerance |

- Manual (user, 2 min): launch via MCP, use the two DEBUG menu
  items for one hold-simulation and one cancel; confirm no crash and
  idle return. (Fake insertion records only — nothing is pasted.)

## 7. Risks and deferred decisions

- Coordinator is an `actor`; Phase 6 UI observation will need a
  `@MainActor`-visible state bridge — deferred, not pre-built.
- `Date()` for `startedAt`; injected clock deferred to Phase 6.
- Real `TargetCaptureService`/`TextInsertionService` (Phases 3–4) must
  honor the fake-proven contract: capture-at-start, change-count
  clipboard rules, layered AX+clipboard insertion.
- Fakes live in `Oto/Services/` beside protocols (Yap-style) rather
  than test-only, so Phase 2 swaps fakes for real implementations
  without coordinator edits. If that offends, say so — alternative is
  fakes under `OtoTests/`.

## 8. Open questions for the user

1. Fakes beside protocols in `Oto/` (swappable later) vs. fakes only
   under `OtoTests/`? (Recommend: beside protocols.)
2. Confirm DEBUG menu items are acceptable as the "fake shortcut"
   (alternative: hidden key combo in the running app — more machinery
   for no benefit).
