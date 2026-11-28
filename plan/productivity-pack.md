# Productivity Pack — Per-App Auto Cleanup, Dictation Language Picker, Fast Snippets, History Search & Last-Dictation Copy

Status: **implemented & verified (780/780 unit tests green, Gemini 4 Neon audit + fixes applied).**

## User Decisions Recorded
1. **Per-App Auto Cleanup:** Support `Off / Light / Medium / Custom` per app, where `Custom` lets the user enter an optional app-specific prompt/instruction (with quick starter presets like Casual chat, Formal email, Bullet points for ease of use; hidden unless `Custom` is selected).
2. **Menu Bar Minimalism:** Keep `OtoMenuBarView` uncluttered — `"Copy Last Dictation"` appears only when a transcript exists in memory, `Language ▸` appears only when 2+ languages are installed, and `Snippets ▸` appears only when ≥1 snippet exists.

## 1. Goal

Ship four high-leverage, low-risk quality-of-life features that build directly on Oto's existing seams without polluting the core dictation state machine or adding new sidebar panes:

1. **Per-App Auto Cleanup:** Override Auto Cleanup level (`None` / `Light` / `Medium`) per target app while keeping the global default and master Apple Intelligence switch honest.
2. **Dictation Language Picker + Menu Bar Quick Switcher:** Replace hardcoded `Locale.current` with an explicit language preference (`System` default or any supported `SpeechTranscriber` locale), with readiness/download via the existing Settings prepare flow and a conditional Menu Bar switcher when 2+ languages are installed.
3. **Fast Snippets (Opt-In Exact-Match Voice Trigger + Menu Bar Quick Copy):** Make the existing Snippets pane fast to use in daily work via an opt-in, exact-utterance voice trigger (honoring each snippet's existing `bundleIDs` scope and bypassing Auto Cleanup on hit) plus a conditional `Snippets ▸` Menu Bar submenu.
4. **History Search + "Copy Last Dictation" in Menu Bar:** Add live multi-word search to `HistoryPane` (matching final text, raw text, and app display name) and a 1-click `"Copy Last Dictation"` action in `OtoMenuBarView` backed by an in-memory-only `lastTranscript` on `DictationCoordinator`.

Explicitly **out of scope**: Spoken Voice Commands on Selected Text ("Voice Transform") and live in-field streaming transcription.

---

## 2. Spec Sources & Existing Codebase References

- `AGENTS.md` — single `DictationCoordinator` owns session state; Apple Speech is the only transcription path; never download on shortcut press (`downloadAndInstall` grep gate in `SpeechAssetPreparer` only); `SystemLanguageModel` only; one native `Settings` scene + `MenuBarExtra`.
- Per-App Cleanup seams:
  - `Oto/Services/WritingPolishService.swift` (`CleanupBehavior`, `CleanupSettings`, `CleanupLevel`, `LivePolishService`)
  - `Oto/Settings/IntelligencePane.swift` (Auto Cleanup card)
  - `Oto/Settings/AppScopePicker.swift` & `Oto/Support/InstalledApps.swift` (app chooser patterns)
  - `Oto/Coordinator/DictationCoordinator.swift` (`prewarmForSession()`, `cleanedText(_:sessionID:)`)
- Language Picker seams:
  - `Oto/Services/AppleSpeechService.swift` (`prepare()`, locale resolution)
  - `Oto/Services/SpeechAssetPreparer.swift` (`status(locale:)`, `prepare(locale:)`, `reserveLocale(_:)`)
  - `Oto/Support/LocaleSnapshotCache.swift` (`resolve(current:now:)`, `invalidate()`)
  - `Oto/Settings/SettingsUIState.swift` (`refreshSpeech()`, `runPrepare()`)
  - `Oto/Settings/DictationPane.swift` (`Speech` section)
- Fast Snippets seams:
  - `Oto/Storage/SnippetStore.swift` (`Snippet`, `SnippetStore`)
  - `Oto/Services/TranscriptPipeline.swift` (`process(_:for:)`)
  - `Oto/Settings/SnippetsPane.swift`, `Oto/Settings/SettingsRoot.swift`
  - `OtoTests/Storage/SnippetStoreTests.swift` (notably `v1SchemaHasNoTriggerKey` at lines 112–125)
- History Search & Copy Last Dictation seams:
  - `Oto/Storage/HistoryPage.swift`, `Oto/Storage/HistoryStore.swift`, `Oto/Settings/HistoryPane.swift`
  - `Oto/UI/OtoMenuBarView.swift`, `Oto/Services/PasteboardOwnership.swift` (`ClipboardWrite`), `Oto/App/OtoApp.swift`

---

## 3. Facts Verified Against Local SDK & Codebase

Verified against local SDK `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.2.sdk`:

- `Speech.framework` (`arm64e-apple-macos.swiftinterface`):
  - `SpeechTranscriber.supportedLocales: [Foundation.Locale] { get async }` (line 411)
  - `SpeechTranscriber.supportedLocale(equivalentTo:) async -> Foundation.Locale?` (line 414)
  - `SpeechTranscriber.installedLocales: [Foundation.Locale] { get async }` (line 415)
  - `AssetInventory.maximumReservedLocales: Int` (line 34), `reservedLocales` (line 37), `reserve(locale:)` (line 41), `release(reservedLocale:)` (line 43), `status(forModules:)` (line 56), `assetInstallationRequest(supporting:)` (line 57).
- `Oto.xcodeproj/project.pbxproj` uses `PBXFileSystemSynchronizedRootGroup` — new `.swift` files created under `Oto/` and `OtoTests/` are picked up automatically by Xcode without editing `project.pbxproj`.
- `SnippetStoreTests.v1SchemaHasNoTriggerKey` asserts that default/newly-added snippets encode only `["id", "name", "expansion", "bundleIDs"]` (or without `bundleIDs` when unscoped). Omitting `voiceTriggerEnabled` from JSON when `false` preserves byte-identical v1 serialization for all existing/non-voice snippets while allowing opt-in `voiceTriggerEnabled: true` to persist cleanly.
- `LocaleSnapshotCache.shared.invalidate()` already posts `.otoSpeechLocaleInvalidated` and clears the snapshot (`LocaleSnapshotCache.swift:128-131`).
- Orchestrator capabilities verified in this session:
  - Provider `antigravity` supports both `gemini-4-hydrogen` (implementation subagents) and `gemini-4-neon` (verification/review subagent).

---

## 4. Assumptions Questioned

1. **Per-app cleanup scope vs. duplicate-rule conflicts:** Storing per-app overrides as `[String: CleanupLevel]` keyed by lowercased bundle ID (instead of multi-app rules) guarantees at most one override per app by construction — zero precedence ambiguity.
2. **Global `None` + per-app `Light`/`Medium`:** When the master Apple Intelligence switch is ON, an explicit per-app override should win even if the global default is `None` (so a user can opt in *only* for Mail/Slack), while turning the master Apple Intelligence switch OFF disables cleanup everywhere unconditionally.
3. **Snippet exact-match safety & Auto Cleanup:** Ambient substring matching is banned (could leak private text mid-sentence). Only a **full-utterance exact match** (trimmed, case-insensitive, ignoring trailing `.!?,;:`) on a snippet with `voiceTriggerEnabled == true` AND matching `bundleIDs` (or global) may expand. On match, Auto Cleanup **must be skipped** so the LLM never rewrites saved URLs, emails, or signatures.
4. **Menu Bar minimalism:** `OtoMenuBarView` is intentionally tiny. Both `Language ▸` and `Snippets ▸` submenus must be **strictly conditional** (`Language ▸` only when ≥2 languages are installed; `Snippets ▸` only when ≥1 snippet exists) so users who don't use those features see zero added clutter.
5. **Privacy of "Copy Last Dictation":** `lastTranscript` is kept **in memory only** inside `DictationCoordinator` (never written to disk, cleared on quit — works even when History is OFF), and the menu item label is strictly `"Copy Last Dictation"` (never renders transcript text inside the dropdown).
6. **Language downloads:** Selecting an uninstalled language in Settings must **never** auto-download on selection or on shortcut press; it updates readiness so the existing `"Not prepared"` button lets the user explicitly download via `SpeechAssetPreparer`.

---

## 5. Exact File Changes (Split Into 4 Disjoint Workstreams + Integration)

### Workstream A — Per-App Auto Cleanup
- **Edit `Oto/Services/WritingPolishService.swift`:**
  - Add `CleanupSettings.appOverridesKey = "app.Oto.cleanupAppOverrides"`.
  - Add pure `CleanupAppOverrides` helper (load/save `[String: CleanupLevel]` normalized to lowercased bundle IDs, `set(_:forBundleID:)`, `remove(bundleID:)`, `sortedOverrides()`).
  - Add `CleanupBehavior.effective(for bundleID: String?, defaults: UserDefaults = .standard) -> CleanupBehavior` (returns `enabled: false, level: .none` when master switch off; otherwise override for `bundleID` if present, else global level).
- **Edit `Oto/Settings/IntelligencePane.swift`:**
  - Under the `Auto Cleanup` section (when Apple Intelligence is enabled), add a clean `App Overrides` list showing each overridden app (name + segmented/menu `Off / Light / Medium` + remove trash button) and an `"Add App Override…"` popover using `InstalledApps` search (matching `AppScopePicker.swift` styling).
  - Keep it lightweight and collapsed cleanly when empty (single `"Add App Override…"` button + short note like `"Override cleanup for specific apps, e.g. Off in Terminal or Medium in Mail."`).
- **New `OtoTests/PerAppCleanupTests.swift`:**
  - Unit tests covering master-off override suppression, global fallback, case-insensitive bundle ID lookup, override winning over global `None`, add/update/remove round-trip with isolated `UserDefaults`.

### Workstream B — Dictation Language Picker + Quick Switcher
- **New `Oto/Support/SpeechLocalePreference.swift`:**
  - `UserDefaults` key `app.Oto.speechLocaleIdentifier` (`String?`; `nil` / empty = System language).
  - Pure `selectedIdentifier(defaults:)`, `setSelectedIdentifier(_:defaults:)` (invalidates `LocaleSnapshotCache.shared` on change), `effectiveLocale(system:defaults:) -> Locale`, and `displayName(for locale: Locale) -> String` (e.g. `"English (United States)"`).
- **Edit `Oto/Services/AppleSpeechService.swift`:**
  - Read `let targetLocale = SpeechLocalePreference.effectiveLocale()` instead of `.current`; pass `current: targetLocale` into `LocaleSnapshotCache.shared.resolve(current: targetLocale)` and `SpeechLocaleMatching.bestMatch(for: targetLocale, in: supported)`.
- **Edit `Oto/Services/SpeechAssetPreparer.swift`:**
  - Update `status(locale:)` default and `prepareDefault()` to use `SpeechLocalePreference.effectiveLocale()`.
  - Add `availableLocales() async -> (supported: [Locale], installed: [Locale])` (read-only inspection, zero downloads).
- **Edit `Oto/Support/LocaleSnapshotCache.swift`:**
  - No breaking changes; verify `resolve(current:now:)` works cleanly with any passed locale (already accepts `current: Locale = .current`).
- **Edit `Oto/Settings/SettingsUIState.swift`:**
  - Publish `selectedLocaleIdentifier: String?`, `supportedLocales: [Locale]`, `installedLocaleIdentifiers: Set<String>`.
  - Populate in `refreshSpeech()`, update `languageText` honestly against the selected (or system) locale.
  - Add `selectLocale(_ identifier: String?)` which persists preference, invalidates `LocaleSnapshotCache`, and triggers `refreshSpeechInBackground()`.
  - Keep `runPrepare()` preparing `SpeechLocalePreference.effectiveLocale()`.
- **Edit `Oto/Settings/DictationPane.swift`:**
  - Add native `Picker("Language", selection: ...)` inside the existing `Speech` section (`System (<current>)` first, divider, then supported locales sorted by display name, annotating installed vs not-yet-downloaded cleanly if helpful).
- **New `OtoTests/SpeechLocalePreferenceTests.swift`:**
  - Tests for default `System` resolution, explicit BCP-47 override, invalidation notification `.otoSpeechLocaleInvalidated` posted on change, and `LocaleSnapshotCache.decide` with non-system locale.

### Workstream C — Fast Snippets (Exact-Match Voice Trigger + Menu Bar)
- **Edit `Oto/Storage/SnippetStore.swift`:**
  - Add `var voiceTriggerEnabled: Bool = false` to `Snippet`.
  - Update `CodingKeys` + tolerant `init(from:)` (`decodeIfPresent(Bool.self, forKey: .voiceTriggerEnabled) ?? false`).
  - In `encode(to:)`, encode `.voiceTriggerEnabled` **only when `true`** so default snippets remain byte-identical to v1 JSON.
  - Update `add(...)` overloads with defaulted `voiceTriggerEnabled: Bool = false`.
- **Edit `Oto/Services/TranscriptPipeline.swift`:**
  - Add `struct ProcessedTranscript: Equatable, Sendable { let text: String; let matchedSnippet: Bool }`.
  - Accept `snippets: [Snippet] = []` in `TranscriptPipeline.init(dictionaryRules:snippets:)`.
  - Add `processDetailed(_ raw: String, for target: TargetApplication) -> ProcessedTranscript`:
    - First check exact-utterance match against snippets with `voiceTriggerEnabled == true` and matching `bundleIDs` (via `DictionaryRule.scopeMatches`, empty = global): normalize spoken text by trimming whitespace/newlines and stripping trailing `.!?,;:`, compare `localizedCaseInsensitiveCompare` against normalized snippet name. If matched, prefer app-scoped over global on tie, return `ProcessedTranscript(text: snippet.expansion, matchedSnippet: true)`.
    - Otherwise run existing dictionary pipeline and return `ProcessedTranscript(text: result, matchedSnippet: false)`.
  - Keep `process(_ raw: String, for target: TargetApplication) -> String` delegating to `processDetailed(...).text` so all existing callers/tests remain source-compatible.
- **Edit `Oto/Settings/SnippetsPane.swift` & `Oto/Settings/SettingsRoot.swift`:**
  - Pass `coordinator: DictationCoordinator` to `SnippetsPane` (matching `DictionaryPane`).
  - Push `coordinator.setSnippets(snippets.snippets)` on add/edit/delete.
  - In `SnippetEditor`, add opt-in `Toggle("Expand when dictated alone", isOn: $voiceTriggerEnabled)` with brief footnote explaining exact-utterance matching and app scope.
  - Update the bottom `OtoPanelNote` in `SnippetsPane` to reflect opt-in exact-utterance expansion honestly.
  - Show a subtle microphone/waveform badge on rows where `voiceTriggerEnabled == true`.
- **Edit `OtoTests/Storage/SnippetStoreTests.swift` & New `OtoTests/SnippetTriggerTests.swift`:**
  - Keep `v1SchemaHasNoTriggerKey` green for default snippets; add test confirming `voiceTriggerEnabled: true` encodes/decodes and legacy JSON without the key decodes as `false`.
  - Test exact match, trailing punctuation (`"Calendar link."`), case insensitivity, non-match when embedded in a sentence (`"send my calendar link please"`), app-scope enforcement, and opt-out (`voiceTriggerEnabled == false`) never expanding.

### Workstream D — History Search
- **Edit `Oto/Storage/HistoryPage.swift`:**
  - Add pure `HistoryFilter.matches(_ entry: HistoryEntry, query: String) -> Bool` and `HistoryFilter.filter(_ entries: [HistoryEntry], query: String) -> [HistoryEntry]`:
    - Empty/whitespace query returns all entries unchanged.
    - Multi-word whitespace-split AND query (all tokens must match), case- and diacritic-insensitive (`localizedStandardContains`) across `entry.finalText`, `entry.rawText`, and `AppNames.displayName(forBundleID: entry.bundleIdentifier)`.
- **Edit `Oto/Settings/HistoryPane.swift`:**
  - Add `@State private var searchQuery = ""` and a compact capsule search bar matching the Settings sidebar search style above the history entries list (shown whenever `!history.entries.isEmpty`).
  - Derive `filteredEntries = HistoryFilter.filter(history.entries, query: searchQuery)`, paginate over `filteredEntries`, reset `historyPage = 1` when `searchQuery` changes, and show an honest `"No matching transcripts"` message + Clear Search button when filtered results are empty.
- **Edit `OtoTests/Storage/HistoryPageTests.swift`:**
  - Add unit tests for `HistoryFilter` (empty query, single word, multi-word AND, case/diacritic insensitivity, `rawText` match, app display name match, no matches).

### Integration Pass (Shared Glue Files)
- **Edit `Oto/Coordinator/DictationCoordinator.swift`:**
  - Update `behaviorProvider` closure type to `(@Sendable (String?) -> CleanupBehavior)?` (with convenience default / backward-compatible init overload or updated call sites so existing tests compile cleanly).
  - Pass `context.target.bundleIdentifier` in `prewarmForSession(for: target)` and `cleanedText(clean, target: context.target, sessionID: sessionID)`.
  - Add `setSnippets(_ snippets: [Snippet]) async` storing current snippet list and rebuilding `TranscriptPipeline(dictionaryRules:snippets:)`.
  - In `finalizeSession`, use `pipeline.processDetailed(raw, for: context.target)`. When `matchedSnippet == true`, skip `cleanedText(...)` and use `processed.text` directly.
  - Track in-memory `private(set) var lastTranscript: String?` updated whenever a non-empty finalized `final` transcript is produced (inserted, target-gone, no-text-field, or insertion-failed). Notify observers on change. Add `func lastTranscriptText() -> String?`.
- **Edit `Oto/App/OtoApp.swift`:**
  - Wire `behaviorProvider: { bundleID in CleanupBehavior.effective(for: bundleID) }`.
  - In the startup store-load Task (`OtoApp.swift:303-308`), also call `await coordinator.setSnippets(snippetStore.snippets)`.
  - Pass `snippetStore` and `settingsUIState` into `OtoMenuBarView`.
- **Edit `Oto/UI/OtoMenuBarView.swift`:**
  - Add `"Copy Last Dictation"` button (shown only when `lastTranscript != nil`; calls `ClipboardWrite.text(text)`). Never renders transcript words in the menu.
  - Add conditional `Menu("Language")` (shown only when `uiState.installedLocaleIdentifiers.count >= 2`) listing `"System"` + installed locales with a checkmark on the active one, calling `uiState.selectLocale(...)`.
  - Add conditional `Menu("Snippets")` (shown only when `!snippets.snippets.isEmpty`) listing snippets (capped/cleanly titled by `snippet.name`), clicking copies `snippet.expansion` via `ClipboardWrite.text`.
- **New `OtoTests/CoordinatorProductivityTests.swift`:**
  - Coordinator integration tests using existing fakes:
    - Per-app cleanup override (`Off` skips polish, `Medium` runs polish with `.cleanup(.medium)`).
    - Voice-triggered snippet expands verbatim and **skips** Auto Cleanup.
    - Non-voice snippet and mid-sentence snippet name do NOT expand.
    - `lastTranscriptText()` updates on completed and failed-insertion sessions, never on empty/cancelled sessions, even when History is OFF.

---

## 6. Subagent Execution & Review Plan

Upon user approval (`execute`):
1. **Wave 1 (Parallel implementation via `delegate_task`, model `antigravity` / `gemini-4-hydrogen`):**
   - 4 parallel children owning strictly disjoint files (Workstreams A, B, C, D).
2. **Wave 2 (Integration via `delegate_task`, model `antigravity` / `gemini-4-hydrogen`):**
   - Wire `DictationCoordinator.swift`, `OtoApp.swift`, `OtoMenuBarView.swift`, and `OtoTests/CoordinatorProductivityTests.swift`.
3. **Wave 3 (Build, Test, and Independent Review via `antigravity` / `gemini-4-neon`):**
   - Run `xcodebuild test -scheme Oto -destination 'platform=macOS'` and grep gates (`downloadAndInstall`, `PrivateCloudComputeLanguageModel`).
   - Spawn a `gemini-4-neon` review delegate to audit the full `git diff` for correctness, Swift 6 concurrency/Sendable safety, backward compatibility, privacy invariants, and UI cleanliness.
   - Fix any review findings and re-run build + full tests until 100% green.

---

## 7. Verification Steps

1. `xcodebuild -scheme Oto -destination 'platform=macOS' build` — 0 errors, 0 new warnings.
2. `xcodebuild test -scheme Oto -destination 'platform=macOS'` — all existing suites + new suites (`PerAppCleanupTests`, `SpeechLocalePreferenceTests`, `SnippetTriggerTests`, `CoordinatorProductivityTests`, updated `SnippetStoreTests` & `HistoryPageTests`) pass.
3. Grep gates:
   - `downloadAndInstall` appears ONLY in `Oto/Services/SpeechAssetPreparer.swift`.
   - `PrivateCloudComputeLanguageModel` appears nowhere.
4. Manual device checklist (packaged signed `.app`):
   - Per-app cleanup: set Global `Light`, Terminal `Off`, Mail `Medium`; verify Terminal inserts exact words and Mail polishes.
   - Language picker: switch to a second language in Dictation Settings → prepare → verify Menu Bar `Language ▸` appears and switches dictation language without relaunch.
   - Fast Snippets: enable voice trigger on a snippet scoped to Notes → dictate its exact name alone in Notes (expands verbatim, no AI rewrite) vs inside a sentence (does not expand) vs in another app (does not expand); verify Menu Bar `Snippets ▸` copies expansion.
   - History search & Copy Last Dictation: filter history by word and by app name; dictate with History OFF and verify `"Copy Last Dictation"` appears in Menu Bar and copies the transcript.

---

## 8. Risks & Deferred Decisions

- **Menu Bar SwiftUI `MenuBarExtra(.menu)` reactivity:** `SettingsUIState` and `SnippetStore` are `@Observable`; reading them directly inside `OtoMenuBarView.body` ensures SwiftUI refreshes the menu on open, and `lastTranscript` updates via the existing `coordinator.stateChanges()` stream. Verify no NSMenu tracking lag.
- **Asset reservation cap (`AssetInventory.maximumReservedLocales`):** If a user switches among many languages exceeding Apple's reservation limit, `SpeechAssetPreparer.reserveLocale` already evicts the oldest reserved locale and `AppleSpeechService.prepare()` fails honestly with `.assetsNotPrepared` until prepared again in Settings.
- **Deferred:** Voice Transform on selected text, live caption preview in Flow Bar, and Snippet direct-insert from Menu Bar (copy-only stays reliable without focus-steal issues).

---

## 9. Open Questions

1. **Per-app cleanup levels:** Should per-app overrides offer `None / Light / Medium` (matching the existing Auto Cleanup levels, zero new prompts), or should we also include `Professional` tone as a 4th option? *(Recommended: `None / Light / Medium` first — keeps the UI and prompts unified with Auto Cleanup.)*
2. **Menu Bar `Language ▸` visibility:** Show only when 2+ languages are installed (zero clutter for single-language users, recommended), or always show?
