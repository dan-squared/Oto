# Settings: compact rows (i / edit / delete) and one-control permission rows

Status: PLANNED (not implemented). Awaiting "execute".

## Goal

1. **Rows stop being bloated.** Dictionary, Snippets and History rows become a
   single line of content plus an icon cluster on the right — pencil, info,
   trash (plus copy / clean-up where the feature exists). Dates, app names and
   per-row text buttons leave the row; the info button opens a small glass
   popover in the recorder's vocabulary.
2. **One control per permission row.** "Not allowed" *is* the button — status
   and action collapse into one pill that changes state. No second button
   underneath, in Settings or onboarding, for microphone, accessibility and
   speech recognition.
3. **Behavior moves to General.** "Show catcher when there's nowhere to paste"
   and "Mute media while dictating" leave Dictation for General.

(3 lives in `plan/onboarding-drop-speech-and-general-behavior.md`.)

## Specification sources

- User screenshot `.context/attachments/nVZG6j/…png` — the reference row:
  title left, **pencil + trash icons** right, one line, 16 pt side padding.
- User screenshot `.context/attachments/4yItzS/…png` — today's History row
  (text + "Conductor · 29 Oct 2026 at 11:46 AM" + Copy / Clean up / Delete).
- User screenshot `.context/attachments/fUemaO/…png` — today's broken
  Accessibility row: amber "Not allowed" pill **and** a primary
  "Open Accessibility settings" button below it, pushing the row out of the
  card's baseline.
- `Oto/Settings/ShortcutRecorderField.swift` — the popover vocabulary the info
  panel must borrow: `.frame(width: 252)`,
  `.presentationBackground(.ultraThinMaterial)`, `.presentationCornerRadius(20)`,
  divider + right-aligned `Close` + `OtoKey("esc")`.
- `Oto/Settings/PermissionRows.swift`, `Oto/Settings/SettingsUIState.swift`,
  `Oto/Onboarding/OnboardingPlates.swift`, `Oto/UI/Theme/OtoControls.swift`.

## Facts verified

- `LabeledContent(title) { VStack(alignment: .trailing, spacing: 8) { pill;
  button } }` is the source of the broken row: two trailing children in a
  vertical stack make the row taller than the card's line and the button hangs
  outside the visual rhythm. `SpeechStatusRow` already does the right thing
  (one control in the trailing slot) — the accessibility row is the outlier,
  and the mic row swaps between a button and a pill depending on state.
- `OtoStatus` is a static capsule (dot + label, `OtoStatus.wash`). Nothing
  makes it clickable today; it is used in Dictation readiness (line 36),
  Intelligence (line 52), the three permission rows and the onboarding speech
  plate.
- Denial routing already exists and is test-pinned: `MicSettingsLink`,
  `SpeechSettingsLink`, `SettingsLinkOpener` (in `UI/FlowBar/PermissionModal.swift`),
  `SettingsUIState.requestAccessibilityPrompt()` → `AXIsProcessTrustedWithOptions`.
- History rows use `AppNames.displayName(forBundleID:)` and
  `entry.createdAt.formatted(date: .abbreviated, time: .shortened)`; both are
  display-only and can move into a popover with no store change.
- `HistoryEntry` is `Identifiable`, so `.popover(item:)` works directly.
  `DictionaryRule` and `Snippet` are `Identifiable` too.

## Design

### 1. Row chrome — new `Oto/Settings/OtoRowActions.swift`

```swift
struct OtoRowButton: View        // 12 pt symbol, 22 × 22 hit area, plain,
                                 // hover wash capsule, .help + accessibility label
struct OtoRowActions<Content: View>  // trailing cluster: HStack(spacing: 2)
struct OtoInfoPopover: View      // the recorder's glass, 252 wide, radius 20
```

- Row content: one line, `.font(.system(size: 13))`, `.lineLimit(1)` for
  Dictionary/Snippets, `.lineLimit(2)` for History (a transcript is the
  content; two lines is the ceiling).
- Cluster always in this order: feature actions → `info.circle` → pencil (where
  editable) → `trash` (red on hover).
- Info popover anatomy: title (12 medium, ink), 2–5 label/value rows
  (11.5; label `muted`, value `ink`, label column 74 wide), optional inline
  action, `Divider()`, right-aligned `Close` + `OtoKey("esc", compact: true)`.
  Same `252 / ultraThinMaterial / 20` numbers as `ShortcutCapturePopover` so
  the two read as one family. Esc closes it (popover default) — the row is a
  hint, not a control.
- Nothing in the popover is editable; edit stays the pencil's job.

### 2. Per-pane rows

**Dictionary** (was: rule → replacement + app-names line + Edit/Delete text)

- line: `"spoken" → "replacement"` (13 pt), dimmed 0.45 when `!isEnabled`
- cluster: `info.circle` → `pencil` → `trash`
- info rows: `Applies in` ("Everywhere" or `InstalledApps.names(for:)`),
  `Status` ("On"/"Off")
- tap on the row still opens the editor (unchanged); the pencil is the explicit
  affordance.

**Snippets** (was: name + preview + app line + Edit/Copy/Delete text)

- line 1: name (13), line 2: preview single truncated line (11.5, secondary) —
  a snippet without its text is unreadable, so one line stays.
- cluster: `doc.on.doc` (Copy, keeps the overwrite guard) → `info.circle` →
  `pencil` → `trash`
- info rows: `Applies in`, `Length` ("142 characters"), plus the full expansion
  in a 6-line `lineLimit` block above the divider.

**History** (was: text + app · date + Copy/Clean up/Delete text)

- text: 2 lines, no app, no date, no second line of chrome.
- cluster: `doc.on.doc` (Copy) → `sparkles` (Clean up, only when
  `polishActionVisible`) → `info.circle` → `trash`
- info rows: `App`, `Saved` (`date .abbreviated`, `time .shortened`),
  `Words` ("Cleaned with Apple Intelligence" / "Original wording kept")
- `Undo AI edit` moves into the popover as a single inline action when
  `wasCleaned && rawText != nil` — it is rare and destructive-ish, so it does
  not earn a permanent icon.
- Pagination and `Clear all…` unchanged.

### 3. One-control status/action pill — `OtoControls.swift`

```swift
struct OtoStatusAction: View {
    let text: String
    let tone: OtoStatus.Tone
    var help: String?
    var busy = false
    let action: () -> Void
}
```

- Identical capsule to `OtoStatus` (dot 6, label 11.5 medium, `wash` fill), but
  a `Button(.plain)` with `OtoBounce()` press physics and a hover fill that
  steps `wash → hover`. Hover is the only affordance added: no chevron, no
  underline, no second button — the label already says what the state is.
- `.help(help)` carries the instruction ("Opens System Settings → Privacy &
  Security → Microphone"), `.accessibilityHint` carries it for VoiceOver.
- `busy` shows "Preparing…" and disables, for the speech download case.
- `OtoStatus` stays for read-only readouts (Intelligence, onboarding readiness
  copy).

**Permission rows** (`PermissionRows.swift`) — exactly one trailing child each:

| Row | Allowed | Not asked | Denied |
|---|---|---|---|
| Microphone | `OtoStatus "Allowed"` | `OtoStatusAction "Allow"` → `ensureMicrophoneGrant()` | `OtoStatusAction "Denied"` (warn) → `MicSettingsLink` |
| Accessibility | `OtoStatus "Allowed"` | — | `OtoStatusAction "Not allowed"` (warn) → `requestAccessibilityPrompt()` |
| Speech | `OtoStatus "Allowed"` | `OtoStatusAction "Allow"` → `ensureSpeechGrant()` | `OtoStatusAction "Not allowed"` (warn) → `SpeechSettingsLink` |
| Readiness (Dictation) | `OtoStatus "Ready"` | `OtoStatusAction "Prepare speech"` → `runPrepare()`, "Preparing…" while busy | same as not asked (error copy lives in the note) |

- `uiState.speechPermission == nil` (not yet read) keeps a static
  "Checking…" pill so a button never appears before the state is known.
- Re-check on `NSApplication.didBecomeActiveNotification` so returning from
  System Settings updates the pill without a reopen (today only `.task` on
  appear refreshes).

**Onboarding permissions plate** — same component, so the chapter is the
rehearsal of the product:

- each row: icon + title, then one pill on the right — static "Allowed" when
  granted, `OtoStatusAction` "Allow" / "Not allowed" otherwise;
- the row's status text and the separate prominent button are deleted; the
  guidance line (e.g. "Needed to type into other apps") stays as muted copy
  under the title only when the grant is missing.

## Exact file changes

| File | Change |
|---|---|
| `Oto/Settings/OtoRowActions.swift` | **new** — row button, cluster, glass info popover |
| `Oto/UI/Theme/OtoControls.swift` | add `OtoStatusAction` (reuses `OtoStatus` visuals) |
| `Oto/Settings/DictionaryPane.swift` | new row layout + info popover |
| `Oto/Settings/SnippetsPane.swift` | new row layout + copy icon + info popover |
| `Oto/Settings/HistoryPane.swift` | new row layout, date/app moved to popover, undo in popover |
| `Oto/Settings/PermissionRows.swift` | one control per row, denied routes to Settings |
| `Oto/Settings/DictationPane.swift` | readiness becomes `OtoStatusAction` |
| `Oto/Settings/SettingsUIState.swift` | only if a derived `micAction`/`speechAction` value is worth unit-testing (preferred over view-side switches) |
| `Oto/Onboarding/OnboardingPlates.swift` | permission rows use the same pill; speech plate deleted by the other plan |

## Verification

1. Build + full unit suite.
2. Extend the settings probe to capture: dictionary list, snippet list, history
   list, the info popover open on a history row, and Dictation/Privacy with
   permissions denied — light and dark.
3. Geometry assertions in a new `OtoRowMetricsTests` are **not** possible for
   SwiftUI layout without snapshots; instead pin the pure mappings that can
   drift: tone/label per permission state, "Everywhere" vs app-name scope copy,
   and the undo visibility predicate.
4. Manual on a signed build: revoke mic/speech in System Settings, reopen →
   one amber pill, click it → System Settings opens on the right pane; grant →
   pill turns green with no layout shift (row heights measured before/after in
   the probe).
5. Accessibility: VoiceOver reads the pill as a button with the state as its
   label and the destination as its hint.

## Risks / deferred

- `OtoStatusAction` inside a `LabeledContent` row is still a button in the
  trailing slot, so hit targets and row heights match the current speech row —
  the broken accessibility row was a *layout* bug, not a control bug.
- Moving `Undo AI edit` into a popover adds one click to a rare action; the
  polish flow itself is untouched.
- Opening System Settings from a pill on a menu-bar-only app must not steal the
  window's key loop; verified manually (the app is `.accessory`, System
  Settings takes focus by design).

## Open questions

1. Should the info button also appear on Dictionary/Snippets rows whose scope
   is global? Default: yes, always — a consistent cluster is cheaper to read
   than a conditional one.
2. History "Words" detail: keep a word count too, or only cleanup state?
   Default: cleanup state only (word count is noise).
