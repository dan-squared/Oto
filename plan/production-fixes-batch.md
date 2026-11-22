# Production fixes batch — failure surface, onboarding gate, dev hooks, metadata, persistence

Status: executed. Debug + Release builds succeed; full `OtoTests` + `OtoUITests` green.

## 1. Goal

Finish the remaining items from the attached review notes (`.context/attachments/5BpGNE/pasted_text_2026-11-20_16-07-00.txt`), in the smallest honest diffs:

1. Every non-recovery `.failed` result is visible at the shortcut.
2. Onboarding cannot finish with missing microphone / Accessibility grants.
3. Developer hooks (probe, clean slate, AX dump) do not ship in a Release build.
4. App metadata: human-readable copyright + application category.
5. Persistence write failures are surfaced in the owning pane, not only logged.
6. Apply the supplied menubar SVG and Apple Icon Composer `.icon` asset.

Explicitly **out of scope** (per the notes' decisions): distribution/signing work, Settings IA changes, removing background speech preparation, bundle-ID change, test-defaults isolation.

Already present in the working tree — **verify, do not redo**:
- MediaDuck immediate restore (`Oto/Services/MediaDuck.swift:134-138,190-233`), stop-tone fix and tests (`OtoTests/MediaDuckTests.swift`, `plan/stop-tone-audible-through-media-duck.md`).
- `applicationWillTerminate` → `MediaDuck.restoreIfCrashed()` (`Oto/App/OtoApp.swift:22-27`).

## 2. Spec sources and verified facts

- `Docs/START_HERE_PRODUCT.md` (canonical): failure recovery "Every uncertain result remains recoverable… never claim success from a paste event" (:139-141); one native Settings scene (:92-99); no third-party speech (:15-19).
- Notes attachment: mapping of the user's replies — keep background download, skip distribution/IA/bundle ID, "fix these and issues that you listed".
- Local SDK truth (verified this session, not memory):
  - Xcode 27.0, SDK `MacOSX27.0.sdk`, deployment target 27.0 (`Oto.xcodeproj/project.pbxproj:391,449`).
  - `Speech.framework/Modules/Speech.swiftmodule/arm64e-apple-macos.swiftinterface`: `SpeechAnalyzer` :226-239, `AssetInventory` :31-56, `AnalyzerInput` :11-13 are all `@available(anyAppleOS 26, *)`. A handful of `AnalyzerInput` properties are 27-only (:16-28) but are not used by Oto. **Answer to "check if it works": yes — the Speech APIs Oto uses are available on macOS 26; no code change needed, deployment target stays 27.0.**
- Existing state verified in tree:
  - `FlowBarProjection.project` hides every `.failed` from the pill (`FlowBarState.swift:147-158`); `RecoveryRouter` owns only `targetGone`/`insertionFailed`/`noTextField` *with kept text* (`:197-217`). Mic-denied owns `PermissionModalController` (`FlowBarController.swift:488-516`). So `audioCapture`, `speechPreparation`, `noAudioCaptured`, and recovery failures without kept text currently have **no visible surface**.
  - `FlowBarController` already has a transient `.message` pill latch (`overLimitText/overLimitUntil`, :80-85, :219-232, :400-401) — the reuse target.
  - `OtoMenuBarView` is entry-points-only and has no status row (:11-35), though `coordinator.lastSessionSummary()` already formats every failure (`DictationCoordinator.swift:277-307`).
  - `OnboardingFlow.next()` finishes unconditionally on `.handsFree` (:68-69, :101-104); `buttonTitle` says "Finish" (:48-53). `prepareDictation()` asks for grants on arrival but does not gate (:131-153).
  - `OtoProbe.swift`, `AXDump.swift`, `CleanSlate.swift` are unguarded; `OtoApp` calls all four probe entry points (`OtoApp.swift:31,35,39,40,112,120`); probe notification observers live in five settings files (verified by grep).
  - `INFOPLIST_KEY_NSHumanReadableCopyright = ""` in both app configs (:471, :503); no `LSApplicationCategoryType`; `AboutPane.swift:30` uses "© 2026 Daniel Girma. All rights reserved."
  - All three `@Observable @MainActor` stores swallow `persist()` errors to a log line (`DictionaryStore.swift:294-300`, `SnippetStore.swift:143-149`, `HistoryStore.swift:170-176`).
  - Assets found: `~/Downloads/Flower_o_Vector.svg` (702×702, same flower as the 18×18 inline SVG) and `~/Downloads/oto.icon/icon.json` + `Assets/Flower_o_Vector.svg` (Apple Icon Composer bundle).
  - Working tree already contains unrelated uncommitted work (onboarding remake, settings polish, tests). Do not revert, move, or rewrite it.

## 3. Assumptions questioned

- "Failure surface for all `.failed` cases" ≠ putting an error card on the pill for every case. Mic-denied already has a card; recovery-owned failures already have the catcher/auto-copy. Doubling them forks truth (`FlowBarState.swift:12-16`). Decision: **suppress the pill message when a dedicated surface owns the failure**, and surface the rest for a few seconds; add a menu status row as the durable record.
- "Onboarding permission gate" is a *gate on Finish*, not a new prompt system. Apple's dialogs keep asking; `prepareDictation()` stays as-is.
- `#if DEBUG` must not break tests: Xcode builds the test target's app with `DEBUG` set, so `CleanSlateTests` still compile. Release needs explicit no-op stand-ins for `wipedClean`/`probeCapture`.
- Copy is generated from the typed `DictationFailure`, never from `lastSessionSummary()` strings, so wording stays in exactly one place per surface.

## 4. Exact file changes

### Task A — Failure surface (pill latch + menu row)

- `Oto/UI/FlowBar/FlowBarState.swift`
  - Add `nonisolated func failurePillText(_ failure: DictationFailure) -> String?` (pure, unit-testable): short copy for `.audioCapture`, `.speechPreparation`, `.noAudioCaptured`, and a fallback for `.targetGone` / `.noTextField` / `.insertionFailed`; `nil` for `.microphoneDenied`.
  - Copy examples: "Audio capture failed — check the microphone", "Speech couldn't start", "No audio captured — check the microphone", "Target app closed", "No text field focused", "Insertion failed — transcript kept".
- `Oto/UI/FlowBar/FlowBarController.swift`
  - Add `failureText`, `failureUntil`, `lastFailureKey`, `failureMessageDuration = 3.0`.
  - Clear both latches wherever `overLimit*` is cleared on a live session (:163-167).
  - Make `syncRecovery` return `Bool` ("a recovery surface owns this transition"); add `syncFailureLatch(state:recoveryOwned:)` that fires once per failure transition (key = session id or `"nil-context"`), skips `.microphoneDenied` and `recoveryOwned`, and arms the latch.
  - Merge into the existing override (:219-232): text = `overLimitText ?? failureText`; both deadlines respected. Render uses the chosen text (:400).
  - `stop()` (:122-139) resets the new latch.
- `Oto/UI/OtoMenuBarView.swift`
  - Accept `coordinator: DictationCoordinator`; add `@State private var lastSummary = ""`.
  - When `lastSummary.hasPrefix("failed:")`, show `Text(lastSummary)` + `Button("Open Settings…") { settings.show() }` + divider above the existing entries.
  - Refresh via `.task` and `NSApplication.didBecomeActiveNotification` (`await coordinator.lastSessionSummary()`).
- `Oto/App/OtoApp.swift` (:281-285): pass `coordinator` into `OtoMenuBarView`.
- `OtoTests/FlowBar/FlowBarControllerTests.swift`: pin (1) audioCapture/speechPreparation/noAudioCaptured latch shows text, (2) mic-denied stays card-only, (3) recovery-owned failure shows no pill message, (4) latch expires, (5) a new live session clears it. Pure-copy test for `failurePillText` can live in the same file.

### Task B — Onboarding permission gate

- `Oto/Onboarding/OnboardingFlow.swift`
  - Add pure `enum PermissionBlocker { case accessibility, microphone }` and `static func blocker(axTrusted: Bool, mic: PermissionsManager.MicrophoneStatus?) -> PermissionBlocker?`; instance `var permissionBlocker` is non-nil only on `.handsFree`/`.handoff`.
  - `buttonTitle` on those steps: `.accessibility → "Enable Accessibility"`, `.microphone → "Allow Microphone"`, otherwise `"Finish"`.
  - `next()` on `.handsFree`: request the blocked grant (AX → `uiState.requestAccessibilityPrompt()` + refresh; mic → `Task { _ = await uiState.ensureMicrophoneGrant(); uiState.refreshPermissions() }`), and only `finish()` when `permissionBlocker == nil`.
  - Existing didBecomeActive refresh in `OnboardingView.swift:64-70` already updates the gate after System Settings; no change needed there.
- `OtoTests/OnboardingStageTests.swift` (or a new `OnboardingFlowPermissionTests.swift`): pin the pure blocker table for granted / notDetermined / denied / untrusted combinations.

### Task C — `#if DEBUG` dev hooks

- `Oto/Onboarding/OtoProbe.swift`: wrap whole file in `#if DEBUG … #endif` (including the `Notification.Name` probe extensions).
- `Oto/Support/AXDump.swift`, `Oto/Support/CleanSlate.swift`: wrap in `#if DEBUG … #endif` (tests compile with DEBUG).
- `Oto/App/OtoApp.swift`: `#if DEBUG` around `AXDump.runIfRequested()`, `OtoProbe.forceAppearance()`, `captureIfRequested`, `captureSettingsIfRequested`, and `CleanSlate.wipeIfRequested()`; define `let probeCapture = false`, `let wipedClean = false` in `#else` so the existing guards still compile.
- Wrap the five probe-notification observers in `#if DEBUG`: `Settings/DictionaryPane.swift:69-72`, `Settings/HistoryPane.swift:72-78`, `Settings/SettingsRoot.swift:388-396`, `Settings/DictationPane.swift:63`, `Settings/ShortcutRecorderField.swift:522`.
- Grep gate after the change: no `OtoProbe`, `AXDump`, `CleanSlate`, or `otoProbe*` reference outside `#if DEBUG` in the shipping target.

### Task D — Metadata

- `Oto.xcodeproj/project.pbxproj` (both Oto Debug :471 and Release :503):
  - `INFOPLIST_KEY_NSHumanReadableCopyright = "Copyright © 2026 Daniel Girma. All rights reserved.";`
  - Add `INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.productivity";`
  - Bundle ID unchanged (`app.Oto`), per notes.

### Task E — Persistence save-failure surfacing

- `Oto/Storage/DictionaryStore.swift`, `SnippetStore.swift`, `HistoryStore.swift`: add `@Observation` `var saveFailed = false` (plus optional short `saveFailedMessage`), set `true` in `persist()`'s `catch`, `false` on success. Keep the log line.
- `Oto/Settings/DictionaryPane.swift`, `SnippetsPane.swift`, `HistoryPane.swift`: show a compact inline banner bound to the store flag (text: "Changes couldn't be saved. Your edits are still here — try again or check disk space."). Place above the existing validation error surface; do not replace it.
- Tests: extend existing storage tests with a persistence stub that throws on `write`, asserting the flag flips and clears.

### Task F — Assets (confirm in open questions)

- Copy `~/Downloads/oto.icon` into `Oto/Resources/` and add it to the Xcode target; set `ASSETCATALOG_COMPILER_APPICON_NAME = oto` in both app configs (currently `AppIcon` :460,:492). Verify `icon.json` is valid for this Xcode version before committing; if it is not, leave the existing `AppIcon` asset set and report why.
- Add the 18×18 menubar SVG (the inline asset / `Flower_o_Vector.svg` scaled) to `Assets.xcassets` as a template image set; change `OtoApp.swift:287` from `Image(systemName: "waveform")` to the named template image with `.renderingMode(.template)`, keeping the accessibility label.
- Do **not** touch `OtoMarkSource` (onboarding hero) — it is a separate mark.

## 5. Verification

1. `xcodebuild -scheme Oto -destination 'platform=macOS' build` (Debug) and a Release build to prove `#if DEBUG` gates compile both ways.
2. `xcodebuild test -scheme Oto -destination 'platform=macOS'` (full suite); targeted: `MediaDuckTests`, `FeedbackSoundsTests`, `FlowBar/FlowBarControllerTests`, `OnboardingStageTests`, storage tests.
3. Grep gates: no unguarded probe symbols; `INFOPLIST_KEY_*` values correct in both configs.
4. Manual in a packaged, signed `.app` (TCC/shortcuts are invalid from a raw executable):
   - Hold-to-talk, speak, release → stop tone audible; media resumes at release (stop-tone regression).
   - Trigger each failure deliberately (deny mic, kill target, no text field, empty audio) → short pill message or permission card, and a failure row in the menu with Settings.
   - Onboarding last chapter with grants missing → Finish requests the missing grant and never completes; with both granted → Finish works.
   - Force a persistence write failure (read-only support dir in a debug scratch copy) → pane banner appears, in-memory edits retained.
5. Confirm no regression in reduced-motion / drag (the `.message` override reuses the existing latch path).

## 6. Risks / deferred

- Pill latch priority: if an over-limit auto-copy and a failure land in the same poll, over-limit wins; documented in code, tested.
- Menu status reads `lastSessionSummary()` on activation; if a menu is opened without app activation, the row may be one event stale. Acceptable; it refreshes on the next activation.
- `#if DEBUG` around `CleanSlate`/`AXDump` means those dev launch arguments are inert in Release — intended.
- Persistence banner reports the failed *write*; it cannot guarantee the in-memory edits survive a relaunch. Copy says "changes couldn't be saved" without promising durability.
- Icon Composer `.icon` compatibility with Xcode 27 must be verified (see Task F); if invalid, keep `AppIcon` untouched.
- Bundle ID, distribution/signing, Settings IA, test-defaults isolation: deferred per the notes.

## 7. Open questions

1. **Icons**: the inline 18×18 SVG and `~/Downloads/oto.icon` are present. Confirm Task F should apply both in this batch (app icon + menu bar), or only supply/store the assets for now. I will not overwrite the onboarding mark.
2. **Menu row**: confirm the durable menu failure row is wanted in addition to the transient pill message (the notes mention both; the pill alone is a transient 3 s surface).
