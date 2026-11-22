# Settings dark theme: deeper ground, real card contrast

Status: PLANNED. Awaiting "execute".

## Goal

Dark mode Settings currently reads as one flat grey slab: the window/form ground
is `0.11` white and grouped cards are about `0.145`, a delta of roughly `0.03`
(measured from `.context/final-general-dark/settings-general.png`: ground
`30,30,30`, card `37,37,37`). Text contrast is acceptable; surface hierarchy is
not.

Make the dark settings ground genuinely dark (`0.055`) while leaving the
system grouped cards, sidebar material, text tokens and **light mode** exactly
as they are. The result is a clear three-level hierarchy: dark ground → cards →
sidebar glass.

## Facts verified

- `OtoPalette` owns every adaptive pair in one table
  (`Oto/UI/Theme/OtoPalette.swift:47-70`). `ground` is `pair(1.0, 0.11)`.
- Settings uses a grouped SwiftUI `Form` for every list pane
  (`Oto/Settings/SettingsPanel.swift:35-48`) and a borderless canvas for empty
  states (`:52-65`).
- The settings window is a normal titled window with
  `.fullSizeContentView`, hidden title and transparent titlebar
  (`Oto/Settings/SettingsWindowController.swift:31-53`); its background is
  `.windowBackgroundColor`.
- The sidebar paints `.regularMaterial` over the window
  (`Oto/Settings/SettingsRoot.swift:455-458`); the detail column hosts the pane
  directly.
- Current screenshots (content view, 2×):
  - dark: detail ground `30,30,30` (0.118), card `37,37,37` (0.145),
    sidebar ~`35,35,35`;
  - light: ground `255,255,255` (1.0), card `247,247,247`.
- So `pair(1.0, 0.055)` preserves light mode byte-for-byte while darkening
  only dark mode.
- `.scrollContentBackground(.hidden)` is already used in the codebase
  (`Oto/Onboarding/OnboardingPlates.swift:318`) and is available on the
  deployment target.

## Decision

Add one token, `settingsGround`, and let the window, detail canvas and grouped
form share it:

```swift
// OtoPalette.swift
static let settingsGround = Color(nsColor: NS.settingsGround)

// NS namespace
nonisolated static let settingsGround = pair(1.0, 0.055)
```

`0.055` resolves to ~14/255. Against the unchanged card (~37/255) that is a
~0.09 surface delta, and against `ink` (0.93) roughly 15:1 text contrast.

Keep `ground` at `0.11`: it is the Flow Bar/other-surface token. Settings is
deliberately the darkest surface in the app; renaming or retuning `ground`
would change the pill and is out of scope.

## File changes

1. `Oto/UI/Theme/OtoPalette.swift`
   - Add `OtoPalette.settingsGround` next to `ground`.
   - Add `NS.settingsGround = pair(1.0, 0.055)` with a comment naming it as the
     Settings-only ground.
2. `Oto/Settings/SettingsWindowController.swift`
   - `window.backgroundColor = OtoPalette.NS.settingsGround` instead of
     `.windowBackgroundColor`. This is what the transparent titlebar and any
     uncovered split area show.
3. `Oto/Settings/SettingsPanel.swift`
   - `OtoPaneForm`: add `.scrollContentBackground(.hidden)` and
     `.background(OtoPalette.settingsGround)` after `.formStyle(.grouped)`
     (keep the existing `contentMargins` line). Hiding the scroll background
     is what lets the darker ground through around the cards.
   - `OtoPaneCanvas`: add `.background(OtoPalette.settingsGround)` so empty
     states match list panes.
4. `Oto/Settings/SettingsRoot.swift`
   - `detailContent`: add `.background(OtoPalette.settingsGround)` as the
     hosting-view safety net (covers the brief layout gap before the pane
     paints).
   - `sidebarContent`: keep `.regularMaterial`, then add
     `.background(OtoPalette.settingsGround)` **behind** it so the material
     samples a deterministic dark base instead of whatever the window happens
     to paint.
5. `OtoTests/Theme/OtoThemeTests.swift`
   - Add `settingsGroundIsDarkerInDarkAndUnchangedInLight`:
     dark `settingsGround` is at least `0.03` below dark `ground`; light
     `settingsGround == 1.0`; the token still differs per scheme.
   - Add it to the existing `palettePairsDifferByScheme` token list.

No pane file changes: every pane already goes through `OtoPaneForm` or
`OtoPaneCanvas` (verified by `grep`: `GeneralPane`, `DictationPane`,
`DictionaryPane`, `SnippetsPane`, `HistoryPane`, `PrivacyPane`,
`IntelligencePane`, `AboutPane`).

## Verification

1. `xcodebuild -scheme Oto -destination 'platform=macOS' build`
2. `xcodebuild test -scheme Oto -destination 'platform=macOS'
   -only-testing:OtoTests`
3. Capture both appearances, several panes:
   ```
   OTO_APPEARANCE=dark OTO_SETTINGS_SHOT=.context/settings-dark-after \
     OTO_SETTINGS_PANES=general,dictation,history,privacy,intelligence,about \
     <Oto.app>/Contents/MacOS/Oto
   OTO_APPEARANCE=light OTO_SETTINGS_SHOT=.context/settings-light-after \
     OTO_SETTINGS_PANES=general,dictation,history,privacy,intelligence,about \
     <Oto.app>/Contents/MacOS/Oto
   ```
4. Sample pixels with PIL and check numerically:
   - dark detail ground ≈ `14,14,14` (±3);
   - dark card ≈ `37,37,37` (unchanged);
   - dark sidebar visibly between ground and card (not crushed to black);
   - light ground stays `255,255,255` and light cards stay `247,247,247`.
5. Compare the before/after dark screenshots by eye for: card borders still
   legible, secondary text still readable, selection fill still visible,
   toolbar glass and traffic lights still legible, empty states not floating
   on a black void.
6. Run `OtoUITests/SettingsUITests.testSettingsOpensAsOneNativeWindow` and the
   settings walk; also open Settings, switch panes, search, and open the
   shortcut recorder (its popover must not inherit a stale light background).
7. Check both appearances live (`System Settings → Appearance`) without
   relaunching, so the dynamic token re-resolves.

## Risks / deferred

- **Material crush.** `.regularMaterial` over `0.055` may read nearly black in
  dark mode. If the sidebar loses its glass separation, raise the ground to
  `0.06` or add a 0.5 pt top highlight to the sidebar; the token is one number.
- **Card colour assumption.** The card value comes from the system grouped
  form, not from us. The numeric check in step 4 is the guard; if macOS changes
  it, adjust the ground, never hard-code a card colour.
- **Light mode drift.** `pair(1.0, …)` matches the measured white ground, but
  the hidden scroll background may expose the hosting view instead of the
  form in some layout pass. The light screenshot comparison is the guard.
- **Other surfaces stay at 0.11.** The Flow Bar and onboarding keep their own
  tokens; this plan intentionally does not touch them.
- **No custom traffic lights / second window.** The fix is background-only and
  preserves the native window chrome.

## Open questions

- Is `0.055` the right depth, or should Settings go to `0.05`? Recommendation:
  `0.055` — it doubles the current card/ground delta without turning the
  window into a black hole.
- Should the sidebar get a slightly lighter explicit tint instead of relying
  on material sampling? Deferred until the after-screenshots are reviewed.
