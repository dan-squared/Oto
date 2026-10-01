# fn crash + tap-lifetime hardening

Status: PLAN ONLY. Nothing implemented. Awaiting `execute`.

## 0. What the evidence proves (read, not guessed)

- 22 `Oto-*.ips` on disk, faulting stacks read for ALL of them:
  every single one is test-host (`XCT*`/`OtoTests` frames present).
  **Zero production crash evidence exists.** Signatures cluster:
  `Set.contains` (×13), `Dictionary.lookup`, `swift/objc
  retain/release`, `pthread_kill` — the memory-unsafety family, all
  inside HID decide paths behind a REAL tap callback firing mid-test.
- Mechanism, verified line-by-line: tests build
  `HIDEventMonitor()` + `configure()` (`HIDDecideTests.swift:21-22`,
  `HIDDecideDualTests.swift:21,156`, plus dispatch-owning suites) →
  `sync()` → `install()` installs a REAL event tap (AX is trusted on
  the dev Mac) → the monitor has **no deinit**
  (`HIDEventMonitor.swift` — contrast `CarbonHotKey.swift:67`,
  "deinit unregisters") and the tap holds `passUnretained(self)`
  (`:181`) → test ends, monitor freed, tap leaked → next real
  key/mouse event (an fn press is the most common real event)
  fires into freed memory → `EXC_BAD_ACCESS`. Every observed
  signature (lookup, contains, retain, release) follows from one
  dangling owner.
- Production ownership is single + app-lifetime (`hidMonitor`,
  `ShortcutDispatch.swift:51`) — safe from THIS variant. The user's
  prod fn incident is therefore UNTRIAGED (protocol §3), not
  explained away: no .ips for it was found.
- Loader tail (`de06998`) stands as designed; "still missing"
  sightings need the §3 protocol (build freshness + success-path
  only — void dictation correctly shows the catcher, never a tail).

## 1. Fix: tap lifetime (the certain root cause)

1. New `TapLifetime` helper: nonisolated `final class`
   `@unchecked Sendable` owning tap + runloop source + opaque self
   (precedent: `SpectrumEngine`, `AudioSpectrumAnalyzer.swift:92`,
   "actors can't reliably destroy isolated state in deinit, hence
   the separate class"). `init` installs (or nops when gated);
   `deinit` invalidates + removes source + releases the retained
   self. Retain discipline: `passRetained` at install,
   `takeUnretainedValue` per fire (unchanged), single `release` at
   teardown — balanced, so even a missed uninstall leaks instead of
   crashing (and uninstall is now also in deinit, so it can't miss).
2. `HIDEventMonitor` moves tap/source/opaque into the helper;
   `install()`/`uninstall()`/`sync()` delegate. No rule, dispatch,
   or coordinator changes.
3. Unit-test gate: taps never install under XCTest —
   `NSClassFromString("XCTestCase") == nil` at install (precedent:
   `OnboardingWindowController.showIfNeeded`, same repo). Decide
   logic is untouched, so the decide suites run green with zero
   taps (also removes their hidden AX-trust dependency). UI tests
   launch the app (no XCTest linked in) → fully live taps there.

## 2. Tests

- Gate test: under XCTest, `configure()` → `isLive == false` AND
  decide paths fully exercised (the existing decide suites ARE this
  coverage — they must stay green unmodified).
- Reconfigure stress (new, deterministic): 50 sequential
  configure/decide cycles on one monitor — exercises the paths the
  crash reports implicate, no hardware.
- Lifetime proof is partly empirical by necessity (CF internals
  aren't headless-observable): full suite run WHILE pressing
  keys/moving the mouse — previously a reliable crasher — must
  produce zero new `.ips`. Stated, not hand-waved.
- Existing HID/dispatch suites untouched, must stay green.

## 3. User triage protocols (exact, no console needed)

- Loader: (1) relaunch fresh from `de06998`+; (2) dictate INTO a
  text field (void → catcher by design, never a tail); (3) watch
  the final 0.6 s. Report which step diverges.
- fn incident: (1) fresh build? (2) exact action — hold-press
  during dictation, recorder press, which slot, which keyboard?
  (3) macOS "quit unexpectedly" dialog? If YES → timestamp of the
  new `Oto-*.ips` (`~/Library/Logs/DiagnosticReports/`) to me. If
  NO dialog and the app just vanished → clean terminate, different
  hunt (terminate paths audit next).

## 4. Verification

Build green; suite green twice; suite-with-live-input run with
zero new `.ips`; matrix (63-keyboard record, flags regression,
catcher re-run); fn incident closed only by §3 answers + matching
evidence, never by assumption.

## 5. Risks / open

- CF invalidate/remove from deinit run off-main by design; both
  calls are thread-safe for this purpose (documented in code).
- If a post-fix prod `.ips` arrives implicating fn, this plan
  reopens with real evidence — the current file says what today's
  evidence supports and no more.
- No entitlements, deps, plist, rule, or dispatch-behavior changes.
