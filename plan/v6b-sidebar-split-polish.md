# V6b: sidebar split + selection takeover + footer buttons

Status: PLAN ONLY. Nothing implemented. Awaiting `execute`.

## 0. Settled context (not re-planned)

- Menubar black slot: RESOLVED and committed. Proof: dresser-disabled
  probe showed a clean icon with Settings open; dresser deleted
  (`SettingsWindowDresser.swift` + tests gone), native chrome kept.
- `.tint(.primary)` + `.fontWeight(.regular)` are in-tree
  (`SettingsRoot.swift`) and INEFFECTIVE — List selection still
  paints blue + bolds. This plan takes over selection rendering
  instead of fighting the accent system.

## 1. Sidebar split 4 → 6

`SettingsPane`: general, dictation, **dictionary, snippets,
history, privacy** (titles as named; symbols: gearshape, waveform,
`book.closed`, `text.quote`, clock, `hand.raised` — all valid SF).
- `WritingPane.swift` DELETE → `DictionaryPane.swift` (rules list,
  `DictionaryRuleEditor`, Add/Clear + dialog) + `SnippetsPane.swift`
  (snippets list, `SnippetEditor`).
- `PrivacyHistoryPane.swift` DELETE → `HistoryPane.swift` (history
  section + history states + `copyEntry` + clear dialog) +
  `PrivacyPane.swift` (privacy section on `uiState`).
- `SettingsRoot` switch gains 4 branches; section enums +
  `OtoSegmented` usages die with the old files. Stores/coordinator/
  `uiState` wiring identical per pane. `HistoryEntry`/`HistoryPage`
  model tests untouched.
- Tests: grep-gate `WritingPane|PrivacyHistoryPane|PaneSection`
  in `OtoTests|OtoUITests` at execute (UI test addresses panes by
  sidebar label — new labels work unchanged).

## 2. Cancel/Copy bigger (catcher only — not global pills)

`OtoPill` gains `large: Bool = false` (13pt / h14 / v8; default
unchanged everywhere else). Catcher footer: both pills large,
gap 8 → 10, row `minHeight` 44 → 52. Chrome 102 → **110**
(20+18+52+20); floor 168 stays. Pin test updates to
`20 + 18 + 52 + 20`; height test auto-holds. Controller, mask,
copy logic untouched.

## 3. Selection takeover (mono, no bold) + hover + white icons

New `SidebarRow` (in `SettingsRoot.swift`): native `List` kept
(scrolling/selection/AX), but rows render explicitly —
- `Label` 14pt, `.fontWeight(.regular)` enforced (kills the bold —
  bolding rode the accent selection renderer, which no longer paints).
- `.listRowBackground`: selected → inset rounded-8 `Color.primary`
  (black in light / white in dark — the ask, exactly); hovering +
  unselected → hover fill; else clear. `@State hovering` + `onHover`.
- Icon foreground: selected → contrast text; unselected → white in
  dark, `.secondary` in light (pure white always would vanish in
  light mode — deviation recorded, see §5 Q1).
- Text on selection: black on white (dark) / white on black
  (light) via scheme read — matches native selected-row contrast.
- Blue accent can never appear: nothing selectable paints accent.

## 4. ">>" + snap (identify first, then remove)

The phantom chevron was never screenshotted — step 1 is a temp AX
probe (dump all buttons in the Settings window; click the toggle if
exposed) to NAME it. Prime suspect: SwiftUI's automatic sidebar
toggle (no toolbar present to host it). Removal per suspect:
- Toggle → `.toolbar(removing: .sidebarToggle)` (verified present
  in `MacOSX27.0.sdk` SwiftUI interface).
- Snap root-cause hypothesis: fixed-size `contentSize` window vs
  animated column show/hide fighting. Fix: lock the column
  (`min == ideal == max` 210) AND remove the collapse path entirely
  (no toggle → always open → no snap class, no animation to tune).
- Matrix (human eyes — motion can't screenshot): collapse affordance
  gone, open/close smooth, both schemes.

## 5. Open questions (recommendations marked *)

- Q1 icons: adaptive white/dark-ink (*) vs pure-white-always (breaks
  light mode — not recommended)?
- Q2 button numbers (13pt/h14/v8, row 52) OK (*)?
- Q3 lock column always-open (*) vs keep collapse working?

## 6. Verification

Build green; suite green twice (flake protocol stands). Matrix:
six rail entries navigate with values intact (hoisted model
untouched), selection screenshots both schemes (mono, regular
weight, white/dark icons), hover visible, no ">>", no snap,
footer buttons bigger with bottom-pinned baseline in
empty/short/50-word cards both slots, full dictation/catcher
rounds (shared footer touched).

## 7. Risks

- §3 replaces accent selection visuals: VoiceOver still announces
  selection (native `List` selection binding kept) — pixels only.
- §4 identification may surprise (if the ">>" is Full Keyboard
  Access focus or a tester-side artifact, the probe says so and the
  removal step is dropped, not forced).
- §1 file deletes are one-way (restore = revert commit).
