# Settings top-bar tabs (PLAN — awaiting approval, NO code changed)

Status: PLAN ONLY (2026-09-21). Answers "can you do that" with the native
mechanism, the rule overrides it costs, and the revert receipt.

## 1. Reference anatomy (user-supplied app screenshot)

Toolbar tab strip: icon-over-label tabs (Practice/Learning/Appearance/...),
centered, selected tab highlighted; titlebar carries traffic lights + the
*selected tab's* name centered ("Practice"); content is a plain grouped form
below. No sidebar, no toggle, nothing to collapse. This is macOS's classic
toolbar-tab preferences pattern (NSToolbar-backed).

## 2. Native mechanism (no custom drawing)

A `TabView` as the DIRECT root of a Settings scene, with `.tabItem {
Label(...) }` per pane, renders as exactly this: the tab labels become
toolbar tabs, the titlebar shows the selected tab name centered, traffic
lights stay system-drawn. Panes (`GeneralPane`, `DictationPane`) move
unchanged as tab content; `SettingsPane` enum survives as the selection
type (raw `Int` tags or the enum — enum kept). Zero custom art, zero window
surgery, all existing controls/rows/recorder untouched.

Confidence note, stated openly: this is SwiftUI's long-standing Settings
rendering contract, but its exact Tahoe/27 styling (pill vs underline
selection, spacing) is screenshot-verified after building, not asserted
here. If the render ever deviates, the fallback is the current HSplitView
(§10 receipt still held).

## 3. Rule overrides required (user signs explicitly)

- 03 "Use `TabView` only inside a selected sidebar destination" — this puts
  `TabView` at the ROOT instead of a sidebar. Direct override.
- START_HERE "Use `NavigationSplitView` with a native `List(selection:)`
  sidebar" — already overridden once for HSplitView (§10); this retires the
  sidebar concept entirely rather than its implementation.
- Cost at Phase 6: four icon tabs still fit a toolbar (the reference shows
  five), so no re-debate is forced — but the sidebar option stays dead
  unless explicitly revived.

## 4. Exact changes (on approval)

1. `Oto/Settings/SettingsRoot.swift` — rewrite root: `TabView(selection:)`
   with General + Dictation tabs (`Label(pane.title, systemImage:)`),
   `.frame(minWidth: 720, minHeight: 520)` + `.defaultSize` kept. HSplitView
   + List deleted from this file (panes untouched).
2. `OtoUITests/SettingsUITests.swift` — sidebar-row assertions die with the
   sidebar; replaced by toolbar-tab assertions (tab buttons by label —
   probe identifiers once via temp test if labels don't match, same loop
   as the Close-button fix).
3. Nothing else: panes, dispatch, preparer, permissions, login, menu,
   coordinator, tests besides the above.

## 5. Verification

- Build + full suite green (updated UI test proves: one window, native
  Close, both tabs present).
- Screenshot checklist vs reference: tabs centered with icon-over-label,
  selected tab highlighted, titlebar shows selected tab name, traffic
  lights native, content unchanged below.
- Revert receipt: HSplitView root (current `SettingsRoot.swift`) restores
  verbatim on your word, same terms as §10.

## 6. Recommendation

**Build it.** The mechanism is the platform's own preferences pattern (not
a custom control imitating one), it deletes the entire toggle/collapse/title
problem class instead of negotiating with it, both panes' code survives
untouched, and the selected-tab-centered title answers the title complaint
as a side effect. The only real price is the two rule overrides above —
take them explicitly and the plan is otherwise risk-free. Say **execute**.

## 7. Phase 6 subsections under a tab root (2026-09-21) — user-raised, planned

Worry: the old answer was "sidebar → pane → TabView classification inside
the pane" (03's TabView-inside-pane rule). With TabView AS the root, that
answer reads as nested tab bars — the exact confusion feared. Resolution:

- **Top level stays FLAT FOUR, never nested:** General, Dictation, Writing,
  Privacy & History — one toolbar tab each (reference proves five fit).
- **Subsections ride an in-content segmented `Picker`, NOT a nested
  `TabView`:** Writing switches Dictionary/Snippets, Privacy & History
  switches History/Privacy, via a plain `@State` + switch behind a native
  segmented control at the top of the pane's `Form`. No tab-nesting, no new
  rules, matches the Clock reference already blessed in this thread.
- **Why not nested TabView (03's original text)?** Legal by the letter,
  confusing by the pixel: two tab bars (toolbar + in-content) competing for
  "where am I". The segmented switcher says the same thing with one bar.
- **Why not six flat tabs?** Dictionary/Snippets/History/Privacy as peers
  crowds the toolbar and orphans the 03 grouping (Dictionary+Snippets share
  the writing task context; History+Privacy share the data-trust context).
  Four tabs + two segmented switchers preserves the grouping with room.
- **Fallback held:** if segmented-in-content ever feels wrong on device,
  the sidebar receipts (§10 HSplitView, pre-§10 split view) still exist —
  navigation is the most reversible decision in this codebase. Dissent is
  cheap by design.
