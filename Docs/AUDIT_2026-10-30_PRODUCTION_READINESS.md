# Oto — Production Readiness Audit

**Date:** 2026-10-30
**Scope:** whole app (`Oto/`, 101 Swift files, 22,891 LOC) + test suite (`OtoTests/`, `OtoUITests/`, 58 files, 601 tests, 10,412 LOC)
**Build state:** `xcodebuild -scheme Oto -destination 'platform=macOS' build` → **BUILD SUCCEEDED** (Apple Development signing, hardened runtime, sandbox off)
**Method:** static audit of every source file in the runtime path, UI, onboarding, storage, and tests; findings carry `file:line`. Runtime device-matrix behaviour (TCC prompts, notarization, notched-display layout) was **not** re-run for this pass.

---

## Verdict

**Not shippable yet, but close in architecture and far in polish.**

The engineering spine is genuinely good: one `DictationCoordinator` actor owns session state, every async result is re-checked against the session ID, finish/cancel are idempotent, insertion verifies the paste instead of assuming it, persistence is versioned + atomic, and 601 headless tests cover the hard parts.

What is missing is not architecture — it is **the last mile of honesty**:

1. Several failure paths are *completely silent* (audio, speech model, dead mic). The user presses the shortcut and nothing happens, forever.
2. Data can be lost silently (dictionary/snippets/history writes fail with a log line and a UI that already said "saved").
3. Quitting mid-dictation can leave the Mac muted until the next launch.
4. The onboarding walkthrough ends without enforcing the permissions it teaches, so the "try it" chapter can succeed visually and fail functionally.
5. Dev-only surfaces (`-OtoCleanSlate`, probes, A/B defaults) ship in the release binary.
6. There is no update path, no localization, no CI, and the test suite writes to the real user defaults domain.

Estimated remaining work to a defensible 1.0: **~3 focused weeks** (P0 ≈ 1 week, P1 ≈ 1 week, P2 ≈ 1 week), assuming no new features.

---

## 0. Your question first: the onboarding shader

**Short answer: it does not keep running. It costs nothing at idle after onboarding — except ~5 MB of VRAM and ~5 MB of RAM that are never released. The real cost is during onboarding itself, and it is fixable without touching the look.**

### What is gone after onboarding (verified)

`OnboardingWindowController.tearDown` (`:419-437`) stops playback (`:422`), nils the frame callbacks (`:423-424`), removes all observers (`:426`), closes the carrier and the native window, and drops `self.window` / `self.carrier`. The `MTKView`'s delegate is weak (`MTKView.h:45`), every Metal callback captures `[weak self]`, and the 60 Hz `Timer` is invalidated (`IntroTiming.swift:229-253`). Result: **no window, no view, no renderer, no timer, no per-frame GPU work.** No retain cycles were found.

### What stays resident (verified)

| Residue | Size | Lifetime | Where |
|---|---|---|---|
| `RayRenderingResources` static cache: `MTLLibrary`, 2 render + 2 compute pipelines | small | process | `MetalOnboardingShaderView.swift:288-289` |
| `OtoLogoAsset` 1024² `rgba8Unorm` mipmapped texture | ≈ 5.3 MB VRAM | process | `OtoMark.swift:206-228` |
| `OtoMarkSource.prepared` 1024×1024×4 `[UInt8]` | 4 MB RAM | process | `OtoMark.swift:104-144` |
| `OtoMarkSource` cropped `NSImage`/`CGImage` | ~1 MB | process | `OtoMark.swift:81-84` |

There is **no eviction path** anywhere. That is acceptable for a one-time intro, but it means a user who never sees onboarding again still pays ~10 MB forever. If onboarding is re-opened from the menu, the cache is what makes it cheap.

**Recommendation:** keep the pipeline cache (recompiling is a visible hitch), but drop `OtoMarkSource.prepared`'s 4 MB pixel array and the logo texture when onboarding tears down, or make them `autoreleasepool`-scoped to the presentation. Low effort, removes the only permanent residue.

### Where the shader actually costs you (during onboarding)

| # | Issue | Evidence | Impact |
|---|---|---|---|
| S1 | **Main-thread GPU sync every frame**: `command.waitUntilScheduled()` + `presentsWithTransaction = true` | `MetalOnboardingShaderView.swift:78, 348` | GPU round-trip on the main run loop that also drives the 60 Hz timer and SwiftUI. Highest hitch/thermal risk on integrated GPUs. |
| S2 | **No occlusion / Space / app-active gating** — only `view.window?.isVisible == true` | `:324` | The intro renders full-tilt for ~7.7 s even when the window is behind another app, on another Space, or the app is inactive. |
| S3 | **Redraw on every SwiftUI invalidation** — `updateNSView` calls `view.draw()` unconditionally; `ShaderState: Equatable` is declared but never compared | `:107`, `:125` | Any stage/row/elapsed change pays a full ray pass. |
| S4 | **~1.76 s of identical frames**: the shader clock freezes at handover (`markImageVisibleAt`) but the timer keeps publishing until `realDuration` ≈ 7.71 s | `OnboardingView.swift:33-34`, `IntroTiming.swift:27,35-45` | ≈ 105 redundant full-screen ray passes of a static image. |
| S5 | **Live-resize reallocates HDR targets per step**: `targets()` keys on exact width/height | `:446` | Each intermediate size allocates a new 9–14 MB radiance texture + 3 bloom textures. Dragging the window edge thrashes tens of MB. |
| S6 | **Two hosts, two queues, two target sets** during the ~2 s carrier→native overlap | `OnboardingWindowController.swift:311`, `:324` | ~60 MB GPU peak; the native host renders one frame at `alphaValue = 0` before being ordered out (`:162-164`). |
| S7 | **Per-frame allocations**: `MTLRenderPassDescriptor()`, `addCompletedHandler`, `addPresentedHandler` + `DispatchQueue.main.async` | `:339-344, 350-352, 374` | Steady allocation churn at 60 Hz. |
| S8 | **Main-thread CPU before the clock starts**: `OtoMarkSource.cropped` runs a 1,048,576-iteration loop, then `prewarm` does `command.waitUntilCompleted()` on the main thread | `OtoMark.swift:104-144, 219-224` via `OnboardingWindowController.swift:81-83` | First-frame latency / beachball risk on cold start. |
| S9 | **Dead fallback path**: `.metal` files compile into `default.metallib`; the bundle contains no `Waves.metal`, so `Bundle.main.url(forResource: "Waves"…)` returns nil and the documented "source fallback" cannot engage | `:281-285`, header `:9-11` | A stripped/mismatched metallib yields `.missingSource` → flat rectangle, not a recompile. |

**Cheapest wins, in order:** S4 (skip `draw()` when `state == lastDrawnState` — one `if`, removes ~105 frames), S3 (same guard removes every post-intro redraw), S2 (add `NSApplication.isActive` + `occlusionState` + Space check to the `:324` guard), S1 (drop `waitUntilScheduled`; keep `presentsWithTransaction` only for the handover window), S8 (move mark preparation off the launch path / cache it on disk).

Visual cost of all of the above: **zero**. The look is unchanged; only redundant work is removed.

**Noise/variability:** none — the shader is deterministic (`Waves.metal:516`, 28 samples/px, up to 56 with the inner branch; procedural `hash31`/`noise3` only, no 3D textures). Peak drawable is `bounds × min(backingScaleFactor, 1.5)` (`:38-44`), i.e. 1.19–1.74 MPx.

---

## 1. P0 — ship blockers

| # | Issue | Evidence | Fix | Effort |
|---|---|---|---|---|
| P0-1 | **Silent dictation failures.** `audioCapture`, `speechPreparation` (model missing / download failed / unsupported locale), and `noAudioCaptured` produce **no user-visible surface at all**. The pill hides (`FlowBarState.swift:147-157`); the menu no longer has a status row (`OtoMenuBarView.swift:20-34`); `lastSessionSummary()` has **zero production call sites** (`DictationCoordinator.swift:260` — only tests). | `DictationCoordinator.swift:359, 369, 392, 521`; `FlowBarState.swift:147-157` | One small failure card in the pill slot (same host as `PermissionModal`), reusing the existing `failed(context, failure)` enum. Copy per case; a "Fix in Settings" button that deep-links the right pane. | M |
| P0-2 | **Silent data loss.** `persist()` catches, logs, and returns; the row stays in the UI. Same shape in snippets and history. | `DictionaryStore.swift:294-300`; `SnippetStore.swift:143-149`; `HistoryStore.swift:126-127` | Return `Result` from mutations; surface a one-line inline error in the pane + keep the row marked unsaved. | M |
| P0-3 | **Quit during dictation leaves the Mac muted.** `MediaDuck` sets a persisted crash flag and volume 0 (`:206-208`); restore only happens on the next launch (`restoreIfCrashed`, `:297`). There is **no `applicationWillTerminate` anywhere**. | `MediaDuck.swift:206-208, 297-315`; `OtoApp.swift` (no terminate hook) | Add `applicationWillTerminate` → synchronous restore; also restore on `NSWorkspace.willPowerOff`. | S |
| P0-4 | **Onboarding teaches permissions but enforces none.** The chapter says "Three grants" (`OnboardingChapters.swift:60`), then "This is the whole product" (`:66`) — a user can reach it with mic/speech/AX all missing and the shortcut dead. | `OnboardingFlow.swift:56-78`; `OnboardingChapters.swift:60-66` | Gate Continue on the three grants, or replace Continue with a per-row grant that turns green. | M |
| P0-5 | **Dev surfaces ship in release.** `-OtoCleanSlate` wipes the entire domain + Application Support + Saved Application State from any launch (`CleanSlate.swift:29-53`, `OtoApp.swift:103`). `OtoProbe` runs and can `exit(0)` (`OtoProbe.swift:44-52`). `InsertionExperiment` A/B keys are writable by `defaults write` (`OtoApp.swift:119-127`). | as cited | `#if DEBUG` all three, or gate on a build flag. | S |
| P0-6 | **First-run shows a false empty state.** Stores load off the launch path (`OtoApp.swift:240-245`); panes render `rules.isEmpty` → "Your words, your way / Add your first rule" before load returns (`DictionaryPane.swift:28`, `SnippetsPane.swift:29`, `HistoryPane.swift:41-53`). | as cited | Add `isLoaded` to each store; render a skeleton/blank until first load resolves. | S |
| P0-7 | **No update path.** No Sparkle, no feed URL, no in-app "check for updates", no download page link. | `project.pbxproj` (no `SUFeedURL`), `AboutPane.swift` (no links) | Ship Sparkle 2 (EdDSA-signed appcast) or an explicit "Download the latest build" link in About. | M |
| P0-8 | **Distribution is undefined.** `ENABLE_APP_SANDBOX = NO`, hardened runtime on, `CODE_SIGN_STYLE = Automatic`, `MARKETING_VERSION = 1.0` / build 1, no notarization step, no privacy manifest (`*.xcprivacy` absent), bundle ID `app.Oto`. | `project.pbxproj:463-486` | Decide: direct distribution (notarize + staple + Sparkle) **or** Mac App Store (sandbox on + privacy manifest + App Store entitlements). Right now it is neither. | M |

---

## 2. Runtime pipeline — what works, what doesn't

**Works (verified, credit where due):**

- Single-owner session state with identity re-checks after **every** suspension (`DictationCoordinator.swift:325-423, 482-633`). No stale-result insertion path found.
- Finish/cancel idempotent and mutually exclusive; cancel wins and invalidates before awaiting (`:221-250`).
- Teardown serialized behind a task chain so a stale cancel cannot kill the next session's engine (`:57, 240-249`).
- Silent-skip is conservative and late-audio-safe (`:429-438`).
- Auto-cleanup race is bounded and fail-open (`:644-658`).
- Delivery is *verified*, not assumed — caret/character-count probe, `.unverifiable` for web editors (`DeliveryVerification.swift:1-120`).
- Clipboard ownership guard before overwriting (`NoTargetModal.swift:426-440`).
- Perf signposts are observation-only, no branches (`PerfTrace`).

**Gaps:**

| # | Gap | Evidence | Impact |
|---|---|---|---|
| R1 | Failure taxonomy exists but only 2 of 7 cases are surfaced (mic-denied card; target-gone/insertion-failed catcher). | `FlowBarState.swift:147-157`, `FlowBarController.swift:494` | See P0-1. |
| R2 | `lastSessionSummary()` is dead in production; the pill comment still claims "menu status" owns errors. | `DictationCoordinator.swift:260`; `FlowBarState.swift:151` | Comment lies; no surface. |
| R3 | Flow Bar polls the coordinator every **150 ms for the entire app life** (2–3 actor hops + string interpolation per tick). | `FlowBarController.swift:27, 110-155` | ~6.7 wakeups/s forever on a menu-bar app. Event-driven or 500 ms idle backoff would be invisible. |
| R4 | Hard-coded timing budgets: auto-cleanup 3 s, silence 500 ms, trailing settle 120 ms, delivery verify 300 ms + 5 ms poll, duck restore grace 250 ms. | `DictationCoordinator.swift:61,81,86`; `RealTextInsertion.swift:62-63`; `MediaDuck.swift:139` | Reasonable, but untested on slow Intel / loaded machines. Should be a single `OtoTiming` file with a matrix note. |
| R5 | No user-facing "insertion is slow / app is busy" state; a 3 s cleanup race shows only "Cleaning". | `FlowBarState.swift:51-58` | Acceptable, but the timeout should be visible as a fallback, not silent. |
| R6 | `DictationCoordinator` logs `privacy: .public` for bundle IDs and failure reasons. | `:317, 621` | Fine for local logs; ensure no transcript text ever joins them (it doesn't today). |

**Verdict:** the pipeline is production-grade in correctness. It is not production-grade in *communication*.

---

## 3. Data, persistence, migration

| # | Issue | Evidence | Severity |
|---|---|---|---|
| D1 | Write failures are swallowed (P0-2). | `DictionaryStore.swift:294-300` | High |
| D2 | "Clear" on Dictionary loops `remove(id:)` per rule — up to 500 sequential atomic rewrites of the whole array, each independently failable. History's `clearAll()` does one write. | `DictionaryPane.swift:92-99`; `DictionaryStore.swift:367-370`; `HistoryStore.swift:148-151` | Medium |
| D3 | Sandbox migration is all-or-nothing per directory: one existing file strands every remaining store. | `LocalPersistence.swift:146` | Medium |
| D4 | Corrupt files move aside (good), but the user is never told their rules vanished. | `LocalPersistence.swift` backup path | Medium |
| D5 | History cap is 100 entries, no user control, no "keep for N days". | `HistoryStore.swift:75, 159-167` | Low |
| D6 | Versioned envelope + atomic writes are solid; schema-version bump path is real. | `LocalPersistence.swift:22-30, 78-82` | — (credit) |

---

## 4. First run, permissions, settings state

| # | Issue | Evidence | Severity |
|---|---|---|---|
| F1 | Onboarding does not enforce permissions (P0-4). | `OnboardingFlow.swift:56-78` | High |
| F2 | Closing the window during the 0.25 s + 0.55 s handoff loses "seen" → onboarding returns next launch. | `OnboardingWindowController.swift:211-229, 242-246` | Medium |
| F3 | Settings state loads **once per process**: a mic plugged in later never appears; speech readiness never re-checks after the first window. | `SettingsUIState.swift:50-66` | Medium |
| F4 | Login item `.requiresApproval` / `.notFound` render as a plain off switch with no guidance. | `GeneralPane.swift:62-70` | Medium |
| F5 | Re-running onboarding is only reachable from the menu bar ("Show onboarding…"), not Settings. | `OtoMenuBarView.swift:22-26` | Low |
| F6 | `SettingsWindowLocator` matches a window by the literal title `"Settings"`; any localization/title change silently disables the onboarding guard. | `OtoApp.swift:280`, `SettingsWindowController.swift:38` | Low |
| F7 | The permissions chapter starts a model download in the background that is never cancelled if the window closes. | `OnboardingFlow.swift:172-175` | Low (arguably intended) |

---

## 5. UI consistency inventory

### 5.1 Counts (verified)

| Dimension | Count | Detail |
|---|---|---|
| Corner radii | **14 values in use** | 4.5, 4.75, 5, 6, 8, 9, 10, 12, 13, 14, 16, 18, 20, 22 (plus 1–2 pt hairline radii; `Capsule` ×14, 2 circles) |
| Hard-coded `.system(size:)` | **73 sites, 11 sizes** | 9, 10, 11, 11.5, 12, 13, 14, 15, 19, 20, 24 |
| Semantic text styles | 23 | `.callout` 8, `.footnote` 6, `.caption` 5, `.title3` 2, `.subheadline` 1, `.body` 1 |
| Spacing literals | 17 | 0, 2, 2.5, 3, 4, 5, 6, 8, 10, 12, 14, 16, 18, 19, 20, 28, 30 |
| Padding literals | 18 | 2, 3, 4, 5, 6, 8, 9, 10, 11, 12, 13, 14, 16, 18, 19, 20, 28, 30 |
| Control heights | 8 | 20, 22, 24, 26, 28, 30, 34, 36 (+ 92 editor) |
| Animation durations | 11 | 0.1, 0.12, 0.14, 0.15, 0.18, 0.2, 0.22, 0.25, 0.30, 0.34, 0.38 |
| Shadow recipes | 6 | `.38/12/6`, `.22/1/1`, `.06/8/2`, `.10/2/1`, `.18/8`, `.22/6` |
| Reduce Transparency | **1 site** | `OtoControls.swift:151` |
| Increase Contrast | **0 sites** | — |
| Differentiate Without Colour | **0 sites** | — |
| Localized strings | **0** | `developmentRegion = en`, no catalogs |

### 5.2 Top 12 visible inconsistencies (ranked by what a user notices)

| # | Issue | Side A | Side B | Fix |
|---|---|---|---|---|
| 1 | **Settings rows render in the wrong typeface.** `.font(.system(size: 13))` has no `design:`, so it does not inherit `.fontDesign(.rounded)` from the shell. | `DictionaryPane.swift:110`, `SnippetsPane.swift:102`, `HistoryPane.swift:198` | `SettingsRoot.swift:455, 509` (rounded) | Drop the explicit size (inherit `.body`) **or** add `design: .rounded`. One choice, everywhere. |
| 2 | **Hand-rolled segmented control** paints selection with a literal white capsule; ignores Increase Contrast. | `OtoControls.swift:116-117` | Native `.unemphasizedSelectedContentBackgroundColor` at `SettingsRoot.swift:262` | Use `.pickerStyle(.segmented)`, or branch on `colorSchemeContrast`. |
| 3 | **Two near-identical shortcut recorders** for the same popover. | `ShortcutRecorderField.swift:363` (`.callout`, spacing 8) | `:594` (11 pt, spacing 5) | Delete `TransformShortcutCapturePopover`, parameterise capture policy. |
| 4 | **Three corner radii for the same floating card.** | Catcher 22 (`NoTargetModal.swift:96`) | Permission 16 (`PermissionModal.swift:103`), onboarding plate 14 (`OnboardingPlates.swift:139`) | One `OtoRadius.popover = 20`. |
| 5 | **Three definitions of the same near-black card colour.** | `PillLayers.swift:144` | `PermissionModal.swift:180`, `CatcherPalette.swift:33` | One `OtoPalette.card`. |
| 6 | **Five disabled treatments.** | `OtoControls.swift:134` (0.48), `:309` (0.5), `:441` (0.55) | `OnboardingContinueButton.swift:115` (0.6), `DictionaryPane.swift:113` (0.45) | One `.opacity(0.45)` token or rely on `.disabled`. |
| 7 | **Primary button varies by surface**: native prominent, hand-built ink rect, hand-built capsule. | `OtoControls.swift:28` | `OtoEmptyState.swift:105-115`, `OnboardingContinueButton.swift:87-106` | `OtoPrimaryButton` / `OtoSecondaryButton`; keep the onboarding capsule as the one documented variant. |
| 8 | **Overlay-in timing differs for the same gesture**: 0.12 / 0.15 / 0.18 / 0.22. | `PermissionModal.swift:342` | `NoTargetModal.swift:200`, `FlowBarPosition.swift:30`, `OtoControls.swift:120` | Two tokens: `settle` (in), `dismiss` (out). |
| 9 | **Empty state uses 5 type sizes and 3 max widths.** | `OtoEmptyState.swift:95, 105-115, 125` | — | One `OtoType` scale, one `maxWidth: 360`. |
| 10 | **Section header idiom alternates inside one pane**; the first Intelligence card has no header. | `GeneralPane.swift:90, 101` | `DictationPane.swift:80, 113`; `IntelligencePane.swift:115` vs `:125/:139` | `Section("Title")` everywhere. |
| 11 | **Two permission-row renderers** for the same three grants. | `PermissionRows.swift:25` | `OnboardingPlates.swift:292-323` | Share one row. |
| 12 | **Five type sizes inside controls ≤36 pt tall.** | `OtoStatus` 11.5, `OtoKey` 10/11, `OtoShortcutPill` 11/12 | Recorder hint 13/11 (`ShortcutRecorderField.swift:392/623`) | Collapse to `micro` 11 / `small` 11.5 / `body` 13. |

### 5.3 Dead design system

A parallel kit exists and is **never called** (0 call sites outside `Oto/UI/Theme/`):

`OtoCard`, `OtoRule`, `OtoLine`, `OtoCaption`, `OtoNothing` (`OtoPlate.swift`), `OtoBig`, `OtoSwitch` (`OtoControls.swift`), plus `OtoDoor`, `OtoQuick`.

`OtoMotion` is 90% dead: only `OtoMotion.reduced` is read (`OtoControls.swift:331`); `glide`, `settle`, `quick` have zero call sites while 11 ad-hoc durations do the same job.

**Decision required:** either migrate the panes onto the kit (bigger job, one visual language) or delete the dead half. Keeping both guarantees drift.

### 5.4 Proposed token set (derived from existing usage, not invented)

```swift
enum OtoRadius {
    static let xs: CGFloat = 5      // keycap, row-button wash
    static let sm: CGFloat = 8      // chips, small fields, popover rows
    static let md: CGFloat = 12     // tiles, onboarding cards
    static let lg: CGFloat = 18     // cards, permission card
    static let xl: CGFloat = 22     // catcher / full-bleed modal
    static let popover: CGFloat = 20
}

enum OtoType {
    static let micro  = Font.system(size: 11,   weight: .medium, design: .rounded)
    static let small  = Font.system(size: 11.5, weight: .medium, design: .rounded)
    static let body   = Font.body                                // 13 pt — all settings rows
    static let bodyMed = Font.body.weight(.medium)
    static let lead   = Font.system(size: 15, design: .rounded)  // onboarding subtitle
    static let title  = Font.system(size: 19, weight: .semibold, design: .rounded)
    static let display = Font.system(size: 30, weight: .medium, design: .rounded)
    static let displayL = Font.system(size: 40, weight: .medium, design: .rounded)
}

enum OtoSpace {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 28
}

enum OtoSize {
    static let controlSM: CGFloat = 22
    static let controlMD: CGFloat = 26
    static let controlLG: CGFloat = 34
    static let controlXL: CGFloat = 36
}

enum OtoElevation {
    static let quiet  = (color: Color.black.opacity(0.06), radius: 8, y: 2)
    static let raised = (color: Color.black.opacity(0.30), radius: 20, y: 6)
}

enum OtoMotion {
    static var quick: Animation?    // 0.14 easeOut — hovers
    static var settle: Animation?   // 0.18 easeOut — overlays in
    static var dismiss: Animation?  // 0.14 easeIn  — overlays out
    static var glide: Animation?    // 0.34 spring 0.82 — page/frame moves
    static var press: Animation?    // 0.25 spring 0.55 — OtoBounce
    static var reduced: Bool
}
```

Collapses 14 radii → 6, 73 size declarations → 8 tokens, 17 spacings → 7, 8 heights → 4, 11 durations → 5, 6 shadows → 2.

---

## 6. Accessibility

| # | Gap | Evidence | Severity |
|---|---|---|---|
| A1 | Onboarding progress dashes are tappable but exposed as a single non-interactive element (label only, no `.isButton`, no action) — VoiceOver cannot change chapter. | `OnboardingChapters.swift:268-276` | High |
| A2 | Permission modal (mic denied) has no accessibility label and never moves focus; it is a floating card that can appear while the user is in another app. | `PermissionModal.swift:96-149, 340` | High |
| A3 | Every segmented control is announced as "Options" regardless of content. | `OtoControls.swift:136` | Medium |
| A4 | Increase Contrast is never consulted; 0.7–1.0 pt hairlines are the primary separator. | repo-wide (0 hits) | Medium |
| A5 | Reduce Transparency honoured on 1 of 5 material surfaces. | `OtoControls.swift:151` vs `SettingsRoot.swift:453`, `OtoRowActions.swift:167`, `ShortcutRecorderField.swift:473, 674`, `OnboardingChapters.swift:224` | Medium |
| A6 | Reduce Motion bypassed by: settings "No results" 0.18 s delay, onboarding pill hovers, row spring, work-pill shine. | `SettingsRoot.swift:450`; `OnboardingContinueButton.swift:118, 152`; `OnboardingPlates.swift:36` | Medium |
| A7 | Row auto-advance every 5 s ignores Reduce Motion and VoiceOver focus. | `OnboardingChapters.swift:174-183, 354-364` | Medium |
| A8 | Duplicate Welcome content may be enumerated twice by VoiceOver (two live windows during the intro). | `OnboardingWindowController.swift:115, 146` | Low (unverified at runtime) |

---

## 7. Release engineering

| Area | State | Needed |
|---|---|---|
| Build | ✅ succeeds, Swift 6, MainActor default isolation, macOS 27 target | — |
| Sandbox | ❌ `ENABLE_APP_SANDBOX = NO` | Decide distribution model |
| Hardened runtime | ✅ on | — |
| Notarization | ❌ no pipeline/script | `notarytool` + staple step |
| Privacy manifest | ❌ no `PrivacyInfo.xcprivacy` | Required for App Store; recommended otherwise (UserDefaults reason `CA92.1`) |
| Updates | ❌ none | Sparkle 2 + appcast |
| Crash reporting | ❌ none (OSLog only) | Optional; at minimum a "Report a problem" link |
| Localization | ❌ 0 localized strings, `en` only | Declare English-only for 1.0, or extract with `SWIFT_EMIT_LOC_STRINGS = YES` (already on) |
| CI | ❌ no workflows | `xcodebuild test` on push + release archive |
| App icon | ✅ full 16–512 @1x/@2x set | — |
| Versioning | ⚠️ 1.0 (1), automatic signing | Bump policy |

**About pane** has no website, support, changelog, or license link (`AboutPane.swift:1-53`). For a paid/indie app that is a trust gap.

---

## 8. Test suite health

**Good:** 601 Swift Testing tests across 58 files, no real TCC/AX/HID/pasteboard access, isolated named pasteboards, deterministic gates instead of sleeps in the coordinator suite, `@Suite(.serialized)` where shared state demands it. Coverage of the hard logic (delivery verification, shortcut decision, storage round-trips, focus policy) is genuinely strong.

**Problems:**

| # | Issue | Evidence |
|---|---|---|
| T1 | **Tests write the real app defaults domain.** `UserDefaults.standard` in the test host *is* `app.Oto`. `cleanDualKey()` deletes the user's real shortcut config; `FlowBarControllerTests` flips the real catcher key; the UI test marks onboarding seen. | `ShortcutDispatchDualTests.swift:45`; `FlowBarControllerTests.swift:83-84`; `OtoUITests/SettingsUITests.swift:14-18` |
| T2 | **57 real-time sleeps** (5 ms → 1.1 s; `Thread.sleep(1.5)` in `FocusTimeoutTests`; 350 ms × 8 in `MediaDuckTests`). Flaky under load and slow in CI. | `OtoTests/**` |
| T3 | UI coverage is one test (149 lines, XCTest) that cannot reach the menu bar. | `OtoUITests/SettingsUITests.swift` |
| T4 | No CI, so the suite is only as good as the machine it was last run on. | — |

---

## 9. Recommended sequence

### Phase A — "nothing fails silently" (≈ 5–7 days)
1. Failure surface for every `DictationState.failed` case (P0-1, R2). Reuse the permission-card host.
2. Persistence mutations return `Result`; panes surface inline errors (P0-2).
3. `applicationWillTerminate` → MediaDuck restore (P0-3).
4. Onboarding permission gate (P0-4).
5. `#if DEBUG` the clean-slate/probe/experiment surfaces (P0-5).
6. `isLoaded` guards on the three list panes (P0-6).
7. Settings `ensureLoaded` → per-window refresh + device-change observer (F3, F4).

### Phase B — "it feels finished" (≈ 5–7 days)
8. Token set (§5.4) + fix the 12 ranked inconsistencies; delete the dead kit or migrate onto it.
9. Shader: S3/S4 redraw guard, S2 occlusion gate, S1 present path, S5 resize debounce, S8 off-main mark prep.
10. Flow Bar idle backoff (R3).
11. Accessibility: A1–A7.
12. About pane links + "Show onboarding" moved into Settings.

### Phase C — "it can ship" (≈ 5–7 days)
13. Distribution decision + notarization + privacy manifest + Sparkle (P0-7, P0-8).
14. CI: build + test on every push, archive/notarize on tag.
15. Test hygiene: isolate defaults (T1), replace sleeps with gates (T2).
16. One device matrix pass: Intel + Apple silicon, notch/external display, non-US keyboard, RTL locale, VoiceOver-only run.

---

## Appendix — evidence index for P0/P1

| Finding | File:line |
|---|---|
| Failures never reach the pill | `Oto/UI/FlowBar/FlowBarState.swift:147-157` |
| Menu has no status row | `Oto/UI/OtoMenuBarView.swift:20-34` |
| `lastSessionSummary` unused in prod | `Oto/Coordinator/DictationCoordinator.swift:260` |
| Failure states set | `DictationCoordinator.swift:359, 369, 392, 521, 589, 630` |
| Silent persist | `Oto/Storage/DictionaryStore.swift:294-300` |
| Empty-state before load | `Oto/Settings/DictionaryPane.swift:28`; `Oto/App/OtoApp.swift:240-245` |
| Duck crash flag / restore | `Oto/Services/MediaDuck.swift:206-208, 297-315` |
| No terminate hook | `Oto/App/OtoApp.swift` (absent) |
| Clean slate arg | `Oto/Support/CleanSlate.swift:29-53`; `OtoApp.swift:103` |
| Permission chapter copy | `Oto/Onboarding/OnboardingChapters.swift:60-66` |
| Settings state once | `Oto/Settings/SettingsUIState.swift:50-66` |
| Login item toggle | `Oto/Settings/GeneralPane.swift:62-70` |
| Shader draw on every update | `Oto/Onboarding/MetalOnboardingShaderView.swift:107` |
| Shader visibility gate | `MetalOnboardingShaderView.swift:324` |
| Main-thread present | `MetalOnboardingShaderView.swift:78, 348` |
| Resource cache | `MetalOnboardingShaderView.swift:288-289` |
| Target reallocation key | `MetalOnboardingShaderView.swift:446` |
| Frozen shader clock | `Oto/Onboarding/OnboardingView.swift:33-34` |
| Real duration 7.71 s | `Oto/Onboarding/IntroTiming.swift:27, 35-45` |
| Mark CPU prep | `Oto/Onboarding/OtoMark.swift:104-144, 219-224` |
| Sample count | `Oto/Resources/OnboardingShaders/Waves.metal:516` |
| Test writes real defaults | `OtoTests/ShortcutDispatchDualTests.swift:45`; `OtoTests/FlowBar/FlowBarControllerTests.swift:83-84` |
