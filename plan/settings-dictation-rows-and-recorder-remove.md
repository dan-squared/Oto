# Dictation rows, General notes, and a recorder that can Remove

Status: IMPLEMENTED (2026-10-29). Build green; `OtoTests` 591/591 green.

Verified with the probe (`OTO_SETTINGS_PANES=dictation,general`,
`OTO_SETTINGS_RECORDER=hold`, `OTO_SETTINGS_RECORDER_CLEAR=1`,
`OTO_APPEARANCE=dark`), captures in `.context/round29/`:
- Dictation: native divider between Push-to-talk and Hands-free (and above
  "Requires Accessibility").
- Recorder: `Remove ⌫` left, `Close esc` right.
- After Remove: popover stays, reads "Record shortcut", Remove gone, and the
  row behind updates live to "Record shortcut".
- General: the card holds only the two toggles.

Probe-only hooks added (never posted in normal use): `.otoProbeOpenRecorder`
(DictationPane), `.otoProbeClearRecorder` (ShortcutCapturePopover).

## Goal

1. **Push-to-talk and Hands-free are two rows.** They currently share one
   `VStack` inside a single Form row, so no row divider separates them. Every
   other section in Settings separates its rows with the grouped Form's native
   divider; these two should match.
2. **The General card stops explaining itself.** Remove the
   "Login item status is unavailable right now." caption and the
   "Off: menu bar only — no Dock, no ⌘Tab." note. Both are always-on copy that
   competes with the two toggles above them. Failure copy (`loginError`,
   `dockError`) stays: it reports a real failed action, not a description.
3. **Backspace clears the shortcut, it does not close the recorder.** Today
   Delete → `setSlotEnabled(false)` + `onClose()`. The trigger kind is left
   untouched, so the row behind still shows the same keycaps: the clear is
   invisible and the only visible effect is the popover closing. The recorder
   should instead:
   - assign `.unassigned` to the slot (so the row reads "Record shortcut"),
   - keep listening so a new shortcut can be recorded straight away,
   - offer a **Remove** button in its footer (with the `⌫` keycap) for the
     same action, and
   - show "Record shortcut" in the capture area while the slot is empty.

## Facts verified in the tree

- `DictationPane.shortcutRow` returns an `HStack`; both rows sit in one
  `VStack` inside a single `Section` row (`DictationPane.swift:59–80`), which
  is why the grouped Form draws no divider between them.
- `ShortcutCapturePopover.onClear` (`ShortcutRecorderField.swift:387–392`)
  only calls `dispatch.setSlotEnabled(false, for: slot)` then closes.
  `ShortcutDispatch.setSlotEnabled` flips the enable flag and leaves
  `configuration.hold/handsFree` intact, so the row's `KeyNames.chips(for:)`
  keeps rendering the old keys.
- `ShortcutTrigger.Kind.unassigned` already exists and is Codable
  (`ShortcutModels.swift:94`); `conflictsWith` treats it as claiming nothing,
  and `resetCalibration` keeps `.notSet` for it. `unassignedHandsFree()` is
  the existing factory; there is no hold counterpart.
- `updateSlot` re-enables a slot on any successful save
  (`ShortcutDispatch.swift:265–273`), so recording after a clear restores the
  slot without extra work.
- Empty-state footnotes in Dictionary/Snippets/History already fall back when
  `KeyNames.chips(for: hold.kind)` is empty, so an unassigned hold slot has an
  honest presentation there (`DictionaryPane.swift:166–170`,
  `SnippetsPane.swift:162–166`, `HistoryPane.swift:276–281`).
- `ShortcutDispatch` is not `@Observable`; the row only re-renders when the
  pane's own `@State` changes. The old `shortcutRefreshID` + `.id(...)` trick
  would recreate the row (and its popover anchor) if it had to run while the
  popover is open, so the pane snapshots the two kinds in `@State` instead.

## File changes

1. **`Oto/Models/ShortcutModels.swift`**
   - Add `ShortcutTrigger.unassignedHoldToTalk()` beside
     `unassignedHandsFree()`.

2. **`Oto/Services/ShortcutDispatch.swift`**
   - Add `clearSlot(_:)`: cancel the active session, assign `.unassigned` to
     the slot, disable that slot only, reset its calibration, `start()`.
     (While the recorder is open, `start()` is a no-op because dispatch is
     suspended; closing the recorder resumes it.)
   - Add a `trigger(for:)` test hook? Not needed — `configuration` is
     readable by tests.

3. **`Oto/Settings/ShortcutRecorderField.swift`** (`ShortcutCapturePopover`)
   - Add `var onChange: () -> Void = {}` so the owning pane can refresh its
     row while the popover stays open.
   - `@State private var isCleared`: seeded from the live slot on appear,
     `true` after Remove/⌫, `false` after a successful capture.
   - Capture area: idle copy reads "Record shortcut" when cleared, otherwise
     "…and a key" (attempts and held modifiers unchanged).
   - `onClear` → `clearShortcut()`: `dispatch.clearSlot(slot)`, reset
     attempts/refusal/message/glow, `isCleared = true`, `onChange()`, keep
     `isListening` true.
   - Footer: `Remove` (with `⌫` keycap, hidden once cleared) on the left,
     existing `Close esc` on the right. Remove calls the same
     `clearShortcut()`.
   - `accept()` sets `isCleared = false`.

4. **`Oto/Settings/DictationPane.swift`**
   - Snapshot `holdKind` / `handsFreeKind` in `@State` (seeded in `init`),
     updated by `syncFromDispatch()`; drop `shortcutRefreshID` and the
     `.id(...)` on the section.
   - Put each shortcut row, the Accessibility warning, and the message in
     their own Form rows so the grouped Form draws the same dividers as the
     other sections.
   - Pass `onChange: syncFromDispatch` to the recorder; `onClose` still
     dismisses and syncs.

5. **`Oto/Settings/GeneralPane.swift`**
   - Delete the `loginCaption` property and both `OtoPanelNote` branches.
     Keep `loginError` / `dockError`.

6. **`OtoTests/ShortcutDispatchDualTests.swift`**
   - Cover `clearSlot`: the slot's kind becomes `.unassigned`, that slot's
     enable flag goes false, the other slot is untouched, and a later
     `updateHoldTrigger` re-enables it.

## Verification

1. `xcodebuild -scheme Oto -destination 'platform=macOS' build`.
2. `xcodebuild test -scheme Oto -destination 'platform=macOS'`.
3. Live check: Dictation → a divider sits between Push-to-talk and
   Hands-free; open the recorder, press ⌫ → popover stays, row reads
   "Record shortcut", Remove replaced by nothing; record ⌘⇧K → green flash,
   popover closes, row shows the new keys.
4. General → the card shows only the two toggles (errors still appear when an
   action fails).

## Risks / deferred

- `.unassigned` for the hold slot means "no push-to-talk". Hands-free
  (double-tap on the hold key, or its own shortcut) still works; empty-state
  footnotes already have copy for the empty case. Recoverable in one click.
- The transform recorder (Intelligence) keeps close-on-clear: its clear path
  already assigns `.unassigned`, so nothing is silently lost there. Giving it
  the same persistent footer is deferred until asked.
