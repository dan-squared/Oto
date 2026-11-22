# Phase 3 — Global shortcuts (VERIFIED COMPLETE 2026-09-20)

Status: COMPLETE. Automated 62/62 green + user on-device proof: menu
opens/clicks normally, right-Option hold dictates with real Finals,
calibration row reads Ready after a real global press-release, menu
`Last session` reads `completed`. First-party path A, zero dependencies.
Fixed during execution: `Set(UInt16(kVK_F1)...UInt16(kVK_F12))` range
trapped the test runner (explicit 12-code list now).

## 0. Locked answers + craftsman requirements

- Path A. `KeyboardShortcuts` 3.1.0 stays a REFERENCE ONLY
  (`/private/tmp/keyboardshortcuts-reference`, MIT): studied its Carbon
  backend in full (`HotKey.swift` RAII + signature routing + menu-open
  raw-fallback, `ConflictPolicy`, recorder Escape/Delete/validation
  semantics). Reimplement patterns as Oto-owned code with attribution
  comments; vendor nothing. No `THIRD_PARTY_NOTICES.md` (no dependency).
- Craftsman bar (senior-SE durable): RAII registration (init?/deinit
  unregister — stale callbacks impossible by construction); signature-
  scoped ID routing; menu-open mode (pause Carbon + raw fallback so a
  release while a menu is open can never stick a session); conflict
  policy (menu-item block / system warn incl. sandbox-disallowed block);
  recorder preserves old value on Escape/invalid; suspend-while-
  recording; AX-revoke → unavailable + retry-on-activation.
- Q2 tweak: default is right-Option HOLD (flagsChanged press/release,
  release-to-finish), NOT F5. F5/Dictation stays supported via HID tap.
  Combos via Carbon for users who switch.
- Q3: DEBUG Settings section now (trigger picker + mode + calibration
  row); DEBUG menu simulate items die (real shortcut is the trigger).

## 1. Goal (12 + 02 + 10_NEXT_STEP §1)

One primary shortcut boundary, two physical sources, one transition
machine, zero coordinator changes:

```text
ordinary modifier combo → ModifierHotkeyMonitor (first-party) → HotkeyTransitionState ─┐
F5 / Dictation key      → FunctionKeyMonitor (HID tap, down+up) → HotkeyTransitionState ─┤→ coordinator
Escape (observe-only)   → EscapeMonitor ─────────────────────────────────────────────────┘
```

Hold-to-talk starts on first non-repeat down, finishes on matching up
(release-during-prep = finish-when-ready, owned by coordinator already).
Hands-free toggles per non-repeat down, ignores up. Escape always
cancels. No session ever starts inside the shortcut layer (12 limit).

## 2. Sources read for this plan

- `Docs/OTO_REBUILD_PLAN/12_SHORTCUT_BACKEND_PLAN.md` (full, 62 lines) —
  two-source boundary, package gate 1–7, non-negotiable limits.
- `Docs/OTO_REBUILD_PLAN/02_RECORDING_WORKFLOWS.md` — hold rules 1–5,
  hands-free rules 1–5, transition ownership.
- `07 §5.2` — default F5/Dictation key, recorder requirements, tap rules.
- `10_NEXT_STEP.md` §1 — calibration acceptance (real global down/hold/
  repeat/up, no stale callbacks, suspend-while-recording).
- macOS 27 SDK by grep: Carbon `kVK_F5 = 0x60` (`HIToolbox/Events.h:288`)
  present; `CGEventTapCreate`/`CGEventTapEnable` + `kCGHIDEventTap`
  present (`CGEvent.h`); `kCGEventKeyDown` present (`CGEventTypes.h:116`);
  `AXIsProcessTrusted[WithOptions]` present, un-deprecated
  (`AXUIElement.h`). CGEvent key-field Swift names compiler-verified at
  build (Yap 0.1.12 compiles them; these are decades-stable C APIs).
- Yap reference at `/private/tmp/yap-reference` 6596874, read in full:
  `HotkeyManager.swift` (17), `ModifierHotkeyMonitor.swift` (149),
  `FunctionKeyMonitor.swift` (165), `EscapeMonitor.swift` (44).
- `KeyboardShortcuts` package, latest release **3.1.0** (Sep 11, 9 days
  old — changelog literally leads with "Improve macOS 27
  compatibility"), via GitHub releases + Context7
  (`/sindresorhus/keyboardshortcuts`): exposes `onKeyDown`/`onKeyUp`
  AND `events(for:)` AsyncStream with `.keyDown`/`.keyUp`. License is
  MIT (sindresorhus standard; recorded in `THIRD_PARTY_NOTICES.md` only
  if adopted).

## 3. Yap assessment: adopt / extend / reject

ADOPT (all current in 27 SDK):

- HID tap mechanics: `cghidEventTap` + `headInsertEventTap`, consume
  ONLY the configured key (return nil), pass everything else through;
  timeout/user-input disable → re-enable; nonisolated C callback with
  synchronous consume decision + async hop for the action; tap exists
  only while a trigger is configured; runloop source on main.
- F5 key identity: `kVK_F5` + media variant `176`; bare-press-only rule
  (no cmd/alt/ctrl/shift — ⌘F5 is VoiceOver; fn flag OK); ignore
  auto-repeat for begin.
- `tapCreate == nil` → unavailable state (Accessibility), retry on next
  launch/trigger change.
- Escape observe-only (global + local, never consumed).
- Single-modifier tap detector pattern (flagsChanged, clean-tap timing,
  combo suppression) as reference for LATER single-modifier triggers —
  not built now.

EXTEND (Yap gap vs our 02/12 contract):

- Yap's HID path is **toggle-only** (keyDown tap → `onTap`, no key-up).
  Our hold-to-talk needs down/up on F5: tap must also listen
  `keyUp`, track pressed keyCode, emit down(isRepeat)/up, and reset
  pressed state on timeout/deactivation (02 rule 5). This is the core
  Phase 3 delta — same mechanics, fuller state machine.
- Yap uses the `KeyboardShortcuts` package for ⌘⇧D toggle only. Our
  hold mode needs package key-up proof on device before pinning
  (12 gate #4) — hence the A/B decision in §5.

REJECT:

- Session behavior inside monitors (none exists in Yap — good; keep it
  that way: monitors emit `ShortcutEvent` values, coordinator decides).
- Per-event `Task { @MainActor }` hops in monitor callbacks (Yap
  `addGlobal`/`addLocal` wrappers): 12 bans unbounded tasks per event.
  Our callbacks forward a tiny value synchronously into the transition
  machine; the ONE async hop to the coordinator happens at the
  dispatch layer, not per event.

## 4. SDK/API facts that shape the design

- Carbon keycodes + CGEvent tap + AX trust all present and
  un-deprecated in the 27 SDK (citations §2). No availability guards
  needed at deployment target 27.
- Package 3.1.0 explicitly improves macOS 27 compat — the "verify
  before pinning" gate is about OUR packaged-build proof (key-up,
  re-register, AX revoke, wake), not about the package's SDK support.
- `NSEvent.addGlobalMonitorForEvents` needs no entitlement; the HID
  tap needs AX trust. Sandbox (still ON) is not expected to block
  either, but the packaged-device matrix must confirm — same sandbox
  question flagged in Phase 0, still open, still not decided here.

## 5. Planned changes

New files:

- `Oto/Models/ShortcutModels.swift` — `ShortcutEvent` (value:
  `keyDown(isRepeat:)`, `keyUp`, `monitorLost`), `ShortcutTransition`
  (`begin/finish/ignore/reset`), `ShortcutTrigger` (`.f5Dictation`,
  `.functionKey(F1–F12)`, `.modifierCombo(modifiers,keyCode)`),
  `ShortcutConfiguration` (trigger + mode, Codable; persisted to
  UserDefaults directly — scalars only, playbook-compliant;
  `PreferencesStore` absorbs it in Phase 5).
- `Oto/Services/HotkeyTransitionState.swift` — PURE
  `(event, mode, pressedState) → (transition, pressedState)`. The
  most-tested file in the phase: hold (down→begin, repeat→ignore,
  up→finish, up-in-starting→finish, down-while-active→ignore),
  hands-free (down→begin, up→ignore, down→finish), lost→reset,
  Escape→cancel. No hardware, no async, exhaustive matrix.
- `Oto/Services/ModifierHotkeyMonitor.swift` — FIRST-PARTY Carbon
  backend (recommendation A): `RegisterEventHotKey` for the recorded
  combo, Carbon down/up/repeat callback → `ShortcutEvent`, suspend
  (unregister) while the recorder listens. Package types never cross
  this file's boundary.
- `Oto/Services/FunctionKeyMonitor.swift` — HID tap adopting Yap
  mechanics (§3) extended to `keyUp` + pressed-state tracking +
  `monitorLost` emission on timeout/deactivation. F5/Dictation only;
  never ordinary combos.
- `Oto/Services/EscapeMonitor.swift` — observe-only Escape (adopt Yap
  shape: global + local, static-weak delivery, never consumed).
- `Oto/Services/ShortcutRecorder.swift` — capture logic separable
  from UI for tests: keyCombo capture (modifiers + keyCode), Escape =
  cancel preserving old value, invalid input (modifier-only, plain
  letters) rejected preserving old, conflict vs active trigger
  detected. Suspends dispatch registration while listening.
- `Oto/Services/ShortcutDispatch.swift` — MainActor owner: holds
  monitors + config + transition state, AX-trust monitoring (re-check
  on app activation), translates transitions → coordinator
  `beginHold/finish/toggleHandsFree/cancel`. The single async hop.
  Re-register path unregisters first (no stale callbacks — acceptance
  item).
- `Oto/UI/SettingsRootView.swift` (DEBUG section, migrates to the
  Dictation pane in Phase 5): trigger picker (F5/Dictation + F1–F12 +
  recorded combo), mode picker (hold/hands-free), and the calibration
  row: `Ready` / `Not received globally` / `Conflicts` /
  `Requires Accessibility` — set only by a REAL observed global
  down/up sequence, never by the recorder.
- `OtoTests/HotkeyTransitionStateTests.swift` — full matrix (§6).
- `OtoTests/FunctionKeyMatchingTests.swift` — shouldFire matrix
  (modifiers/repeats/wrong-code/176-variant) as pure function tests.
- `OtoTests/ShortcutConfigurationTests.swift` — Codable round-trip +
  UserDefaults persistence + recorder validation rules.

Modified files:

- `Oto/App/OtoApp.swift` — construct dispatch (monitors + config)
  next to coordinator; default trigger F5/Dictation, hold-to-talk.
- `Oto/UI/OtoMenuBarView.swift` — DEBUG simulate items DIE here
  (real shortcut is the trigger now); Prepare item stays.
- `OtoTests/` — all 35 existing tests untouched.

Explicitly NOT in Phase 3: `KeyboardShortcuts` package (decision §8);
single-modifier-tap triggers (fn/shift-tap — later); shortcut sync
across devices; real insertion (Phase 4); full Settings product
(Phase 5); spoken triggers (later).

## 6. Verification

- `BuildProject` green; new suites green; all 35 existing green.
- Deterministic matrix (no hardware): every hold/hands-free/lost/
  Escape transition; shouldFire combos; recorder preserve-on-Escape/
  preserve-on-invalid; config round-trip.
- Packaged-device acceptance (user-assisted, 10_NEXT_STEP §1):
  real down/hold/repeat/up fires exactly one session per gesture in
  BOTH modes; calibration row reads `Ready` only after a real global
  sequence; re-register leaves no stale callback (change combo, fire
  old combo → nothing); AX revoked → row reads `Requires
  Accessibility`, Settings/menu still work; sleep/wake → clean idle,
  no stuck recording; F5 press does NOT summon macOS dictation
  (consumed at tap head).
- `grep KeyboardShortcuts` → zero hits outside the decision record
  (path A); `grep Task {` in monitor callbacks → zero (12 limit).

## 7. Risks and deferred decisions

- First-party Carbon backend is more code than the package, but its
  key-up path is OURS and unit-provable; the package stays a
  documented fallback with its gate checklist preserved in
  `plan/yap-reference-status.md`-style decision record if chosen.
- Carbon `RegisterEventHotKey` is old but stable and present in 27
  SDK; risk is behavioral (focus/menus swallowing keys), covered by
  the device matrix, not by API availability.
- Lost-key-up (tap timeout mid-hold) leaves coordinator recording
  until cancel/timeout — 02 rule 5 assigns outcome ownership to the
  coordinator; dispatch resets local pressed state only. A hold
  watchdog (max-duration failsafe) is deferred to Phase 4 matrix
  findings — logged, not built.
- Sandbox × event-tap/paste stays open until the device matrix says
  otherwise (carried from Phase 0).

## 9. Root cause + redesign (menu freeze, found live)

- Bisect proved it: menu works with monitors off, freezes with EITHER
  flagsChanged NSEvent monitor (global or local) on. NSEvent monitors
  wedge MenuBarExtra menu tracking on this macOS — mechanism unknown,
  evidence conclusive.
- Permanent fix: ZERO NSEvent monitors in the trigger path.
  Modifier-hold moved to the HID tap (`HIDEventMonitor`: keyDown/up +
  flagsChanged + mouse buttons, single tap/source); Carbon combos stay
  (no monitors involved); Escape folded into the tap (observed-only,
  never consumed); Carbon menu-open raw fallback REMOVED (same
  interference class); `EscapeMonitor.swift` deleted. Cost accepted:
  HID triggers require Accessibility trust (Phase 4 insertion needs it
  anyway; calibration row reports it).
- FlagsChanged are never consumed (system must see Option held).
- Combo-suppression preserved via tap-observed key/mouse activity.
- 6 new `ModifierHoldStateTests`; suite total 62/62 green.
