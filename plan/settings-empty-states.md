# Settings: reference empty states for Dictionary, Snippets, History

Status: PLANNED (not implemented). Awaiting "execute".

## Goal

Replace the three `ContentUnavailableView` blockers with one empty-state
composition measured from the user's reference (VXYWdS screenshot), and give
each pane its master control in the window's top-right corner, the way the
reference does it:

- a centred stack, no card chrome: 56 pt icon tile → title → one paragraph →
  three tinted example chips → one dark primary button → a muted caption with
  inline keycaps;
- the pane's on/off switch (History) or its primary action (Dictionary,
  Snippets) at the top-right of the detail column, *also* reachable from the
  button in the empty state — two paths to the same thing.

## Specification sources

- User screenshot 2026-10-29 11:46 (`.context/attachments/VXYWdS/
  file-52b4b5cc1e54c15449a5834132b151cd.png`): "Spaces" empty state. Measured
  it is a 2× capture of a **578 × 542 pt detail column** — Oto's detail column
  is 580 pt wide, so the reference is effectively 1:1 with Oto's pane. All
  numbers below are that screenshot ÷ 2.
- User screenshot `.context/attachments/nVZG6j/…png` (list rows: title left,
  pencil + trash right) — the same visual language carried into the list state.
- `Oto/Settings/SettingsRoot.swift` — the shell (split view, toolbar, safe
  area). `Oto/UI/Theme/OtoPalette.swift` — the only colour authority.
- `Oto/Settings/DictionaryPane.swift`, `SnippetsPane.swift`, `HistoryPane.swift`
  — current states.

## Facts verified (measured, not assumed)

From the reference (points, after ÷2):

| Element | Geometry |
|---|---|
| tile | 56 × 54, radius 12, 1 px hairline + soft shadow, glyph ≈ 22 |
| title | ≈ 18–19 semibold, centred |
| body | ≈ 14, secondary, 2 lines, block ≈ 317 wide, centred |
| chips | height ≈ 29, radius ≈ 10, gap 8, 14 semibold, tinted fill (violet / blue / green) |
| primary button | 120 × 33, radius ≈ 10, black fill, white 14 semibold |
| caption | ≈ 13 tertiary, 2 lines, inline keycap wells ≈ 12 × 11 |
| vertical rhythm | tile→title 16, title→body 8, body→chips 18, chips→button 16, button→caption 19 |
| switch | 44 × 21 at the top-right of the pane column, off = light track + white knob |
| arrows | glass capsule, top-left of the same column, 31 pt tall |

Repo facts:

- `SettingsRoot.detailContent` wraps **every** pane in `Form { … }
  .formStyle(.grouped)` (lines 436–445). A `ContentUnavailableView` inside a
  `Section` therefore renders as a card in a form row — not the reference's
  borderless, pane-centred composition. The `Form` has to move into the panes.
- The root view already owns the toolbar (`ToolbarItemGroup(.navigation)` for
  back/forward) and applies `.ignoresSafeArea()`; the split view is full-bleed
  and the detail hosting view reports safe-area top 52 (measured in
  `plan/settings-titlebar-and-recorder-glow.md`). A `.primaryAction` toolbar item is the
  one place that is guaranteed interactive, sits at the far right of the
  window, and lands exactly where the reference's switch is.
- `.toolbar` items declared *inside* a pane cannot work: panes live in
  `NSSplitViewItem` hosting controllers, which are separate SwiftUI roots, so
  toolbar preferences never reach the window. The accessory must be published
  up to `SettingsRoot` (see "Chrome" below).
- History's enable flag is `@AppStorage("app.Oto.historyEnabled")`; turning it
  off with entries on file must keep asking first (`setHistoryEnabled`), so the
  switch cannot be a bare binding — it routes through the pane's existing
  method.
- Dictionary and Snippets have **no** master enable. Dictionary rules reach the
  coordinator via `setDictionaryRules`; snippets have no apply path at all
  (they are copied from this pane only). A switch for either would be a lie
  unless new gating is built. Open question 1.

## Design

### 1. Shared empty state — new `Oto/Settings/OtoEmptyState.swift`

```swift
struct OtoEmptyState<Chip: View>: View {
    let symbol: String
    let title: String
    let message: String
    var chips: [OtoEmptyChip] = []      // symbol, label, tint
    var actionTitle: String?            // nil = no CTA
    var action: (() -> Void)?
    var footnote: [OtoEmptyFootnote]    // text + optional keycap chips
}
```

- Layout: `VStack(spacing: 0)` centred in the pane, `maxWidth 360` for the
  paragraph, tile 56 pt (`OtoPalette.wash`, `angle: .continuous` radius 13,
  `OtoPalette.hairline` border 0.75, `shadow(.black.opacity(0.06), radius: 8, y: 2)`),
  symbol 24 medium in `OtoPalette.ink`.
- Title 19 semibold rounded; paragraph 14 `OtoPalette.muted`; chips row 8 gap;
  CTA 34 pt tall, radius 10, `OtoPalette.ink` fill with `OtoPalette.ground`
  label (so it inverts for free in Dark Mode, like the rest of the app);
  footnote 12 `OtoPalette.faint`, keycaps via existing `OtoKey(text:compact:)`.
- Chips: `ChipTint` enum with three light/dark pairs **added to `OtoPalette`**
  (violet / blue / green) — no colours live outside the palette file.
  Illustrative only: `.allowsHitTesting(false)`, `.accessibilityHidden(true)`.
- Motion: none on appear (the pane is not a stage). `OtoMotion.reduced` is
  irrelevant because nothing animates — no new animation vocabulary.

### 2. Pane canvas — move the `Form`

New in `Oto/Settings/SettingsPanel.swift`:

```swift
struct OtoPaneForm<Content: View>: View   // Form { … }.formStyle(.grouped)
struct OtoPaneCanvas<Content: View>: View // borderless, centred, no scroll card
```

`SettingsRoot.detailContent` becomes bare `paneContent` with the shared
`.font(.system(size: 13)).fontDesign(.rounded).controlSize(.regular)
.textFieldStyle(.roundedBorder)` modifiers kept on the wrapper. Each pane wraps
its own body:

- `GeneralPane`, `DictationPane`, `PrivacyPane`, `IntelligencePane`,
  `AboutPane` → `OtoPaneForm { … }` (unchanged pixels).
- `DictionaryPane`, `SnippetsPane`, `HistoryPane` →
  `if empty { OtoPaneCanvas { OtoEmptyState(…) } } else { OtoPaneForm { … } }`.

Safe-area note: the hosting view already reports top inset 52, so
`OtoPaneCanvas` centres inside the usable pane and never hides under the
toolbar. Verify in the probe, not by eye only.

### 3. Top-right accessory — `SettingsChrome`

New `Oto/Settings/SettingsChrome.swift`:

```swift
@MainActor @Observable final class SettingsChrome {
    enum Accessory {
        case toggle(isOn: Bool, help: String, set: (Bool) -> Void)
        case action(symbol: String, help: String, run: () -> Void)
    }
    var accessory: Accessory?
}
```

- `SettingsRoot` owns `@State private var chrome = SettingsChrome()`, clears
  `chrome.accessory` on `selection` change, and renders it as a
  `ToolbarItem(placement: .primaryAction)`: a `Toggle` with
  `.toggleStyle(.switch).labelsHidden().controlSize(.small)` for `.toggle`, a
  glass icon button (`buttonStyle(.glass)`, `.buttonBorderShape(.circle)`) for
  `.action`.
- Panes receive `chrome` explicitly (environment does **not** cross the
  `NSHostingController` boundary that the split view creates) and publish on
  appear + on change:
  - `HistoryPane` → `.toggle(isOn: historyEnabled, help: "Remember transcripts")`
    routed through `setHistoryEnabled` (confirmation preserved).
  - `DictionaryPane` → `.action("plus", "Add rule")`.
  - `SnippetsPane` → `.action("plus", "Add snippet")`.
- Fallback if toolbar churn on pane switch is visible: render the same
  accessory with `.safeAreaInset(edge: .top)` inside the detail wrapper, same
  components, same corner. Decided at verification time, recorded in the
  commit message.

### 4. Copy per pane

Font/symbol/keycap content is deliberately specific; chips are categories, not
fake data (the reference's chips name Spaces, ours name the kinds of thing the
pane holds).

**Dictionary** (always has something to add — no off state)

- symbol `character.book.closed`, title "Your words, your way"
- body: "Teach Oto how you say things. A spoken form becomes the replacement
  every time you dictate."
- chips: "Names" (`person.text.rectangle`, violet), "Jargon"
  (`textformat.abc`, blue), "Shorthand" (`arrow.right`, green)
- CTA: "Add your first rule" → opens the existing `DictionaryRuleEditor`
- footnote: "Applies whenever you dictate with <hold keycaps>." (live chips
  from `dispatch.configuration.hold.kind`)

**Snippets**

- symbol `text.quote`, title "Text you say once, use often"
- body: "Save the paragraph, the address, the signature. Copy it from here
  whenever you need it."
- chips: "Signature", "Address", "Meeting link"
- CTA: "Save your first snippet" → existing `SnippetEditor`
- footnote: "Nothing inserts itself — you choose when to copy."

**History — off**

- symbol `clock.arrow.circlepath`, title "History is off"
- body: "Oto keeps nothing. Turn it on and your last 20 transcripts stay here,
  on this Mac, until you clear them."
- chips: "Last 20", "30 days", "On this Mac"
- CTA: "Turn On History" → `setHistoryEnabled(true)`
- footnote: "Nothing is uploaded. Turning it off again stops new saves and
  keeps what is already here."

**History — on, empty**

- symbol `clock.arrow.circlepath`, title "Nothing here yet"
- body: "Finished dictation lands here with the words, the app you were in, and
  the time."
- chips as above (no CTA — you dictate, you don't "turn on" anything)
- footnote: "Hold <hold keycaps> to dictate." (same live chips)

### 5. List state (unchanged structure, new chrome feeding it)

- `Add rule` / `Add snippet` move from the bottom of the card to the top-right
  accessory; the bottom row keeps only `Clear` (Dictionary) where it exists.
- Retention note for History stays as the last card's `OtoPanelNote`.
- Row redesign is a separate plan (`plan/settings-rows-and-permissions.md`).

## Exact file changes

| File | Change |
|---|---|
| `Oto/Settings/OtoEmptyState.swift` | **new** — empty-state composition + chip + footnote types |
| `Oto/Settings/SettingsChrome.swift` | **new** — accessory model |
| `Oto/Settings/SettingsPanel.swift` | add `OtoPaneForm`, `OtoPaneCanvas` |
| `Oto/UI/Theme/OtoPalette.swift` | three tint pairs + `OtoPalette.chip(_:)` |
| `Oto/Settings/SettingsRoot.swift` | drop the `Form`, pass `chrome`, clear on switch, toolbar accessory |
| `Oto/Settings/DictionaryPane.swift` | canvas/list split, CTA, chrome action, `dispatch` param |
| `Oto/Settings/SnippetsPane.swift` | same |
| `Oto/Settings/HistoryPane.swift` | off/empty/list split, switch removed from the card, chrome toggle, `dispatch` param |
| `Oto/Settings/GeneralPane.swift`, `DictationPane.swift`, `PrivacyPane.swift`, `AboutPane.swift`, `IntelligencePane.swift` | wrap body in `OtoPaneForm` (mechanical) |

## Verification

1. `xcodebuild -scheme Oto -destination 'platform=macOS' build`
2. `xcodebuild test -scheme Oto -destination 'platform=macOS'` (full suite,
   plus the new tests below)
3. Extend `OtoProbe.captureSettingsIfRequested` to walk panes and states, both
   appearances (`OTO_APPEARANCE=light|dark`), writing into `.context/`:
   dictionary empty, snippets empty, history off, history on+empty, history
   list, general. Confirm measured geometry against the table above (tile 56,
   chips 29, CTA 34, switch in the top-right of the column).
4. New unit tests (`OtoEmptyStateTests`): chip/footnote value mapping, the
   History CTA mapping (off → "Turn On History", on+empty → no CTA), palette
   tint pairs resolve for both appearances.
5. Manual: switching panes must never leave a stale accessory; turning History
   off with entries still asks first; the switch must not flip while the
   dialog is open.

## Risks / deferred

- Toolbar accessory rebuild on pane switch could flicker (fallback above).
- Moving `Form` into panes touches all eight panes; the diff is mechanical but
  wide. Any pane that relied on `SettingsRoot`'s Form row insets is re-checked
  in the probe.
- Tinted chips are a deliberate, contained departure from the monochrome
  palette; they live only inside `OtoPalette` and only in empty states.

## Open questions

1. **Dictionary/Snippets top-right control.** The reference's corner control is
   a real on/off switch. Neither pane has one today. Default in this plan: a
   glass **+** (add) button in the same corner, so the corner is still "the
   pane's master action" and the empty-state CTA does the same thing.
   Alternative: a genuine master switch — for Dictionary it would gate
   `setDictionaryRules([])`; for Snippets it would gate nothing until an
   insertion path exists, so I would only build it for Dictionary. Say which.
2. Should `History` keep showing its entries while the switch is off? Today the
   pane replaces them with the off state (existing behaviour, kept).
