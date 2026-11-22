# Settings feedback round: copy without asking, quieter recorder, compact Flow Bar row

Status: EXECUTED (2026-10-31), then polished in the same day's follow-up
round (see "Follow-up" at the end).

Source: user feedback with four screenshots
(`.context/attachments/887sqx`, `xNd5aV`, `wnaOL6`, `yb7hJk`) plus two
clarifying answers:

- Snippets rows: drop **both** the copy and the info button (keep edit + delete).
- Flow Bar position: keep Oto's glass segmented pill, just make it compact and
  right-aligned with the label on the left.

## Goal

1. **Copy never asks.** Clicking Copy anywhere (History, snippet expansion,
   catcher modal, manual clean-up Keep/Original) writes the clipboard straight
   away. The "Replace clipboard contents?" confirmation is gone.
2. **No "Try it" in the dictionary editor.** The rule sheet keeps what-you-say,
   replacement, scope, enabled, Save/Cancel — no sample-sentence preview.
3. **History rows lose the "Clean up transcript" (sparkles) action.** The
   details popover keeps its Cleanup row and "Undo AI edit" (auto-cleanup still
   writes those facts).
4. **Editing a transform shortcut stops spraying row errors.** While any
   transform recorder is open, no row shows the "Couldn't register…" note (it is
   false then — `transforms.stop()` runs on purpose) and no row shows a stale
   per-preset refusal. Refusals stay inside the popover.
5. **Shortcut pills show a stroke when pressed / active.** The rounded
   record-shortcut pills (Dictation, Intelligence) get a 1 pt stroke while the
   mouse is down and while their recorder is open.
6. **Recorder: ⌫ hint moves to the top centre.** "Press ⌫ to delete" sits above
   the keycaps (like the reference), tappable, and the footer keeps only
   `Close esc`. Same affordance on the transform recorder when the slot holds a
   combination.
7. **Flow Bar position row matches the reference.** Label on the left
   ("Position"), compact glass segmented control ("Top | Bottom") on the right;
   the control no longer stretches across the row.

## Facts verified

Local toolchain: Xcode 27.1 (27A9275), SDK `MacOSX27.0.sdk`, deployment 27.0.

SDK evidence (`swiftinterface` on this Mac):
- `LabeledContent` is macOS 13+ —
  `SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface:5117,5120`.
- `frame(width:height:alignment:)` and
  `frame(minWidth:idealWidth:maxWidth:…)` both take `CGFloat?` (`nil` = no
  constraint), so one view can hug content or fill depending on a parameter —
  `SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface:15692,15729`.
- `strokeBorder(_:lineWidth:)` exists on shapes —
  `SwiftUICore.…swiftinterface:13235`.
- The track keeps using the existing `.glassEffect(.regular, in: .capsule)`
  path (`OtoControls.swift:127`, macOS 26 availability already guarded). No new
  API is introduced, so nothing new needs `#available`.

Tree evidence:
- The confirmation dialog exists in five places, all driven by
  `ClipboardOverwriteGuard.shouldConfirm` (`PasteboardOwnership.swift:38–56`):
  `HistoryPane.swift:112–124`, `SnippetsPane.swift:81–93` and `223–232`,
  `PolishSheet.swift:75–91`, `NoTargetModal.swift:437–445`.
- `PasteboardReceipt` / `PasteboardSnapshot` (insertion ownership + restore) are
  a different mechanism and are untouched: `PasteboardOwnership.swift:21–31`,
  `62–92`; product rule `Docs/START_HERE_PRODUCT.md:252` still holds.
- `placePolishedOnClipboard` lives in `PolishSheet.swift:18–22` and is used by
  `OtoTests/PolishServiceTests.swift:83,92–93,219`; deleting the sheet requires
  moving that primitive.
- `PolishSheet` is reachable **only** from the History sparkles button
  (`HistoryPane.swift:96,211–215`). `polishActionVisible` is defined in
  `WritingPolishService.swift:382`.
- Transform monitors are deliberately stopped while a recorder is open
  (`IntelligencePane.swift:203`, `transformRecorder` `onRecord` →
  `transforms.stop()`), and `isLive` is `carbonHotKey != nil`
  (`TransformRunner.swift:164–166`, `ModifierHotkeyMonitor.swift:56`). So every
  other row's "Couldn't register — already used by another app."
  (`IntelligencePane.swift:258–266`) is a false alarm during recording.
- Per-preset refusal copy is stored in `messages[preset]` and shown as a row
  warning (`IntelligencePane.swift:246–257`); the same string is already shown
  inside the popover via `refuse(_:)` (`ShortcutRecorderField.swift:631–634,
  649–652, 697–700`).
- `OtoShortcutField`/`OtoShortcutPill` have hover fill but no press/active
  stroke (`OtoControls.swift:248–311`); rows pass no active flag
  (`DictationPane.swift:152–159`, `IntelligencePane.swift:198–207`).
- Recorder footer today: Remove ⌫ left, Close esc right
  (`ShortcutRecorderField.swift:441–470`); the transform recorder has only
  Close (`616–672`).
- Flow Bar row is a label-less full-width `OtoSegmented`
  (`GeneralPane.swift:84–92`) because `OtoSegmented` forces
  `.frame(maxWidth: .infinity)` (`OtoControls.swift:96–133`).
- Xcode project uses `PBXFileSystemSynchronizedRootGroup`
  (`Oto.xcodeproj/project.pbxproj:71–87`), so deleting/adding source files
  needs no project edits.

## Assumptions questioned

- *"Copy should warn because it destroys the clipboard."* Dropped by explicit
  request. Copy is an explicit command; the guard was UX friction, not safety
  for the transcript (History still holds the text). The insertion path's
  snapshot/restore is untouched.
- *"Row errors are useful while recording."* No: during recording the monitors
  are intentionally dead, and the popover already says the same thing. Keeping
  them off while a recorder is open and clearing them on close removes the noise
  without losing the real post-close registration warning.
- *"Remove the sparkles button but keep the manual clean-up sheet."* Keeping an
  unreachable view is dead code; the sheet is deleted and its one reusable
  primitive moves. Auto Cleanup (pre-insertion) and Undo AI edit remain.
- *"Snippets need a row-level copy button."* Removed by the user's choice; the
  editor's "Copy expansion" is the remaining copy path, so the empty-state
  footnote is reworded to match.
- *Segment width 84 pt* is a starting value chosen to read like the reference
  ("minimal", not full row); easy to nudge after the capture review.

## File changes

### 1. `Oto/Services/PasteboardOwnership.swift`
- Delete `ClipboardOverwriteGuard` (33–56).
- Add the manual-write primitive (also receives `placePolishedOnClipboard`):

```swift
/// Manual clipboard writes (History copy, snippet expansion copy, catcher
/// copy): Copy is an explicit command, so it writes straight through. The
/// "Replace clipboard contents?" confirm was removed 2026-10-31 by request.
/// Insertion never uses this — it snapshots and restores (see receipts).
enum ClipboardWrite {
    nonisolated static func text(_ text: String, to board: NSPasteboard = .general) {
        board.clearContents()
        board.setString(text, forType: .string)
    }
}

/// Legacy name kept for the polish tests' injectable board.
func placePolishedOnClipboard(_ text: String, board: NSPasteboard = .general) {
    ClipboardWrite.text(text, to: board)
}
```

- Keep `PasteboardReceipt` and `PasteboardSnapshot` exactly as they are.

### 2. `Oto/Settings/HistoryPane.swift`
- Remove `confirmCopyOverwrite`, `pendingCopyEntry` and the dialog (98–124).
- `copyEntry` → `ClipboardWrite.text(entry.finalText)` + `copyFlash.flash(id)`.
- Remove the sparkles button (211–215), `polishEntry`, `polishAvailability`,
  `.sheet(item: $polishEntry)` (95–97), the `polish` property,
  `@AppStorage(CleanupSettings.enabledKey)`, and the `polish.prewarm()` branch in
  `onAppear` (67–73).
- Keep: copy button, info popover (Cleanup row + Undo AI edit), trash, pagination.

### 3. `Oto/Settings/SnippetsPane.swift`
- Row actions reduce to pencil + trash (delete copy 114–121 and info 122–136).
- Drop `copyFlash`, `infoSnippetID`, `infoBinding`, `copySnippet`, `writeSnippet`,
  `confirmCopyOverwrite`, `pendingCopySnippet`, the copy dialog (81–93), and the
  `.otoProbeOpenInfo/.otoProbeCloseInfo/.otoProbeCopyFirst` handlers (61–70).
- `SnippetEditor`: drop `confirmCopyOverwrite` and its dialog (223–232);
  `copyDraft()` keeps the empty-draft guard then calls `ClipboardWrite.text`.
- Header comment and empty-state footnote: copy now lives in the editor
  ("Nothing inserts itself — open a snippet to copy it." / "Dictate first, then
  save the words here. Your key is …").

### 4. `Oto/Settings/PolishSheet.swift` — delete
Unreachable once the History sparkles button is gone. `placePolishedOnClipboard`
moves to §1; `polishTimingCaption` already lives in `WritingPolishService.swift`.
`SettingsRoot.swift:554` loses the `polish:` argument to `HistoryPane`.

### 5. `Oto/UI/Scratchpad/NoTargetModal.swift`
- Remove `confirmOverwrite` (391–393), the dialog (437–445) and the guard branch
  (429–435): the Copy pill calls `controller.copy()` directly.
- `copy()` writes through `ClipboardWrite.text(...)`, keeps the tick,
  auto-close and VoiceOver announcement (349–385, guard call removed).

### 6. `Oto/Settings/DictionaryPane.swift`
- Delete `sample` (190) and the whole `Section("Try it")` (203–215).
- Sheet `minHeight` 380 → 320 so the shorter form does not float.

### 7. `Oto/Settings/IntelligencePane.swift`
- Row error block (246–267) only renders while `recording == nil`; the
  registration note therefore never appears during a recording session (and
  `!isRecording` is then implied).
- Clear the transient message when a recorder closes: in the popover's
  dismissal binding `set:`, in `onClear` and in `onCancel`,
  `messages[preset] = nil` (the popover already showed the refusal).
- Pass `active: recording == preset` to `OtoShortcutField`.
- Pass `hasShortcut: !KeyNames.chips(for: kind).isEmpty` to the transform
  recorder.

### 8. `Oto/UI/Theme/OtoControls.swift`
- `OtoShortcutPill`: add `var active = false`; overlay
  `Capsule().strokeBorder(Color.primary.opacity(active ? 0.34 : 0), lineWidth: 1)`.
- Add `OtoShortcutPress: ButtonStyle` — 1 pt capsule stroke while
  `configuration.isPressed` (plus the same 0.985 squish OtoBounce uses, Reduce
  Motion respected).
- `OtoShortcutField`: add `var active = false`, pass it through, and use
  `OtoShortcutPress()` instead of `.plain`.
- `OtoSegmented`: add `var segmentWidth: CGFloat? = nil`.
  - When set: each option gets that width, the track hugs its content and sits
    at natural width (`frame(width: segmentWidth)` +
    `frame(maxWidth: .infinity)` only when nil).
  - Add a hairline track stroke (`Color.primary.opacity(0.10)`, 0.7 pt) so the
    track reads on the light card like the reference.
  - IntelligencePane's Auto Cleanup keeps `segmentWidth: nil` (unchanged,
    full width).

### 9. `Oto/Settings/GeneralPane.swift`
```swift
Section {
    LabeledContent("Position") {
        OtoSegmented(
            options: [(.top, "Top"), (.bottom, "Bottom")],
            selection: $flowPosition,
            segmentWidth: 84
        )
    }
    OtoPanelNote("Top sits below the notch. Drag the pill anytime — it snaps.")
} header: {
    Text("Flow Bar")
}
```

### 10. `Oto/Settings/ShortcutRecorderField.swift`
- `ShortcutCapturePopover` body, top to bottom:
  1. New top row (only while `!isCleared`), centred:
     `Button { clearShortcut() } label: { Text("Press") OtoKey("⌫", compact: true) Text("to delete") }`,
     `.buttonStyle(.plain)`, `.help("Remove this shortcut")`, padding top 12.
  2. Chips row unchanged, `minHeight` 94 → 78 (the hint takes that space back).
  3. Message block unchanged.
  4. Footer: `Spacer()` + `Close esc` (Remove button deleted).
- `TransformShortcutCapturePopover`: add `var hasShortcut = false`; same top
  hint when true, calling the existing `onClear`. Behaviour on clear is
  unchanged (slot empties and the popover closes).

### 11. `Oto/Settings/DictationPane.swift`
- `OtoShortcutField(..., active: capturePopoverSlot == slot)`.

### 12. Tests
- `OtoTests/PasteboardOwnershipTests.swift`: delete `ClipboardOverwriteGuardTests`
  (106–134); add `ClipboardWriteTests`: empty board writes; writing replaces
  prior foreign text; a scratch board ends up holding exactly the new string.
- `OtoTests/PolishServiceTests.swift`: `placePolishedOnClipboard` calls keep
  working through the legacy shim; rename the two "Keep/Use original" tests to
  clipboard-write wording and drop the now-dead "manual flow" comment.
- No other test asserts the removed UI copy (`IntelligencePaneTests` only pins
  the Auto Cleanup footnote, which is unchanged).

## Verification

1. `xcodebuild -scheme Oto -destination 'platform=macOS' build`
2. `xcodebuild test -scheme Oto -destination 'platform=macOS'`
3. Probe captures (probe hooks already exist; `.context/round29` precedent):
   - `OTO_SETTINGS_SHOT=.context/round30 OTO_SETTINGS_PANES=general OTO_APPEARANCE=dark`
     → Flow Bar row: label left, compact pill right, hairline track.
   - `… PANES=dictation OTO_SETTINGS_RECORDER=hold` (+
     `OTO_SETTINGS_RECORDER_CLEAR=1`) → hint top-centre, footer only
     `Close esc`; after clear the hint is gone.
   - `… PANES=history` → copy / info / trash only; no sparkles.
   - `… PANES=snippets` → pencil + trash only.
   - `… PANES=dictionary` → editor sheet without "Try it" (open a row via
     `OTO_SETTINGS_INFO=1` is not enough — check by hand).
   - `… PANES=intelligence` → no row error while a recorder is open.
   - Repeat the useful ones with `OTO_APPEARANCE=light`.
4. By hand in the built `.app`: Copy from History and from a snippet editor
   with foreign clipboard content → no dialog, tick shows; hold the shortcut
   pill → stroke appears; open the Intelligence recorder → the other rows stay
   quiet, closing it restores the real registration note if it is genuinely
   dead.

## Risks / deferred

- **Clipboard overwrite is now silent.** That is the request; History keeps the
  text, and insertion still snapshots/restores. If this ever feels wrong, the
  guard is one `git revert` away.
- **Manual clean-up surface removed.** Auto Cleanup, the Cleanup row in details
  and "Undo AI edit" remain; the sheet is recoverable from git.
- **Snippet copy moved into the editor.** One extra click to copy; footnotes
  updated so the pane does not promise a row button that is gone.
- **Hiding row errors while recording** could mask a genuinely dead
  registration for the duration of the popover; the same refusal text is shown
  inside the popover and the row note returns on close.
- `OtoSegmented` is shared: Auto Cleanup deliberately keeps the full-width
  track; only the Flow Bar row opts into the compact form.
- Deferred: same compact treatment for Auto Cleanup (not asked); keeping the
  transform recorder open after a clear (existing close-on-clear behaviour is
  unchanged).

## Follow-up (2026-10-31, second pass on the user's capture)

Three defects from the rendered row and recorder:

1. **"Position" floated above the pill.** `LabeledContent` pins the label to
   the row's first line while the custom control centres in the taller cell.
   Replaced with `HStack(spacing: 12) { Text("Position"); Spacer; OtoSegmented }`,
   which centres both on one axis (`GeneralPane.swift`).
2. **Note copy.** "Top sits below the notch. Drag the pill anytime — it snaps."
   read as jargon plus an em dash. Now: "Top places the pill under the menu bar.
   Bottom places it above the Dock. Drag the pill to move it and it snaps into
   place."
3. **The accepted/refused wash was clipped to the chips row.** Adding the
   top-centre Delete hint made the glow start below it, so the green (and red)
   read as a band instead of the popover's own tint. The wash moved from the
   chips row's background to the whole popover's background, clipped to the
   same 20 pt shape as the glass, in both recorders
   (`ShortcutRecorderField.swift`).
4. **⌫ hint is a glyph, not a keycap.** Both recorders render `Text("⌫")` in
   the sentence; the "esc" hint on Close keeps its keycap because that one is
   the key that closes the surface.

Verified: build, 600 unit tests, UI test (flaky once, passed on re-run), dark
and light captures of General and the Dictation recorder, plus a temporary
probe capture of the accepted wash (probe removed after the check).

Outstanding (user will supply logs): the onboarding permission crash. The
crash reports on 2026-10-29 and 2026-10-31 are both
`EXC_CRASH/SIGABRT` with termination namespace `TCC` and "must contain
NSSpeechRecognitionUsageDescription". The built bundle's `Info.plist` does
contain the key, so the next step is to read Xcode's log and the current
TCC/LaunchServices state on the machine that reproduces it.
