# All-phases hardening + cleanup (A/B/C/D) — spec-conflict items excluded

## Goal

Execute the audit's R1–R4 minus everything that relitigates shipped design.
Excluded by user order: sidebar IA, Settings-scene return, `List(selection:)`,
native-vs-Dia controls, extra custom surfaces. What remains is pure hardening
with zero intended visual change (except A3's Prepare button, which is the point).

## Spec sources

- `plan/production-readiness-audit.md` §§1–5 (R1–R4), `Docs/START_HERE_PRODUCT.md`
  canonical (untouched areas stay as-is).
- Local SDK truth (this session): `MacOSX27.0.sdk`,
  `SFSpeechRecognizer.h:105-108` (missing `NSSpeechRecognitionUsageDescription`
  crashes `requestAuthorization`), `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
  (`project.pbxproj:482,514`), `XCUIElement.value` + `NSPredicate` expectations
  (standard XCUITest).

## Facts verified (not memory)

- Mic key set at `project.pbxproj:472,504`; speech key absent (grep).
- `CarbonHotKey` constructed only from `@MainActor` (`ModifierHotkeyMonitor.swift:39`);
  `enabledSystemShortcuts()` called only from View context (`ShortcutRecorderField.swift:259`);
  no test constructs either. Implicit MainActor isolation already applies via the
  build setting — explicit annotation is behavior-free documentation.
- `OtoHunt` zero call sites; `OtoKey` used once (onboarding `:300`).
- Dictation Mic-Status + AX + Speech rows verbatim-equal to Privacy's
  (`DictationPane.swift:86-123` vs `PrivacyPane.swift:19-50`).
- `OnboardingView`/`OnboardingWindowController` constructed only in
  `OtoApp.swift:121` / controller `:78`; no test pins their inits.
  `uiState.readinessText` (`"Ready"`) + `languageText` render the same Ready row
  as onboarding's locals (`"Ready (\(tag))"`).
- Post-`stop()`, `holdSlots` is empty so `decideRoutedHold` returns
  `(nil, nil, false)` (`HIDEventMonitor.swift:344-346`) — C1 assertions are exact.
- `OnboardingStore.shouldShow`: string value → `integer(forKey:)` is 0 → shows;
  `current+1` → hides. C2 pins both.
- `OtoSwitch` exposes `.isToggle` + value "On"/"Off" (`OtoControls.swift:94-95`);
  `ShowInDockToggle` identifier precedent works in the UI test — C3 adds
  `CatcherToggle` the same way (catcher flip-flop self-restores the pref).

## Exact file changes

**A1** `project.pbxproj:472,504`: add
`INFOPLIST_KEY_NSSpeechRecognitionUsageDescription` after each mic line.
**A2** `CarbonHotKey.swift:41,88`: `@MainActor` on both classes + comment;
`deinit:67-78`: `assert(Thread.isMainThread)` + one-line comment.
**B1** `OtoControls.swift:194-228`: delete `OtoHunt` + doc comment.
`ShortcutModal.swift:51-58`: chip `Text` → `OtoKey(chip)` (accepts 44pt min-width).
**B2a** new `Oto/Settings/PermissionRows.swift`: `MicStatusRow`,
`AccessibilityRow`, `SpeechStatusRow` (verbatim row bodies, no cards).
`DictationPane.swift:86-124` and `PrivacyPane.swift:19-50` use them; cards,
rules, captions untouched.
**B2b+A3** `OtoApp.swift:121-128`: build `settingsUIState` first, pass into
`OnboardingWindowController(dispatch:uiState:)`; controller `:26-35,77-84`
drops preparer/permissions; `OnboardingView.swift`: `uiState` param replaces
both, local mic/ax/speech/readiness/language state + `refreshPermissions()` /
`refreshSpeech()` deleted, Ready unprepared branch gains Prepare button via
`uiState.runPrepare()` / `isPreparing` (mic-denied copy mapped locally so
pixels are identical).
**B3** `DictationPane.swift:166-180`: `while` poll → `.onAppear` sync +
sheet `onDismiss` sync. `SettingsRoot.swift:15-17`: comment says six panes.
**C1** `TapLifetimeTests.swift`: stop-without-configure, double-stop,
stop-clears-slots, dealloc-releases (weak-nil, guards the no-cycle invariant).
**C2** `OnboardingStoreTests.swift`: corrupt-string shows, future version hides.
**C3** `DictationPane.swift:133`: `.accessibilityIdentifier("CatcherToggle")`;
`SettingsUITests.swift`: Dictation → flip-flop with `NSPredicate value ==`
expectations, asserts restore.
**D**: build + unit file tests + full suite; report.

## Verification

- `xcodebuild -scheme Oto -destination 'platform=macOS' build`
- Targeted: `-only-testing` TapLifetime, OnboardingStore, SettingsUIState,
  ShortcutRecorder/Flags/Fn suites (regression around modal chips).
- Full `xcodebuild test`; UITest green depends on automation mode (matrix-owned).
- Grep gates re-run (unwraps/`Timer`/logging still 0 in prod).

## Risks / deferred

- Chip min-width 44pt widens single-glyph chips (intended standardization).
- Dictation calibration status can stale while pane stays open (re-syncs on
  appear + modal close); accepted, recorded.
- UITest can't green in this shell (automation-mode timeout is environmental);
  written standardly, matrix verifies.
- Spec-conflict items (§2 of audit) deliberately untouched.
