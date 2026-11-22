# Onboarding: drop the try-it page, anchor the mark, close on hands-free

Status: implemented in the working tree (the user asked to continue and
remove the try-it page directly).

## Goal

1. Remove the try-it chapter and its input field from onboarding. The walk is
   copy-only; Settings → Dictation keeps its own "Try it" field.
2. Replace the `A|` tag chip at the top of the copy column with the real Oto
   mark, so the finish flight has a visible place to start from.
3. Replace the try-it chapter with a real shipped feature. Chosen: hands-free
   recording (double-tap the hold key), the one dictation mode onboarding
   never taught.

## Why hands-free

- It is real: `ShortcutDispatch` has a hands-free trigger, Settings →
  Dictation names the double-tap, and `DictationCoordinator` runs the same
  session for both modes.
- It is not covered anywhere else in the walk: how / catcher / intelligence /
  dictionary all describe the transcript after it exists; hands-free changes
  how you dictate.
- It needs no new UI on a page the user asked to keep visual-free.

## Facts verified in the working tree

- Chapters are `[.how, .catcher, .intelligence, .dictionary, .tryIt]`
  (`OnboardingStage.Step.chapters`), raw values 1...5, `.welcome` 0 and
  `.handoff` 6. Renaming `.tryIt` → `.handsFree` in place keeps every
  persisted resume point landing on a real chapter.
- The tag chip is `OnboardingGlyph` + tag text in an ink capsule
  (`OnboardingChapters.swift`). It is the `A| Try it` seen in the report.
- `OnboardingWindowController.headerMarkScreenRect()` currently returns the
  *Welcome* header slot (`WelcomeLayout.frame(at: IntroTiming.duration,
  rise: 1)`) — a header the walk no longer draws, so the finish flight starts
  from empty space.
- The try-it plate owned the only call to `flow.prepareTrial()`; the trial
  also auto-focused a field. The Accessibility/microphone asks must move to
  the new last chapter or a fresh Mac finishes onboarding ungranted.
- `OtoMarkSource.cropped` is the plate-lifted template image already used by
  the Welcome handover; it is prewarmed in `show()` before the clock starts.
- `OnboardingStageTests` pins the chapter list, the order, the raw values and
  the `.handoff` clamp; all four change with the rename.
- The Xcode project uses `PBXFileSystemSynchronizedRootGroup`, so deleting
  `OnboardingPlates.swift` needs no pbxproj edit.

## Design

### Page mark (the flight's origin)

- One `OnboardingChapterLayout` (pure geometry) returns the frame numbers and
  `markRect(in:)` for a panel size. The view draws the mark with that rect and
  `headerMarkScreenRect()` reads the same function, so they cannot drift.
- The mark is a fitted box at the top-left of the page (x = leading margin,
  y = vertical padding), tinted with `OnboardingTheme.ink` as a template. It
  replaces the tag chip; per-chapter tags/symbols are gone (the titles carry
  the meaning and the user asked for no decoration).
- The mark hides while `stage.markInFlight` is true, exactly like the Welcome
  mark, so the moving copy is the only mark on screen.
- The copy block stays vertically centred; the footer stays bottom-left. The
  mark is a page header, not part of the turning copy, so its rect is stable
  across chapters and window sizes.

### Last chapter

`handsFree` (raw 5), copy:
- title: "Double-tap, keep talking"
- subtitle: "Tap Right ⌥ twice and Oto keeps listening until you tap again —
  no need to hold." (key name comes from the live config)

Finish flow, button labels and the resume clamp are unchanged apart from the
rename.

### Grants

`prepareTrial()` becomes `prepareDictation()`, still idempotent per walk. It
is called when the last chapter arrives (chapter view `onAppear` + step
change, and on `didBecomeActive` while on it), which is the same moment the
try-it plate used. Apple's own Accessibility and microphone dialogs remain
the only ask; the probe/test suppression is untouched.

### Cleanup

- Delete `OnboardingPlates.swift` (try-it plate), `OnboardingCard`,
  `OnboardingGlyph`, `flow.trialText`, and the now-orphaned theme tokens
  (`card`, `cardEdge`, `field`, `fieldEdge`, `tagIdle`, `tagActive`,
  `tagIdleText`).
- The media panel keeps its quiet gradient (no pictures) and loses the
  replaced-content ZStack.

## Exact file changes

- `Oto/Onboarding/OnboardingStage.swift` — rename `.tryIt` → `.handsFree`,
  chapter list, `.handoff` clamp, comments.
- `Oto/Onboarding/OnboardingChapters.swift` — copy table without tag/symbol,
  `OnboardingChapterLayout`, `OnboardingMark`, page-mark ZStack, simplified
  media panel, no tag chip, no card/glyph views.
- `Oto/Onboarding/OnboardingFlow.swift` — moves for `handsFree`, button
  titles, `prepareDictation()`, remove `trialText`.
- `Oto/Onboarding/OnboardingView.swift` — prepare on the last chapter (task
  and active-again), not `.tryIt`.
- `Oto/Onboarding/OnboardingWindowController.swift` — flight start from the
  page mark.
- `Oto/Onboarding/OtoProbe.swift` — capture the renamed last chapter.
- `Oto/Onboarding/OnboardingTheme.swift` — drop orphaned tokens.
- `Oto/Onboarding/OnboardingPlates.swift` — deleted.
- `OtoTests/OnboardingStageTests.swift` — renamed last step, plus layout
  tests for the mark rect.
- `OtoUITests/SettingsUITests.swift` — comment only.

## Verification

1. `xcodebuild -scheme Oto -destination 'platform=macOS' build`
2. `xcodebuild test -scheme Oto -destination 'platform=macOS'
   -only-testing:OtoTests`
3. `OTO_APPEARANCE=dark OTO_SHOT=...` walk: five chapters, no tag chip, mark
   at the top-left of every page, no field, Finish on the last chapter.
4. Manual: Finish flight leaves from the visible page mark and lands on the
   menu-bar item; Escape still closes without marking seen.

## Risks / deferred

- The mark is a page header at a fixed offset, so it does not follow the
  copy's vertical centring. This is deliberate: a stable flight origin.
- Removing the tag row removes the "Apple Intelligence" / "Dictionary"
  category labels; the titles and subtitles still name the feature.
- Hands-free copy names the live hold key; if someone records a custom key,
  the sentence follows it.

## Open questions

1. Keep the media panel at all now that every chapter is copy-only? Kept —
   it is the frame the walk has always had and the user only asked to keep it
   empty.
2. Should the page mark also appear on Welcome? No — Welcome already owns the
   big mark-and-word pair.
