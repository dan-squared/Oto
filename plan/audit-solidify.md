# Audit: mis-implementations, test solidity, dead weight — plan (no code changed)

Status: PLANNING ONLY. Nothing implemented. Awaiting user go-ahead per item (§8).

Method: all 35 source + 14 test files read in full; every SDK/API claim
re-checked in `MacOSX27.0.sdk` headers (Carbon bit values, IOKit main port,
AVAudioApplication, SFSpeechRecognizer, activation policy); callers verified
by grep, not memory. Test verdicts are per-test, not per-file.

## 1. Test-solidity verdict (the trust question)

Strong — keep, not tautological. Specifics, not praise:
- `RealTextInsertionTests`: refusal tests assert `changeCount` byte-identical
  (proves zero writes) + hook silence counters (`hid/reactivates/focusReads
  == 0`); restore tests assert marker absence + prior-string return; poll
  tests assert sleep counts. These cannot pass against a broken gate.
- `DictationCoordinatorTests`: 12 paths assert terminal states, call counts,
  target identity (`calls.first?.target == stubTarget` pins no-redirect),
  recovery contents. Race/idempotency covered both orders.
- `HotkeyTransitionStateTests`, `ShortcutRecorderTests`,
  `PasteboardOwnershipTests`, `SpeechReadinessMappingTests`,
  `SpeechLocaleMatchingTests`, `AudioBufferRelayTests`,
  `BufferConverterTests`: pure, deterministic, behavior-pinning.
- `SettingsUITests`: asserts real window + chrome + (new) toggle existence.
- Thin-but-honest: my `DockVisibilityTests` (mapping/default/round-trip)
  pins exactly the inversion risk + upgrade default; `apply()` is
  untestable in unit (needs live NSApp) — proof is UI existence + device
  matrix, stated plainly.
- Trivial (delete): `OtoTests/OtoTests.swift` (empty example, asserts
  nothing), `OtoUITests/OtoUITests.swift` (`testExample` launches and
  asserts nothing; `testLaunchPerformance` is noise on a windowless app).

## 2. Real mis-implementations (fix)

- **F1 — BufferConverter ignores input-format change.**
  `BufferConverter.swift:31`: cache keyed on output format only. After a
  mid-session device switch the tap delivers a NEW hardware format but the
  cached `AVAudioConverter` holds the OLD input format → every buffer
  throws → silently dropped (`AudioFeedBox.feed` swallows, uncounted).
  Fix: `|| converter?.inputFormat != inputFormat` in the rebuild condition
  + test converting A→C, then B→C on one instance.
- **F2 — `refreshAvailability()` has zero callers.**
  `ShortcutDispatch.swift:137` doc says "call on app activation"; grep
  proves nobody does. AX revocation / tap death at runtime never surfaces
  or heals. Fix: call it from the menu `.task` (runs per open — the one
  place guaranteed to execute while the user is present); requires passing
  `dispatch` into `OtoMenuBarView` (it currently takes coordinator +
  inserter). Small wiring change.
- **F3 — Menu `feedback` never resets.**
  `OtoMenuBarView.swift:24-31`: `.task` refreshes status/recovery but not
  `feedback`, so a stale "Posted — check…" line survives to the next open.
  Fix: `feedback = nil` first line of the task.
- **F4 — Retry is blind to secure input.**
  `retryPostToFrontmost` deliberately skips policy gates, but under secure
  input the keystroke vanishes while the menu reports "Posted". The check
  is already injectable (`events.secureInputEnabled`). Fix: refuse fast
  with an honest "blocked" result + test (secure:true → false, hid==0).
- **F5 — Preparer lies when `reserve` fails.**
  `SpeechAssetPreparer.swift:70-78`: reserve throws → logged, but returns
  "Already prepared". Fix: return "Installed but could not be reserved:
  …" on that path + test the string branch if separable (else device note).

## 3. Dead weight (added, should not exist)

- **D1 — `Oto/Item.swift`.** SwiftData template sample, zero code
  references (grep). Keep-condition ("until PreferencesStore lands",
  phase-0 §3.5) can never fire — Phase 5 rejected PreferencesStore.
  Delete file. Also drops the pointless SwiftData linkage.
- **D2 — Template tests** (§1): delete `OtoTests/OtoTests.swift`;
  delete `OtoUITests/OtoUITests.swift` (SettingsUITests is the real suite).
- **D3 — Unreachable failure chain.** `ModifierHotkeyMonitor
  .onRegistrationFailure` is assigned but never fired (Carbon center does
  no resume monitoring); `CarbonHotKey.onRegistrationFailed` likewise
  dead; hence `ShortcutDispatch.handleBackendFailure` is unreachable.
  Remove all three; the configure-time `.conflicts` path (reachable,
  tested) stays.
- **D4 — Recorder `.menuItem` conflict is dead in production.**
  `ShortcutRecorderField.swift:96-100` passes `menuItemTitles` default
  `[:]` — the branch fires only in tests. Oto cannot enumerate other
  apps' menus, and its own menu is trivial, so harvesting is theater.
  Recommended: remove the branch + `menuItemTitles` param (keep system +
  disallowed). Alternative: keep rules-pure for a future that needs it —
  say so in §8 if you prefer.
- **D5 — `PermissionsManager.requestSpeech()` dead.** Zero callers; legacy
  `SFSpeechRecognizer` API the Analyzer path never uses; its plist key
  (`NSSpeechRecognitionUsageDescription`) isn't even set, so it could
  never have prompted. Remove; keep display-only `speechStatus()`.
- **D6 — Stale comments.** `ShortcutModels.swift:64` ("Absorbed by
  PreferencesStore in Phase 5" — rejected future); menu "same contract as
  Settings retry" (no Settings retry exists). Reword both.

## 4. Structural solidity

- **S1 — SWIFT_VERSION = 5.0 (headline).** Every `Sendable`/actor claim in
  the codebase is design discipline, NOT compiler-verified. Concrete
  suspect already visible: `RealTargetCapture: TargetCapturing` (Sendable
  protocol) on a plain class compiles only in Swift 5 mode. Fix: flip to
  Swift 6 mode, build, fix fallout, report. Fallout size unknown —
  timebox step 1 to flip + build + report before committing to the fix
  list. This is the single biggest solidity win available.
- **S2 — Two `RealTextInsertion` instances.** `OtoApp.swift:34,47` builds
  one for the coordinator and a second for the menu Retry. Stateless
  today, divergence risk tomorrow. Fix: build one, inject into both.
- **S3 — Dispatch routing + HID `decide` untested.** Dispatch takes a
  concrete coordinator (no seam); `HIDEventMonitor.decide*` is private.
  Recommended split: expose `decide` functions internal + matrix tests
  (cheap, pure — do it); leave dispatch gesture routing to the device
  matrix (already proven per-gesture on device) rather than a protocol
  seam + mock coordinator (cost > value now; revisit if routing logic
  grows).
- **S4 — Missing targeted tests** (add with §2 fixes): locale
  rg-extension widening (`en_US@rg=…` — the actual bug class behind the
  matcher); converter format-switch; `lastSessionSummary` copy strings
  (UI-visible, zero coverage); reserve-failure message.

## 5. Noted, not charged

- **N1 — Relay attach ordering race.** `AudioBufferRelay.attach` flushes
  buffered audio after setting the sink; a buffer arriving mid-flush jumps
  ahead of older buffered audio. Microsecond window at session start,
  quality-only. Options: accept + note, or sequence-number the flush.
  Default: accept (§8 to override).
- **N2 — Hardware paths untestable by construction** (AudioEngine,
  SpeechAnalyzer, HID tap, Carbon). Device matrix is the proof; no action.
- **N3 — Speech locale frozen at launch** (`.current` captured in
  `OtoApp.init`). System language change needs relaunch. Cheap fix
  available (resolve `Locale.current` per `prepare()`); say the word to
  include.

## 6. SDK facts reconfirmed (not from memory)

Carbon bits 1<<8/9/11/12 = 256/512/2048/4096 (`Events.h:110-114,123-127`)
match `CarbonModifiers`; `kIOMainPortDefault` current, master-port name
deprecated (`IOKitLib.h:107-135`); `AVAudioApplication.recordPermission`
+ request API current, macOS 14+ (`AVAudioApplication.h:109,119`);
`SFSpeechRecognizer.authorizationStatus/requestAuthorization` available,
undeprecated (`SFSpeechRecognizer.h:98,115`); activation-policy semantics
as previously recorded; `downloadAndInstall` single call site (§gate
holds).

## 7. Verification (on execute)

`xcodebuild build` + `test` green (incl. new F1/F4/S4 tests, UI suite
minus templates); grep gates (`DEBUG`, `NSAppleScript`,
`titlebarAppearsTransparent`, `SettingsWindowAccessor` → 0;
`downloadAndInstall` → 1; `refreshAvailability` callers ≥ 1;
`onRegistrationFailure` → 0); S1 reported separately (flip + build log
before fixes). Device delta: switch audio device mid-dictation (F1);
revoke AX → open menu → calibration flips (F2); Retry under secure input
says blocked (F4). No push until you verify (standing rule).

## 8. Open questions (answer per item, or "all recommended")

1. D4: remove `.menuItem` branch (recommended) vs keep rules-pure?
2. S3: decide-matrix tests only (recommended) vs full dispatch seam?
3. S1: Swift 6 flip now (recommended first step: flip + build + report)?
4. N1: accept the race (recommended) vs sequence-number fix?
5. N3: include per-prepare locale (recommended small) or defer?
6. Scope execute: F-fixes + D-cleanup + S2/S4 in one pass (recommended)?

## 9. Swift 6 migration record (executed 2026-09-21, this session)

- Docs pipe verified live: official Swift book via context7
  (`/swiftlang/swift-book`). TSPL Concurrency model drove the strategy.
- Root cause: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (Xcode 27 build
  default, not in our pbxproj) + `SWIFT_VERSION = 5.0` meant every
  `Sendable`/actor claim was design discipline, never compiler-verified.
  Flipped to 6.0; kept the safe default; annotated boundaries instead of
  weakening the setting.
- Annotation rule actually applied: provably-stateless members →
  `nonisolated`; lock-guarded realtime storage → `nonisolated(unsafe)`
  on the STORAGE with checked `nonisolated` methods (unsafe-on-methods
  does not cover member access — learned from the compiler, round 3).
  `NSLock` is Sendable (`NS_SWIFT_SENDABLE`, 27 SDK). Static lets of
  Sendable type need no attribute at all (compiler-advised).
- Structural fixes the migration forced (all real): `isAlive` → async
  (actor witnesses can't satisfy sync Sendable requirements); capture
  requirement + chain → `nonisolated` (incl. explicit `nonisolated init`
  and `==` for snapshot structs); Carbon deinit → direct OS unregister
  (deinit is nonisolated by definition) + weak-map sweep.
- Cascade-suppression warning for future migrators: Swift reports one
  error layer per clean build — incremental builds HIDE remaining errors
  (only recompiled files re-emit). Always clean-build to inventory.
- Transient anomaly recorded: the first post-flip build emitted a wide
  cascade (everything looked MainActor-bound); all later clean builds
  converged on the true, fixable set above. Attributed to module-cache
  state across the language-mode switch; did not recur.

## 10. Audio-tap modernization (S5, EXECUTED 2026-09-21 — see plan/s5-audiotap.md)

- macOS 27 deprecates `installTapOnBus:bufferSize:format:block:` (void)
  (`AVAudioNode.h:117`, replacement named in the attribute).
- Replacement: `installTapOnBus:bufferSize:format:error:block:`
  (`AVAudioNode.h:160`, `API_AVAILABLE(macos(27.0))`,
  `NS_REFINED_FOR_SWIFT`) → Swift `installAudioTap(onBus:bufferSize:
  format:tapProvider:) throws` (AVFAudio swiftinterface:247), whose block
  is `@Sendable` and receives `AVReadOnlyAudioPCMBuffer` (not
  `AVAudioPCMBuffer`).
- NOT migrated deliberately: the read-only buffer type crosses the full
  relay → feed → converter chain, and that change ships only with a
  device audio-matrix (record → transcript quality), never blind. The
  deprecated call still works (present in the 27 SDK, device-proven
  audio path). One deprecation warning remains as the honest marker.
- Executed: `installAudioTap` + `AVAudioPCMBuffer(copying:)` bridge
  (one copy per block); relay/feed/converter untouched; bit-exact
  headless round-trip tests; deprecation warning at zero. The
  `init(copying:)` isolation risk did not fire. Device matrix pending —
  plan/s5-audiotap.md §5.

## 11. Migration complete (2026-09-21, same session)

- Clean-build error trajectory (each a clean build): 14 → 1 syntax
  (truncated file, restored from git) → 7 → 2 → 1 → … → 0. Causes of
  confusion recorded honestly: incremental builds hide errors (only
  recompiled files re-emit), and the compiler reports one cascade layer
  per build — clean builds are the only inventory.
- Final rules applied: stateless members `nonisolated`; lock-guarded
  realtime storage `nonisolated(unsafe)` + checked `nonisolated` methods;
  Sendable-literal statics need no attribute; explicit `nonisolated ==`
  for every enum compared cross-domain; `@Sendable` closures capture via
  a lock-guarded test box, never captured vars; C-pointer boundaries
  parse-then-dispatch (Sendable snapshot crosses, raw pointer never does).
- Suite: 104 passed / 0 failed, TEST SUCCEEDED. Only remaining warning
  is the S5 installTap deprecation (deferred with SDK facts in §10).

## 12. BT-flap execution record (2026-09-21, same session)

- Debounce core: `RebuildDebouncePolicy` (pure, 5 tests) + actor wiring
  (cancel-on-stop, single scheduled rebuild, rebuild log line with format).
- Observability: converter-failure counter (feedBox, reset per session),
  relay delivered counter (per attach window), one finish summary line
  (delivered/dropped/convFail/chars). Rebuild success/failure both logged.
- Fail-loud: `SpeechSessionError.noAudioCaptured` →
  `DictationFailure.noAudioCaptured` ("no audio captured — check the
  microphone"), recovery stays empty, clipboard untouched. Zero buffers
  all session is the trigger — legit silence still streams buffers, so
  quiet users still complete empty as before.
- Test-crash lesson (real): `AnalyzerInput(buffer:)` TRAPS on non-int16
  buffers (SpeechFramework precondition). A new test used a float target
  and crashed the whole runner — Swift Testing reported the collateral
  as dozens of silent 0.000s failures across suites. Fixed with an int16
  target + a comment naming the trap. Production is safe by
  construction (buffers are always converted to the analyzer's own
  format) and device-proven (transcripts land).
- Suite: 115 passed / 0 failed, TEST SUCCEEDED. Only warning is the
  deferred S5 installTap deprecation (§10).
