# Phase 5 — Native Settings product (PLAN, awaiting execute)

Status: PLAN ONLY + AUDITED 2026-09-21 (§9). Nothing implemented. Read §10,
answer, say **execute**.

## 1. Goal (START_HERE Phase 5 + 03 UI plan)

Replace the DEBUG Settings placeholder with the native first-release Settings
product, and give the menu bar a production menu — with zero behavior change
to coordinator, speech, shortcuts, or insertion:

```text
SettingsRootView (DEBUG Form) → SettingsRoot (NavigationSplitView, native)
OtoMenuBarView (DEBUG items)  → production menu (status + recovery + Quit)
SettingsWindowAccessor (custom titlebar) → DELETED (native chrome)
Trigger/mode/locale live in dispatch/memory → persisted PreferencesStore
```

## 2. Sources read for this plan

- `START_HERE_PRODUCT.md:85-115` (navigation rules — one Settings scene,
  split view + `List(selection:)`, `Form` + native controls, `TabView` only
  inside a pane, no custom chrome, `SettingsLink`/`openSettings`, short
  sidebar) + `:255` (Phase 5 brief) + `:305-313` (milestone).
- `03_NATIVE_SWIFTUI_UI.md` — scene skeleton, 4-pane sketch, controls,
  acceptance checks. 03's 4-pane sketch vs Phase 6 scope conflict resolved in
  §7 Q1; START_HERE is canonical.
- `02_RECORDING_WORKFLOWS.md:127-136` — recovery table: Copy/Retry must have a
  product home before DEBUG dies (Phase 6 Flow Bar is too far away).
- Yap `SettingsView.swift` (318 lines, read in full) — boundary evidence only:
  ADOPT section list (shortcut / language / general-toggles / mic-label /
  permissions banner shown only when missing / about); REJECT custom
  `Card`/`Theme`/button-styled rows — 03 forbids cards, all of it becomes
  `Form` + `Section` + `LabeledContent` + native `Toggle`/`Picker`.
- ACP `DocumentationSearch`: Settings-scene sizing (`defaultSize`,
  `windowResizability`) confirmed; `NavigationSplitView` search returned only
  unrelated symbols — stated plainly, the 03 skeleton + SDK carry that weight.
- Local `MacOSX27.0.sdk` (not memory): `SMAppService.mainApp`,
  `API_AVAILABLE(macos(13.0))` (`SMAppService.h:91`) — no availability gate
  needed at deployment target 27. `ShortcutTrigger` + `ShortcutConfiguration`
  are already `Codable` (`ShortcutModels.swift:35,66` — the shape anticipates
  this phase). Bundle id `app.Oto` (pbxproj). All SwiftUI APIs specced here
  (`Settings`, `SettingsLink`, `NavigationSplitView`, `Form(.grouped)`,
  `MenuBarExtra(.menu)`) predate the deployment target — no `#available`.
- `12_SHORTCUT_BACKEND_PLAN.md:46` — one store only (killed the planned
  PreferencesStore before it was born).
- `07_APPLE_SPEECH_IMPLEMENTATION_PLAN.md:388` — explicit fallback *label*,
  not a picker (no selection seam exists).
- `ShortcutRecorderTests:128-141` — persistence already covered; plan claims
  no new persistence tests.

## 3. What exists vs what is new (verified in source)

| Need | State |
|---|---|
| Trigger picker + combo recorder + conflicts + calibration row | Exists as DEBUG (`SettingsRootView.swift:33-151`), migrates to Dictation pane; recorder modifier + rules untouched |
| Speech prepare action | Exists (`SpeechAssetPreparer.prepareDefault()`), migrates from menu DEBUG button |
| Locale matching | Exists (`SpeechLocaleMatching`); persistence seam UNVERIFIED — execute-time check (§6) |
| Mic device enumeration | DOES NOT EXIST in Oto — no `inputDevices`/`currentInput` anywhere. Yap ships label-only ("uses system default") |
| Permissions state | `PermissionsManager.swift` exists, API UNREAD — execute-time check; fallback is refresh-on-appear + deep links |
| Launch at login | DOES NOT EXIST — new `SMAppService.mainApp` wrapper |
| Preferences persistence | EXISTS — `ShortcutConfiguration.load/save` + `didSet` autosave + dispatch `init(configuration: .load())`, tested (`ShortcutRecorderTests:128-141`). NOTHING TO BUILD. Dropped from §4 (was planned as a new store — redundant). |
| Locale selection | NO seam (service takes `.current` at init; matching is pure `bestMatch`). 07:388 asks for an explicit fallback *label*, not a picker → language status row only; picker deferred until a real selection seam exists |
| Production menu | DOES NOT EXIST — rewrite `OtoMenuBarView` |

## 4. Planned changes

New files:
- `Oto/Settings/SettingsRoot.swift` — `SettingsPane` enum (General, Dictation;
  extensible for Phase 6), `NavigationSplitView` + `List(selection:)`,
  `.frame(minWidth: 720, minHeight: 520)` per 03. No `TabView` (single-context
  panes — 03's tab rule doesn't trigger).
- `Oto/Settings/DictationPane.swift` — `Form(.grouped)`: Speech section
  (readiness row via new `status()`, Prepare action with result feedback,
  language status row — system locale → matched fallback label, no picker); Shortcut section (interaction segmented picker, trigger picker,
  combo recorder + conflict text migrated as-is, calibration row kept as
  product "press your shortcut to test" — Q5); Microphone section (system
  default input label only, no picker and no Sound button — no seam exists,
  Yap parity); Permissions section (mic row via
  existing `ensureMicrophone()`, AX row via `AXIsProcessTrustedWithOptions`
  prompt API, speech row status-only — audit A2, no raw Settings URLs as
  primary); safe `TextEditor` test
  field (START_HERE first-launch journey #5).
- `Oto/Settings/GeneralPane.swift` — `Form(.grouped)`: launch-at-login
  control (new wrapper; THREE states per audit A1 — on / off /
  requires-approval-with-guidance, never a lying spinner), About
  `LabeledContent` (version, bundle id). Thin by design — §8 Q4 explains what
  is deliberately omitted.
- `Oto/Support/PreferencesStore.swift` — `@Observable` single source of truth
  (audit A4): `ShortcutConfiguration` (JSON) + locale id (if seam exists) in
  `UserDefaults`. Dispatch restores at startup in `OtoApp.init`; Settings
  binds to the store.
  **CORRECTION (pre-execute seam check): DROPPED — redundant.** Persistence
  already exists and is tested (`ShortcutConfiguration.load/save`, autosave
  in `didSet`, `init(configuration: .load())`). No store, no dispatch seam,
  no persistence tests. Settings binds call the same
  `updateTrigger/updateInteraction/setEnabled` the DEBUG section uses.
- `Oto/Support/LoginItemManager.swift` — `SMAppService.mainApp`
  `register()/unregister()/status` behind a protocol (SMAppService is final —
  tests use a fake; all three statuses covered). No entitlement needed for the
  main app (execute-time device confirm).
- `OtoTests/LoginItemManagerTests.swift` — all three statuses via fake;
  toggle-intent mapping (on/off/approval-guidance) unit-tested.
- `OtoUITests/SettingsUITests.swift` — 03 acceptance #1 made real: launch,
  open status item, activate Settings link, assert exactly one Settings
  window appears (replaces placeholder coverage with a product assertion;
  launch/perf template tests stay).
- UI tests with mock coordinator/dispatch per 03 acceptance (never mic/tap).

Modified:
- `Oto/App/OtoApp.swift` — pass dispatch/preparer/coordinator/managers into
  `SettingsRoot` (no restore wiring needed — config persistence already
  loads in dispatch `init`); Settings scene hosts `SettingsRoot` (keep
  `.menuBarExtraStyle(.menu)`; scene size per 03 skeleton; NO
  `titlebarAppearsTransparent` anywhere).
- `Oto/Services/SpeechAssetPreparer.swift` — ADD thin `status(locale:) async
  -> SpeechReadiness` (supported/installed + existing tested mapper; no
  download — the `downloadAndInstall` grep gate still holds). The readiness
  row needs a query, not another prepare path.
- `Oto/UI/OtoMenuBarView.swift` — production menu: one-shot status text on
  open (the 500ms poll loop DIES with DEBUG), `SettingsLink`, recovery
  section (Copy + Retry, shown ONLY when `recoveryText()` non-nil), Quit.
  Probe + Prepare DEBUG buttons die (prepare lives in Settings now).
- `Oto/Services/ShortcutDispatch.swift` — NO CHANGES. (Was planned as a
  restore seam — redundant: persistence already loads/saves around every
  mutation.)

Deleted:
- `Oto/Support/SettingsWindowAccessor.swift` — custom titlebar blending
  (`titlebarAppearsTransparent`, hidden title, strip-view surgery, traffic-light
  repositioning) violates 03 rules explicitly. Reverses the Phase-0 user
  exception — needs sign-off (§8 Q2).
- `Oto/UI/SettingsRootView.swift` DEBUG section (recorder modifier moves to
  `Oto/Settings/` as product code, not deleted).

Explicitly NOT in Phase 5: Writing + Privacy&History panes (no stores exist —
  Phase 6 scope; §10 Q1); sounds/diagnostics toggles (no engines — dead controls
  rejected); AI modes/tones (per 03, later phase); Flow Bar (Phase 6);
  sandbox/entitlement changes; coordinator/shortcut/insertion behavior; locale
  picker (no selection seam — status row only). One thin speech addition IS in:
  `SpeechAssetPreparer.status()` readiness query (no download; grep gate holds).

## 5. Assumptions questioned

- "Four panes now because 03 sketches four" — 03 also bans blank panes and
  START_HERE puts dictionary/snippets/history in Phase 6. There is no honest
  content for Writing or Privacy&History today. Two real panes + extensible
  enum beats four panes with two apologies. (§8 Q1)
- "Settings should expose every backend knob" — sounds (no engine),
  diagnostics (no infra), full mic picker (no enumeration API), Flow Bar
  visibility (no Flow Bar) would all be dead controls. Thin-and-real wins.
- "System Settings deep links are stable" — SUPERSEDED by audit A2: prompt
  APIs (`ensureMicrophone()`, `AXIsProcessTrustedWithOptions`) are primary;
  deep links survive only as device-proven fallback or are removed.
- "Persist locale" — RESOLVED: no selection seam exists (service takes
  `.current` at init), so there is nothing to persist. Language status row
  only (system → matched fallback label per 07:388); picker deferred until a
  real selection seam exists.
- "A new PreferencesStore is needed" — REFUTED pre-execute: persistence
  exists and is tested. No second store (12:46).

## 6. Verification

- ACP `BuildProject` green; `xcodebuild test` green (new suites + all existing).
- Grep gates: `DEBUG` → 0 hits in `Oto/`; `titlebarAppearsTransparent` → 0;
  `NSAppleScript` → 0 (standing); `SettingsWindowAccessor` → 0 references.
- UI tests use mocks only (03 acceptance); no mic/tap in tests.
- Device matrix (user, packaged app): Settings opens via menu + Cmd-comma +
  `SettingsLink` as ONE native window; traffic lights native in light + dark;
  resize + larger text clips nothing; sidebar fully visible, keyboard
  navigable; trigger/mode change survives relaunch; login toggle appears in
  System Settings → General → Login Items; mic/AX prompt APIs fire (prompt
  appears exactly once per explicit tap); test field accepts a real dictation; recovery buttons appear
  only after a failed session and vanish after use; normal dictation +
  insertion suite re-run (Phase 4 stays green).

## 7. Risks and deferred decisions

- Settings open steals focus → insertion fail-closed with the "Oto itself"
  reason (§11). ACCEPTED interaction, not a bug; the reason line covers it.
- `SMAppService` register in a sandboxed dev build: spec says no entitlement
  for mainApp, device matrix confirms; if refused, login toggle degrades to a
  System Settings deep link (fallback, not failure).
- Sidebar grows to four in Phase 6 — stated, not snuck.
- Writing/Privacy pane content, Flow Bar, AI modes: later phases, untouched.

## 9. Audit pass (2026-09-21) — every decision re-questioned, then verdict

Tool honesty first: the ACP `DocumentationSearch` bridge is GONE from this
session's tool catalog (confirmed via tool search — no Xcode doc-search tool
exists anymore). All verification below is local-SDK headers/swiftinterface
plus previously recorded ACP results. No `#available` is needed anywhere:
deployment target is 27.0, and every API specced here shipped in 16.0 or
earlier — that long-availability is itself the compatibility proof.

**VERIFIED, plan unchanged:**
- `.windowStyle(.titleBar)` exists (`SwiftUI.swiftinterface:3965`) — the 03
  scene skeleton is valid as written.
- `SettingsLink` (macOS 14+) + `OpenSettingsAction` exist in the swiftinterface
  — menu/Theme entries all target one window, no gates needed.
- `MenuBarExtra(.menu)` — already compiled in `OtoApp.swift`; shipped usage
  beats any doc quote.
- `SMAppService.mainApp` + `register/unregister/status`, macOS 13+
  (`SMAppService.h:84-153`).
- Mic-enumeration absence (no seam in Oto) + Yap label-only precedent — Q3
  stands as recommended.
- Two panes now (03 no-blank-pane rule + Phase 6 scope + START_HERE canonical
  on conflict) — Q1 stands as recommended.
- Omissions (sounds/diagnostics/dock) stand: no engines exist, and the dock
  toggle is activation-policy surgery dressed as a preference.

**AMENDED by the audit (plan text above already reflects these):**
- **A1 — login item is FOUR states, not two** (corrected during execute:
  the test caught it — `SMAppService.h:30-35` adds `.notFound`, which is what
  a non-app host reports). `SMAppService.h:23-24` `.requiresApproval` (user
  revoked consent in System Settings). The General
  toggle renders guidance for both ("approve in System Settings → General →
  Login Items" / "status unavailable"), never a lying spinner.
  `LoginItemManager` exposes the raw status; tests cover all four.
- **A2 — no raw Settings URLs for permissions.** `PermissionsManager` covers
  mic + speech ONLY (no AX row — read the file, `PermissionsManager.swift`).
  AX uses `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`
  (verified `AXUIElement.h:55-66`, since 10.9) — Apple's blessed prompt that
  opens the right page itself. Mic uses existing `ensureMicrophone()`. Speech
  row is status display (+ explicit Request button only — 07 bans speculative
  prompting, a tap is explicit). Deep links survive only as fallback if a
  prompt API ever no-ops, proven on device or removed.
- **A3 — test field upgraded from "recommend" to "include, device-proven".**
  The 20:10:48 session pasted 29 chars into Oto itself: Oto-frontmost + own
  pid passes every insertion gate, so dictating into the Dictation pane's own
  `TextEditor` works. The START_HERE safe-test journey is implementable as
  specced — no focus paradox.
- **A4 — SUPERSEDED pre-execute: no store at all.** The seam check found
  persistence already built and tested (`load/save`, `didSet` autosave,
  `init(configuration: .load())`, `ShortcutRecorderTests:128-141`). A new
  `@Observable` store would be a second competing store — exactly what 12:46
  forbids. Settings binds call dispatch directly, as the DEBUG section does.

**STILL OPEN (§8):** Q2 (accessor deletion reverses your Phase-0 exception —
only you can sign that), Q5 is now decided-yes by A3's device evidence unless
you object. Q1/Q3/Q4 stand as recommended.

## 10. Original §8 questions (answer these, then say execute)

1. **Two real panes now (General, Dictation), Writing + Privacy&History in
   Phase 6? (Recommended.)** Alternative: four-pane shell now with honest
   "arrives with Flow Bar" rows — rejected: placeholder rows are blank panes
   with better copy.
2. **Delete `SettingsWindowAccessor` (reverses your Phase-0 titlebar
   exception)? (Recommended.)** 03 forbids it by name; keeping it keeps a
   custom titlebar into the "native Settings" phase, which defeats the phase.
3. **Microphone row label-only + Sound-settings link (Yap parity)?
   (Recommended.)** Alternative: build device enumeration — rejected: no seam
   exists, new AV/AudioObject API surface for a picker nobody asked for.
4. **Confirm omissions: no sounds, no diagnostics, no dock-icon toggle?**
   (Recommended.) All three lack engines; the dock toggle in particular is
   activation-policy surgery dressed as a preference.
5. **Keep the calibration row as a product "test your shortcut" row?
   (Recommended.)** It's built, tested, and genuinely useful; only the DEBUG
   label dies.
