# Titlebar parity vs Font Book (PLAN — awaiting approval, NO code changed)

Status: PLAN ONLY (2026-09-21). Situation → SDK findings → options +
recommendation (§5). Nothing implemented.

## 1. Situation

- Reference (user-supplied, both images): Apple Font Book, sidebar-collapsed
  (`vu7cI5`, "Show Sidebar" tooltip visible) and sidebar-expanded (`2NS1LD`).
  Target anatomy: toggle button beside the traffic lights, single compact
  bar, no title text, content owns its header.
- Subject: Oto Settings window. **No current Oto screenshot exists** — both
  supplied images are Font Book, so "no change" is unverified against any
  pixels. The verification protocol (§6) requires an Oto shot first.
- Process check (2026-09-21, read-only): exactly ONE Oto alive — PID 59293,
  the post-edit build (titles removed, defaultSize applied). "No change" is
  NOT a stale process.
- Saved-state check: no `app.Oto.savedState` on disk — no stale frame
  restoration is observable from here (does not prove SwiftUI scene storage
  isn't restoring size some other way — stated as unknown).

## 2. SDK findings (local MacOSX27.0.sdk, not memory)

- `NSWindow.h:306-309`: `titleVisibility` (default Visible) only hides title
  TEXT; `titlebarAppearsTransparent` only removes the background, and is
  "only useful when `NSFullSizeContentViewWindowMask` is set" — i.e. the
  Font Book unified bar = transparent background + full-size content +
  toolbar-in-titlebar, as one package.
- SwiftUI swiftinterface: `ToolbarDefaultItemKind.sidebarToggle` EXISTS —
  `NavigationSplitView` provides the toggle as an automatic toolbar item;
  explicit placement control is available natively (no custom buttons).
- `windowStyle(.titleBar)` EXISTS (verified §9) — already the 03-compliant
  setting; it does not shrink the Settings titlebar row.
- `.defaultSize` on a Settings scene: NO header evidence it overrides scene
  restoration; effect unverified — screenshot verdict required.
- ACP doc-search bridge is absent this session (recorded §9); no doc quotes
  beyond headers are claimed.

## 3. Why "no change" — ranked hypotheses (not conclusions)

- H1 (needs no code): the comparison is memory-vs-memory — without an Oto
  screenshot, neither "changed" nor "unchanged" is established. Rule out
  first (§6 step 1).
- H2: `.defaultSize` not honored by the Settings scene (or scene storage
  restores the old narrow frame through a path invisible from `ps`) —
  sidebar still collapses, toggle still floats, layout identical.
- H3: titles ARE gone but the Settings scene keeps its standard titlebar
  row regardless — the band shrinks only partially, and the remaining
  height is native chrome, not our content.
- H4: user inspected the wrong surface (menu extra, old window) — unlikely
  (single fresh process) but cheap to exclude via screenshot.

## 4. The category problem (read before choosing)

Font Book is a REGULAR window with a toolbar. Oto Settings is a SETTINGS
scene — mandated by START_HERE ("one native Settings scene", Cmd-comma +
SettingsLink integration) and 03 (explicit titlebar-transparency ban). The
exact Font Book bar (unified, titleless, toolbar-in-titlebar) is
technically ONE package: transparent background + full-size content — i.e.
precisely the deleted accessor. There is no native half-measure that yields
their pixels: hiding title text alone (narrow, 03-legal) removes the word,
not the row.

## 5. Options + recommendation

- **A. Native Settings chrome, Font-Book-informed (RECOMMENDED).**
  Zero titles (done), sidebar visible (done, verify), explicit leading
  toolbar toggle beside the lights (native `ToolbarItem`, system glyph,
  no custom art), content sections unchanged. Whatever bar height remains
  IS macOS Settings chrome — the reference class becomes Xcode/Safari
  Settings, not Font Book. Cost: smallest; rules intact; remaining delta
  vs Font Book is declared, not hidden.
- **B. A + hide title text via narrow AppKit accessor (no transparency, no
  repositioning, no strip surgery).** Removes the word if any title text
  survives; does NOT change bar height. Cost: one small representable,
  03's letter kept ("never TRANSPARENT"), spirit debatable — say so openly.
  Recommend only if the screenshot shows surviving title text.
- **C. Full Font Book bar (transparency + full-size content).** REJECTED
  unless you explicitly override 03: it reinstates the deleted hack by
  another name, with the same hover/rebuild fragility that got it deleted.
- **D. Settings as a regular Window scene styled like Font Book.** REJECTED:
  breaks START_HERE's Settings-scene mandate and Cmd-comma/SettingsLink
  integration for pixels.
- **E. Do nothing further (declare parity complete).** Available if the Oto
  screenshot shows A already achieved — H1 must be excluded first.

Standing recommendation: **A now; B only on screenshot evidence of
surviving title text; C/D require your explicit rule override, which I
advise against.**

## 6. Verification protocol (no code until approved)

1. User sends a CURRENT Oto Settings screenshot (both sidebar states if
   possible) — excludes H1/H4.
2. On approval: implement the chosen option, rebuild, UI suite, relaunch.
3. Fresh Oto screenshot compared against the Font Book anatomy checklist
   (toggle beside lights / single compact row / no title text / sidebar
   visible / uniform rows). Residual delta, if any, is measured in pixels
   against THIS checklist, not memory.

## 7. Oto screenshots (2026-09-21) — H1/H4 excluded, diagnosis revised

- `H6f4ql` (General, sidebar collapsed): titlebar reads "Oto Settings";
  toggle floats below-left in content; dead band to the "General" header.
- `GrDXcq` (sidebar expanded): rows uniform with blue accent glyphs (the
  row-icon complaint is RESOLVED by this evidence — they match); toggle
  still floats at the top of the sidebar column, NOT in the toolbar;
  same dead band under a titlebar that reads "Oto Settings".
- `bX4WXL`: Apple Clock segmented switcher (World Clock/Alarms/…) —
  user's proposed alternative to the sidebar.

**Revised findings (overrule parts of §3):**
- F1: "Oto Settings" is the SETTINGS SCENE's own title, not our content:
  all three `.navigationTitle`s are already deleted (§11 executed, code
  verified), yet the text persists. Omission is exhausted — anything
  further here is AppKit surgery, not SwiftUI omission.
- F2: the toggle is NOT in the toolbar in either state. `NavigationSplitView`
  did not place it beside the lights automatically in this scene. Explicit
  native toolbar placement is the remaining lever (SDK: automatic
  `ToolbarDefaultItemKind.sidebarToggle` exists; explicit `ToolbarItem`
  control is untested — screenshot loop decides).
- F3: the dead band = standard Settings titlebar row + grouped-Form top
  inset. With titles deleted and it persisting, the row is native chrome,
  not our content. Shrinking it further means leaving native chrome
  (see options).
- F4: defaultSize did NOT visibly take (shot 1 collapsed at open). Either
  not honored by Settings scenes or overridden by scene storage through an
  unobserved path. Explicit toolbar + screenshot loop is the decider, not
  more static reading.

## 8. Options (user reads, analyzes; I recommend; user approves; then change)

- **A. Explicit leading toolbar toggle + accept the title row (RECOMMENDED).**
  Native `ToolbarItem` beside the lights driving the standard sidebar
  toggle; "Oto Settings" stays (every Apple Settings window carries its
  title — Xcode, Safari, System Settings). Fixes the two placed complaints
  (toggle position, collapse handling) with zero rule-breaking; the bar
  height that remains is macOS Settings chrome, reference class stated.
- **B. A + Clock-style segmented switcher INSTEAD of sidebar.** Kills the
  toggle/collapse class entirely (no sidebar, nothing to collapse) and
  matches the user's reference. COST: overrides the explicit 03/START_HERE
  sidebar mandate ("Use NavigationSplitView with a native List sidebar")
  and re-opens the IA at Phase 6 when rows double to four. Viable only on
  your explicit rule override — I advise against while the mandate stands.
- **C. Segmented + sidebar together.** REJECTED: two navigations for two
  panes is redundant chrome by any standard.
- **D. Hide title text via narrow AppKit accessor (no transparency, no
  repositioning).** Removes the WORD "Oto Settings", not the row height —
  only choose this if the text (not the height) is the complaint. 03's
  letter survives ("never TRANSPARENT"), spirit debatable — said openly.
- **E. Nothing further.** If A still leaves a bar you dislike, the honest
  statement is that Settings chrome is what it is — Font Book parity was
  always the wrong reference class (regular window vs Settings scene).

**Recommendation: A.** It answers both placed complaints inside the rules;
  B is yours to take only by overriding the product docs, with the Phase-6
  cost named above.

## 9. Option A executed (2026-09-21, approved)

Explicit `.toolbar` + `ToolbarItem(.navigation)` driving standard
`toggleSidebar(_:)`, system glyph, beside the lights. TEST SUCCEEDED,
relaunched. Awaiting screenshot verdict: toggle in toolbar (single, not
duplicated), sidebar state, residual bar height.

## 10. HSplitView experiment (2026-09-21, user-directed override)

User overrode the 03 NavigationSplitView mandate: fixed two-column layout
with nothing to collapse. Terms: try it; on user word, revert. This section
is the revert receipt — the NavigationSplitView shape lived in
`SettingsRoot.swift` pre-edit (List(selection:) + detail switch + toolbar
toggle) and restores verbatim on request.

## 14. Sidebar presence + title position (2026-09-21) — user screenshot

Device evidence (`ZDrlD9`, General pane): HSplitView renders — sidebar
visible, selection blue and native, rows uniform. Two asks: (a) "Oto
Settings" title sits top-left beside the lights — move it right/center;
(b) rows read thin vs surrounding type — size them up, 14pt guidance
explicitly lifted by the user.

**Findings:**
- (b) is straightforward and authorized: sidebar rows get explicit type
  (15pt) + larger glyph scale. Scoped to the rows only (not a global font
  modifier — the 03 rule that remains). Hover/select states need nothing:
  native List selection is already correct in the screenshot.
- (a) Title position is system-drawn window chrome: the string is the
  Settings scene's own title (proven §7 F1 — survives zero
  `.navigationTitle`s), and macOS places scene titles itself. No supported
  SwiftUI/AppKit API centers it; toolbar content can influence toolbar
  layout but with unpredictable, version-specific results. Stated plainly
  instead of faked.

## 15. Options (user analyzes; I recommend; user approves; then change)

- **A. Bigger rows only (RECOMMENDED).** 15pt + larger glyph scale on
  sidebar rows; title left exactly where macOS puts Settings titles
  (Xcode/Safari Settings agree). Fixes the evidenced complaint (thin
  rows) with zero chrome fights.
- **B. A + toolbar-layout experiment for title position.** Add toolbar
  content hoping the title centers. Uncertain outcome, adds chrome to
  chase pixels the system owns — advise against unless the title
  position (not the rows) is the real irritant. Screenshot loop decides,
  not theory.
- **C. Hide the title text (narrow accessor, §8 option D revived).**
  Removes the word, keeps the row height — only if the TEXT offends.
  Does not center anything.

## 16. Title rename verdict (2026-09-21) — "Settings", not "Oto Settings"

SDK-verified (`SwiftUI.swiftinterface:533`): `Settings` exposes ONLY
`init(content:)` — no title parameter exists. "Oto Settings" is
system-composed (app name + Settings) and NOT settable by any supported
API. Rows fix shipped in the same pass (15pt, glyph scales with text).
Remaining choice is binary: keep the composed title, or hide title text
entirely (narrow accessor, no transparency — removes the word, changes no
height). Awaiting user pick; nothing further built on the title.
