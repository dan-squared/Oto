# Dock visibility setting — plan (no code changed)

Status: PLANNING ONLY. Nothing implemented. Awaiting user `execute`.

## 1. Goal

Finish the half-landed dock setting so the user gets one working control:
`Settings → General → "Show Oto in Dock"` (default ON = current behavior),
applied immediately via `setActivationPolicy`, persisted across relaunch.
Then push (with the uncommitted Phase-5 UI-polish stack) after device sign-off.

User's second question — "X should remove it from the Dock when the setting
is enabled" — is answered in §6: there is no such half-state in the SDK.
This plan corrects the mental model before building so we don't promise it.

## 2. Spec sources

- `Docs/START_HERE_PRODUCT.md` — General holds low-frequency app behavior
  (`Launch, Flow Bar, Appearance, About`); one native Settings scene;
  production menu stays minimal.
- `plan/phase-5-settings.md` §3 — dock toggle deliberately omitted ("no
  engines — dock is activation-policy surgery"). This plan retires that
  omission line on execute.
- Local SDK truth (never from memory — headers read 2026-09-21):
  - `NSRunningApplication.h:35-36` — Regular: "ordinary app that appears in
    the Dock and may have a user interface. Default for bundled apps."
  - `NSRunningApplication.h:38-39` — Accessory: "does not appear in the Dock
    and does not have a menu bar, but may be activated programmatically or
    by clicking on one of its windows. Corresponds to LSUIElement=1."
  - `NSRunningApplication.h:41-42` — Prohibited: "does not appear in the Dock
    and may not create windows or be activated. Corresponds to
    LSBackgroundOnly=1." Unsuitable — rejected.
  - `NSApplication.h:304-306` — `setActivationPolicy` "any policy may be set"
    since 10.9, returns YES/NO, available macOS 10.6+. Deployment target 27.0
    so availability is trivially satisfied.
- Project state (read-only verification):
  - `Oto.xcodeproj/project.pbxproj:471-472,505-507` — generated Info.plist,
    no `LSUIElement` key anywhere → default Regular → Dock shows today.
  - `Oto/Settings/GeneralPane.swift:18-35` — `DockVisibility` enum already
    exists (defaults key `app.Oto.showInDock`, default shown=true,
    `policy(for:)` mapping, `apply` persists only on success). Correct.
  - `Oto/Settings/GeneralPane.swift:42-43` — `@State showInDock/dockError`
    declared but NEVER rendered; `apply` has zero call sites (repo-wide grep
    for `apply(` finds only the definition). The setting is dead code today.
  - `Oto/App/OtoApp.swift:46-61` — MenuBarExtra + Settings scenes, no launch
    restore of the preference. Relapse/flicker risk on every launch.
  - `Oto/UI/OtoMenuBarView.swift:15-73` — production menu: status (one-shot),
    recovery-only, SettingsLink, Quit. No toggle. Minimal by Phase-5 decision.

## 3. Assumptions questioned

1. "Put it in the menu bar, Settings, or both?" — Questioned. Menu
   duplicates the source of truth, clutters the minimal production menu, and
   the menu's one-shot-read pattern is wrong for a live toggle (needs
   observation to stay in sync). START_HERE places this in General
   (Appearance-class behavior). Recommendation: **Settings General only**.
   The menu already reaches it via SettingsLink — one hop, zero drift.
2. "X removes the Dock icon when hiding is enabled." — False premise.
   X closes the Settings *window* only; the process stays alive for the
   MenuBarExtra. Dock presence is a *process policy*, not a window state:
   Regular → icon persists after X (native, not a bug); Accessory → icon
   never exists (open or closed). There is no supported "icon while open,
   gone on close" mode. Quit-on-close would be a different product decision
   (kills the menu-bar utility) — not proposed.
3. "Need a model store for this?" — No. Scalar `UserDefaults` Bool is what
   shipped; rule 12:46 (one store) is untouched. No new store.
4. "Need `LSUIElement` in Info.plist instead?" — No. Static plist bakes the
   choice; runtime `setActivationPolicy` gives the user the switch. Plist
   stays untouched.
5. "Prohibited as the hide mode?" — Rejected by header: app "may not create
   windows or be activated." Settings could never reopen. Accessory only.

## 4. Exact file changes (on execute)

1. `Oto/Settings/GeneralPane.swift`
   - Render the existing dead state in the General section (above About):
     `Toggle("Show Oto in Dock", isOn: $showInDock)` +
     `.toggleStyle(.switch)` + caption: effect is immediate, no relaunch;
     Dock + Cmd-Tab follow it; menu-bar icon always stays.
   - `onChange(of: showInDock)`: call `DockVisibility.apply(shown:)`; on
     `false` return revert `showInDock` to prior value and set `dockError`
     caption (never a lying toggle). Persist-only-on-success stays.
   - Keep `DockVisibility` enum in place (no move — smallest diff).
2. `Oto/App/OtoApp.swift`
   - New `DockRestoreDelegate` (`NSApplicationDelegateAdaptor`):
     `applicationDidFinishLaunching` calls `DockVisibility.apply(shown:
     DockVisibility.isShown())` so persisted OFF restores at launch.
     MUST live here, never in `App.init` — NSApp is nil there
     (crash-proven 2026-09-21: `GeneralPane.swift:31` fatal unwrap).
     Failure path is silent by design (Regular remains, stored pref
     untouched since `apply` writes only on success).
3. `OtoTests/DockVisibilityTests.swift` (new)
   - `isShown` defaults true with empty suite; `policy(for:)` maps
     true→`.regular` / false→`.accessory`; defaults round-trip true/false
     via isolated `UserDefaults(suiteName:)`. NO `apply()` unit test
     (requires live NSApp — device/UI-test covered instead).
4. `OtoUITests/SettingsUITests.swift`
   - Extend: open Settings (existing Cmd-comma path), select General tab,
     assert `checkboxes["Show Oto in Dock"]` (or Toggle-mapped element)
     exists. Existence only — never flips policy in CI (would hide the
     runner's Dock). Same probe loop as the Close-button fix if the
     identifier misbehaves.
5. `plan/phase-5-settings.md` — on execute, strike the §3 "dock toggle"
   omission line and point here. No architecture section rewrites.

Explicitly NOT changed: Info.plist generation, `OtoMenuBarView` (no menu
duplicate), coordinator/speech/shortcuts/insertion, login item, scene type.

## 5. Verification

- `xcodebuild -scheme Oto -destination 'platform=macOS' build` green.
- `xcodebuild test -scheme Oto -destination 'platform=macOS'` green
  (3 new unit + extended UI, first-run pass expected; probe loop only if
  Toggle accessibility role differs).
- Grep gates: `DockVisibility.apply` call sites = 2 (launch + toggle);
  `LSUIElement` still 0 in project; `DEBUG` still 0.
- Device matrix (packaged `.app`, user runs):
  1. Fresh launch → Dock icon present (default ON preserves upgrade).
  2. General → toggle OFF → Dock vanishes immediately, waveform menu stays,
     Settings stays open and reopens from menu afterwards.
  3. X with OFF → window closes, no Dock (nothing to "disappear" — it was
     never there); menu icon remains. X with ON → window closes, Dock stays.
  4. Toggle ON → Dock returns immediately; Cmd-Tab follows in both states.
  5. Relaunch in each state → persists. Failure caption path: only if
     `setActivationPolicy` returns NO (revert + message, pref unclobbered).

## 6. Direct answers (what I think)

- Placement: **Settings General only.** Menu duplicate buys one fewer click
  at the price of two synced controls and a cluttered production menu. If
  device use proves frequent toggling, revisit — evidence, not anticipation.
- X behavior: **default like that is a misunderstanding, honestly.** When
  hide is ON there is no Dock icon at all (that IS the hide); X only closes
  the window. When show is ON the icon staying after X is correct macOS
  behavior — the app is still running for the menu bar. No extra code can
  or should make X "remove" the icon; the policy already owns it.

## 7. Risks / deferred

- Accessory also drops the app menu bar + Cmd-Tab per header; MenuBarExtra
  is not the app menu and should survive, but device step 2 is the proof.
- Toggling to accessory with Settings open: window should persist
  (accessory keeps windows), device confirms — if it vanishes, note as
  platform behavior, not a bug we chase with window surgery.
- `setActivationPolicy` NO-path exists (sandbox/test contexts); UI revert
  covers it. No spinner, no silent persist.
- Push gate: this change + uncommitted titlebar/topbar polish push together
  to `main` only after test-green + device steps 1–5 signed off.

## 8. Open questions (need one-word answers before execute)

1. Placement: Settings-only (recommended) vs also-menu — say which.
2. Default ON (recommended, preserves today) confirmed?
3. X model in §6 accepted (no disappear-on-close half-state)?
4. Push together with the pending UI-polish stack after sign-off?
