# Onboarding — hero layout, pure ground, media panel

_User ask, 2026-11-03 (reference: Mobilerun hero card; current chapter shot)._

## Goal

Bring the chapter frame in line with the reference: words top-left, a large
rounded gradient media panel on the right, Back + Continue in the bottom-left
corner, no centred "Oto" header on chapters, and a stage that is pure black
(better: `#000`) in Dark and pure white (`#FFF`) in Light — never
`windowBackgroundColor`.

## Reference read

- Copy block starts at the top of the content area, left column only.
- Media fills the right column edge-to-edge with the column, inset from the
  window by the page margin, rounded ~24 pt, with a soft two-stop gradient.
- One row of actions at the bottom-left, below the copy column.
- No branding above the copy inside the card.

## Decisions (and what was rejected)

- **Keep the chapter's real plates, composited inside the media panel.** The
  panel is the film frame; today it holds the Flow Bar preview, catcher,
  recorder, permission rows and try-it field. Replacing them with a flat
  gradient would delete the only place a first-run user can grant permissions
  and record the key. The gradient is the placeholder *behind* them.
- **Header removed from chapters only.** Welcome keeps the arrival (shader →
  mark → word) as its hero; leaving Welcome fades the pair instead of rising
  it into a header. `WelcomeLayout.frame(rise:)` and its tests stay untouched;
  the finish hand-off still flies from the header slot (now empty) to the menu
  bar, which reads as the app leaving the window.
- **Progress dashes move to the bottom-right**, the buttons keep the left
  corner. Nothing is lost; the row stays one line.
- **Pure ground lives in the shader too.** The Metal composite paints
  `OtoSurface` behind everything, so only changing the window colour would
  leave a grey stage wherever the shader still draws. Both resolve to pure
  white/black now.

## Exact file changes

1. `Oto/Onboarding/OnboardingTheme.swift`
   - add `ground` (dynamic: light `#FFF`, dark `#000`);
   - add `mediaTop`, `mediaBottom`, `mediaEdge` (dynamic, cool silver → slate).
2. `Oto/Onboarding/OnboardingChapters.swift`
   - new frame: `HStack(alignment: .top)` with a fixed copy column and a
     flexible rounded gradient media panel; top padding instead of centring;
   - footer: Back, Continue, spacer, dashes — buttons at bottom-left;
   - `OnboardingPreviewPlate` loses its own backdrop (the panel is the
     backdrop); content scales and centres;
   - `thing(for:)` centred inside the panel with one inset.
3. `Oto/Onboarding/OnboardingView.swift`
   - `WelcomePair` only while `stage.isWelcome`, no `rise`; the pair fades on
     the way into the first chapter; drop the now-meaningless rise haptic.
4. `Oto/Onboarding/MetalOnboardingShaderView.swift`
   - `OtoSurface.resolve` returns pure black / white.
5. `Oto/Onboarding/OnboardingWindowController.swift`
   - window background is the same pure dynamic colour.
6. `Oto/Onboarding/OtoProbe.swift`
   - capture composite honours `OTO_APPEARANCE` (probe only), so the dark
     screenshot is actually dark.

## Verification

- `xcodebuild -scheme Oto -destination 'platform=macOS' build`.
- Probe both appearances (`OTO_SHOT`, `OTO_APPEARANCE=dark|light`), inspect all
  five chapters for margins, header absence, footer and panel padding.
- `xcodebuild test -scheme Oto -destination 'platform=macOS'` (WelcomeLayout and
  stage tests must stay green).

## Risks / deferred

- The gradient is a stand-in; when real chapter media exists it replaces the
  fill, the panel geometry stays.
- The finish flight starts at the old header slot; if it reads as popping in
  from nowhere, the next pass can start it from the panel's top edge.
- Welcome's own button stays centred; only the chapters moved.
