# Onboarding v2 — fresh-start first-run (Dia-shaped, compact, no-skip)

Status: PLAN ONLY. Nothing implemented. Awaiting `execute`.

Supersedes `plan/onboarding-first-run.md` (which specced a singular
`Window("Welcome to Oto", id:)` scene — that type **does not exist** in
the local SDK, §2 — plus a Skip button the user has now vetoed).

## 0. User asks locked in

1. Onboarding experience that lists features + lets the person keep or
   change the hold-to-talk key (default Right ⌥). Hands-free toggle
   stays empty by design; its always-on path (double-tap of the hold
   key) is shown as a derived row.
2. App starts fresh for testing: wipe every Oto-owned datum (settings,
   cache, stored files) — §6 wipe protocol.
3. Reference look: the three Dia screenshots (dark card, centered
   column, dots bottom-left, Back/Continue bottom-right) — but the
   window must be **small**, not the ~1300px reference size.
4. **No Skip button anywhere** — onboarding is mandatory reading.
5. Menubar gets an onboarding button so it can be re-run on demand.
6. This plan lists the exact pages (§3).

## 1. Spec sources (canonical first)

- `Docs/START_HERE_PRODUCT.md` is canonical on conflict. It already
  mandates this journey (§First launch): menu-bar utility → short
  shortcut+privacy explanation → permissions only when needed →
  speech readiness with explicit offline prepare → safe-field shortcut
  test. This plan implements exactly that, nothing more.
- House rules honored: one native `Settings` scene (untouched), Flow
  Bar is the only custom surface (onboarding uses plain SwiftUI in a
  native window — no custom traffic lights, no custom chrome),
  coordinator owns sessions (onboarding owns no services; try-it
  dictation flows through the real dispatch+coordinator like the
  Settings try-it field does).
- Prior art reused, not reinvented: `KeycapField`,
  `ShortcutRecorderModifier`, `KeyNames`, `ShortcutStaging` gate,
  `PermissionsManager`, `SpeechAssetPreparer`, `NoTargetModalSettings`
  key pattern, `DictationPane` permission-button patterns.

## 2. Facts verified against the local SDK (never from memory)

Checked 2026-09-28 via Xcode ACP + `MacOSX27.0.sdk` headers/`.swiftinterface`:

- ACP log: `XcodeListWorkspaces` → none open;
  `XcodeOpenWorkspace(/Oto.xcodeproj)` → `workspace-xGQ1ChtV1E`,
  scheme Oto, destination My Mac; `XcodeListSchemes` → 1 scheme (Oto);
  `XcodeListTargets` → Oto app + OtoTests + OtoUITests.
- Xcode 27.0 (27A266a), `MACOSX_DEPLOYMENT_TARGET = 27.0`,
  `PRODUCT_BUNDLE_IDENTIFIER = app.Oto`, `ENABLE_APP_SANDBOX = NO`,
  hardened runtime YES (`Oto.xcodeproj/project.pbxproj`).
- **Load-bearing correction:** there is NO singular `Window` Scene in
  `SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface` (34,178
  lines; `Scene` conformers are `Settings`, `MenuBarExtra`,
  `WindowGroup`, `UtilityWindow`, `DocumentGroup`, … — zero `struct
  Window : Scene`). The old plan's `Window("Welcome to Oto", id:)`
  would not compile. Onboarding uses **`WindowGroup(id:)`** +
  `.defaultSize(width:height:)` + `.windowResizability(.contentSize)`,
  all three confirmed present in the same `.swiftinterface`.
- `@Environment(\.openWindow)` (`OpenWindowAction`, line 3777) and
  `@Environment(\.dismissWindow)` (`DismissWindowAction`, line 30540)
  confirmed present — menubar re-run and Finish/close paths.
- `SettingsLink` confirmed (line 11907) — untouched.
- Permissions: `AVAudioApplication.requestRecordPermissionWithCompletionHandler`
  `API_AVAILABLE(macos(14.0))` (`AVAudioApplication.h:119`); 
  `SFSpeechRecognizer.authorizationStatus`
  (`SFSpeechRecognizer.h:98`); AX blessed prompt
  `AXIsProcessTrustedWithOptions` (existing `DictationPane` path,
  no raw Settings URLs).
- Speech: `SpeechAssetPreparer` remains the ONLY `downloadAndInstall`
  caller (grep gate holds) — onboarding's prepare button calls
  `prepareDefault()`, never the shortcut path.
- Data inventory on this Mac (the wipe target, §6):
  `~/Library/Preferences/app.Oto.plist` holds
  `dualShortcutConfiguration`, legacy `shortcutConfiguration`
  (read-only migration source — never written), `flowBarPosition`,
  `historyEnabled`, `mediaDuckedByOto` + saved volume/device,
  `showInDock`, `noTargetModal`, `muteMediaWhileDictating`,
  `NSWindow Frame …Settings_window`;
  `~/Library/Application Support/Oto/` holds `dictionary.v1.json`,
  `history.v1.json`, `Backups/*.json`, `Models/`;
  legacy `~/Library/Containers/app.Oto/…` is migration-read-only
  (`LocalPersistence.migrateSandboxedStoreIfNeeded`,
  `MediaDuck` container plist path). TCC grants (Mic/AX/Speech) are
  system-owned and **cannot** be reset by any wipe — stated honestly
  in the matrix.

## 3. Pages (5, compact, no Skip)

Fixed window **620×480**, `.windowResizability(.contentSize)`,
standard native traffic lights, centered content column max-width
**480** (Dia rhythm at Oto scale). Dots bottom-left, Back + primary
(Continue/Finish) bottom-right. No ScrollView (content budgeted to
fit); system light/dark adaptive (never forced dark). No Skip button
on any page; red-close does NOT mark seen (§4) so closing can never
skip.

1. **Welcome** — "Oto turns speech into text, anywhere." One line each:
   hold a key → speak → release → text lands where you were.
   Private by construction: on-device Apple Speech, no account, no
   cloud fallback. [Continue]
2. **What Oto does for you** (the feature list, 3 rows, SF Symbols):
   - Push to talk — hold a key for short bursts (default Right ⌥).
   - Double-tap → hands-free — tap-tap the same key, talk long,
     press again to stop. Zero setup, follows your hold key.
   - Recoverable — no field, no loss: catcher window / clipboard /
     opt-in history. Plus one line: works offline once speech is
     prepared. [Back] [Continue]
3. **Your hold key** — live `KeycapField` (click to re-record) +
   hold-key menu + presets, default Right ⌥ chip shown with
   "Keep it, or press Change." Staged edits apply **immediately**
   through `dispatch.updateHoldTrigger` (same gate/conflicts/Swap
   rules as Settings; blocked shows the same inline message + Swap).
   Below: derived non-editable `Double tap <live hold chip>` row
   (mirrors staged-or-saved hold; fn shows the system-owned caption
   per model policy). Hands-free toggle is NOT on this page — one
   line notes it lives in Settings, empty until opted in. [Back]
   [Continue] (Continue never gated — keeping the default is valid.)
4. **Permissions** — three honest rows with status + action button
   each (patterns copied from `DictationPane`):
   - Microphone → `ensureMicrophone()` on button (user gesture).
   - Accessibility → blessed AX prompt; copy names the why (global
     keys + insertion).
   - Speech recognition → status only (system grant path).
   [Back] [Continue] always enabled — never trap; rows stay honest.
5. **Ready + try it** — `Prepare offline speech` button
   (`prepareDefault()`, feedback line, disabled while preparing) +
   readiness/language line + try-it `TextEditor` (real dispatch path,
   inserts into whatever app is frontmost incl. Oto's own window) +
   [Back] [**Finish**] — Finish marks `onboardingVersion = 1` and
   dismisses. First-run completes in a working state.

Deliberately out: hands-free setup, login-item prompt, appearance
pickers, analytics, custom window chrome, `+` alternate bindings.

## 4. Exact file changes

1. `Oto/Onboarding/OnboardingStore.swift` (new, pure + tested):
   `enum OnboardingStore { static let key = "app.Oto.onboardingVersion";
   static let current = 1; static func shouldShow(defaults:) -> Bool;
   static func markSeen(defaults:) }` — absent = show, `>= current` =
   hidden, bump re-shows. `NoTargetModalSettings` precedent.
2. `Oto/Onboarding/OnboardingView.swift` (new): 5-step pager per §3;
   takes `dispatch/preparer/permissions` as params (owns no
   services); reuses `KeycapField`, `ShortcutRecorderModifier`,
   `KeyNames`, `ShortcutStaging` preview; ESC is **not** a skip —
   bind ESC to Back (or nothing on page 1); window-close path marks
   nothing (reshows next launch by construction).
3. `Oto/App/OtoApp.swift`: add `WindowGroup(id: "onboarding")`
   scene with `.defaultSize(width: 620, height: 480)` +
   `.windowResizability(.contentSize)`; on launch (deferred past
   composition, never blocking audio/speech init) call
   `openWindow(id:)` when `OnboardingStore.shouldShow()`; pass the
   existing coordinator/dispatch/preparer/permissions instances
   (audit S2: no duplicates).
4. `Oto/UI/OtoMenuBarView.swift`: add `Show onboarding…` item
   (`openWindow(id: "onboarding")`) above `SettingsLink` with a
   `Divider`; everything else untouched (recovery, escape note,
   Settings, Quit).
5. Reuse untouched: `ShortcutModal` card logic (no fork — onboarding
   embeds the same field + gate), `PermissionsManager`,
   `SpeechAssetPreparer`, `MediaDuck`/`DockVisibility` (no interplay).
6. Tests (deterministic, no hardware): store absent→show,
   marked→hidden, version-bump→reshow, close-without-finish→reshow;
   staging/gate reuse needs no new tests (same code paths as
   Settings — cite, don't duplicate).

## 5. Verification

- Build green; full suite green twice (existing suites untouched,
  must stay green; only new store tests added).
- Fresh-start device matrix (§6 wipe first, then): cold launch shows
  onboarding at 620×480 with zero Skip affordances; red-close →
  relaunch reshows; walk all 5 pages; change hold key (applies +
  persists + double-tap row follows); keep-default path; grant mic
  + AX from their buttons (TCC prompts need the gesture — all
  requests ride buttons); prepare offline speech; try-it dictation
  inserts; Finish → never reshows; menubar `Show onboarding…`
  reopens mid-session with live state; light + dark screenshots for
  the no-custom-chrome check.
- TCC honesty: Mic/AX/Speech grants survive the wipe (system-owned)
  — matrix records them as pre-granted, not as failures.

## 6. Fresh-start wipe protocol (dev machine only, irreversible)

Run before the matrix so the app starts with no settings, no cache,
no stored storage (TCC excepted, §2):

```sh
pkill -x Oto || true
defaults delete app.Oto
rm -rf ~/Library/Application\ Support/Oto ~/Library/Containers/app.Oto
rm -rf ~/Library/Developer/Xcode/DerivedData/Oto-*
# relaunch from Xcode (Run), then cold-launch checks in §5
```

What this clears key-by-key: every plist key in §2 (dual + legacy
shortcut configs, flow position, history flag, duck flags, dock
flag, catcher/media flags, Settings window frame) + `onboardingVersion`
itself (absent = show) + all versioned JSON stores + backups. What it
cannot clear: TCC (Mic/AX/Speech), the system speech asset itself
(installed locales stay — correct: assets are Apple's, not Oto data).

## 7. Risks / deferred decisions

- Red-close reshow could annoy: accepted deliberately (no-skip
  mandate); the window is small and Finish is one try-it away.
- Continue-never-blocked means a user can finish with mic denied:
  accepted (START_HERE first-launch journey says explain + offer,
  never trap); rows stay honest, dictation surfaces the recoverable
  failure later.
- Hands-free setup stays in Settings (empty default + double-tap
  note) — no second recorder in onboarding keeps the window small.
- No custom illustrations beyond SF Symbols — keeps the diff native
  and the window compact.

## 8. Open questions

None. Prior Qs locked: uniform staging (yes — Done-gate semantics
reused for the hold key), ambiguous roles keep diverting (yes,
unchanged), fn policy derives from `Kind.isSystemTapSensitive` /
`supportsHandsFreeToggle` (unchanged), empty hands-free default
(unchanged).
