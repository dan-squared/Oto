# Phase 3 — Solidity audit (2026-09-20)

Status: F1–F3 APPLIED 2026-09-20. Bridge build green, 60/60 unit + 2/2 UI
green after the fixes. F4–F6 remain documented minor gaps. Awaiting on-device
hands-free check (press, press → `completed (handsFree)`).

Thorough code + architecture review of the shipped shortcut layer, doc-verified
via the Xcode bridge (`DocumentationSearch`) and macOS 27 SDK headers — not memory.
No harsh rewrites: every finding carries file:line evidence and a proportional fix.

## 0. Verification base

- `xcodebuild test -scheme Oto`: exit 0, full suite green. 60 `@Test` cases +
  2 UI tests = 62/62. Claim confirmed, not inherited.
- `BuildProject` via Xcode bridge (`workspace-vRDl4bdLsA`): success, zero errors/warnings.
- Device proof on record (prior session): menu alive, right-Option hold dictates
  real Finals, calibration Ready, `completed`.

## 1. Doc-verified facts (strengthen the plan)

1. `CGEvent.tapCreate` signature, head-insert placement, active-filter consume
   semantics — confirmed via `DocumentationSearch` symbol doc
   (`/documentation/CoreGraphics/CGEvent/tapCreate...`). Matches
   `Oto/Services/HIDEventMonitor.swift:99`.
2. Tap callback thread: `CGEvent.h` header — "The event tap callback runs from
   the CFRunLoop to which the tap CFMachPort is added." Ours is added to the
   main runloop (`HIDEventMonitor.swift:123`), so `MainActor.assumeIsolated`
   (`:160`) is valid by construction, not hope.
3. `kVK_RightOption = 0x3D`, `kVK_F5 = 0x60` — confirmed in
   `HIToolbox/Events.h:278,288`. Default trigger + Dictation codes are correct.
4. `RegisterEventHotKey` present in 27 SDK (`HIToolbox/.../CarbonEventsCore.h`),
   compiles with zero warnings at target 27 — availability proven, not assumed.
5. `AXIsProcessTrusted()` is NOT deprecated — only `AXAPIEnabled` is
   (`AXUIElement.h:49`). `ShortcutDispatch.swift:200` uses the right API.
6. NSEvent-monitor vs MenuBarExtra interference appears NOWHERE in Apple docs.
   The ban stays as device-proven empirical law (three-build bisect), mechanism
   unknown. Do not present it as documented behavior.
7. Header nuance the plan mis-states: without AX trust, `tapCreate` returns
   "NULL **or a tap with cleared mask bits**" (`CGEvent.h`). Non-null tap ≠
   delivery. Our calibration is already delivery-gated (Ready only on a real
   down+up, `ShortcutDispatch.swift:176`), so the design is right — but plan
   wording "tapCreate fails without Accessibility" should read "returns NULL
   or a neutered tap".

## 2. Architecture verdict: SOLID — keep it

- Pure `HotkeyTransitionState` + `ModifierHoldState`, exhaustively tested, own
  all key memory. Backends emit values only (12 limit holds).
- RAII Carbon registration, signature-scoped routing, unregister-first
  re-register, suspend-cancels-session, release matched by tracked press
  (not flags — Shift-tap mid-hold can't stick it).
- Single async hop per gesture; no per-event Task (12 limit holds — the
  timeout-path Task and per-gesture Tasks are bounded user intents).
- Stuck-session self-healing: a reset-while-recording leaves `activeSessionID`
  intact, so the next press-release finalizes instead of stranding.
- `12` limits respected: no F5 via Carbon, no session started in backend,
  calibration never from recorder, Escape observe-only.

## 3. Findings (ranked, evidence-backed)

**F1 — Hands-free misrouted in production (real, small fix).**
`ShortcutDispatch.swift:264` routes `.begin` → `coordinator.beginHold()` and
`.finish` → `coordinator.finish(id)` in ALL modes. `toggleHandsFree()` is
called nowhere outside `DictationCoordinatorTests.swift:312` (grep-verified).
Hands-free works end-to-end today (same pipeline, same terminal outcome), but
every hands-free `SessionContext.interaction` is recorded as `.holdToTalk` —
the mode label is a lie, and the tested toggle path is dead code in the binary.
Any future interaction-branching (VAD auto-stop per 02 hands-free rule 5,
Flow Bar labels) would misbehave silently. Fix: in `route()`, hold mode →
`beginHold`/`finish`, hands-free → `toggleHandsFree` for both transitions.
Do in Phase 4 or as a standalone fix — not a rewrite.

**F2 — Dead pause/resume path (cruft, harmless).**
`CarbonHotKeyCenter.setEnabled/pauseAll/resumeAll/isEnabled`
(`CarbonHotKey.swift:99-107,185-195`) has zero callers — dispatch suspends via
`stop()/start()`. Either wire suspend through it or delete it. No behavior risk.

**F3 — Stale comments contradict the code (hygiene).**
`Oto/App/OtoApp.swift:42` still says "TEMP-DIAGNOSIS (menu freeze bisect):
re-enabled for step 1" — the bisect is over, the HID redesign is permanent.
`Oto/UI/OtoMenuBarView.swift:46` NOTE claims `lastResult` "no longer updates
from sessions" while the `.task` at `:28` refreshes it on every menu open.
Both mislead the next reader; fix the words, not the code.

**F4 — Calibration bar is below the 10 §1 acceptance (minor gap).**
`10_NEXT_STEP.md:59` demands Ready only after "a real down/hold/repeat/up
sequence". Ours marks Ready on ANY down+up (`noteObserved`), repeats included
as downs. Delivery-proof, yes; hold+repeat-proof, no. Either extend
`noteObserved` to require a repeat-or-hold sample, or record the deviation.
Not ship-blocking — the observed sequence is still genuinely global.

**F5 — Escape-cancel silently missing on combo path without AX (minor).**
Combo triggers install the HID tap for Escape only
(`ShortcutDispatch.swift:95`); without trust the tap is NULL/neutered and
Escape-cancel dies with no calibration signal (combo `backendsLive` ignores
the tap). Acceptable (combos work without AX by design), but say it in the
calibration copy or log — silent loss of cancel is the wrong kind of silent.

**F6 — One NSEvent monitor remains (justified, constrain it).**
`SettingsRootView.swift:229` installs a LOCAL keyDown-only monitor while the
combo recorder listens. Acceptable under the ban: local (not global),
keyDown-only (the bisect implicated flagsChanged), globals suspended meanwhile,
removed on stop/disappear. Rule for Phase 5: never add a flagsChanged monitor
of either kind; this recorder pattern is the only sanctioned exception.

## 4. What I deliberately did NOT flag

- `handle()` emitting via `DispatchQueue.main.async`: FIFO-ordered, same-thread
  hop, no reorder risk. Fine.
- `refreshAvailability` re-registering on every activation: unregister-first
  makes it idempotent; Carbon handler installed once. Fine.
- `updateInteraction` not restarting backends: backends are mode-agnostic, the
  transition machine is reset. Correct.
- Carbon's age: present, un-deprecated, warning-free at target 27. Keep.
- Lost-key-up watchdog: already a logged Phase 4 risk in the phase plan.
  Still deferred, still correct to defer.

## 5. Verdict

Ship-approved as designed. One real fix (F1), one deletion (F2), comment
hygiene (F3), three documented minor gaps (F4–F6). Nothing here questions the
HID-tap direction, the zero-dependency stance, or the coordinator contract.
Recommend: apply F1–F3 before Phase 4 insertion lands (Phase 4 will branch on
session outcomes; F1's mislabeled interaction would rot quietly there).
