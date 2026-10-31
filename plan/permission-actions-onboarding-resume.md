# Permission pills that say what to do, onboarding that resumes, and the speech-authorization crash

Status: DONE (2026-10-31) — rounds 1–3 executed, built, unit-tested
(603/603) and committed to `main`. Round 3 added the two UI fixes the user
reviewed that evening: each switch's note now sits in the same row as its
switch, and the How chapter's selectors are gone with its words centred.

Source: user's two screenshots (`.context/attachments/34zgTr`,
`.context/attachments/ReIYb4`) — both show Dictation → Microphone → Status
reading a static-looking **Denied** pill — plus their report that granting a
permission in onboarding loses the session, and the console output they pasted.

## Goal

1. **A permission that is not allowed invites the click.** No row ever ends at
   a bare "Denied" / "Not allowed". Every actionable pill reads **"Allow"** —
   one word, same in Settings (Dictation + Privacy) and in onboarding, for
   microphone and Accessibility. The press still does the right thing per
   state (prompt when one exists, System Settings when it does not), and the
   `.help` tooltip keeps naming the exact pane.
   **The pill's look does not change**: same capsule, dot, tone, size and
   padding as today — only the string inside it. "Allow" is shorter than every
   string it replaces ("Denied", "Not allowed", "Not asked yet"), so nothing
   can overflow `.lineLimit(1)`; the probe captures below confirm it.
2. **Remove the Speech Recognition privacy grant.** Oto never calls
   `SFSpeechRecognizer.requestAuthorization`. Onboarding's permissions chapter
   becomes "Two grants" (microphone, Accessibility); the Apple Speech *asset*
   readiness row stays exactly where it is (it is not a TCC permission).
3. **Onboarding resumes instead of restarting.** The step/row survives a window
   close and an app relaunch; the menu's re-run entry continues where the
   person stopped instead of going back to Welcome.
4. **Silence the duplicate-ID log noise**: `the ID Right ⌥ occurs multiple times`
   from the onboarding "tap twice" illustration.

## Round 2 — the user's follow-up review (same session)

Three more asks, on top of 1–4 above. They are executed in the same pass.

5. **Teach the double-tap in Dictation itself.** Today the hold key's
   double-tap (hold key → hands-free, press again to stop) is only taught
   in onboarding's "How" chapter. Settings says nothing, so a person who
   skipped or finished onboarding never learns it. Add **one** quiet,
   non-interactive line inside the existing Shortcut card, under the two
   rows, in the same footnote style as the conditional "Requires
   Accessibility" line: the live hold key's name, the mechanic, and how
   to stop. No new control, no second card, no chrome.
6. **Stop repeating permissions in Dictation.** `DictationPane` draws a
   `Section("Permissions")` with Accessibility (and, before this round,
   Speech). Privacy already owns every permission row. Remove the whole
   section from Dictation; the pill text change from #1 lands in Privacy
   only. Microphone *input* stays in Dictation (it is a device, not a
   grant); its Status row stays because it is the one place a denied mic
   is in context.
7. **Order the sidebar by relevance.** General first (the user's explicit
   call), Intelligence pulled up next to Dictation (it is the shipped,
   differentiating feature), then the personal library (Dictionary,
   Snippets, History), then the rarely-visited tail (Privacy, About).
   Reordering only — no pane is merged, renamed, or removed.

## Why #2 is the crash (evidence, not inference)

Three crash reports on this Mac — `Oto-2026-10-29-070226.ips`,
`Oto-2026-10-31-182900.ips`, `Oto-2026-10-31-184852.ips`:

- `exception: EXC_CRASH/SIGABRT`, stack `__TCCAccessRequest_block_invoke` →
  `__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__`.
- `termination.namespace = TCC`, details: *"must contain an
  NSSpeechRecognitionUsageDescription key"*.
- Every one: `responsibleProc = conductor`, `coalitionName = com.conductor.app`,
  `parentProc = launchd`.

The bundle Oto was running from does contain the key (built Debug
`Info.plist`: both `NSMicrophoneUsageDescription` and
`NSSpeechRecognitionUsageDescription`). What lacks it is the **launching** app:

- `/Applications/Conductor.app/Contents/Info.plist` → has
  `NSMicrophoneUsageDescription` only.
- `/Applications/Xcode.app/Contents/Info.plist` → has camera + microphone only.

So a TCC *request* for speech recognition aborts the process when the app is
launched from Xcode or Conductor. That is the "crash when I give permission",
and the reason microphone never crashed them.

It also matches the pasted console: a full dictation completed
(`speech finished delivered=135 … completed, inserted 128 chars`) with no
speech authorization ever granted. Microphone + on-device SpeechAnalyzer is
all dictation needs.

## Spec sources (canonical)

- `Docs/START_HERE_PRODUCT.md:107` — "Oto requests microphone and Accessibility
  permissions only when the related action is needed."
- `Docs/OTO_REBUILD_PLAN/07_APPLE_SPEECH_IMPLEMENTATION_PLAN.md:645` — do not
  request `NSSpeechRecognitionUsageDescription` unless the app introduces
  `SFSpeechRecognizer`; Apple treats that path as separate from SpeechAnalyzer.
- `…/07…md:399–410` — permissions table: Microphone, Accessibility, Apple
  Speech **assets** (`AssetInventory`), login item. No speech-privacy row.

## Facts verified

Local toolchain: Xcode 27.1 (27A9275), SDK `MacOSX27.0.sdk`, deployment 27.0.

SDK (`swiftinterface`, `arm64e-apple-macos`):
- `SpeechAnalyzer` and `SpeechTranscriber` are public Swift types with no
  authorization surface — `Speech.swiftmodule/…swiftinterface:228,346`.
- Authorization lives only on the Objective-C
  `SFSpeechRecognizer`: `SFSpeechRecognizer.h:98` (`authorizationStatus`) and
  `:115` (`requestAuthorization:`).

System:
- `CGWindowListCopyWindowInfo` probe (`.context/winlist.swift`): with
  onboarding up, activating Finder and then Oto again left the 868×608 window
  `onscreen=true` both times. **The window does not close itself on an app
  switch** — the disappearance is process death (the TCC abort), not window
  ordering.
- TCC's usage string is read from the responsible process: Conductor and Xcode
  plists above.

Tree:
- `Oto/Support/PermissionsManager.swift:64–98` — `speechStatus`,
  `requestSpeech`, `ensureSpeech` (the only `SFSpeechRecognizer` calls).
- `Oto/Settings/SettingsUIState.swift:43,71,113,140–150,172–181` —
  `speechPermission`, `speechText`, `speechAction`, `speechTone`,
  `speechDeniedGuidance`, `ensureSpeechGrant`.
- `Oto/Settings/PermissionRows.swift:33–62` (mic), `:65–75` (AX),
  `:80–110` (speech). Every actionable pill passes the **state** string
  (`micText` = "Denied"), never the action.
- `Oto/Settings/DictationPane.swift:113–116` and `Oto/Settings/PrivacyPane.swift:18–23`
  both list `SpeechStatusRow`.
- `Oto/Onboarding/OnboardingPlates.swift:240–280` — third row is speech;
  `:284–320` `row()` passes `status` + `action`.
- `Oto/Onboarding/OnboardingChapters.swift:58–62` — chapter title "Three grants".
- `Oto/Onboarding/OnboardingFlow.swift:137–166` — `openSpeechSettings`,
  `grantSpeech`; `Oto/UI/FlowBar/PermissionModal.swift:71–79` —
  `SpeechSettingsLink` (used only by those two).
- `Oto/Onboarding/OnboardingWindowController.swift:86` — `show()` calls
  `OnboardingStage.shared.reset()` (that is why a re-show starts at Welcome);
  `:299` `complete()` also resets.
- `Oto/Onboarding/OnboardingStage.swift:141–162` — `advance`/`open`/`reset`;
  state is memory-only.
- `Oto/UI/OtoMenuBarView.swift:24` — "Show onboarding…" calls `show()`.
- `Oto/UI/Theme/OtoControls.swift:283` — `ForEach(chips, id: \.self)`;
  `Oto/Onboarding/OnboardingPlates.swift:54` deliberately passes
  `chips + chips` → duplicate IDs at every launch.
- `OtoTests/SettingsUIStateTests.swift:26,29,56–72` pin the speech strings.
- `Oto.xcodeproj/project.pbxproj:473,506` — the generated-plist key in both
  configurations.

## Assumptions questioned

- *"Denied is the honest label."* It is honest but useless: the only affordance
  is the pill itself, and a pill that says "Denied" does not look like a way
  out. The state is still carried by the dot colour and the row's guidance.
- *"Speech recognition needs its own grant."* No: Apple's SpeechAnalyzer path
  is authorized by the microphone; the user's own successful 128-character
  dictation proves it on this machine.
- *"Onboarding closes when you switch apps."* Probed: it does not. The process
  dies on the speech prompt; that is what looked like a closed window.
- *"Keeping the Info.plist key is harmless."* Harmless but misleading: the key
  claims a permission the app never uses. Remove it so the specification and
  the bundle agree.

## File changes

### 1. `Oto/Support/PermissionsManager.swift`
- Delete `speechStatus()`, `requestSpeech()`, `ensureSpeech()` and
  `import Speech` (mic uses AVFoundation only).
- Keep the microphone half verbatim.

### 2. `Oto/Settings/SettingsUIState.swift`
- Delete `speechPermission`, `speechText`, `speechAction`, `speechTone`,
  `speechDeniedGuidance`, `ensureSpeechGrant()`, and the speech line in
  `refreshPermissions()` / `ensureLoaded()`.
- Add action labels in the one place the state is derived:

```swift
/// The pill's label: the state where there is nothing to do, the one word
/// that invites the press where there is. "Denied" is never the last word.
var micActionText: String {
    switch micAction {
    case .none: micText
    case .allow, .openSettings: "Allow"
    }
}

var axActionText: String { "Allow" }
```

- Keep `speechReadiness`, `readinessText`, `speechReady`, `runPrepare`,
  `refreshSpeech` — that is the Apple Speech asset row, not a permission.

### 3. `Oto/Settings/PermissionRows.swift`
- `MicStatusRow`: actionable branches render `uiState.micActionText`; readout
  keeps `micText`.
- `AccessibilityRow`: `text: uiState.axActionText`.
- `SpeechStatusRow`: delete. `import Speech` goes with it.
- Tooltips stay as they are (they already name the System Settings pane).

### 4. `Oto/Settings/DictationPane.swift`, `Oto/Settings/PrivacyPane.swift`
- Dictation: delete the whole `Section("Permissions")` (round 2, #6). Privacy
  is the one place permissions are listed.
- Privacy: delete the `SpeechStatusRow` line; the section is Microphone +
  Accessibility + the existing storing note.
- Dictation also gains the double-tap line inside `Section("Shortcut")`
  (round 2, #5), in the same `Label` footnote style as "Requires
  Accessibility":

```swift
Label(
    "Double-tap \(KeyNames.shortLabel(for: holdKind)) to record without holding.",
    systemImage: "hand.tap"
)
```

  Copy is one sentence and says exactly what the gesture does; the longer
  "keep listening hands-free … press again to stop" was rejected as too
  involved for a settings footnote (round 2 follow-up).

  `KeyNames.shortLabel` already answers "Right ⌥", "⌃Space" or "the Dictation
  key" for every hold kind, so the line cannot drift from the recorded key.
  It sits above the conditional Accessibility warning: teaching first, the
  exception second.

### 5. `Oto/Onboarding/OnboardingPlates.swift`
- Delete the speech row and `speechAction()`; `micAction()` passes
  `uiState.micActionText`, Accessibility passes `"Allow"`.
- The permissions card keeps its `.task { prepareSpeechInBackground() }` — the
  model still downloads there, silently.

### 6. `Oto/Onboarding/OnboardingFlow.swift`
- Delete `grantSpeech()` and `openSpeechSettings()`.

### 7. `Oto/UI/FlowBar/PermissionModal.swift`
- Delete `SpeechSettingsLink` (no remaining callers).

### 8. `Oto/Onboarding/OnboardingChapters.swift`
- "Three grants" → "Two grants"; subtitle keeps its em-dash-free rewrite:
  "Oto asks only when it needs to, right here."

### 9. `Oto.xcodeproj/project.pbxproj`
- Delete `INFOPLIST_KEY_NSSpeechRecognitionUsageDescription` in both
  configurations (473, 506). One-line comment in the plan/changelog: the app
  never introduces `SFSpeechRecognizer`, so it must not declare the key.

### 10. Onboarding resume — `Oto/Onboarding/OnboardingStage.swift`,
`Oto/Onboarding/OnboardingWindowController.swift`, `Oto/UI/OtoMenuBarView.swift`
- `OnboardingStage` gains a small `UserDefaults`-backed store (keys
  `app.Oto.onboardingStep`, `app.Oto.onboardingRow`), written on `advance` /
  `open` and cleared by `reset()` and by `complete()`.
- `restore()` replaces the reset in `show()`: read the stored step, clamp it to
  the current `chapters` (a stored `.handoff` falls back to `.tryIt`, unknown
  values to `.welcome`), and apply it without animation.
- `complete()` keeps `reset()` (which clears the stored step).
- `OtoMenuBarView`: while `OnboardingStore.shouldShow()` the item reads
  **"Continue setup…"**; once finished it reads "Show onboarding…" and starts at
  Welcome as today.
- No change to the no-skip rule: closing still marks nothing.

### 11. `Oto/UI/Theme/OtoControls.swift`
- `OtoShortcutPill`'s chip `ForEach` keys by offset (`id: \.offset`) instead of
  `\.self`; the duplicated "tap twice" chips become legal and no log line is
  printed. No visual change.

### 12. Tests
- `OtoTests/SettingsUIStateTests.swift`: delete the speech string/tone tests
  (56–72); add `micActionText` coverage: `.allow` and `.denied` → "Allow",
  `.granted`/nil → the state string.
- `OtoTests/OnboardingStoreTests.swift`: add the resume keys — round-trip,
  clamp of `.handoff` → `.tryIt`, unknown raw value → `.welcome`, and
  `clear()` leaving nothing behind.
- `OtoTests/OnboardingStageTests.swift`: add a resume test — advance to
  `.permissions`, `restore()` on a fresh stage lands there; `reset()` clears
  it. Existing chapter-order assertions stay.
- No UI test asserts the removed speech row or the removed Dictation
  Permissions section.

### 13. `Oto/Settings/SettingsRoot.swift` — sidebar order (round 2, #7)
- Reorder `SettingsPane`'s cases only. `allCases` is declaration order, so
  the sidebar, search results and probe walk all follow:

```text
General · Dictation · Intelligence · Dictionary · Snippets · History ·
Privacy · About
```

- The default pane stays `.dictation` (the reason people open Settings at
  all); "General first" is about the list's order, not the landing page.
- Update the enum's doc comment so the next agent knows the order is
  deliberate: most-used first, library in the middle, rare tail last.

### 14. `Oto/Settings/GeneralPane.swift` — one description per switch (round 3)
- The Behavior card had one footnote for two switches ("Catcher: … Mute: …"),
  so the mute paragraph read as part of the catcher row. Split it: each switch
  is followed by its own `OtoPanelNote`, in the same pattern as Speech
  (control, then its note) and the mic picker.
- Copy, plain and short: catcher — "No text field? Oto opens a small window.
  Off: the text is copied instead."; mute — "Silences speakers while you
  dictate, then restores the volume."

### 15. `Oto/Settings/GeneralPane.swift` — the note belongs to the switch, not the card
- The two notes from #14 are Form rows of their own, so the grouped card draws a divider between a switch and the sentence that explains it; the user read that as two unrelated things (round 3 screenshot).
- Put each switch and its note in **one** row: a `VStack` (toggle on top, callout note 3 pt under it, full width so the switch stays at the trailing edge). No divider is drawn inside a row, so the note sits with its title and the card ends after the last note.

### 16. `Oto/Onboarding/*` — the How chapter is one chapter like the rest
- The How chapter walked two rows (Push to talk / Hands-free) on the left to drive the preview on the right. The user removed that pattern: the frame will carry the visualisations, so the left side has no selectors (round 3 screenshot: the row list is what goes).
- Delete the row machinery rather than leave it dormant: `Step.rows`, `stage.row`, `stage.dwell`, `open(row:)`, the `row:` parameter of `advance`, `OnboardingChapterCopy.Row`/`rows`, the `OnboardingChapterRows` view, the row/dwell parameters of `OnboardingProgressDashes`, the resume `row` key, and the probe's per-row captures.
- `.how` copy keeps tag "What Oto does", title "Speak. It lands.", subtitle "Oto turns your voice into text in whatever app you're in." Its words centre vertically like every other chapter, and the tag uses the idle capsule (no chapter has rows to point at).
- `OnboardingFlowBarPreview` drops `row`/`chips` and always shows the listening pill over the landing field. Hands-free is still taught one chapter later (the shortcut card's "Double tap ⌥ for hands-free" row) and in Settings → Dictation.
- Tests: chapter order, resume and clamps stay; the row tests go (`.how.rows` no longer exists). The store's resume point is the step alone.

## Verification

1. `xcodebuild -scheme Oto -destination 'platform=macOS' build`
2. `xcodebuild test -scheme Oto -destination 'platform=macOS'` (unit + UI).
3. Probe captures:
   - `OTO_SETTINGS_SHOT=… PANES=dictation OTO_APPEARANCE=dark` and `light` —
     no Permissions section, the double-tap line under the two shortcut
     rows reads cleanly against both the normal and the "Requires
     Accessibility" state, and nothing clips.
   - `PANES=privacy` — mic + Accessibility only, no speech row; a denied mic
     reads "Allow" (reproducible with `tccutil reset Microphone app.Oto`).
   - The same settings capture shows the sidebar order General, Dictation,
     Intelligence, Dictionary, Snippets, History, Privacy, About.
   - `OTO_SHOT=…` — permissions chapter shows two rows, title "Two grants".
   - Launch twice: advance onboarding to `.permissions`, quit, relaunch →
     the window opens on `permissions`, not Welcome; menu reads
     "Continue setup…".
4. Console free of `the ID Right ⌥ occurs multiple times`.
5. Grant microphone from onboarding under Xcode **and** under Conductor: no
   abort, the row flips to "Allowed" on return (the existing
   `didBecomeActive` refresh).
6. `plutil -p …/Oto.app/Contents/Info.plist | grep -i speech` → empty.

## Risks / deferred

- **SettingsUITests' onboarding walk failed once in a full-suite run**
  (`Onboarding must reach Finish`, after the probes had written a resume point),
  and passed when run alone immediately after. Not isolated; the resume change
  is the prime suspect (the walk can now open on a chapter whose button is
  "Finish" before the intro enables it). Re-run before trusting a red suite.

### Deferred: the hand-off flight (answered, not built)

The user asked whether the mark's finish flight can land exactly on the menu
bar and be felt on landing. Both are possible; neither was built this round.

- **Exact landing.** `menuBarTarget` is a constant (`maxX - 30`), which is
  only right when Oto's item is the rightmost one on the main display. The
  real item is a `MenuBarExtra`, i.e. an AppKit status item underneath: its
  window is an `NSStatusBarWindow` whose `contentView` is the
  `NSStatusBarButton`. Reading `NSApp.windows` for that window gives the
  button's frame in screen coordinates, which already accounts for the notch,
  display width, menu-bar height and every neighbouring item — so the flight
  can land on the icon itself and scale to its size, at any window size. The
  usual caveat: match the window whose button's identifier/bundle belongs to
  Oto, never "the last status window". Verify with a probe before shipping.
- **Haptic.** `NSHapticFeedbackManager.defaultPerformer.perform(.alignment,
  performanceTime: .now)` at the end of the flight — the same API
  `OtoHaptics` already uses for the intro. It needs a Force Touch trackpad or
  a Magic Trackpad and respects the system's haptic setting; on a mouse it is
  silently a no-op, and it needs no TCC grant. Fire it on the completion of
  the flight, not on the window closing, so the tap reads as the landing.

- **Removing a visible permission row** changes the onboarding story from three
  grants to two; that is the canonical product rule and the crash fix at once.
  Recoverable from git if the product decision changes.
- **Stored onboarding step** means a person who abandons mid-walk resumes there
  on the next launch; if a future version deletes a chapter, the clamp lands
  them on the nearest valid step.
- The Info.plist key removal is intentional; a future `SFSpeechRecognizer`
  introduction must re-add the key **and** expect the launch-host abort to
  return under Xcode/Conductor.
- Deferred: showing the row's guidance line inside Settings panes (today only
  onboarding prints "Allow it in System Settings → …"); the pill label now
  carries that job.

## Open questions

1. ~~Pill wording~~ — resolved by the user: **"Allow"**, one word, look
   unchanged.
2. ~~Settings mic footnote~~ — resolved: no new line in the panes. The raw
   change is the word inside the pill; onboarding keeps its existing guidance
   line for denied states. A Settings footnote stays deferred.
3. Menu label while onboarding is unfinished: **"Continue setup…"**
   (recommended) versus keeping "Show onboarding…".
