# Phase 5 — Native Settings product (EXECUTED 2026-09-21)

Status: built, TEST SUCCEEDED (90+ unit + UI), pushed to main (8d4862f).
UI-polish commits after that push (titlebar, top-bar, row size) are
UNCOMMITTED on `abu-dhabi` — push after visual sign-off. Supplement plans
`phase-5-titlebar.md` (§9–§16) and `phase-5-topbar.md` (§7) hold the
screenshot-driven trail; this file is the as-built truth. If any section
below disagrees with those supplements, THIS file wins on architecture and
the supplement wins on its own experiment's history.

## 1. As-built architecture (read this; skip the archaeology)

- Dock visibility: `Settings → General → "Show Oto in Dock"` (default ON),
  immediate `setActivationPolicy` + scalar persist, restored at launch via
  `DockRestoreDelegate.applicationDidFinishLaunching` (NSApp is nil in
  App.init — crash-proven, never restore there). See
  `plan/phase-5-dock-visibility.md`. Single source of
  truth — no menu duplicate.

- Settings scene → `Oto/Settings/SettingsRoot.swift`: **`TabView` root,
  two tabs (General, Dictation)**. `SettingsPane` enum (General, Dictation)
  survives as the selection type and is extensible — Phase 6 adds cases,
  nothing changes shape.
- `Oto/Settings/GeneralPane.swift` — `Form(.grouped)`: launch-at-login
  control with FOUR states (on / off / requires-approval guidance /
  notFound guidance — never a lying spinner) + About (version, bundle id).
  Thin by design.
- `Oto/Settings/DictationPane.swift` — `Form(.grouped)`: Speech (readiness
  row via new `status()`, Prepare action, language status row
  system→matched-fallback, NO picker — no selection seam exists);
  Shortcut (trigger picker, combo recorder, mode segmented, calibration as
  product test row); Microphone (system-default label only — no enumeration
  seam, Yap parity); Permissions (mic via `ensureMicrophone()`, AX via
  `AXIsProcessTrustedWithOptions` prompt API, speech status-only);
  `TextEditor` try-it field (device-proven: Oto-frontmost passes gates).
- `Oto/Settings/ShortcutRecorderField.swift` — recorder modifier +
  conflict copy + calibration text, migrated verbatim from DEBUG (logic
  untouched, still covered by `ShortcutRecorderTests`).
- `Oto/Support/LoginItemManager.swift` — protocol + live `SMAppService`
  wrapper, four statuses, fake-tested. No entitlement for main app.
- `SpeechAssetPreparer.status(locale:)` — readiness query mirroring the
  inspection half of `AppleSpeechService.prepare()` (same mapper, no
  download — `downloadAndInstall` grep gate holds).
- `Oto/UI/OtoMenuBarView.swift` — production menu: one-shot status on
  open (no poll loop), recovery section ONLY while a transcript is kept
  (Copy + Retry), `SettingsLink`, Quit. Probe/Prepare buttons dead.
- Deleted: `SettingsWindowAccessor.swift` (custom titlebar — 03 ban,
  user-signed reversal of the Phase-0 exception), `SettingsRootView.swift`
  (DEBUG; recorder code migrated, not lost), `probeActivation` (dead —
  sandbox verdict settled).
- Row type: sidebar era ended at 15pt rows; top-bar era has no rows.
- Scene: `.defaultSize(760×620)` on Settings; min frame 720×520.
- Grep gates (all clean): `DEBUG` → 0 in `Oto/`+tests; `NSAppleScript` → 0;
  `titlebarAppearsTransparent` → 0; `SettingsWindowAccessor` → 0;
  `postToPid` → 0 (Phase 4 revert holds).

## 2. Navigation decision log (why old words differ — read before reviving)

- **D1 — split view → fixed columns** (`phase-5-titlebar.md` §10,
  user-directed): `NavigationSplitView` auto-collapsed the sidebar at open
  and floated its toggle in content. Tried `HSplitView` + `List` (nothing
  to collapse). Revert receipt held, now SPENT (superseded by D2 — the
  HSplitView shape is still restorable verbatim from §10 if ever wanted).
- **D2 — fixed columns → toolbar tabs** (`phase-5-topbar.md`, user-approved):
  `TabView` as Settings root renders native toolbar tabs; selected tab's
  name centers in the titlebar; toggle/collapse class deleted instead of
  negotiated. Panes moved untouched.
- **D3 — Phase 6 subsections** (`phase-5-topbar.md` §7, planned, unbuilt):
  top level stays FLAT FOUR (General, Dictation, Writing, Privacy&History);
  Dictionary/Snippets and History/Privacy switch behind in-content
  segmented `Picker`s — never a nested `TabView` (two competing tab bars),
  never six flat tabs (crowded, grouping destroyed).
- **Active deviations from 03/START_HERE (explicit, user-signed):** no
  `NavigationSplitView` sidebar; `TabView` at root instead of inside a
  pane. Everything else in 03 (native controls, no custom chrome, scene
  ownership, acceptance checks) is honored.

## 3. Deliberate omissions (not oversights)

No locale picker (no selection seam — 07:388 wants a fallback label, which
is what shipped); no mic picker (no enumeration seam); no sounds /
diagnostics (no engines); no Writing / Privacy&History panes (no stores —
Phase 6); no second
PreferencesStore (12:46 — persistence already exists, tested
`ShortcutRecorderTests:128-141`); no System-Settings URL schemes as primary
(prompt APIs instead); no titlebar surgery of any kind.

## 4. Sources (what actually grounded this)

START_HERE navigation rules + Phase 5 brief; 03 scene skeleton/controls/
acceptance; 02 recovery table (recovery's product home); Yap SettingsView
(adopted section list, rejected custom cards); 07:388 (fallback label);
12:46 (one store); local SDK headers/swiftinterface (`SMAppService.h`
four statuses incl. `.notFound`; `AXUIElement.h` prompt API;
`SettingsLink`/`OpenSettingsAction`/`windowStyle(.titleBar)` in
swiftinterface; `Settings` exposes ONLY `init(content:)` — the scene title
is system-composed, hence §16); device sessions (try-it 29 chars into Oto,
switch/Retry/recovery trails).

## 5. Verification record

- `xcodebuild test` green at every step (unit + `SettingsUITests`: one
  window, native Close, both tabs by label).
- ACP `BuildProject` green; app relaunched per step for the screenshot
  loop (PIDs 44767→98192→59293→79589→88411→4996).
- Device-confirmed: try-it insertion, switch fail-closed + Retry,
  password refusal + copy recovery, SENTINEL restore discipline.
- Pending (user matrix §6 of the original draft): login toggle in System
  Settings, mic/AX prompt firing, Cmd-comma + SettingsLink paths,
  resize/large-text, Phase 4 suite re-run post-Settings.

## 6. Known limits (declared, not hidden)

- Scene title reads "Oto Settings" and is NOT renamable by supported API
  (§16: `Settings` has no title parameter). Keep vs hide-text awaits user
  pick; anything else is custom-titlebar surgery under a new name.
- Titlebar row height is native Settings chrome (Font Book is a regular
  window — wrong reference class; Xcode/Safari Settings is the right one).
- ACP doc-search bridge absent all session; verification is SDK + prior
  ACP results (recorded where used).
