# History trim + toolbar toggle glass

User-ordered follow-up (2026-10-29) to the settings-chrome round:

1. The History on/off switch in the titlebar sits on a "weird frame glass
   thingy" — remove it (or opacity 0).
2. Remove the "Copied — paste with ⌘V." line: the row's green tick is enough.
3. Remove the "On this Mac only. Newest 100 entries, 30 days." note: the
   empty-state chips already say it.

## Spec sources / SDK facts

- Screenshot evidence: `.context/shot10/settings-history.png` (2× capture,
  760×500 window). Measured in points:
  - shared glass plate behind the switch ≈ 37.5 × 35, top edge ≈ 7 pt;
  - the switch itself ≈ 44.5 × 21.5, centred ≈ 26.75 pt.
  So the plate is the toolbar's standard 36 × 36 item background: the switch
  is wider than it and shorter than it, hence the visible ring around/below.
- `ToolbarContent.sharedBackgroundVisibility(_:)` exists in the local SDK
  (`MacOSX27.0.sdk`, `SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface`
  line 7320) and is `@available(macOS 26.0)`. Deployment target is 27.0, so it
  can be used unconditionally. It is the documented way to opt an item out of
  the toolbar's shared glass background — no hand-drawn button replacing the
  native switch.
- The `+` action accessory keeps its glass circle: that one is sized by the
  toolbar for a single glyph and reads correctly (same family as back/forward
  in `.context/shot10/settings-snippets.png`).

## File changes

### `Oto/Settings/SettingsChrome.swift`

- Add `Accessory.usesSharedBackground` (`false` for `.toggle`, `true` for
  `.action`) so the root can opt the switch out of the glass plate while the
  `+` keeps its circle.

### `Oto/Settings/SettingsRoot.swift`

- In the toolbar, apply
  `.sharedBackgroundVisibility(accessory.usesSharedBackground ? .visible : .hidden)`
  to the accessory `ToolbarItem`. Native `Toggle` stays; nothing is redrawn.
  Comment records the measurement and the API (macOS 26+).

### `Oto/Settings/HistoryPane.swift`

- Delete `feedback = "Copied — paste with ⌘V."` — `OtoCopyFlash` (row glyph →
  green tick) is the copy confirmation, matching Snippets.
- Keep `feedback` only for "Original wording restored." (undo AI edit has no
  tick), now auto-cleared after 3 s so a stale line never becomes chrome.
- Delete the `OtoPanelNote("On this Mac only. Newest … entries, … days.")`
  row; the empty-state chips (`Last 100`, `30 days`, `On this Mac`) carry it.

### `Oto/Settings/OtoRowActions.swift`

- Fix the `OtoCopyFlash` comment that still promises a bottom-of-pane paste
  line.

## Verification

- `xcodebuild -scheme Oto -destination 'platform=macOS' build`
- `xcodebuild test -scheme Oto -destination 'platform=macOS'`
- Probe capture (`OTO_SETTINGS_SHOT`, `OTO_SETTINGS_FRAME=1`,
  `OTO_SETTINGS_PANES=history`, `OTO_SETTINGS_COPY=1`): titlebar shows the
  bare switch with no plate, at the back/forward baseline; the pane shows the
  tick but no "Copied" line and no retention note.
- Existing suites stay green (no test references these strings).

## Risks

- `.sharedBackgroundVisibility(.hidden)` also removes the hover/selection
  wash AppKit draws for the item; the switch keeps its own focused/hover
  feedback because it is the real control. If the bare switch looks unmoored,
  fallback is `.controlSize(.mini)` inside the plate instead (not preferred:
  it shrinks the hit target).
- The undo line auto-clear is timing-based; it only ever holds one string and
  clears on the next undo, so no correctness risk.

## Open questions

- None blocking. If the user wants the retention facts on the list state too,
  they can be re-added behind the info popover rather than as a footer.
