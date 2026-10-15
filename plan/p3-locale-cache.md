# P3 — Cached locale resolution (hardened plan, v2)

Status: **implemented 2026-10-15 — build green, 534 unit tests pass (57 suites, incl. 8 new LocaleSnapshotCacheTests). Flag default false (inert until matrix).**
P3.1 only (resolution cache; probe stays per-session). P3.2 data-gated.
Isolation notes (MainActor-default target, found by compiler, not memory):
`Notification.Name` extension member + `init` + `observer`/`snapshot` slots all
`nonisolated`; observer slot is `var = nil` (a `let` cannot capture `self` in
its own initializer — two-phase-init rule); test struct is `@MainActor` per
repo convention (`InsertionExperimentTests` precedent).
Pending manual (packaged signed app only): flag-off identical behavior; flag-on
`localeResolve ≈ 0ms` with `assetProbe` unchanged; language-change drill;
Settings-prepare drill.

## Proof run 2026-10-15 (TEMP arming, same mechanism as late probe arming)

`defaults write` is unusable on dev machines (protected stale container +
CleanSlate wipes), so measurement arms via a TEMP shared-scheme launch arg
(`-app.Oto.localeCache YES`, argument domain wins in-process). Compare
steady-state (2nd+ dictation) `pressToReady` against the 140–160ms baseline
from the probe logs; expect ~5–30ms. REVERT the arg after measurement whatever
the outcome — graduation is a code-default flip or Settings toggle (scheme args
don't exist in the shipped app), decided on the data.

## Goal

`AppleSpeechService.prepare()` awaits `SpeechTranscriber.supportedLocales` and
`SpeechTranscriber.installedLocales` on every key press
(`AppleSpeechService.swift:149,164`). These change at human speed (OS update,
user installs a language in Settings), not per-dictation speed. Resolve from a
fresh-enough snapshot on the press path; re-query only when the snapshot is
provably stale. P1's `localeResolve` interval proves the wait is gone.

## Spec sources

- `Docs/START_HERE_PRODUCT.md`: speech prepared explicitly in Settings, works
  offline after; never downloads on shortcut press; never cloud-fallbacks.
- `07_APPLE_SPEECH_IMPLEMENTATION_PLAN.md:89` (measure-first rule — P1 satisfies).
- `plan/perf-latency-audit.md` F2 (locale awaits are state reads at human speed).
- Existing in-repo precedent: `SpeechReadinessMapper` (pure mapping, tested),
  `SpeechLocaleMatching.bestMatch` (pure widening match, tested — DO NOT
  re-implement), `InsertionExperiment.current()` (flag pattern to copy).

## Facts verified against the local SDK / source (never from memory)

Checked 2026-10-15 on this Mac (SDK `MacOSX27.0.sdk`, Xcode 27.0):

- `SpeechTranscriber.supportedLocales / installedLocales` are
  `static var ... { get async }` (swiftinterface lines ~411-417) — real
  suspension points. Removing them from the press path is a real win (~5-30ms
  est., P1 confirms).
- `Locale.current` is dynamic; the system change signal is
  `NSLocale.currentLocaleDidChangeNotification` (Foundation, stable API —
  implementer verifies the exact symbol name at implementation time against the
  macOS SDK headers, not from this sentence).
- The only in-app path that changes installed state: `SettingsUIState.runPrepare`
  → `SpeechAssetPreparer.prepare(locale:)` (`Oto/Services/SpeechAssetPreparer.swift:55`).
  A successful prepare MUST invalidate the cache (one-line post in that path).
- `AppleSpeechService.prepare()` currently reads per session deliberately
  (comment at lines 145-147: "a language change without relaunch must still
  dictate"). The cache preserves that guarantee via notification invalidation +
  age cap — correctness is never traded for speed. The auditor's N3 concern
  stays satisfied.
- No `LocaleSnapshotCache`, no `LocaleCacheExperiment`, no locale-change
  observer exists today (grep 2026-10-15: zero hits). Greenfield, ~20 lines + tests.
- Test style: Swift Testing (`import Testing`, `struct …Tests`, `@Test`,
  `#expect`) — see `OtoTests/SpeechLocaleMatchingTests.swift`.

## Assumptions questioned

1. "Cache the probe too" — REJECTED for the first slice. The
   `installedLocales + AssetInventory.status` probe is the readiness correctness
   check (unprepared language must fail honest, not dictate into the void).
   P3.1 caches locale resolution only; P3.2 (probe-from-snapshot) ships ONLY if
   P1 data shows the probe itself is expensive. Two-slice design, not timidity.
2. "10-minute expiry" — a starting value, not a truth. Session-spacing data
   from P1 sets the final number. The cap exists so a missed notification can
   only lie for minutes, never for a launch lifetime.
3. "Actor vs lock for the cache" — cache is read on the speech actor's press
   path and written from a notification observer (unknown thread). Implement as
   a small `actor` OR lock-disciplined class following the `AudioFeedBox` lock
   pattern; either is acceptable, but the decision + thread-safety argument must
   appear in the implementation commit message. No MainActor hops on the press path.

## Exact file changes

### New: `Oto/Support/LocaleSnapshotCache.swift` (~80 lines)

```swift
struct LocaleSnapshot: Equatable, Sendable {
    var supported: [Locale]
    var installed: [Locale]
    var takenAt: ContinuousClock.Instant
}
enum LocaleCacheDecision: Equatable {
    case use(Locale)   // resolved from snapshot, zero awaits
    case requery       // absent, stale, or unresolvable — slow path
}
/// + final class/actor LocaleSnapshotCache with:
///   - pure static resolve(current:snapshot:now:maxAge:) -> LocaleCacheDecision
///     (nil → requery; age > maxAge → requery; current unresolvable via
///     SpeechLocaleMatching.bestMatch → requery; else .use(match))
///   - store(supported:installed:takenAt:) / invalidate()
///   - init observes locale-change notification → invalidate()
///   - maxAge: start .minutes(10), tuned by P1 data
```

Rules: matching ALWAYS goes through `SpeechLocaleMatching.bestMatch` (pin one
sample locale through both paths in tests). `sameLocale` for P2's reuse policy
is derived from this snapshot's resolved locale — P2 reads it, never duplicates it.

### Edit: `Oto/Services/AppleSpeechService.swift` (`prepare()`, ~15 lines)

```swift
switch LocaleSnapshotCache.shared.resolve(now: .now) {  // exact accessor per implementer
case .use(let locale): resolved = locale                 // zero awaits
case .requery:
    let supported = await SpeechTranscriber.supportedLocales
    ... existing bestMatch; throw unsupportedLocale on miss ...
    cache.store(supported: supported, installed: installed, takenAt: .now)
}
```

- P3.1: the `installedLocales + AssetInventory.status` probe stays per-session
  (lines 163-173 untouched). P1's `assetProbe` interval measures it.
- P3.2 (conditional): read `installed` from the snapshot when fresh — ONLY if
  P1 shows the probe costs real press-path time. Separate commit, separate matrix run.

### Edit: `Oto/Settings/SettingsUIState.swift` (1 line + import)

On `SpeechAssetPreparer` success path: post cache invalidation
(`LocaleSnapshotCache.invalidate()` / notification — implementer picks the
mechanism P2 will also observe; document the choice). Failed prepares do NOT
invalidate (nothing changed).

### New: `LocaleCacheExperiment` flag (same file or tiny new file)

Copy `InsertionExperiment.current()` exactly:
`defaults read app.Oto.localeCache` (Bool, default **false**). Matrix A/B's via
`defaults write` + relaunch, zero rebuilds. P1's `localeResolve ≈ 0ms` with the
flag on is the graduation proof; default stays false until then.

### New: `OtoTests/LocaleSnapshotCacheTests.swift` (Swift Testing)

- Fresh snapshot → `.use` (and the used locale equals `bestMatch` output).
- Expired snapshot (age > maxAge) → `.requery`.
- Snapshot nil → `.requery`.
- Current locale unresolvable from snapshot → `.requery` (slow path produces the
  honest `unsupportedLocale`).
- Invalidation notification clears → next resolve requeries.
- No system calls, no hardware, deterministic (same discipline as
  `SpeechLocaleMatchingTests`).

## Verification

1. Build + full test suite green (`xcodebuild test -scheme Oto -destination 'platform=macOS'`).
   `SpeechReadinessMappingTests`, `SpeechLocaleMatchingTests` unchanged.
2. Flag off: behavior byte-identical (all presses take the slow path).
3. Flag on, packaged signed app: P1 shows `localeResolve ≈ 0ms`, `assetProbe`
   unchanged (P3.1); dictation succeeds.
4. Language-change drill: change system language mid-run → next dictation
   requeries and either dictates or fails with honest `unsupportedLocale`
   (never a stale-language dictation, never a crash).
5. Settings drill: prepare a language in Settings → next press requeries once,
   then re-caches.

## Risks / deferred decisions

- Risk: stale snapshot hides a newly-installed language → bounded by
  prepare-completion invalidation (the only in-app mutator) + 10-min cap +
  notification observer. Residual risk accepted and bounded.
- Risk: `Locale.current` vs transcriber expectation mismatch → unchanged code
  path (`bestMatch` still decides); cache only skips the fetch, never the match.
- Deferred: P3.2 probe skip (data-gated). Deferred: expiry tuning (P1 data).
- Explicitly NOT in this change: any analyzer reuse (that's P2), any insertion
  timing change, any model/cloud path (locked boundary).

## Open questions

- Expiry length (10 min start) — set from P1 session-spacing data.
- P3.2 ships only if P1's `assetProbe` numbers justify it.
- Observer mechanism (direct call vs NotificationCenter name P2 also observes) —
  implementer decides, documents in commit, keeps P2's dependency in mind.
