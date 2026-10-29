# General gets Behavior; onboarding loses the Speech chapter

Status: PLANNED (not implemented). Awaiting "execute".

## Goal

1. **Behavior lives in General.** "Show catcher when there's nowhere to paste"
   and "Mute media while dictating" move out of Dictation into General. The
   copy, keys and defaults do not change — only the destination.
2. **The Speech chapter leaves onboarding.** "Works offline / Speech" (the
   `OnboardingSpeechPlate`) disappears; the dash count drops from six to five
   and the path becomes welcome → how → catcher → shortcut → permissions →
   try it → handoff.

## Specification sources

- User screenshot `.context/attachments/ZI2BkM/…png` — the Behavior card that
  must move (verbatim copy: "Catcher: no text field? Oto opens a small window.
  Off: auto-copies instead." / "Mute: silences speakers, restores volume
  automatically.").
- User screenshot `.context/attachments/95J4Ie/…png` — the Speech chapter that
  must go.
- `Oto/Settings/DictationPane.swift` lines 101–108 (the card),
  `Oto/Settings/GeneralPane.swift` (destination),
  `Oto/Onboarding/OnboardingStage.swift` (`Step`, `chapters`, `rows`),
  `Oto/Onboarding/OnboardingFlow.swift` (`next`/`back`/`buttonTitle`),
  `Oto/Onboarding/OnboardingChapters.swift` (copy + `thing(for:)`),
  `Oto/Onboarding/OnboardingPlates.swift` (`OnboardingSpeechPlate`).

## Facts verified

- The two toggles bind raw `@AppStorage` keys owned elsewhere:
  `app.Oto.noTargetModal` (pinned to `NoTargetModalSettings.key` by
  `NoTargetModalTests`) and `app.Oto.muteMediaWhileDictating`
  (`MediaDuckSettings.key`, pinned by `MediaDuckTests`). Moving the views does
  not touch either key or either test.
- `OtoUITests/SettingsUITests.swift` clicks **Dictation** and then reads
  `toggles["CatcherToggle"]` (line 72–73). With the card moved, that test must
  read the toggle under General instead (it already navigates to General first
  for the Dock toggle, so this simplifies the test).
- `SettingsPane.searchTerms` (lines 55–59) advertises "catcher media" under
  Dictation; General's term list has neither.
- `OnboardingStage.Step` is `IntEnum` with `.speech` between `.permissions` and
  `.tryIt`; `chapters` is a static array; `rows` only counts `.how`.
  `OnboardingChapterCopy.copy(for:)`, `OnboardingChaptersView.thing(for:)`,
  `OnboardingFlow.buttonTitle/next()/back()`, and `OtoProbe.captureIfRequested`
  (line 124–127) all switch over it.
- `OnboardingSpeechPlate` is the only consumer of `flow.prepareSpeech()`;
  `uiState.runPrepare()` is also used by Settings' readiness row, so the
  service stays. `OnboardingStageTests` line 18 pins the chapter list and line
  68 advances to `.speech`.
- Nothing else in the app opens a speech download on first run: the speech
  asset is prepared only from Settings (Readiness) or the chapter being
  removed. That is the one consequence that needs a decision (open question 1).

## Design

### 1. Behavior → General

- Cut the `Section { Toggle… Toggle… OtoPanelNote… } header: Text("Behavior")`
  block from `DictationPane` and paste it into `GeneralPane` **after** the Flow
  Bar section (app behaviour, not dictation input), same order, same copy,
  same `CatcherToggle` accessibility identifier.
- `GeneralPane` gains the two `@AppStorage` properties (no new store, no new
  key — the 12:46 one-store rule is untouched: these are scalar preferences).
- `SettingsPane.searchTerms`: General becomes
  `"launch login dock flow bar position catcher media mute"`; Dictation drops
  `"catcher media"` and keeps the rest.
- `DictationPane`'s header comment ("Everything that makes dictation work …")
  drops "behavior" if it mentions it; no other change.
- Update `SettingsUITests` as described, and keep the flip-and-restore
  discipline.

### 2. Speech chapter removed

- `OnboardingStage.Step`: delete `case speech`;
  `chapters = [.how, .catcher, .shortcut, .permissions, .tryIt]`.
- `OnboardingChapterCopy.copy(for:)`: delete the `.speech` case.
- `OnboardingChaptersView.thing(for:)`: delete the `.speech` case.
- `OnboardingFlow`: `buttonTitle` switch drops `.speech`; `next()` goes
  `.permissions → .tryIt`; `back()` goes `.tryIt → .permissions`; delete
  `prepareSpeech()`.
- `OnboardingPlates.swift`: delete `OnboardingSpeechPlate`.
- `OtoProbe`: drop `(.speech, 0)` from the capture list.
- `OnboardingStageTests`: chapters expectation becomes the five above;
  `openOnlyOpensRowsThatExist` advances to `.permissions` instead of `.speech`.
- `SettingsUITests.finishOnboardingIfPresent` comment: "then shortcut,
  permissions, and tryIt finishes" (the loop itself is count-based and still
  works).
- Accessibility: the removed chapter was the only place the footer counted
  six dashes; five is correct after the change and is asserted by the test.

## Exact file changes

| File | Change |
|---|---|
| `Oto/Settings/GeneralPane.swift` | add Behavior section + two `@AppStorage` |
| `Oto/Settings/DictationPane.swift` | remove Behavior section + its `@AppStorage` |
| `Oto/Settings/SettingsRoot.swift` | search terms for General / Dictation |
| `Oto/Onboarding/OnboardingStage.swift` | drop `.speech`, five chapters |
| `Oto/Onboarding/OnboardingChapters.swift` | drop `.speech` copy + plate |
| `Oto/Onboarding/OnboardingFlow.swift` | path + title + delete `prepareSpeech` |
| `Oto/Onboarding/OnboardingPlates.swift` | delete `OnboardingSpeechPlate` |
| `Oto/Onboarding/OtoProbe.swift` | drop the chapter from the capture list |
| `OtoTests/OnboardingStageTests.swift` | chapter list + advance target |
| `OtoUITests/SettingsUITests.swift` | catcher under General; comment |

## Verification

1. Build; run `OtoTests` (chapter-order tests are the guard for the path).
2. `OTO_SHOT=.context/onboarding-shots` at light and dark: exactly five dashes,
   no "Works offline" chapter anywhere in the walk, and the permissions
   chapter still grants for real.
3. Settings probe, General: Behavior card sits under Flow Bar with the same
   two switches and the same note; Dictation no longer has it.
4. UI test: `SettingsUITests.testSettingsOpensAsOneNativeWindow` — catcher flip
   round-trips under General.
5. Regression: `Search "catcher"` in the sidebar lands on General, not
   Dictation (the search term move is the only behaviour of that field).

## Risks / deferred

- **Speech asset readiness** (open question 1). Without the chapter, a fresh
  Mac reaches "Try it" before the on-device model is installed, so the first
  real dictation may need a download anyway. Options: (a) prepare silently in
  the background once the permissions chapter is satisfied; (b) keep a
  one-line readiness row inside the permissions card; (c) accept and leave the
  download to Settings. Default in this plan: (a), a background
  `uiState.runPrepare()` fired when the permissions chapter is shown — no new
  UI, no chapter.
- Removing a chapter changes the recorded onboarding "shape" but not
  `OnboardingStore.version` (the version marks completion, not content).
- Anyone mid-onboarding when the app updates keeps their stored version; only
  fresh installs see five dashes. Deferred.

## Open questions

1. Speech download: silent background prepare (recommended), a small row inside
   the permissions card, or nothing at all?
2. Behavior card placement in General: after Flow Bar (recommended) or above
   it?
