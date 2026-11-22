# Onboarding: port Firstlight's arrival flow to Oto

Status: BUILT. Shader intro and soundtrack included (answers to questions 1 and 2), 1020×760 clamped (question 3).

## Goal

Oto's first run should feel like Firstlight's: one full-window dark stage, a
hero mark that becomes the header, chapters that share one frame, one pill that
travels from the welcome to the footer and only changes its label, dashes that
count chapters, and transitions that hand over in place rather than sliding
pages. Oto's chapters carry Oto's content (shortcut, permissions, speech, try
it) and stay wired to the real services.

## Spec sources (read, not remembered)

Firstlight source in `~/Downloads/Firstlight-source/mac`:

| File | What it owns |
|---|---|
| `App/Interface/Onboarding/OnboardingWindowController.swift` (352) | Window: up to 1020×760 clamped to the screen, `.titled + .fullSizeContentView`, min 620×420, a borderless carrier window behind for the shader canvas, dimmer for the handoff. |
| `App/Interface/Onboarding/OnboardingStage.swift` (174) | `Step` enum (`welcome`, chapters, `handoff`), `chapters` list, per-step row counts, the shared `ObservableObject`, and the transition vocabulary: `forward`/`backward` (8 pt + opacity + blur), `turningForward/Backward` (12 pt sideways), `replacingForward`. |
| `App/Interface/Onboarding/OnboardingChapters.swift` (483) | The chapter frame: words left, plate right, footer; chapter copy table; `OnboardingDashes` (one dash per chapter, current one widens, rows fill it); rows that open one at a time. |
| `App/Interface/Onboarding/OnboardingContinueButton.swift` (220) | One pill for the whole flow. Anchor preference carries its slot so it travels from Welcome to the footer; violet vertical gradient, hairline top edge, glass on macOS 26; progress state. |
| `App/Interface/Onboarding/OnboardingView.swift` (357) | Full-bleed stage, `.preferredColorScheme(.dark)`, `.ignoresSafeArea()`, welcome hero (mark + name + line + pill), pair rising into the header on the first step. |
| `App/Interface/Onboarding/OnboardingSound.swift` (96) | One prepared soundtrack, `AVAudioPlayer`, kept alive for its tail. |
| `App/Interface/Onboarding/OnboardingSetupSteps.swift` (557) | Asked chapters: profile form, privacy choices, invite; card + chip styling. |
| `App/Interface/Onboarding/MetalOnboardingShaderView.swift` (416), `WelcomeLayout.swift`, `IntroPlayback.swift` | Shader logo timeline: the light becomes the mark, then hands over to a plain image. |

Oto today (`Oto/Onboarding/`, 605 lines): `OnboardingView` is a 5-page
620×480 flow (welcome, features, hold key, permissions, ready) with a
ground canvas, 26 pt titles, a capsule footer (dots + Back + Continue/Finish)
and 40 pt slide transitions. It is already wired to the real
`ShortcutDispatch` + `SettingsUIState` — that wiring must survive the port.

## What changes, in order

### Phase 1 — Stage and chrome (no content change)

1. `Oto/Onboarding/OnboardingStage.swift` (new)
   - `@MainActor final class OnboardingStage: ObservableObject` with
     `enum Step: Int, CaseIterable { welcome, how, shortcut, permissions, speech, tryIt, handoff }`
     and `static let chapters: [Step]` (the five between welcome and handoff).
   - Port the transition vocabulary verbatim (`forward`, `backward`,
     `turningForward`, `turningBackward`, `replacingForward`) with the same
     numbers (8 pt, 12 pt, blur), and the durations Firstlight uses
     (`stepDuration`).
2. `Oto/Onboarding/OnboardingWindowController.swift`
   - Window becomes `min(1020, screen - 24) × min(760, screen - 24)`, min
     620×420, `.titled + .fullSizeContentView`, title hidden, traffic lights
     only (no full screen — same rule as Settings).
   - Keep the existing `OnboardingStore` completion gate and
     `OnboardingWindowLocator` contract.
3. `Oto/Onboarding/OnboardingPill.swift` (new) — port
   `OnboardingContinueButton` + `OnboardingContinuePill` + the anchor
   preference and the travelling slot, so Welcome's button and the footer's
   are one object. Oto's palette replaces Firstlight's violet
   (`OtoPalette.accent`); glass on macOS 26 as today's `OtoSegmented` does.
4. `Oto/Onboarding/OnboardingDashes.swift` (new) — one dash per chapter; the
   current widens and fills with rows.

### Phase 2 — The shared chapter frame

5. `Oto/Onboarding/OnboardingChapterFrame.swift` (new) — words on the left
   (tag, title, line), a plate on the right (the live control), the dashes and
   pill in the footer. Only what differs between two chapters leaves.
6. `Oto/Onboarding/OnboardingView.swift` — rewritten as the stage: dark,
   full-bleed, header = mark + name after Welcome, chapters inside the frame.
   The current page switcher, `.frame(width: 620, height: 480)` and the
   `foot` capsule are deleted.
   - Keep `dispatch`, `uiState`, `onFinish` parameters and the
     `.task { holdKind = …; fnUsage = …; uiState.refreshPermissions() … }`
     loading exactly as they are.
7. `Oto/Onboarding/OnboardingChapters.swift` (new) — Oto's copy table:
   - **Shortcut** (asks): push-to-talk vs hands-free, the same recorder the
     Settings row uses.
   - **Permissions** (asks): microphone, Accessibility, Speech — each row is a
     live grant button, not a screenshot.
   - **Speech** (shows/asks): readiness + Prepare offline speech, reusing
     `uiState.runPrepare()`.
   - **Try it** (shows): the trial field, same as today's ready page.

### Phase 3 — Feel

8. `Oto/Onboarding/OnboardingSound.swift` (new) — the full soundtrack
   (`arrival-02.m4a`), not chapter cues: the visual clock is scaled into the
   recording so the music's crest lands on the reveal (see Built, item 2).
9. Reduced Motion: every travel collapses to the fade, as in Firstlight
   (`stage` transitions already carry this rule).

### Phase 4 — Tests and verification

10. `OtoTests/OnboardingTests.swift` — stage order, chapter count, dash fill
    maths, and the existing completion/`OnboardingStore` contract.
11. `xcodebuild build`, `xcodebuild test -only-testing:OtoTests`, and captures
    of each chapter at 1020×760 and at the 620×420 minimum.

## Built — decisions that differ from the plan above

1. **The Metal shader was ported, not dropped.** `MetalOnboardingShaderView`,
   `OtoMark`, `IntroTiming`, `WelcomeLayout` and `Oto/Resources/OnboardingShaders/Waves.metal`
   are the Firstlight files with Oto's mark and a cool silver palette
   (`OtoOnboardingPalette.silver`) instead of amethyst, so the light gathers
   into Oto's white waveform bars. Xcode compiles the `.metal` into
   `default.metallib`; the renderer prefers `device.makeDefaultLibrary()` and
   falls back to the bundled source, logging a fallback rather than failing
   silently.
2. **The soundtrack was ported.** `arrival-02.m4a` (Firstlight's) plays through
   `OnboardingSoundPlayer`; the visual clock is scaled into the recording
   (`clockScale = realHandoff / windowCue`), so the bass crest lands on the
   final reveal haptic. The intro therefore runs ≈10.1 s real, not 7.7 s —
   Firstlight's own pacing. With no sound (missing asset, Reduce Motion) the
   same timeline plays at 1× and is 7.7 s.
3. **The mark is a bundled 1024 px plate, not `NSApp.applicationIconImage`.**
   Oto's icon is a white waveform on a near-black rounded square, so the
   square has to be lifted out before the light gathers. The runtime `.icns`
   is composited by LaunchServices and its plate carries a light rim that
   survived thresholding and drew stray lines above and below the bars.
   `Oto/Resources/icon-1024.png` (a copy of `icon_512@2x.png`) is the same
   pixels the AppIcon set holds; the plate (peak ≈ 0.067) is removed with a
   0.30–0.55 ramp, the bars (peak ≈ 0.969) survive, and the same masked
   pixels feed the shader texture — so the plate carries no light at all.
   Keep the copy in step with the AppIcon.
4. **The pill is solid, not glass.** Glass layers are not captured by
   `cacheDisplay`, and on the dark stage a white-tinted glass pill is
   effectively opaque anyway. `OnboardingContinueButton` draws a white
   vertical gradient capsule with a hairline top edge — Oto's own inversion —
   which also makes the button visible in verification captures.
5. **No skip.** Firstlight's "Close" button is deliberately absent: the red
   close quits without marking `OnboardingStore`, and only Finish (try-it)
   marks it seen, per the existing no-skip rule.
6. **Handoff target.** Oto's `MenuBarExtra` exposes no `NSStatusBarButton`, so
   the mark flies to `OnboardingHandoff.menuBarTarget` (top-right of the main
   screen, under the menu bar) rather than to a real status item.
7. **Two windows, as in Firstlight.** A borderless carrier at
   `.statusBar + 1` draws the intro above a desktop dimmer at `.statusBar`,
   then hands over to the real `.titled` window at `IntroTiming.handoff`. The
   carrier is retired only when the native surface actually presents a Metal
   frame (`onNativeFramePresented`), so a dead shader can never leave a blank
   screen. Like Firstlight, the dimmer and the carrier sit above the menu bar
   for the length of the intro.
8. **Reduced Motion** collapses the whole intro (`playback.start` calls
   `finish()`), and the chapter transitions drop their travel, as planned.

## Tests

- `OtoTests/OnboardingStageTests.swift`: step order, the five chapters, row
  counts, `advance`/`open`/`reset` invariants, `IntroTiming.shaderTime`
  monotonicity across 2000 samples, the dimming curve, the welcome
  choreography's ordering, and `WelcomeLayout`'s centring/settle/rise maths.
- `OtoUITests/SettingsUITests.swift` walks the real flow: it waits for the one
  pill to become hittable (the intro is ~10 s), clicks Continue/Next until
  Finish appears, and finishes.
- `xcodebuild test -only-testing:OtoTests` → 582 tests, all pass except the
  pre-existing flaky `RealTextInsertionTests.retryPostsWithoutFocusGates`,
  which passes when run alone.

## Verification limits

Screen capture is unavailable on this machine (no Screen Recording; the
`CGWindowListCreateImage` API is gone on macOS 27), so the visuals were checked
with in-process `cacheDisplay` captures of the native window at every chapter
(Metal draws blank there, so the shader itself is proven by the fact that the
carrier is only retired from a presented Metal frame). Those capture hooks were
removed before commit.

## Open questions

None outstanding. The three questions above were answered: port the shader,
port the full soundtrack, use 1020×760 clamped.
