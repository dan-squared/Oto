# P2 — Warm-analyzer reuse (hardened plan, v2)

Status: **probe harness landed 2026-10-15 — build green, 543 unit tests pass (58 suites, incl. 9 new WarmAnalyzerPolicyTests). Warm slot NOT built: blocked on hardware probe results below.**
Landed headless-executable parts (all inert, zero behavior change):
- `Oto/Support/WarmAnalyzerPolicy.swift` (permanent): pure `decide()` +
  `WarmAnalyzerExperiment` flag (default false). No call sites yet.
- Probe harness in `Oto/Services/AppleSpeechService.swift` (TEMPORARY, all lines
  marked PROBE-START/END, flag `app.Oto.probeAnalyzerReuse` default false):
  success-path seeding in `finish()`, single reuse attempt in `prepare()`
  (re-`start()` + results re-iteration, fallback to slow path on any throw),
  slot clearing in `cancel()`. DELETE after hardware reports.
- Isolation note: synthesized `Equatable` inherits MainActor isolation, so all
  four P2 types carry explicit `nonisolated ==` (`PolishAvailability` precedent).
- Harness v2 (2026-10-15): the kept TRANSCRIBER is never reused — its `results`
  stream already served a full iteration and may be single-use (first hardware
  run showed the second dictation landing empty, consistent with a dead
  re-iteration). Each attempt builds a FRESH transcriber + `setModules` before
  `start`; every throw still falls back to the slow path, so text lands in all
  outcomes but a dead results pipeline (which is itself the verdict).
This is the deferred item from `07_APPLE_SPEECH_IMPLEMENTATION_PLAN.md:89`
("add only a bounded `prepared` state that has no open microphone tap and
expires on idle, memory pressure, sleep, or an error"). The conditions in that
sentence are implemented literally below — every one has a code line.

## Goal

Remove the per-session `prepare()` engine-build cost from between the key press
and `.recording`, without weakening the single-session, teardown-serialized
discipline the stuck-states workstream built. Expected effect (P1 confirms):
~50–200ms off every press; the pill's "starting" beat all but disappears.

## Spec sources

- `Docs/START_HERE_PRODUCT.md` (coordinator owns state; finish/cancel
  idempotent + mutually exclusive; identity re-check after every await; audio
  callbacks do no UI work; queues bounded; target captured at start).
- `07_APPLE_SPEECH_IMPLEMENTATION_PLAN.md:87-89` (short-lived default +
  measure-first), `:572` (capture→prepared), `:603` table row (sleep/wake:
  "invalidate any prepared session, require a new press").
- `plan/perf-latency-audit.md` F2/F5 (analyzer build is the expensive part;
  only unbounded-by-time retention found is the polish warm session — this plan
  does NOT extend that pattern blindly; idle expiry is mandatory).
- Phase-11 stuck-states + `EscapeCancelTests` (canaries — must pass unchanged).

## Facts verified against the local SDK / source (never from memory)

Checked 2026-10-15 on this Mac (SDK `MacOSX27.0.sdk`, Xcode 27.0):

- `SpeechAnalyzer` is `final public actor : Sendable` with
  `prepareToAnalyze(in:)`, `start(inputSequence:)`,
  `finalizeAndFinishThroughEndOfInput()`, `cancelAndFinishNow()`,
  `setModules(_:)`, `bestAvailableAudioFormat(compatibleWith:)` (swiftinterface
  verified). **The interface does NOT document whether `start()` may be called
  again after finalize/cancel, nor whether `transcriber.results` supports
  re-iteration.** Nothing in headers answers it → hardware probe is mandatory,
  not optional. (Same unknown as the v1 plan — re-verified, still unknown.)
- `AppleSpeechService` today: per-session `transcriber + analyzer + resultTask +
  finalizedText`; `teardown()` nils all three + `relay.reset()` + clears
  `finalizedText` (`AppleSpeechService.swift:281-286`). `AudioFeedBox.createStream()`
  is already per-session; `relay.attach` replaces the sink; coordinator's
  `teardownTask` chain (`DictationCoordinator.swift:50-57`) serializes teardown
  vs next-session prepare. The warm slot must respect ALL of this.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — the warm slot lives INSIDE
  `actor AppleSpeechService` (already off-MainActor), new policy type is a
  `nonisolated` pure struct like `SpeechLocaleMatching`. No new isolation hops.
- `AudioBufferRelay` bounded (125 buffers ≈ 2MB); silent-skip and drop-counter
  semantics must survive reuse (feedBox per-session stream is recreated either way).
- No warm-slot, policy, experiment flag, or memory-pressure observer exists
  today (grep zero hits). Greenfield behind a default-false flag.

## Assumptions questioned

1. "Reuse the whole analyzer+transcriber" — the cheapest assumption, and the
   one most likely to be wrong (undocumented `results` re-iteration). The probe
   has three outcomes (not two): full reuse / analyzer-only + fresh transcriber
   via `setModules` / STOP. The design below implements outcome 1, with the
   outcome-2 fallback sketched so the probe result slots in without redesign.
2. "Warm is always faster" — false if `setModules` on a warm analyzer costs as
   much as a fresh build. The probe measures the fallback path too.
3. "60s idle expiry" — a starting value. P1's session-spacing data sets the
   final number before default-on is even considered. The timer is one
   replaceable `Task.sleep`, never accumulated.
4. "Memory pressure never happens" — it does (menu-bar resident 24/7). The
   `DispatchSource.makeMemoryPressureSource` observer (old stable API;
   implementer verifies the exact factory name against the SDK at build time)
   is a ship requirement, not polish.

## Exact design (what the implementer builds — no more, no less)

### 1. Pure policy (new): `Oto/Support/WarmAnalyzerPolicy.swift` (~60 lines, unit-tested)

```swift
struct WarmStateInput: Sendable, Equatable {
    var lastUse: ContinuousClock.Instant
    var now: ContinuousClock.Instant
    var sameLocale: Bool          // from P3's resolved locale, never recomputed here
    var memoryPressureSinceLastUse: Bool
    var lastOutcome: Outcome      // .completed | .failed | .cancelled
}
enum WarmDecision: Equatable { case reuse, rebuild }
enum WarmAnalyzerPolicy {
    nonisolated static let warmIdleLimit: Duration = .seconds(60) // P1 data tunes
    nonisolated static func decide(_ input: WarmStateInput) -> WarmDecision
}
```

Conservative rules (every doubt → `rebuild` = today's behavior):
`reuse` ONLY IF lastOutcome == .completed AND sameLocale AND age < warmIdleLimit
AND no memory pressure since last use. `.failed` never reuses. `.cancelled`
never reuses (cancel-wins distrust: a cancelled engine is not borrowed).
Pure → exhaustively unit-tested, no hardware (`OtoTests/WarmAnalyzerPolicyTests.swift`).

### 2. Warm slot (edit): `Oto/Services/AppleSpeechService.swift`

- Inside the actor: `private var warm: (analyzer: SpeechAnalyzer, locale: Locale, format: AVAudioFormat, lastUse: Instant)?`
  (transcriber deliberately EXCLUDED in the first cut pending probe outcome 1 vs 2 —
  see Probe; if outcome 2, the slot holds analyzer-only and the transcriber is
  rebuilt per session via `setModules`).
- `prepare()` fast path (policy says `.reuse`): fresh `feedBox.createStream()` +
  `configure(format: cachedFormat)` → `start(inputSequence:)` on the warm
  analyzer → `relay.attach` exactly as today. Everything else skipped. Any throw
  → drop warm, fall back to the full slow path WITHIN the same `prepare()` call
  (single retry, then propagate — no retry loops).
- Terminal paths (`finish/cancel` → after existing teardown of relay/finalizedText):
  move analyzer+locale+format into `warm` (policy permitting) instead of nil.
  Per-session teardown ORDER untouched; only the final assignment changes.
  `resultTask` is NEVER reused (always cancelled + recreated per session).
  `finalizedText` is NEVER reused (always reset).
- Invalidation (any → `warm = nil`):
  idle Task (`warmIdleLimit`, re-armed every session end, one task replaced per arm);
  memory-pressure source → invalidate; P3 locale-change signal → invalidate;
  audio device/format change signal (mirror `AppleAudioCapture`'s existing
  rebuild trigger) → invalidate; system sleep/wake (07:603 — "invalidate any
  prepared session") → invalidate; ANY session error → invalidate.

### 3. Flag (codebase convention)

`WarmAnalyzerExperiment.current()` reading `defaults read app.Oto.warmAnalyzer`
(Bool, default **false**) — byte-copy of `InsertionExperiment.current()`.
Matrix flips via `defaults write` + relaunch. Default-false: the change lands
dead-code-safe; P1's signposts prove the win before default-on is even proposed.

## Probe (MUST run before writing the slot — packaged signed app, temporary debug build)

Keep a prepared analyzer past `finalizeAndFinishThroughEndOfInput()`, then:
(a) call `start()` again with a fresh stream; (b) re-iterate `transcriber.results`;
(c) measure both wall-clocks vs today's full prepare. Outcomes:

- Both work → build §2 as written (analyzer+transcriber in the slot).
- `start` works but `results` re-iteration doesn't → slot holds analyzer ONLY;
  per-session fresh `SpeechTranscriber` attached via `setModules` (probe which
  call order is valid) or `SpeechAnalyzer(modules:)` per-session if `setModules`
  proves expensive — probe measures this, decision recorded in the commit.
- Neither works → **P2 STOPS HERE.** Report, keep P1+P3 wins, revisit only with
  new Apple docs. No heroics against undocumented internals.

## Verification

1. `xcodebuild -scheme Oto -destination 'platform=macOS' build` + full
   `xcodebuild test` green. Phase-11 stuck-states tests + `EscapeCancelTests`
   pass UNCHANGED (teardown-chain canaries). Policy tests new and green.
2. P1 signposts prove it: fast path shows `localeResolve/assetProbe/engineWarm`
   absent and `pressToReady` shrunk by the same run's matrix comparison
   (flag off vs on, same device, same mic).
3. Manual matrix (packaged app only): 5 consecutive dictations (warm hits);
   cancel mixed in (never reuses); idle past expiry (rebuilds); locale flip
   (rebuilds); `memory_pressure` CLI / simulated warning (rebuilds); BT SCO
   reconnect per `plan/bt-sco-flap.md` (rebuilds — device change invalidates);
   sleep/wake (rebuilds). Warm must survive ONLY the valid cases.
4. Grep gates: no `downloadAndInstall` outside `SpeechAssetPreparer`; no ship
   branch on any timing value; warm slot never crosses session identity
   (every await re-checks `currentSessionID`, coordinator-side, unchanged).

## Risks

- Undocumented analyzer reuse semantics → mitigated by probe + flag-off default
  + conservative policy + single-retry fallback. Residual risk accepted only
  after probe passes on real hardware.
- Warm analyzer holding memory between sessions → bounded by idle expiry;
  RSS sampled at idle before/after (P4's question answers itself here: if the
  analyzer's idle RSS is noise, P4 stays deferred; if it isn't, expiry shortens).
- `setModules`-fallback cost erasing the win → probe measures; if it erases,
  outcome is STOP, not ship.

## Open questions (all answered by P1 data + probe — none blocking the plan)

- Idle expiry (60s start) — from P1 session-spacing percentiles.
- Fresh `AnalysisContext`/volatile-range setup on re-`start()`? — probe answers.
- Transcriber in slot or fresh per session? — probe answers.
- Default-on? — NOT proposed. Only after matrix data says so, separate decision.

## Execution order (binding)

P1 green → P3 lands (locale signal exists) → Probe runs → P2 implements
against the probe result. P2 compiling against a P3 symbol before P3 exists is
a plan violation — implement P2 after P3, no exceptions.
