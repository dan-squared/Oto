# V6c: sidebar refinement (translucent indicator, spacing, bounce, title, hover, collapse)

Status: PLAN ONLY. Nothing implemented. Awaiting `execute`.

## 0. What the two screenshots proved (analysis)

- Dark shot: full-width WHITE pill, dark text/icons, NO blue → the
  `listRowBackground` takeover works; native selection is gone.
- Light shot: full-width BLACK pill SHOULD appear but shows WHITE +
  invisible text → the only remaining defect class is explicit-color
  resolution per scheme (`.primary`-style adaptive tokens can't be
  trusted in row backgrounds). Fix: hard explicit colors per scheme
  everywhere in the row (no adaptive tokens in fills or selected text).
- The ` seule native List + manual selection` architecture is
  validated — refine it, don't replace it. Native items used:
  `NavigationSplitView`, `List`, `Button`, `Menu`, `ScrollView`.
  Custom only: row fills, control capsules (unchanged this round
  except press physics).

## 1. Tinted translucent indicator + hover spacing

- Selected fill: NO solid color. Dark → white at 0.85 opacity;
  light → black at 0.85 opacity — explicit literals per scheme
  (never adaptive tokens): `scheme == .dark ? Color.white.opacity(0.85)
  : Color.black.opacity(0.85)`. Text/icon on selection: explicit
  contrast (black on the white pill, white on the black pill).
- Hover fill (unselected only): wash as today.
- Spacing between the two states: rows get vertical breathing via
  `.listRowInsets(top: 3, bottom: 3)` on top of the 36pt content, so
  a hovered row never touches a selected neighbor. Horizontal inset
  stays 6.
- Rationale for translucency over solid: sidebar shows traces of the
  material beneath (depth), and it degrades gracefully if any system
  surface ever paints under it again.

## 2. Button bounce + smoother feel

- New `OtoPressable` ViewModifier in `OtoControls.swift`: pressed →
  scale 0.96 with spring (response 0.25, damping 0.55); release
  springs back. Respects Reduce Motion (no scale when
  `OtoMotion.reduced`).
- Applied inside `OtoBig`, `OtoPill`, `OtoQuick` (all buttons inherit
  it — one place, consistent physics). Catcher Copy/Cancel + modal
  Done + rail actions all gain it free. Hover behavior untouched.

## 3. Remove "Settings" window title

- `WindowGroup("", id:)` — empty title, traffic lights stay. Native,
  zero-risk (no dressing code, no resurrection of the black-box
  class).
- Guard update (load-bearing): the single-open guard matches
  `styleMask.titled && title.isEmpty` (only window we own matching
  that shape; onboarding is titled, panels are borderless). Same
  focus-or-open semantics, both entries.
- Cost recorded: Exposé/AX window name goes generic (content
  unchanged). Accepted per ask.

## 4. Hover: background-only (kills perceived bold)

- Hover changes NOTHING but the fill. Text stays muted, weight
  stays regular, icon color stays — the "bold on hover" the user
  sees is a contrast illusion (muted→ink reads heavier); removing
  the text shift removes the effect structurally.
- Selected state keeps its explicit contrast colors (§1).

## 5. Sidebar collapse: provide reopen (the missing half)

- Root cause of the trap: collapse is reachable (edge swipe) but the
  toggle was removed, so a closed sidebar strands the user.
- Fix: `NavigationSplitView(columnVisibility:)` binding (owned by
  `SettingsRoot`, default all-visible) + custom edge chevron
  (`OtoDoor`-styled, `sidebar.left` glyph) revealed ONLY when the
  sidebar is hidden + View-menu command "Show Sidebar" (⇧⌘S) in the
  existing commands block. No toolbar (titlebar stays clean).
- Snap: with locked widths (210) the show/hide animates the column
  only; window stays fixed. Matrix judges smoothness — motion can't
  screenshot, human eyes own this one.

## 6. Verification

- Build green; suite green twice (flake protocol stands).
- Screenshot probe (established pipeline): light sidebar — black
  translucent pill full-width, white text, no blue; hover row wash
  with UNCHANGED text (prove no-bold); dark — same mirrored.
  Delete probe after.
- Matrix (human): bounce feel on Copy/Done/Change, collapse→chevron
  →expand round-trip smoothness, empty/short/50-word catcher cards,
  full dictation rounds (footer touched).

## 7. Risks

- `columnVisibility` binding + programmatic chevron is more code
  than a toolbar toggle — chosen to keep the titlebar clean per the
  standing aesthetic; fallback is the native toolbar toggle.
- Translucent fills over vibrancy stack translucency-on-translucency
  — matrix decides between 0.85 and solid.

## 8. Open questions (recommendations marked *)

- Q1 translucency strength 0.85 (*) vs solid?
- Q2 empty-title AX cost accepted (*)?
- Q3 custom edge chevron (*) vs native toolbar toggle?
