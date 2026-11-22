# Onboarding remake: keep the intro, adopt the TourKit slide language

Status: REVERTED. Implemented in the working tree, reviewed by the user, and
rolled back to the committed onboarding on 2026-11-07. The committed chapter
frame is now being refined in place instead (traffic lights hidden, page dashes
removed, centred copy, symmetric media margins, window-matched corner). Kept as
a record of the analysis; do not re-apply without a new decision.

## Goal

Keep the arrival exactly as it is — the Metal light, the soundtrack, the
haptics, the mark, the desktop dimming, the carrier→native handoff — and
replace everything *after* Welcome with a clean, card-based walkthrough in the
spirit of `rampatra/TourKit`: one large real screenshot, a soft blend into a
text panel, a title + line, a page indicator, glass back/close controls, and
one pill CTA.

Also:

- remove the traffic lights from the onboarding window;
- replace the SVG/plate illustrations with real screenshots (placeholders now,
  drop-in replacements later);
- keep the shortcut recorder, permission grants, and try-it field *live* on
  their slides — they are the product, not pictures of it.

## Package analysis (cloned, not memorised)

Cloned `https://github.com/rampatra/TourKit.git` into `.context/tourkit`
(gitignored). Release tag `v1.0.0` (commit `0cac3a5`) is what
`from: "1.0.0"` resolves to; it is MIT licensed, macOS 13+, swift-tools 6.2,
zero dependencies, and the library source is a single 615-line
`Sources/TourKit/TourKit.swift`.

What TourKit actually provides:

| Feature | Verdict for Oto |
|---|---|
| `TourSlideshowView`: image hero, gradient blend, dark panel, title/description, page dots, glass back/close, one CTA, Return shortcut | Good visual reference; layout is worth adopting |
| `TourKitWindowController`: borderless, floating, fixed-size card window | Wrong window policy for Oto (see below) |
| `TourPage`: `LocalizedStringKey` title/description + image from bundle | Fine, but the model cannot carry a live control |
| Colours: `Color(white: 0.10)` panel, white type, blue gradient CTA | Conflicts with Oto's adaptive light/dark palette and monochrome pill |
| Motion: one `.easeInOut(0.25)` cross-fade | No Reduce Motion handling |
| Window: `.floating` level, borderless, fixed 660 pt, no resize | Oto's onboarding should not float above every app |
| Live controls (recorder, permissions, text field) | Not supported at all |

**Conclusion: do not add the package as a dependency.** It does not align on
theme adaptivity, window policy, CTA language, accessibility/reduce-motion, or
the only parts of onboarding that must actually do something. We implement the
slideshow pattern natively in `Oto/Onboarding/`, using TourKit's geometry and
choreography as the reference, which is the fallback the user allowed
("if it doesn't align with us, clone it, analyse it, and we will implement
some of its features").

## Source of truth / facts verified

- Xcode 27.2 (build 27B52), SDK `MacOSX27.2.sdk`, deployment target 27.0.
  `AGENTS.md` still says 27.0; the installed SDK is 27.2. Baseline
  `xcodebuild -scheme Oto -destination 'platform=macOS' build` succeeds.
- `OnboardingWindowController` currently opens a `.titled +
  .fullSizeContentView` window with hidden title and visible traffic lights;
  a borderless carrier carries the shader until the native window takes over.
- `OnboardingView` already switches between the intro (`WelcomePair` +
  subtitle + pill) and the chapters (`OnboardingChaptersView`).
- `OnboardingStage` already has `welcome, how, catcher, shortcut, permissions,
  tryIt, handoff`; `chapters` is `[how, catcher, shortcut, permissions,
  tryIt]`.
- `OtoPalette` is an adaptive light/dark pair table. `OnboardingTheme` already
  mirrors it but its `tagIdleText`/`tagIdle` pill is unreadable on the dark
  stage (seen in `.context/onboard-after-dark/how.png`), and the two-column
  chapter frame leaves a large empty column.
- `NSWindow.standardWindowButton(.closeButton/.miniaturizeButton/.zoomButton)`
  exposes the traffic lights; hiding and disabling them is a supported AppKit
  path and keeps the native window's resize, shadow, corners, and drag.
- SwiftUI `Button`, `TextEditor`, `OtoShortcutField`, `OtoStatus`,
  `OtoStatusAction`, `SettingsLink` all work inside the new card without new
  permissions.
- `OnboardingStore` / the no-skip rule: closing the window must not mark the
  flow seen. The new close control calls `performClose`, not `finish`.

## Assumptions challenged

1. **"Use TourKit as a package."** Rejected for the reasons above. We copy the
   pattern, not the dependency. No `Package.swift` / pbxproj change, no
   supply-chain or fixed-palette debt.
2. **"Remove the traffic lights means a borderless window."** Not necessarily.
   Hiding the three standard buttons on the existing titled window gives the
   same clean look while keeping native resize, shadow, rounded corners,
   keyboard window management, and the UI test's `app.windows["Welcome to
   Oto"]` lookup. We keep the titled window and hide the buttons.
3. **"A slideshow can host onboarding's functional chapters."** False as a
   pure image+copy slide. The shortcut recorder, permission rows, and try-it
   field remain live inside the slide's text panel. The screenshot above them
   is the illustration; the panel is the control.
4. **"The window can keep 1020×760 and the card can be any size."** A
   16:10 hero plus a readable panel needs ~775 pt of height. We grow the
   window to 980×820 (clamped to the screen) and make the hero height
   flexible so short windows crop the image before shrinking type.
5. **"The first slide is Welcome."** Welcome remains the intro's end state.
   The card is the walkthrough after the person presses Continue. The intro's
   clock, sound, haptics and handoff are untouched.

## Design

### Window

- Keep `OnboardingWindowController`'s carrier→native choreography, dimmers,
  sound, shader prewarm, and generation tickets.
- Native window size: `min(980, area.width - 24) × min(820, area.height - 24)`,
  minimum `720 × 640`.
- Hide `.closeButton`, `.miniaturizeButton`, `.zoomButton` on the native
  window; re-hide them in `windowDidBecomeKey` because AppKit revalidates
  titlebar buttons on focus changes. `zoomButton` stays disabled as today.
- Keep `title = "Welcome to Oto"` for the UI test and for window identity.
- The card is centered in the content view; the ground behind it is the
  onboarding ground (black in dark, white in light).

### Card (new `OnboardingTourCard`)

```
┌────────────────────────────────────────────┐
│  [mark]                            [close] │  ← over the image
│                                            │
│              real screenshot               │  16:10, scaledToFill
│                                            │
│         gradient into the panel            │
│              ●  ○  ○  ○  ○                 │  ← page dots
├────────────────────────────────────────────┤
│  Title                                     │
│  One or two lines of supporting copy       │
│  [live accessory, when the slide has one]  │
│                                            │
│  [‹ Back]              [ Continue ]        │  ← Oto pill
└────────────────────────────────────────────┘
```

- Card width: `min(760, window.width - 64)`.
- Panel height: 320 pt (fixed for every slide, so the card does not jump when
  moving between pure and functional slides).
- Hero height: `min(cardWidth / 1.6, window.height - 48 - panelHeight)`, with a
  floor of 180. The image uses `.scaledToFill()` inside the hero rect so a
  short window crops it instead of shrinking the panel.
- Corner radius 24, hairline border, soft shadow. The image is clipped by the
  same shape; the panel is the bottom part of the shape.
- The gradient over the image uses `OnboardingTheme.panel` at the bottom
  (clear → panel) so the screenshot melts into the panel on both polarities.
- Top chrome: small Oto mark at the top-left (this is also the start point of
  the finish flight), close glass circle at the top-right. Back is a glass
  circle in the footer, left of the pill, hidden on the first slide.
- Page dots: five capsules, current one longer; tap to jump (same behavior as
  the current dashes).
- Typography: rounded system font, title 30–34 pt medium, subtitle 14–15 pt
  `OnboardingTheme.muted`, tracking -0.8 on the title.
- CTA: reuse `OnboardingContinuePill` (inverted ink pill). Keep the labels
  "Continue" / "Finish" so the UI test and muscle memory survive.
- Motion: the card fades/scales in when leaving Welcome; slides cross-fade the
  image and replace the panel copy with a short vertical rise. Reduce Motion
  collapses to opacity only.
- Accessibility: the card is one group; title is a header; the image is
  decorative; dots have "Step N of 5"; back/close have labels and hints; the
  CTA keeps Return.

### Slides

Five chapters, same order and same `OnboardingStage` machine:

| Step | Image (placeholder name) | Panel |
|---|---|---|
| `how` | `OnboardingHow` — a text app with the Oto pill and a finished sentence | title "Speak. It lands." + one line |
| `catcher` | `OnboardingCatcher` — the catcher card | title "Nothing gets lost" + one line |
| `shortcut` | `OnboardingShortcut` — the pill/keycaps | live recorder row + double-tap caption |
| `permissions` | `OnboardingPermissions` — System Settings privacy | two live grant rows |
| `tryIt` | `OnboardingTryIt` — a document with text | live TextEditor + "Hold your key and speak" |

The old `tag` pill and decorative glyph are removed from the card. Copy is
shortened and kept in `OnboardingChapterCopy` (rename to `OnboardingSlide` or
keep the name) so it stays localizable.

### Images

- Add `Oto/Onboarding/OnboardingArtwork.swift`:
  `image(for: OnboardingStage.Step) -> Image?` loads the asset by name and
  falls back to the media gradient if missing.
- Add five imagesets to `Oto/Assets.xcassets` (single-scale universal):
  `OnboardingHow`, `OnboardingCatcher`, `OnboardingShortcut`,
  `OnboardingPermissions`, `OnboardingTryIt`. Placeholder PNGs 1600×1000
  (16:10), generated locally with a neutral gradient + SF Symbol + small
  "Screenshot placeholder" label. They are deliberately replaceable: dropping
  a real 16:10 PNG into the same imageset is the whole update.
- Record the expected size and names in this plan; a later screenshot harness
  (out of scope here) writes those five files.

## Exact file changes

New:

- `Oto/Onboarding/OnboardingTour.swift` — `OnboardingTourCard`,
  `OnboardingTourLayout` (pure geometry), top chrome, panel, footer, dots.
- `Oto/Onboarding/OnboardingArtwork.swift` — asset lookup + fallback.
- `Oto/Assets.xcassets/OnboardingHow.imageset/…`
- `Oto/Assets.xcassets/OnboardingCatcher.imageset/…`
- `Oto/Assets.xcassets/OnboardingShortcut.imageset/…`
- `Oto/Assets.xcassets/OnboardingPermissions.imageset/…`
- `Oto/Assets.xcassets/OnboardingTryIt.imageset/…`
- `OtoTests/OnboardingTourTests.swift` — layout math, slide/asset mapping,
  chapter order.

Modified:

- `Oto/Onboarding/OnboardingView.swift` — keep `WelcomePair`, the intro
  playback, and the Welcome CTA; replace the `OnboardingChaptersView` branch
  with the centered `OnboardingTourCard`; remove the travelling-pill anchor
  preference if it is no longer needed.
- `Oto/Onboarding/OnboardingChapters.swift` — stop drawing the two-column
  frame, tag pill, media gradient panel, and dash row; keep the copy table
  and the slide→view mapping; the chapter footer moves into the card.
- `Oto/Onboarding/OnboardingPlates.swift` — turn the three functional plates
  into panel accessories (no outer `OnboardingCard`, no media-panel sizing):
  `OnboardingShortcutAccessory`, `OnboardingPermissionsAccessory`,
  `OnboardingTryAccessory`. Reuse the existing recorder, status actions, and
  `TextEditor`.
- `Oto/Onboarding/OnboardingTheme.swift` — add `panel`, `panelEdge`,
  `pageDot`, `pageDotActive`; keep the adaptive ground/ink pairs. The old
  `mediaTop`/`mediaBottom` become the missing-image fallback.
- `Oto/Onboarding/OnboardingWindowController.swift` — window size/minimum,
  hide traffic lights (and re-hide on key), keep the carrier/dimmer/handoff
  logic; `headerMarkScreenRect()` now returns the card's top-left mark rect
  using `OnboardingTourLayout`, so the finish flight starts from a visible
  mark.
- `Oto/Onboarding/OnboardingContinueButton.swift` — keep the pill; drop or
  bypass the travel-slot machinery if no longer used (the card owns one pill
  and Welcome owns one; they do not need to cross the window).
- `Oto/Onboarding/OnboardingSound.swift`, `IntroTiming.swift`,
  `MetalOnboardingShaderView.swift`, `WelcomeLayout.swift`, `OtoMark.swift`,
  `OtoHaptics.swift`, `OnboardingHandoff.swift` — **no changes**. This is the
  guard that the intro stays exactly as asked.
- `OtoUITests/SettingsUITests.swift` — keep the onboarding walk; only touch
  the selector if the window title or CTA labels change. They should not.

## Verification

1. `xcodebuild -scheme Oto -destination 'platform=macOS' build`
2. `xcodebuild test -scheme Oto -destination 'platform=macOS'
   -only-testing:OtoTests`
3. Capture the walk in both appearances:
   ```
   OTO_APPEARANCE=dark OTO_SHOT=.context/onboarding-tour-dark \
     <Oto.app>/Contents/MacOS/Oto
   OTO_APPEARANCE=light OTO_SHOT=.context/onboarding-tour-light \
     <Oto.app>/Contents/MacOS/Oto
   ```
   Check every slide: title readable, panel not clipped, hero not stretched,
   dots correct, CTA reachable, no traffic lights in the real window.
4. Run `OtoUITests/SettingsUITests.testSettingsOpensAsOneNativeWindow`; the
   onboarding walk must still reach Finish and close.
5. Manual device pass: launch from a clean slate, watch the intro (shader,
   sound, haptics, handoff) unchanged, then walk the five slides, record a new
   key, grant microphone/accessibility, dictate into the try-it field, finish,
   and confirm the mark flight lands on the menu-bar item.
6. Confirm the window closes via the card's X and Escape without marking the
   flow seen (reopens next launch), and Finish alone marks it seen.

## Risks / deferred

- **Short windows / large text.** Flexible hero height + a 720×640 minimum
  keep the panel readable. If the panel still overflows at Accessibility text
  sizes, the accessory area scrolls rather than clipping.
- **Hide-vs-borderless.** Hiding standard buttons keeps native window
  behavior. If the user wants an actual borderless TourKit card, that is a
  one-line style-mask change plus a custom drag region; deferred until asked.
- **Path playback.** Hidden traffic lights are verified in the real window, not
  in `OTO_SHOT` (which captures the content view).
- **Placeholder art.** The five PNGs are intentionally placeholders. The
  layout must not depend on their exact content.
- **Package.** No dependency is added; the TourKit clone stays in
  `.context/tourkit` for reference only.

## Open questions

1. Keep all five chapters, or collapse shortcut + permissions into one
   "Set up" slide? Proposed: keep five — the UI test and the resume point
   already understand them, and each live control gets its own screen.
2. Should the close X be present at all? Proposed: yes; it closes without
   marking the flow seen, so first-run still reappears (current no-skip rule).
3. Placeholder art style: neutral gradient + SF Symbol + "Screenshot
   placeholder", or a plain grey 16:10 field? Proposed: the former, so the
   slides are reviewable at a glance.
4. Do you want the finish mark flight kept? Proposed: yes, starting from the
   card's top-left mark, so the brand leaves the onboarding for the menu bar.
