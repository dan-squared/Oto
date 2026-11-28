# Productivity Pack Polish — Download Progress + Cancel, Clean Language Labels, Menu Bar Cleanup, Message Pill Width Fix

Status: **implemented & verified (785/785 unit tests green, grep gates passed, packaged Oto.app relaunched).**

## 1. Goal

Resolve four live-app polish issues spotted right after running the Productivity Pack build:

1. **Speech Model Download Progress + Cancel Button:** Yes — clicking `"Not prepared"` downloads Apple's on-device speech asset for the chosen language via `AssetInventory.assetInstallationRequest(supporting:)`. Replace the plain static `"Preparing…"` pill in `DictationPane` with a compact inline **circular progress ring** (showing real `Foundation.Progress.fractionCompleted` or spinning indeterminate ring while starting) plus a small **Cancel** button that cancels the active Apple asset download.
2. **Remove "Continue setup…" / "Show onboarding…" from the Menu Bar:** Remove the onboarding row from `OtoMenuBarView` to keep the menu bar minimal (first-run auto-show in `DockRestoreDelegate` and DEBUG probes remain intact).
3. **Fix `"Speech unavaila…"` Pill Truncation:** Fix the `.message` layout path in `PillLayers.swift` and `VisualizerMath.swift` so transient failure notices like `"Speech unavailable"` render completely with balanced capsule padding instead of ellipsizing.
4. **Clean Language List Naming (No User Country Suffix like `"Region=Ethiopia"`):** Strip Unicode regional extensions (`-u-rg-...`) when formatting locale names, use concise regional indicators (`English (US)`, `English (UK)`, etc.), omit redundant regions for single-variant languages (`Japanese`, `Korean`, `Hindi`), and display the resolved speech locale (never raw `Locale.current` with `-u-rg-etzzzz`) on the `"System"` row and `languageText`.

---

## 2. Facts Verified Against Local SDK & Codebase

- **`Speech.AssetInstallationRequest`** (`MacOSX27.2.sdk`, `arm64e-apple-macos.swiftinterface:509-514`):
  - Conforms to `Foundation.ProgressReporting` with `public var progress: Foundation.Progress { get }`.
  - `downloadAndInstall() async throws` can be cancelled via `request.progress.cancel()` inside `withTaskCancellationHandler`.
- **Root cause of `"English (United States, Region=Ethiopia)"`:**
  - Verified on this Mac: `SpeechTranscriber.supportedLocales` returns 45 clean locales (`en-US`, `en-GB`, `en-AU`, `en-CA`, `en-IE`, `en-IN`, `en-NZ`, `en-SG`, `en-ZA`, `es-ES`, `es-MX`, `ja-JP`, `ko-KR`, etc.), while `Locale.current` on a Mac with language English (US) and country Ethiopia serializes as `en-US-u-rg-etzzzz`.
  - `SpeechLocalePreference.displayName(for:)` passed `locale.identifier(.bcp47)` verbatim into `displayLocale.localizedString(forIdentifier:)`, which renders the `-u-rg-etzzzz` extension as `", Region=Ethiopia"`.
  - Building display names from `locale.language.languageCode` + `locale.language.region` (ignoring `-u-rg-...` extensions) eliminates the user's country suffix everywhere.
- **Root cause of `"Speech unavaila…"` truncation in Flow Bar pill:**
  - In `VisualizerMath.swift:133-136`, `messagePillWidth` uses `workPadding * 2 + workTextSlack` (`8.25 * 2 + 6 = 22.5 pt`) — narrower than the capsule's rounded end-caps (`13.2 pt` radius each).
  - In `PillLayers.swift:794-807`, the `.message` layout branch uses raw `label.sizeToFit()` without `usesSingleLineMode = true` and without `workTextSlack` (unlike `.work` at lines 814–827, which explicitly adds `workTextSlack` to prevent exact-fit AppKit `NSTextField` ellipsizing).

---

## 3. Exact File Changes

### A. Circular Download Progress + Cancel
- **`Oto/Services/SpeechAssetPreparer.swift`:**
  - Extend `prepare(locale:onProgress:)` and `prepareDefault(onProgress:)` with an optional `onProgress: (@Sendable (Double?) -> Void)? = nil` (default `nil` keeps `OnboardingFlow` and all existing callers unchanged).
  - Observe `request.progress.observe(\.fractionCompleted, options: [.initial, .new])` while `downloadAndInstall()` runs (reporting `nil` while `isIndeterminate` or `<= 0`, else `0.0...1.0`), invalidating the KVO token in `defer`.
  - Wrap `try await request.downloadAndInstall()` in `withTaskCancellationHandler` calling `request.progress.cancel()` on cancel.
  - Detect cancellation (`Task.isCancelled`, `CancellationError`, or `CocoaError.userCancelled`) and return a dedicated `nil`/cancelled result cleanly without logging an error.
  - `downloadAndInstall()` remains strictly inside `SpeechAssetPreparer.swift` only.
- **`Oto/Settings/SettingsUIState.swift`:**
  - Add `var prepareProgress: Double? = nil` and `private var prepareTask: Task<Void, Never>?`.
  - Update `runPrepare()` to guard `!isPreparing`, track `prepareTask`, stream `prepareProgress` updates onto `@MainActor`, clear `prepareProgress` and `prepareTask` in `defer`, and skip stale feedback if cancelled or locale changed.
  - Add `func cancelPrepare()` to cancel `prepareTask`, clear `prepareFeedback`, and let the row return cleanly to `"Not prepared"`.
- **`Oto/UI/Theme/OtoControls.swift` & `Oto/Settings/DictationPane.swift`:**
  - Add a compact, native-styled `OtoProgressStatus` capsule (matching `OtoStatusFace` height, `OtoPalette.wash` background, and typography):
    - Small 14×14 pt circular progress ring (determinate smooth stroke arc when `progress != nil`, or mini `ProgressView` while connecting/indeterminate) + concise label (`"42%"` or `"Preparing…"`).
    - Inline small cancel icon button (`xmark.circle.fill`, `.plain`, `.help("Cancel download")`, `.accessibilityLabel("Cancel download")`) calling `uiState.cancelPrepare()`.
  - Use it in `DictationPane`'s `Readiness` row when `uiState.isPreparing`.

### B. Remove "Continue setup…" / "Show onboarding…" from Menu Bar
- **`Oto/UI/OtoMenuBarView.swift`:**
  - Remove the `Continue setup…` / `Show onboarding…` button, unused `@AppStorage(OnboardingStore.key)`, and unused `onboarding` property.
- **`Oto/App/OtoApp.swift`:**
  - Remove the `onboarding:` argument from `OtoMenuBarView(...)` construction (first-run onboarding in `DockRestoreDelegate` and `#if DEBUG` probes remain untouched).

### C. Fix `"Speech unavaila…"` Pill Truncation
- **`Oto/UI/FlowBar/VisualizerMath.swift`:**
  - Add `nonisolated static let messagePadding: CGFloat = dictationInset` (`12.375 pt`, matching the pill's optical side air inside the `13.2 pt` capsule end-caps).
  - Update `messagePillWidth(textWidth:)` to `min(messageMaxWidth, max(dictationWidth, ceil(textWidth) + messagePadding * 2 + workTextSlack))`.
- **`Oto/UI/FlowBar/PillLayers.swift`:**
  - Set `label.usesSingleLineMode = true` in `init` so AppKit never wraps or under-sizes single-line pill labels.
  - In the `.message` branch of `update(...)`, compute `let measured = ceil(VisualizerMath.measureWorkText(label.stringValue)) + VisualizerMath.workTextSlack`, size `f.size.width = min(max(label.fittingSize.width, measured), max(0, currentWidth - VisualizerMath.messagePadding * 2))`, and center horizontally within `currentWidth`.
  - Expose `messageLayoutFrame() -> CGRect` test hook for headless verification.

### D. Clean Language List Labels
- **`Oto/Support/SpeechLocalePreference.swift`:**
  - Add `displayName(for locale: Locale, includeRegion: Bool = true, in displayLocale: Locale = .current) -> String`:
    - Builds strictly from `locale.language.languageCode?.identifier` and `locale.language.region?.identifier` (never from raw `.identifier(.bcp47)` with `-u-rg-...` extensions).
    - Uses concise regional indicators (`"US"` → `"US"`, `"GB"` → `"UK"`, otherwise `displayLocale.localizedString(forRegionCode:)`).
    - Handles `"mul"` cleanly (`"Multilingual"`).
    - When `includeRegion == false` (single-variant languages like `ja-JP`, `ko-KR`, `hi-IN`), returns just the language name (`"Japanese"`, `"Korean"`, `"Hindi"`).
  - Add `displayNames(for locales: [Locale], in displayLocale: Locale = .current) -> [String: String]` (keyed by BCP-47 tag) that automatically sets `includeRegion = true` ONLY for language codes that appear more than once in `locales`, and `false` for single-variant languages.
  - Update `dedupedSortedLocales` to sort by those clean display names.
- **`Oto/Settings/SettingsUIState.swift`, `Oto/Settings/DictationPane.swift`, `Oto/UI/OtoMenuBarView.swift`:**
  - `DictationPane` `"System"` row shows `"System (\(resolvedName))"` using `SpeechLocaleMatching.bestMatch(for: .current, in: uiState.supportedLocales)` (or plain `"System"` before locales load) — never raw `Locale.current` with `-u-rg-etzzzz`.
  - `DictationPane` and `OtoMenuBarView` use the clean regionalized names (`English (US)`, `English (UK)`, `Japanese`, etc.).
  - `SettingsUIState.languageText` displays the resolved speech locale's clean name (e.g. `"English (US)"`), never `"Region=Ethiopia"`.

### E. Tests
- **`OtoTests/SpeechLocalePreferenceTests.swift`:**
  - Verify `en-US-u-rg-etzzzz` and `en-ET` never include `"Ethiopia"` or `"Region="`; verify `en-US` → `"English (US)"`, `en-GB` → `"English (UK)"`; verify single-variant languages omit redundant country (`ja-JP` → `"Japanese"`), while multi-variant languages keep concise regions.
- **`OtoTests/FlowBar/PillLayersTests.swift` & `OtoTests/FlowBar/VisualizerMathTests.swift`:**
  - Assert `"Speech unavailable"` and every `failurePillText` string fits inside `messagePillWidth` with `labelFrame.width >= ceil(measureWorkText(text)) + workTextSlack` and `labelFrame.minX >= 0 && labelFrame.maxX <= width`.
- **`OtoTests/SettingsUIStateTests.swift`:**
  - Verify initial `prepareProgress == nil` and `cancelPrepare()` resets cleanly.

---

## 4. Verification Steps

1. `xcodebuild test -scheme Oto -destination 'platform=macOS' -only-testing:OtoTests` — all unit tests green, 0 warnings.
2. Grep gate: `downloadAndInstall` appears ONLY in `Oto/Services/SpeechAssetPreparer.swift`.
3. Rebuild and relaunch packaged `Oto.app` so you can visually confirm the menu bar, clean language picker, circular progress + cancel button, and un-truncated `"Speech unavailable"` pill.

---

## 5. Risks & Open Questions

- **None blocking:** Apple's `AssetInstallationRequest.progress` sometimes reports indeterminate (`0%`) briefly while negotiating with the asset daemon before ticking up smoothly — our mini spinner → circular progress ring transition handles both states seamlessly.
