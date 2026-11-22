# Onboarding: drop Permissions & Shortcut, add Apple Intelligence & Dictionary

## Goal

The walk tells the product's story, not its paperwork:

1. **Welcome** — unchanged.
2. **What Oto does** — unchanged.
3. **Nothing gets lost** (catcher) — unchanged.
4. **NEW: Apple Intelligence** — what Oto does to the words after they land
   (Auto Cleanup + Transforms), on device.
5. **NEW: Dictionary** — teach Oto the words only you use.
6. **Try it** — unchanged in intent, but now: "Hold Right ⌥ and speak", the
   field takes focus, and macOS's own Accessibility/microphone dialogs do the
   asking. No custom permission UI anywhere in the app's onboarding.

The shortcut chapter goes away because the default (`Right ⌥`) is the point,
and a reader who wants another key finds it in Settings → Dictation. The
permissions chapter goes away because a custom allow/deny table is the exact
kind of bespoke TCC surface the product rules forbid.

## Spec sources

- `Docs/START_HERE_PRODUCT.md` — product boundary, Settings IA. Settings owns
  availability/toggles; onboarding shows the product.
- `AGENTS.md` — plan-before-execute; Apple docs as truth; native `Settings`
  scene is the only settings surface.
- Apple:
  - `AXIsProcessTrustedWithOptions` + `kAXTrustedCheckOptionPrompt`
    (ApplicationServices; header verified in `MacOSX27.0.sdk`).
  - `AVAudioApplication.requestRecordPermission` (AVFoundation; header
    verified in `MacOSX27.0.sdk`).
  - Human Interface Guidelines: ask for access in context, never speculatively
    at launch.
- Local code read in full:
  - `Oto/Onboarding/{OnboardingStage,OnboardingFlow,OnboardingChapters,
    OnboardingPlates,OnboardingView,OtoProbe,OnboardingStore,OnboardingTheme}.swift`
  - `Oto/Coordinator/DictationCoordinator.swift` (prepare path, mic gate)
  - `Oto/Support/PermissionsManager.swift`
  - `Oto/Settings/{SettingsUIState,IntelligencePane,DictionaryPane,
    ShortcutRecorderField}.swift`
  - `Oto/Services/{ShortcutDispatch,HIDEventMonitor,WritingPolishService}.swift`
  - `OtoTests/OnboardingStageTests.swift`, `OtoTests/DictationCoordinatorTests.swift`
  - `OtoUITests/SettingsUITests.swift`

## Facts verified against the code (not memory)

- `OnboardingStage.Step` is `Int: CaseIterable` with raw order
  `welcome 0, how 1, catcher 2, shortcut 3, permissions 4, tryIt 5, handoff 6`.
  Resume persists `rawValue`; replacing `shortcut`→`intelligence` and
  `permissions`→`dictionary` **in place** keeps raw 3/4 meaning "the middle of
  the walk", so no persisted resume lands on a wrong page.
- `OnboardingFlow` currently owns `fnUsage`, `reloadHold()`,
  `grantMicrophone()`, `openMicrophoneSettings()`, `openAccessibility()` and
  `prepareSpeechInBackground()`. Only the two plates being deleted call the
  first five. `prepareSpeechInBackground()` is called only from
  `OnboardingPermissionsPlate.task`.
- The global hold uses `CGEvent.tapCreate(.cghidEventTap, …)`
  (`HIDEventMonitor`), which fails without Accessibility, and
  `RealTextInsertion` refuses when `CGPreflightPostEventAccess()` is false.
  **The try-it cannot work before AX is granted**, so AX must be prompted
  before the reader presses the key.
- `ShortcutDispatch.refreshAvailability()` re-registers the tap after trust
  changes; it is safe to call repeatedly and never rebuilds mid-hold.
- `DictationCoordinator.runPreparation` currently reads
  `PermissionsManager().microphoneStatus() == .denied` and fails with
  `.microphoneDenied`; when status is `.notDetermined` it proceeds and the
  prompt only appears later inside `AppleSpeechService.prepare()` — i.e. after
  `audio.start()`. Ordering the prompt before `audio.start()` is a real change.
- `PermissionsManager.ensureMicrophone()` = granted → true, denied → false,
  notDetermined → `requestMicrophone()` (the native TCC dialog).
- `AXIsProcessTrustedWithOptions([axPromptKey: true])` shows Apple's own
  "Open System Settings" alert and no-ops when already trusted.
- `KeyNames.shortLabel(for: .modifierHold(kVK_RightOption))` → `"Right ⌥"`.
- `SettingsUIState.axTrusted`, `.micPermission`, `.refreshPermissions()` are
  synchronous; `.ensureMicrophoneGrant()` is `async` and just forwards to
  `ensureMicrophone()`.
- `TransformPreset` cases are `polish`, `concise`, `professional`, `custom`
  with display names "Polish", "Concise", "Professional", custom name.
- `OnboardingTheme` already provides `card`, `cardEdge`, `field`, `fieldEdge`,
  `divider`, `tagIdle`, `ink`, `muted`, `faint`. No new tokens needed.
- `OnboardingTryPlate`'s `TextEditor` is not focused today; the onboarding
  window is key, and the FlowBar panel is nonactivating, so focus survives a
  dictation — but only if something focuses the editor first.
- The UI test finishes onboarding by clicking Continue until a "Finish"
  button exists; it does not pass launch arguments today.

## Design

### Chapter 4 — Apple Intelligence (`.intelligence`)

Left copy:
- tag: `Apple Intelligence`, symbol `sparkles`
- title: **"Tidied as you speak"**
- subtitle: "Auto Cleanup drops the filler, Transforms rewrite what you
  select. Both run on this Mac."

Right media (a still showcase, no toggle — the switch lives in Settings →
Intelligence):
- Card: header row `sparkles` + "Auto Cleanup" + quiet pill "Light".
- Before line, struck/muted: "um, so yeah — I think we should, uh, ship it Friday"
- After line, ink: "I think we should ship it Friday."
- Divider, then a row "Transforms" with three small chips: Polish, Concise,
  Professional.
- Muted footnote: "On-device. Nothing leaves this Mac."

### Chapter 5 — Dictionary (`.dictionary`)

Left copy:
- tag: `Dictionary`, symbol `character.book.closed`
- title: **"Say it your way"**
- subtitle: "Teach Oto the names and jargon only you use — spoken form in, the
  right words out."

Right media:
- Card with three rule rows, spoken (muted) → replacement (ink):
  - `kube control` → `kubectl`
  - `jason` → `JSON`
  - `dan cubed` → `Dan Cubed`
- Muted footnote: "Applies in every app, every time you dictate."

Both plates `.accessibilityHidden(true)`, like the other previews.

### Chapter 6 — Try it

- Copy subtitle: `"Hold \(KeyNames.shortLabel(for: flow.holdKind)) and speak into the field. This is the whole product."`
  (`Right ⌥` by default; always the live hold key.)
- Plate header: `"Hold Right ⌥ and speak"` — same source, so it can never drift.
- The `TextEditor` takes focus when the chapter appears (short delay so the
  transition has settled), so the pasted transcript lands in it.
- No controls. If something is genuinely denied, one muted line explains where
  to fix it (text only, never a custom grant button):
  - AX untrusted → "If the key does nothing, allow Oto in System Settings →
    Privacy & Security → Accessibility."
  - mic denied → "Allow the microphone in System Settings → Privacy &
    Security → Microphone."
  - otherwise no line at all.

### Permission timing

On first arrival at `.tryIt` (`prepareTrial()`, idempotent per walk):

1. `prepareSpeechInBackground()` (moved from the deleted permissions plate).
2. If AX untrusted: `uiState.requestAccessibilityPrompt()` → Apple's alert.
3. `dispatch.refreshAvailability()` so a grant already made takes effect.
4. After ~0.9 s (the AX alert must not race it): `uiState.ensureMicrophoneGrant()`
   → the native mic dialog, only when `.notDetermined`. Then refresh status.

Suppressed entirely under `OTO_SHOT`, `-OtoUITest`, and XCTest, so neither
screenshot probes nor the UI test can hang on a TCC dialog.

`OnboardingView`'s `didBecomeActive` handler additionally calls
`dispatch.refreshAvailability()` and (when on `.tryIt`, guarded) `prepareTrial()`
so returning from System Settings heals the tap without a re-prompt.

## Exact file changes

### 1. `Oto/Onboarding/OnboardingStage.swift`

- Rename cases in place (raw values must not move):
  ```swift
  /// Shown: what Oto does to the words after they land — Auto Cleanup and
  /// Transforms, on device. Settings owns the switch.
  case intelligence            // raw 3, was .shortcut
  /// Shown: the dictionary — spoken form in, the person's own words out.
  case dictionary              // raw 4, was .permissions
  ```
- `static let chapters: [Step] = [.how, .catcher, .intelligence, .dictionary, .tryIt]`

### 2. `Oto/Onboarding/OnboardingChapters.swift`

- `OnboardingChapterCopy.copy(for:holdLabel:)` — new optional `holdLabel`
  parameter (default nil); `.tryIt` subtitle uses it with the fallback
  "your key".
- Replace the `.shortcut` / `.permissions` copy cases with `.intelligence` /
  `.dictionary` (copy above).
- `thing(for:)`: `.shortcut` → `OnboardingIntelligencePlate()`,
  `.permissions` → `OnboardingDictionaryPlate()`.
- Where copy is built, pass `KeyNames.shortLabel(for: self.flow.holdKind)`.

### 3. `Oto/Onboarding/OnboardingPlates.swift`

- Delete `OnboardingShortcutPlate` and `OnboardingPermissionsPlate` whole.
- Drop the now-unused `ApplicationServices`, `Carbon.HIToolbox`, `Speech`
  imports (verify by compile; keep `SwiftUI` and anything still referenced).
- Add `OnboardingIntelligencePlate` and `OnboardingDictionaryPlate` (both
  `OnboardingPreviewPlate(width: 390, height: 300)`, card styled from
  `OnboardingTheme`).
- `OnboardingTryPlate`:
  - `@FocusState private var fieldFocused: Bool` on the `TextEditor`,
    `.onAppear { Task { try? await Task.sleep(for: .milliseconds(250)); fieldFocused = true } }`.
  - Header text from `KeyNames.shortLabel(for: self.flow.holdKind)`.
  - `.onAppear { self.flow.prepareTrial() }`.
  - Conditional muted hint line (AX / mic denied), text only.
- File header comment updated: no permission rows, no recorder.

### 4. `Oto/Onboarding/OnboardingFlow.swift`

- Remove `fnUsage` + its read in `load()`, `reloadHold()`,
  `grantMicrophone()`, `openMicrophoneSettings()`, `openAccessibility()`.
- `buttonTitle`: `case .welcome, .how, .catcher, .intelligence, .dictionary: "Continue"`.
- `next()`: `catcher → intelligence → dictionary → tryIt`;
  `back()` mirrors it.
- Keep `prepareSpeechInBackground()`.
- Add:
  ```swift
  /// One-shot per walk: re-entering the chapter never re-prompts.
  private var trialPrepared = false

  func prepareTrial() { … }   // steps 1–4 above
  private static var suppressesNativePrompts: Bool { … }
  ```

### 5. `Oto/Onboarding/OnboardingView.swift`

- Extend the `didBecomeActive` handler:
  `refreshPermissions()` + `dispatch.refreshAvailability()` +
  `if stage.step == .tryIt { flow.prepareTrial() }`.

### 6. `Oto/Coordinator/DictationCoordinator.swift`

- Replace the `.denied`-only gate with an explicit "may capture" gate that
  asks first:
  ```swift
  private let microphoneAccessOverride: (@Sendable () async -> Bool)?
  ```
  Default path: `await PermissionsManager().ensureMicrophone()` (granted → true,
  denied → false, notDetermined → native prompt). Failure keeps
  `.microphoneDenied`, but now happens **before** `audio.start()`.
- Remove `micDeniedOverride`; update its 12 test call sites mechanically
  (`{ false }` → `{ true }`, `{ micDenied }` → `{ !micDenied }`).

### 7. `Oto/Onboarding/OtoProbe.swift`

- Line ~152: `[.how, .catcher, .intelligence, .dictionary, .tryIt]`.

### 8. Tests

- `OtoTests/OnboardingStageTests.swift`
  - line 27: chapters list.
  - line 64/70: `.permissions` → `.dictionary`.
  - New: raw values are stable — `Step(rawValue: 3) == .intelligence`,
    `Step(rawValue: 4) == .dictionary` (protects persisted resume).
- `OtoTests/DictationCoordinatorTests.swift`
  - Existing denied test updated to the new closure.
  - New: a `.denied` override fails with `.microphoneDenied` and
    `FakeAudioCapture` never started.
  - New: an override that returns false after a delay is awaited before
    `audio.start()` (assert start was never called).
- `OtoUITests/SettingsUITests.swift`
  - `app.launchArguments += ["-OtoUITest"]` in `testSettingsOpensAsOneNativeWindow`.
  - Update the walk comment (no shortcut/permissions chapters; AI +
    dictionary instead).

### 9. Not touched

- `plan/onboarding-tourkit-remake.md` stays as historical analysis.
- `Docs/` untouched.
- Settings panes (`IntelligencePane`, `DictionaryPane`) untouched — the
  chapters only point at them.

## Verification

1. `xcodebuild -scheme Oto -destination 'platform=macOS' build`.
2. `xcodebuild test -scheme Oto -destination 'platform=macOS'` (unit).
3. Screenshot probe:
   `OTO_SHOT=$PWD/.context/onboard-ai-dictation ./build/.../Oto.app/Contents/MacOS/Oto`
   — inspect `intelligence`, `dictionary`, `tryIt` in both appearances.
   Confirm the tag pill is readable (the older opaque-pill capture may have been
   a `cacheDisplay` artifact; check live).
4. UI test on the packaged app (onboarding walk with `-OtoUITest`).
5. Manual, signed `.app`, fresh defaults domain:
   - Launch → walk to Try it → Apple's Accessibility alert appears once.
   - Mic dialog appears once, after AX.
   - Allow both → focus the field, hold Right ⌥, speak, release → text lands
     in the onboarding field.
   - Deny mic → the muted hint line appears; no custom button anywhere.
   - Quit mid-walk and relaunch → resumes on the same chapter.
   - Re-enter Try it (Back → Continue) → no second prompt.

## Risks / deferred decisions

- **Prompting on chapter appearance** is one step earlier than "on the user's
  action". Justification: without AX the hold key is dead, so the chapter would
  otherwise be a fake demo. Mitigation: the coordinator gate re-asks only when
  still `.notDetermined`; the UI never draws its own grant control.
- **Dismissed AX alert**: macOS shows it once per launch (TCC remembers the
  denial). The text-only hint is the only recovery path offered; Settings →
  Privacy remains the real one. If the user rejects even that line, the hint
  is a one-line deletion.
- **Auto-focus** relies on the onboarding window being key when the chapter
  appears; if the FlowBar or a TCC dialog takes key, focus returns on the
  `didBecomeActive` pass only because the plate is re-created — otherwise the
  reader clicks the field (it is a real editor).
- **Async override** changes a `@Sendable` closure type in 12 test call sites;
  mechanical, compiler-checked.

## Open questions

1. Bump `OnboardingStore.current` to 2 so existing installs see the new
   chapters once? Default: **no bump** (renaming in place keeps resume honest;
   a bump would re-nag every existing walk). Say the word if you want the bump.
2. Keep the text-only "allow it in System Settings" hint on Try it? Default:
   **keep** — it is copy, not a control; deleting it leaves a silent dead key
   after a denied prompt.
