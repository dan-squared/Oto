# Production-readiness audit — abu-dhabi (pre-cleanup stress test)

## Goal

Stress-test the app for production readiness **before** the cleanup round: verify
everything works, find real bug patches needed, flag bad practices / outdated code
vs the latest docs, judge whether tests are solid or task-placating, cross-check
conflicting specs, and recommend what to fix in what order.

User ask: "cleanup is good but before starting this we need to stress test the app
and make sure everything works … check the tests if they are solid … make sure the
app is production ready … crosscheck conflicting things and list all in md file with
recommendation … start your analysis."

## Spec sources

- `Docs/START_HERE_PRODUCT.md` — **canonical on conflict**: Apple Speech only, one
  `DictationCoordinator`, Flow Bar is the only custom surface, one native `Settings`
  scene + `NavigationSplitView` + `List(selection:)` + `Form` + native controls,
  sidebar = `Dictation / Writing / History / General` (+`Intelligence` only when
  shipped), `SettingsLink`/`openSettings`, phased order, engineering rules.
- `Docs/OTO_REBUILD_PLAN/` numbered plans (deeper matrices, intent record).
- `plan/pre-merge-rigor-audit.md` — prior audit (224-test era); superseded by this
  file on counts, still valid on pill/analyzer verdicts.
- Local SDK truth (this session, never memory): Xcode 27.0 (27A266a),
  `MacOSX27.0.sdk`, deployment target 27.0, `SWIFT_VERSION 6.0` (Effective 6),
  bundle `app.Oto` — via `xcodebuild -version`, `xcrun --sdk macosx --show-sdk-path`,
  `-showBuildSettings`, and direct header greps below.

## Facts verified against the local SDK (this session)

| Fact | Evidence |
|---|---|
| Build green | `xcodebuild -scheme Oto -destination 'platform=macOS' build` → **BUILD SUCCEEDED** (this session) |
| Full suite | `xcodebuild test -scheme Oto` this session: **417 unit tests, 6 failed — all 6 in `RealTextInsertionTests` focus paths** (`otoFrontmostNamesItselfOnFocusRace`, `proceedPostsHIDWhenActiveAndFrontmost` ×4, `focusRaceRestoresSynchronously`) + UITests runner timed out enabling automation mode. Re-ran `RealTextInsertionTests` in isolation: **24/24 passed**. Verdict: environmental (frontmost-focus + automation-mode timeout on a live machine), not code — matches the previously proven clean-tree focus trio pattern |
| Test census | 417 `@Test` in `OtoTests/` + 1 UI test = **418** (`grep -r "@Test"`, `grep "func test" OtoUITests`) |
| `SFSpeechRecognizer` NOT deprecated | `Speech.framework/Headers/SFSpeechRecognizer.h:40,76` — `API_AVAILABLE`, no deprecation. Oto uses only `authorizationStatus()` (`PermissionsManager.swift:64-65`) |
| Old `installTapOnBus:bufferSize:format:block:` IS deprecated | `AVAudioNode.h:117` `API_DEPRECATED_WITH_REPLACEMENT(…macos(10.10, 27.0))`. Oto correctly uses the modern `installAudioTap(onBus:bufferSize:format:block:)` (`AppleAudioCapture.swift:190`) + `format:nil` degenerate guard (`:159-161`) + fresh-engine-per-start (`:127`) |
| `SMAppService` is the correct side | `SMLoginItem.h:33` `__OSX_DEPRECATED(10.6, 13.0, "Please use SMAppService instead")`. Oto uses `SMAppService.mainApp register()/unregister()` (`LoginItemManager.swift:21,29-31`), zero `SMLoginItemSetEnabled` |
| `CGEventPostToPid` current | Only `CGEventPostToPSN` deprecated (`CGEvent.h:367`). Oto posts via `CGEventPostToPid` path (`RealTextInsertion.swift:97-104`), taps via `CGEventTapCreate` (`HIDEventMonitor.swift:464-474`, no deprecation) |
| Carbon hotkey legacy-but-NOT-deprecated | `CarbonEvents.h` symbols `AVAILABLE_MAC_OS_X_VERSION_10_0_AND_LATER`, no deprecation; `Carbon.tbd` still exports. Oto scope-minimal (hold/function keys on HID path), owned from `@MainActor` (`ModifierHotkeyMonitor.swift:21-22`) — keep pinned, do not expand |
| Speech path current | `SpeechTranscriber` + `AssetInventory.status(forModules:)` + `SpeechAnalyzer.prepareToAnalyze/finalizeAndFinishThroughEndOfInput` (`AppleSpeechService.swift:148-172,211`). Only `downloadAndInstall()` caller is `SpeechAssetPreparer.swift:83` (Settings/onboarding only, grep-gated `:12-13`); dictation path inspects readiness only |
| Force/timer/logging gates | Postfix-`!` force-unwrap pattern in `Oto/`: **0 hits**. `try!`/`as!`: **0 in prod**, 5 in tests only (see §4). `fatalError`: 2, both standard unavailable-`init(coder:)` nib traps (`PermissionModal.swift:107`, `PillLayers.swift:160`). `Timer(`: **0**. `print(`/`NSLog(` in `Oto/`: **0**. `TODO/FIXME/HACK/XXX` in `Oto/`: **0** |
| Entitlements/sandbox coherent | `Oto.entitlements` empty `<dict/>` + `ENABLE_APP_SANDBOX = NO` + `CODE_SIGN_ENTITLEMENTS` set. No audio-input/Automation entitlement needed (no sandbox, no System Events route by design `RealTextInsertion.swift:152-157`) |
| Mic usage string present, speech key gap | `INFOPLIST_KEY_NSMicrophoneUsageDescription` set (covers `requestRecordPermission`). **No `NSSpeechRecognitionUsageDescription`** — safe today (never calls `SFSpeechRecognizer.requestAuthorization`, only `authorizationStatus()`), but per header `SFSpeechRecognizer.h:105-108` any future auth prompt without the key **crashes**. See R1 |

## 1. Core dictation path — SOLID (no bug patch needed)

Read in full: `DictationCoordinator.swift`, `DictationState.swift`,
`AppleAudioCapture.swift`, `AppleSpeechService.swift`, `ShortcutDispatch.swift`,
`ModifierHotkeyMonitor.swift`, `HIDEventMonitor.swift`, `RealTextInsertion.swift`,
`RealTargetCapture.swift`, `TranscriptPipeline.swift`, `OtoApp.swift`.

- **Ownership/idempotency:** `actor DictationCoordinator` (`:22`) is the sole owner.
  `finish` guards `context.id==sessionID && currentSessionID==sessionID && canFinish`
  (`:130-134`); `cancel` guards `canCancel`, nils session first (`:153-164`).
  `runPreparation` re-checks identity after every `await` (`:258,267,273,278,282`);
  `finalizeSession` terminal-first ordering with re-checks (`:355-357,362,368-381,
  383-385,405,411,425,428-429`). Terminal states are safe to call repeatedly
  (`DictationState.swift:159-187`).
- **Target captured at start, never re-inferred:** `capture()` synchronously in
  `begin` before any `Task`/UI (`:217-219`); immutable `SessionContext`
  (`DictationState.swift:67-83`); insert/history/liveness all use
  `context.target`, never frontmost-now (`:387,402,410,423` + `:408-409` comment).
  Dead target → transcript kept + `.failed(.targetGone)` (`:412-419`).
- **Clipboard restore is fail-closed:** single-read frontmost-PID race guard
  (`RealTextInsertion.swift:265-271`), pre/post trust re-gate (`:277-283`),
  `changeCount`+marker ownership check in one bounded `Task` (`:396-412`,
  `PasteboardOwnership.swift:21-31`) — user copy always wins. `clearContents`
  + failed `writeObjects` leaves clipboard empty by documented design
  (`PasteboardOwnership.swift:10-12,62-65`) — accepted, not a bug.
- **Secure fields refuse one layer down:** `.secureField → .recoverableFailure`,
  clipboard untouched, transcript kept (`RealTextInsertion.swift:231-245`,
  `EditableFocusCheck.swift:60-70,128-135`). Global secure-input deliberately not
  a gate (`:117-124`) — correct.
- **No cloud / no download on hotkey path:** `AppleSpeechService.prepare`
  (`:136-179`) is status-inspect + `prepareToAnalyze` only; `OtoApp.swift:87-94`
  never wires the preparer into coordinator/speech/dispatch (only onboarding +
  `SettingsUIState`, `:121-125,128`). Launch `Task` loads dictionary/snippet/
  history only (`:131-136`).
- **Known-benign items (not fixes):** 120 ms trailing settle sleep (`:331`),
  insertion timing sleeps 5–600 ms (`RealTextInsertion.swift:15-34` + 6 sites),
  1.5 s rebuild debounce (`AppleAudioCapture.swift:237` + `RebuildDebouncePolicy:39`),
  fn-confirm timer + `Task.yield` spin (`ShortcutDispatch.swift:486,547-549`),
  per-insertion restore `Task` without handle (`RealTextInsertion.swift:403-412`),
  launch `Task` without handle (`OtoApp.swift:131-136`) — all bounded, owned, or
  pre-existing precedent. `unsafeDowncast` in `RealTargetCapture.swift:91,100`
  is `CFGetTypeID`-gated, not a bare `as!`.
- **Concurrency gaps (runtime-contract, → R2):** `CarbonHotKey`/`CarbonHotKeyCenter`
  are plain classes with `nonisolated(unsafe)` refs and comment-only main-thread
  safety (`CarbonHotKey.swift:41,48,67-78,229-236`); `BufferConverter.converter`
  safety rests on single-instantiation convention (`BufferConverter.swift:25-28`);
  `RealTargetCapture` relies on protocol conformance for `Sendable`;
  `DockRestoreDelegate` and `ShortcutRecorderField.MonitorBox` unannotated.
  No compiler violation (Swift 6 clean build); harden with annotations, not
  behavior change.

## 2. Conflicts vs `START_HERE_PRODUCT.md` — the real list (needs product decisions)

All verified against the live files this session. The doc is canonical, so each
item is phrased as conflict → options → recommendation.

1. **Sidebar has 6 items; spec wants 4** (`SettingsRoot.swift:18-25`:
   General/Dictation/Dictionary/Snippets/History/Privacy vs required
   Dictation/Writing/History/General + future Intelligence).
   - No `Writing` destination; Dictionary+Snippets are top-level instead of tabs
     (`Writing: Dictionary Snippets Formatting`, doc :66-72). No `Formatting` UI
     exists anywhere. No `History` tabs (`Transcripts Retention Privacy`,
     doc :74-80) — instead History+Privacy are split items; `HistoryPane.swift:26`
     mentions retention only in a caption. `Dictation` is one scrolling `VStack`
     (`DictationPane.swift:31-164`), not `Behavior Shortcuts Audio Speech` tabs
     (doc :58-64). `General` is one `VStack` (`GeneralPane.swift:48-113`), not
     `Launch Flow Bar Appearance About` (doc :82-88) — no `Appearance` section.
   - No `Intelligence` pane — **compliant** (doc :56 forbids empty placeholder).
   - Recommendation: keep 6 for now (it ships and tests pass); schedule a
     **Writing/History-consolidation plan** as part of cleanup, not as a bug fix.
     Do NOT churn IA under a "stress test" banner.
2. **Settings is a custom `WindowGroup`, not a native `Settings` scene**
   (`OtoApp.swift:139-169`, comment :148-153 "experiment"). Zero `Settings {`
   scenes in `Oto/`. Cmd-comma is hand-wired (`:182-185,241-262`) instead of
   system-bound; **zero `SettingsLink`/`openSettings` uses** in prod (only
   `openWindow(id:)` from menu `:21,88-96` and Cmd-comma). Chrome is manipulated
   (`.toolbar(removing: .title/.sidebarToggle)`, custom View-menu sidebar,
   in-header `OtoDoor`, fixed 805×621 geometry). Spec requires one native
   `Settings` scene + `SettingsLink`/`openSettings` (doc :92,98,180-193,220-221).
   - Recommendation: keep the window (reverting now re-breaks the dressed
     titlebar work you signed off); record the `Settings`-scene return as a
     **deferred cleanup decision**, not a production blocker — ⌘-comma, menu
     entry, and single-open guard all work today.
3. **Selection surface is custom, not `List(selection:)`** (`SettingsRoot.swift:
   84-98`, comment :175 "replaces the native selection surface"; custom
   `SidebarRow` `:126-206`). Spec requires native `List(selection:)` (doc :92-93).
   - Recommendation: same as (2) — cosmetic/architectural debt, not a ship
     blocker. Fold into the IA consolidation plan.
4. **Controls are recreated, not native** (spec doc :93-94,97 + Phase 5 :257).
   `OtoSwitch` (capsule+circle+tap, `OtoControls.swift:78-97`) replaces `Toggle`
   in 6 places; `OtoSegmented` (HStack+matchedGeometry, `:100-132`) replaces
   `Picker`; `OtoCard/OtoRule/OtoLine/OtoCaption/OtoBig/OtoPill/OtoQuick/OtoStatus/
   OtoDoor` replace `Form/Section/LabeledContent` in every pane. Native
   `Toggle`/`Picker`/`Form` survive only inside the two editor sheets.
   Mic selector is a custom `Menu` (`DictationPane.swift:67-84`), not a `Picker`.
   Traffic lights are **compliant** (never recreated; onboarding keeps live
   lights `OnboardingWindowController.swift:54-64`, overlays use legitimate
   `.nonactivatingPanel`).
   - Recommendation: keep — this is the Dia-look you approved over two rounds.
     Note the deliberate deviation in the cleanup plan; do not relitigate per
     pane.
5. **"Flow Bar is the only custom surface" is exceeded** (doc :261). Live custom
   surfaces: Settings theme (`OtoPalette` + cards/rows in every pane), shortcut
   sheet (`ShortcutModal.swift:88-161`, header :11-14 bans Form/GroupBox/List),
   onboarding window (620×480 AppKit host + custom canvas/dots/footer),
   catcher panel (`NoTargetModal.swift:92-138,357-413`), permission card
   (`PermissionModal.swift:52-318`, 5 s auto-dismiss), snap ghosts
   (`FlowBarPanel.swift:422-445`). Pill itself is compliant (read-only,
   150 ms poll, reduced-motion via `motionFrozen`).
   - Recommendation: accept catcher + permission card as recovery-family (they
     keep transcripts recoverable per doc :140-141); the rest is approved design
     debt. No action before cleanup.
6. **Duplication / dead code (cleanup fodder, not blockers):**
   - Permissions rows duplicated Dictation (`DictationPane.swift:102-124`) vs
     Privacy (`PrivacyPane.swift:18-51`) — same fields, same grants, both refresh
     on appear. General correctly avoids duplication (`:1-7`).
   - `OtoHunt` defined (`OtoControls.swift:194-228`), **zero call sites**.
     `OtoKey` used once (onboarding `:300`); `ShortcutModal` inlines an
     equivalent chip instead of reusing it.
   - `DictationPane.swift:166-175` runs a 500 ms `while !Task.isCancelled` poll
     alongside the modal's staged editing; `OnboardingView.swift:37-39,424-444`
     keeps separate mic/AX/speech `@State` duplicating `SettingsUIState`.
   - Recovery Copy lives in 4 homes (menu, catcher, history, snippet) — by
     design for recoverability, but note for cleanup.
   - Ready page has **no Prepare action** (only "Prepare it any time in
     Settings › Dictation", `OnboardingView.swift:472-474`); prepare lives
     solely in `DictationPane.swift:40-44`. Speech row has no action (`:391`).
     Matches "explicit preparation in Settings" but weakens first-launch journey
     (doc :103-109). Recommendation: one-line fix in cleanup — surface the
     existing preparer action on the Ready page.

## 3. Bad practices / outdated code — verdict: CLEAN in prod

- `try!`/`as!`: none in `Oto/`; 5 hits all in tests (JSON casts
  `HistoryStoreTests.swift:95`, `SnippetStoreTests.swift:100,106`; `try!` export
  `DictionaryRuleTests.swift:212`; `try!` buffer `SpectrumEngineTests.swift:87`).
  Test-only; acceptable but listed in §4 hardening.
- sleeps: all inventoried in §1, all bounded/injected; `EditableFocusCheck.swift:
  222` `Thread.sleep(100ms)` sits on a `.global(.utility)` worker, not main.
- No `Timer(`, no `print(`/`NSLog(`, no TODOs in prod.
- Deprecated-API scan: **nothing deprecated in the prod path**. Only legacy item
  is Carbon (not deprecated, §Facts) and the missing speech usage key (R1).
- TCC/shortcut validation hygiene: **clean** — `liveTapsEnabled=false` under
  XCTest (`HIDEventMonitor.swift:159-168`), `micDeniedOverride`
  (`DictationCoordinator.swift:62-64`), injectable `isMicDenied`
  (`FlowBarController.swift:58-61`), calibration only from real global events
  (`ShortcutDispatch.swift:14-15,392-403`). Nothing claims live success from a
  raw executable or test host.

## 4. Are the tests solid or task-placating? — MOSTLY SOLID, thin edges listed

Census 417 + 1. Zero disabled/skipped tests. No AX snapshots. Methodologies:
fake-driven coordinator E2E, pure-function truth tables, real service +
scratch pasteboard for insertion, deterministic state machines for
recorder/flags/Fn/double-tap.

- **Solid (ship-grade):** `DictationCoordinatorTests` (33 — cancel/finish races,
  insertion-failure-keeps-transcript, mic-denied, prepare/finish throws,
  dead-target, zero-audio), `RealTextInsertionTests` (24 — strongest suite:
  changeCount untouched, HID counts, focus-race restore, revoked-trust re-gate,
  secure/pidless/refused-activation fail-closed + retry), `ShortcutRecorderTests`
  (23 — classify truth-table + conflict policy + round-trip), `FlagsCaptureTests`
  (8), `FnHoldConfirmTests` (7), `DoubleTapTrackerTests` (7),
  `HIDDecide/DualTests`, `ShortcutDispatchDualTests`, `Storage/*`
  (dictionary/snippet/history/persistence round-trips).
- **Thin but adequate:** `SpeechReadinessMappingTests` (7 — real branching
  truth-table, but pure lookup; no offline/download E2E), `ZeroAudioTests` (2 —
  one real fail-loud proof + one string pin), `TapLifetimeTests` (3 —
  `liveTapsEnabled==false` is true-by-construction under XCTest; one happy path
  + 50× loop of the same path; no teardown/dealloc repro),
  `OnboardingStoreTests` (4 — trivial get/set; close-without-Finish,
  corrupt/future-version claims untested), `OtoUITests/SettingsUITests` (1 —
  existence-only smoke: window count, labels, toggle exists but never flipped;
  focus-dependent `activate`/`typeKey`, 5–10 s waits, writes real
  `onboardingVersion`, tests Cmd-comma proxy not the system path).
- **Can't-fail pins (accepted, cap them):** constant equalities
  (`silencePeakThreshold==0.01`, `maxPressDuration==250ms`, `maxGap==350ms`),
  copy/errorDescription/caption/palette pins, `frontmostChangeDoesNotRedirect`
  (fake returns stub by construction), `unitTestsNeverGoLive` (environment
  tautology). These pin regressions, not behavior — fine in small doses.
- **Missing coverage (→ R3):** real app-switch redirect (faked away),
  offline asset-download E2E (mapping only), live Speech/audio/HID tap,
  packaged-app TCC/shortcut validation, corrupt/future onboarding version,
  permission-denied UI paths beyond branching.
- **Flake pattern (→ R4):** real sleeps in `DictationCoordinatorTests` (600 ms
  silence), `FlowBarControllerTests` (250–2700 ms), `NoTargetModalTests`,
  `MediaDuckTests` (350 ms), `ShortcutDispatchDualTests` (200–500 ms),
  insertion restore polls, tick-gate 120 ms — mostly gated/polling, plus the
  known rotating host-crash/focus trio previously proven identical on the clean
  tree (environmental, not code).

## 5. Recommendations (ordered; nothing here blocks the suite, items need your call)

**R0 — Verify before cleanup (do first, no code):**
- Full `xcodebuild test -scheme Oto` green on a calm machine (background run
  kicked off during this audit) + your live device matrix: cold dictate →
  stop → deny-mic → drag pill → quit/relaunch (slot persists) → Settings flip
  (live pill moves) → catcher on/off → 10-bar feel → WiFi-icon neighbor check.
- Decide §2 items (sidebar IA, Settings-scene return, native controls) as
  **deferred cleanup scope**, not production defects — record the decisions in
  the cleanup plan so agents stop relitigating them.

**R1 — Tiny hardening patch (4 small edits, zero behavior change, do pre-cleanup):**
1. Add `INFOPLIST_KEY_NSSpeechRecognitionUsageDescription` to the project
   (prevents a future crash the header explicitly warns about).
2. `@MainActor` (or explicit main-thread deinit hop) for `CarbonHotKey` /
   `CarbonHotKeyCenter` (`CarbonHotKey.swift:41,88`).
3. `if let` the two documented-safe force-adjacent sites only if touched by
   cleanup anyway (prior audit S1/S2 — cosmetic, optional).
4. Surface the existing preparer action on onboarding Ready
   (`OnboardingView.swift:457-493` + `DictationPane.swift:40-44`) — one-line
   journey fix.

**R2 — Cleanup scope (the actual next phase, needs your §2 decisions first):**
- IA consolidation (Writing/History tabs, Dictation/General tabs or explicit
  keep-as-VStack decision), `List(selection:)` return, control-unification
  (`OtoSwitch/Segmented` vs native — or explicit keep), delete `OtoHunt`,
  dedupe permissions rows, share `SettingsUIState` with onboarding, remove the
  500 ms `DictationPane` poll, fix `SettingsRoot.swift:15-17` misleading comment.

**R3 — Test hardening (after cleanup, small):**
- `TapLifetimeTests`: teardown/dealloc + real crash-repro coverage.
- `OnboardingStoreTests`: corrupt + future-version cases.
- `SettingsUITests`: flip one toggle, assert one value round-trips; stop writing
  real `onboardingVersion` (isolate defaults).
- Optional: offline-prepare E2E (network off, prepared-language dictate) as the
  one integration test the suite lacks. Keep constant/copy pins capped where
  they are.

**R4 — Flake hygiene (process, not code):**
- Re-run the full suite on a calm (focused, idle) machine for the second green;
  the rotating host-crash/focus trio is proven environmental (reproduced on the
  clean tree). No code change.

## 6. Verification steps

- [x] `xcodebuild -scheme Oto -destination 'platform=macOS' build` → SUCCEEDED (this session)
- [x] `xcodebuild test -scheme Oto -destination 'platform=macOS'` → 417 unit: 6 focus-path failures in full run; **24/24 green in isolation**. UITests runner automation-mode timeout (environmental). Second green needed on calm machine
- [x] Grep gates: force-unwrap 0 (prod) / `try!`+`as!` test-only 5 / `fatalError` 2 nib-traps / `Timer(` 0 / logging 0 / TODO 0
- [x] SDK header checks: SFSpeechRecognizer, AVAudioNode tap, SMLoginItem, CGEvent, Carbon — all §Facts
- [x] Every §2 conflict re-read against live files (paths + lines above), not memory
- [ ] Live device matrix (yours only): real dictation rounds, 10-bar feel, catcher cards both slots, WiFi neighbor check, packaged-app TCC/shortcut

## 7. Risks / deferred

- The §2 deviations are deliberate, approved, and shipped — "fixing" them
  without your explicit IA decision would regress signed-off design. This audit
  recommends **recording**, not reverting.
- Tooling has twice dropped/truncated edits in this repo's history — the full
  suite re-run + grep gates are the backstop; never merge cleanup on stale counts.
- Catcher desktop-dictate eyes-on verification and the live fn-usage/241 matrix
  remain yours; Phase 7 (Intelligence) stays gated behind the core release gate
  per the product doc.

## 8. Open questions (for you, before cleanup)

1. Sidebar: consolidate to spec 4 (+tabs) or keep 6? (Recommendation: consolidate
   in cleanup — spec is canonical — but keep shipping 6 until then.)
2. Settings scene: return to native `Settings` (regains system ⌘-comma +
   `SettingsLink`) or keep dressed `WindowGroup`? (Recommendation: return in
   cleanup; the dresser proved the look is achievable either way.)
3. Controls: unify on native or keep the Dia kit with a recorded deviation?
   (Recommendation: keep the kit — you signed it off twice — and record it.)
4. R1 patch now (4 small edits) or fold into cleanup? (Recommendation: now —
   tiny, zero-risk, and R1.1 prevents a real future crash.)
5. Full-suite second green + device matrix before cleanup starts? (Recommendation: yes.)
