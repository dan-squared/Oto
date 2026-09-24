# Dual shortcut: hold-to-talk + hands-free live together, per-mode recorders

Status: PLAN ONLY. Nothing implemented.
Decisions locked 2026-09-23 (user accepted all recommendations):
D1 two separate live shortcuts, one per mode. D2 defaults: hold = Right
Option, hands-free = Dictation/F5. D3 recorder = combo-only + presets per
slot. D4 Delete-to-clear disables GLOBALLY (single `enabled`, no per-slot
toggle) — plus a deliberate one-line fix (§5.2 F1): any fresh valid
assignment re-enables, closing today's one-way door (today Delete is
permanent-off with no UI way back: `updateTrigger` never sets
`enabled=true`, verified `ShortcutDispatch.swift:150-171` + single
production `setEnabled` caller at `DictationPane.swift:103`).

## 1. Goal

Both modes live at once, no Mode picker, no Settings trip to switch:

- **Hold slot** drives `beginHold`/`finish` (down begins, up finishes).
- **Hands-free slot** drives `toggleHandsFree` (press toggles begin/finish).
- Settings shows **two recorder rows** — "Hold to talk" and "Hands-free" —
  each with a native press-to-record hotkey field (Escape cancels, Delete
  clears, conflict warnings), plus kind presets covering today's three
  trigger kinds (modifier-hold, Dictation/F5 key, custom Carbon combo).
- Conflicts are impossible by construction: same-shortcut-both-slots is
  blocked at save; overlapping modifier/combo pairs resolve deterministically
  (combo wins, hold suppressed — the existing `usedInCombination` rule);
  the coordinator's single-session guard arbitrates simultaneous presses
  (first begin wins, second is a no-op).

Defaults (unchanged hardware): hold = Right Option hold, hands-free =
Dictation/F5 key toggle — i.e. today's two presets become the two live slots.

## 2. Spec sources

- `Docs/START_HERE_PRODUCT.md`: hold-to-talk journey (down → capture →
  Flow Bar → audio → Speech → up → finalize → dictionary → insert),
  hands-free journey (press → record → press → finalize/insert), "Both modes
  use the same coordinator and terminal-state rules. They must not have
  separate recording implementations." (`DictationPane.swift` Mode picker is
  the thing this plan deletes.)
- `Docs/OTO_REBUILD_PLAN/02_RECORDING_WORKFLOWS.md` (hold rules 1–5,
  hands-free rules 1–5, transition ownership) + `12_SHORTCUT_BACKEND_PLAN.md`
  (two-source boundary, one async hop, suspend-while-recording).
- `plan/phase-3-shortcuts.md` (verified complete 2026-09-20; NSEvent trigger
  ban, HID-tap immunity, calibration-only-by-observed-events).
- Current code: `Oto/Models/ShortcutModels.swift` (single
  `ShortcutConfiguration{trigger,kind+interaction,enabled}`),
  `Oto/Services/ShortcutDispatch.swift` (one transition machine, one config,
  mode-parameterized routing), `Oto/Services/HotkeyTransitionState.swift`
  (pure, mode-parameterized — no change needed),
  `Oto/Services/ModifierHotkeyMonitor.swift` (single Carbon combo),
  `Oto/Services/HIDEventMonitor.swift` (single `holdCode` + `functionCodes`
  union + Escape observation on one tap), `Oto/Services/ShortcutRecorder.swift`
  (combo-only classify rules), `Oto/Settings/DictationPane.swift:68-132`
  (Trigger picker + Mode segmented + calibration row),
  `Oto/Coordinator/DictationCoordinator.swift:106-124` (`beginHold`,
  `toggleHandsFree` cross-mode safety), `Oto/App/OtoApp.swift:101-106`
  (dispatch composition).

## 3. Facts verified against the local SDK today (never from memory)

SDK: `/Applications/Xcode.app/.../MacOSX27.0.sdk` (Xcode 27.0), checked
2026-09-23 via header grep:

- `RegisterEventHotKey` present, **not deprecated**:
  `Carbon.framework/.../HIToolbox.framework/.../Headers/CarbonEvents.h:15484`,
  `AVAILABLE_MAC_OS_X_VERSION_10_0_AND_LATER`. No availability guard needed
  at deployment target 27.0. Multi-registration: header states one
  combination per app but distinct combos coexist; our
  `CarbonHotKeyCenter` already keys `hotKeys[hotKey.id]` by id, so two live
  combos (one per slot) need no center change — verified by reading
  `Oto/Services/CarbonHotKey.swift:88-127`.
- `CGEventTapCreate` present, **not deprecated**:
  `CoreGraphics.framework/Headers/CGEvent.h:296`, `API_AVAILABLE(macos(10.4))`.
  One tap multiplexes keyDown/keyUp/flagsChanged/mouse — the dual design
  keeps ONE tap, extended to two hold codes + tagged function codes.
- `NSEvent.addLocalMonitorForEvents` present (`AppKit/Headers/NSEvent.h:554`,
  macos 10.6+). Recorder stays local-monitor (Settings modal context, never
  the trigger path) — the Phase-3 NSEvent trigger ban is untouched.
- Keycodes: `kVK_Escape 0x35`, `kVK_RightOption 0x3D`, `kVK_F5 0x60`
  (`HIToolbox/.../Headers/Events.h:270,278,288`).
- `CopySymbolicHotKeys` present (`CarbonEvents.h:15530+`) — recorder
  conflict warnings keep working per slot.
- No new API adopted: no matched-geometry equivalent exists here; no
  replacement for Carbon combos or HID taps in SDK 27. Decision recorded:
  extend current backends, adopt nothing.

## 4. Assumptions questioned

- **"d/t shortcut" = different shortcut per mode, both live.** If you meant
  one shared shortcut whose *gesture* picks the mode (tap = hands-free,
  hold = hold-to-talk on the SAME key), say so — that is a different,
  harder design (hold-vs-tap disambiguation timer on one transition
  machine) and this plan does NOT cover it. Open question §8 Q1.
- **Interaction becomes a slot property, not user data.** Each stored
  trigger keeps its `interaction` field but dispatch enforces
  hold-slot=`.holdToTalk`, hands-free-slot=`.handsFree` at the routing
  call site (transition `step(_, mode:)` is already parameterized —
  `HotkeyTransitionState.swift:35`). The Mode segmented control is deleted.
  Alternative (keep per-trigger interaction + two slots = 4 combos) rejected:
  multiplies the conflict matrix for zero product value.
- **Recorder stays combo-only + presets.** The hardened
  `ShortcutRecorderRules.classify` (Escape-cancel, Delete-clear,
  modifier-only/plain-letter invalid, system/reserved conflicts) is reused
  verbatim per slot. Bare-modifier and F-key capture are NOT added to the
  recorder; those arrive via per-slot kind presets (Hold key / Dictation key
  / Custom combo), mirroring today's `TriggerChoice`. Rationale: new capture
  kinds invent new validation, new conflicts, new tests — presets cover 100%
  of today's shipped triggers with zero new rules.
- **Migration is deterministic.** Old single config → its matching slot by
  stored interaction; other slot ← factory default (hold default if old was
  hands-free and vice versa). One-shot, versioned key, old key left in place
  (read-only fallback, never written again).

## 5. Exact file changes

1. `Oto/Models/ShortcutModels.swift`
   - Add `DualShortcutConfiguration: Codable, Sendable, Equatable`
     `{ hold: ShortcutTrigger, handsFree: ShortcutTrigger, enabled: Bool }`
     with `defaultsKey = "app.Oto.dualShortcutConfiguration"`,
     `default()` = hold `.defaultHoldToTalk()` + hands-free
     `.dictationKeyHandsFree()`, `load()` with one-shot migration from
     `ShortcutConfiguration.defaultsKey` (old trigger → matching slot,
     other slot ← factory default; interactions enforced), `save()`.
   - Add `conflictsWith(_:)` on `ShortcutTrigger.Kind`: same kind+codes =
     conflict; combo-vs-combo same keyCode with overlapping modifiers =
     conflict (conservative: same keyCode at all); modifierHold-vs-combo
     sharing the modifier = NOT a conflict (combo wins by construction,
     hold suppressed via `usedInCombination` — document, don't block);
     functionKey-vs-combo = conflict only if combo keyCode ∈ function codes
     AND combo modifiers empty (else `shouldFire` bare-press rule already
     separates them — document, don't block).
   - Keep `ShortcutConfiguration` (read-only migration source; marked
     deprecated-in-code with comment, removed no earlier than 2 releases).

2. `Oto/Services/ShortcutDispatch.swift` (the core change)
   - Own TWO `HotkeyTransitionState` (`holdTransition`, `handsFreeTransition`),
     TWO `ModifierHotkeyMonitor` instances (Carbon center already multi-key),
     ONE `HIDEventMonitor` (extended, see 3).
   - `configuration: DualShortcutConfiguration`; `start()` registers both
     slots then one shared Escape observation; per-slot liveness →
     per-slot calibration (`calibrationHold`, `calibrationHandsFree`,
     same 5-case enum).
   - `receive(_:from:)` tags events by source slot, steps the slot's machine
     with the slot's FIXED mode (`.holdToTalk` / `.handsFree`), routes via
     existing `route(_:mode:)` unchanged. `activeSessionID` overwrite only
     on non-nil coordinator return (existing guard covers the
     second-begin-while-active race).
   - `updateHoldTrigger(_:)` / `updateHandsFreeTrigger(_:)` each:
     same-slot-equality → no-op; cross-slot `conflictsWith` → return
     `.blocked` WITHOUT saving (UI keeps old + message); else
     cancel-active-session + save + reset that slot's calibration + `start()`.
     PRESET picks route through this same gate (a preset equal to the other
     slot's live trigger is refused with the same message — no bypass).
   - F1 (deliberate fix, closes today's one-way door): any successful save
     through the gate above sets `enabled = true` (Delete cleared it globally;
     a fresh explicit assignment is intent to have shortcuts on). Without
     this, a re-recorded combo saves but never registers (`start()` early-returns
     on `!enabled`) — verified dead-end on today's code, pinned by new test.
   - `updateInteraction(_:)` DELETED (no Mode concept left); call sites removed.
   - `setSuspended(_:)` unchanged in shape (cancels session, stops ALL —
     either recorder listening suspends both slots; second recorder button
     disabled while first listens — UI rule, see 4).
   - `isEscapeCancelAvailable`, `requiresAccessibility`, `backendsLive`
     computed PER SLOT; overall calibration = worst-of for menu callers that
     need one value (keep single-value API as derived, not stored).
   - Menu-compat (added 2026-09-24): `Oto/UI/OtoMenuBarView.swift:33-34`
      reads `refreshAvailability()` + single-value `isEscapeCancelAvailable`
      and is NOT changed. Both signatures are preserved as derived values:
      `refreshAvailability()` keeps its shape (heals both slots via `start()`);
      single-value `isEscapeCancelAvailable` = shared-tap liveness
      (`hidMonitor.isLive` — Escape rides the one tap in every
      configuration); single-value `calibration` = worst-of both slots.
      Per-slot accessors are additive only.

3. `Oto/Services/HIDEventMonitor.swift`
   - `configure(functionCodes:holdKeyCode:)` → slot-tagged:
     `configure(holdCodes: Set<UInt16>, functionMap: [Int64: Slot],
     escapeObserved:)` where `Slot = .holdAUTO/.handsFree` (tiny enum in
     `ShortcutModels.swift`). Two `ModifierHoldState` instances keyed by
     hold code; `decideHold` routes by keyCode; `pressedFunctionCode` →
     `pressedFunction: (code, slot)?`; emit values tagged
     `(ShortcutEvent, Slot)` — dispatch splits to the right machine.
     Combination-suppression (`otherActivity`) applies to the held slot(s)
     independently.
   - Single-slot convenience preserved for tests (`HIDDecideTests` keep
     passing unmodified; new dual tests added).

4. `Oto/Settings/DictationPane.swift` (+ `ShortcutRecorderField.swift` row extraction)
   - Delete `TriggerChoice` + `interaction` state + Mode segmented
     (`DictationPane.swift:44-50,119-126`).
   - Two sections/rows: "Hold to talk" and "Hands-free", each =
     kind picker (Hold key / Dictation key / Custom combo) + recorder button
     (combo kind only) + per-slot calibration `LabeledContent` + conflict
     message line. Recorder callbacks call `updateHoldTrigger` /
     `updateHandsFreeTrigger`; `.blocked` result → keep old label + show
     "Same as your <other> shortcut — pick a different one."
   - `syncFromDispatch()` reads both slots; preset picks call the per-slot
     updaters (§5.2 gate, never direct assignment). Either row's Delete →
     label resets to placeholder, stored trigger KEPT (today's semantics),
     `setEnabled(false)` globally (D4); either row's fresh capture/preset →
     re-enables globally (F1). Second recorder button disabled while the
     first listens (only one listener at a time; dispatch suspends both
     slots either way).
   - Test-shortcut caption updated: "Press either shortcut anywhere. Ready
     appears per row after a real global sequence."

5. `Oto/Services/ModifierHotkeyMonitor.swift` — NO change (instantiated twice).
   `Oto/Services/HotkeyTransitionState.swift` — NO change (already
   mode-parameterized). `Oto/Services/ShortcutRecorder.swift` — NO change
   (rules reused per slot). `Oto/Services/CarbonHotKey.swift` — NO change
   (multi-key already). `Oto/UI/OtoMenuBarView.swift` — NO change
   (menu-compat: derived single-value API preserved, see §5.2).
   `Oto/Coordinator/DictationCoordinator.swift` — NO change
   (single-session guard + cross-mode no-ops already correct:
   `toggleHandsFree` on a hold session → `begin(.handsFree)` → nil while
   non-terminal; `beginHold` during hands-free → nil).

6. Tests (new/updated, all deterministic, no hardware):
   - `OtoTests/DualShortcutConfigurationTests.swift` (new): Codable
     round-trip, defaults, migration from each old interaction, same-shortcut
     conflict matrix (`conflictsWith` all 9 kind pairs), old-key untouched.
   - `OtoTests/ShortcutDispatchDualTests.swift` (new, fake coordinator):
     hold down/up → begin/finish; hands-free down/down → begin/finish;
     second begin while active → nil (no overwrite); hold-down during
     hands-free session → no-op; hands-free press during hold session →
     no-op; same-trigger save → `.blocked`, old kept; preset equal to other
     slot → `.blocked`; Delete → global off (both calibrations Untested,
     neither fires); fresh capture after Delete → global on, both slots live
     (F1 re-enable pin); suspend cancels + stops both.
   - `OtoTests/HIDDecideDualTests.swift` (new): two hold codes route
     independently; function code→slot map; combination-use swallows only
     the held slot's release; Escape still observed once.
   - Existing `HotkeyTransitionStateTests`, `HIDDecideTests`,
     `ShortcutRecorderTests`, `EscapeCancelTests` — untouched, must stay green.

## 6. Verification steps

- `xcodebuild -scheme Oto -destination 'platform=macOS' build` green;
  `xcodebuild test -scheme Oto` full suite green twice (target: current
  286 + ~25 new).
- Device matrix (packaged/Xcode Run, console live), per round verdict:
  1. Hold slot (Right Option): hold → record → release → insert; calibration
     row Ready after one global cycle.
  2. Hands-free slot (F5): press → record → press → insert; no up-behavior.
  3. Cross-presses: hold-down mid-hands-free session → ignored (session
     continues); hands-free press mid-hold session → ignored; both pressed
     same instant → exactly one session (first wins, no double-begin).
  4. Conflict: set hands-free = hold's combo → blocked message, old kept,
     no registration change (calibration rows unchanged).
  5. Recorder: recording either row suspends BOTH triggers (dictate mid-record
     → nothing); Escape in recorder → old kept; Delete → global off, both
     rows Untested; fresh capture/preset after Delete → both live again (F1).
  6. Overlap: hold=RightOption + hands-free=Option+D combo → typing ⌥D fires
     combo only (hold release swallowed — `usedInCombination`); bare ⌥ hold
     fires hold only.
  7. AX revoked: HID slots → Requires Accessibility, Carbon combo slot still
     Ready (per-slot rows prove it independently).
  8. Re-run of the catcher matrix §void/editor/rename/refusal/cancel (insertion
     path untouched, but dispatch changed → full re-run, not spot-check).

## 7. Risks / deferred decisions

- Two modifier-holds at once (user sets BOTH slots to bare modifiers):
  supported mechanically (two `ModifierHoldState`), but flagsChanged for two
  modifiers held together emits two downs — each machine independent, first
  begin wins, second nil. Documented, tested, no block.
- Carbon double-registration failure surfaces PER SLOT (existing nil →
  `.conflicts` calibration per row); the other slot keeps working. No shared
  failure mode (separate `CarbonHotKey` refs, swept independently).
- Prefs: single global `enabled` kept (per-slot enable deferred — no product
  ask, doubles calibration/test surface; revisit only on user demand).
- Menu `Last session` / status line unchanged (coordinator-owned).
- No second target, no MAS impact (direct-download posture unchanged; AX
  reads unaffected — this work touches event taps + Carbon only).
- Out of scope (explicit): same-key tap-vs-hold disambiguation, spoken
  triggers, per-app shortcuts, sync across devices,_fncn/media-key capture
  beyond today's F5/176 set.

## 8. Open questions — ALL RESOLVED 2026-09-23 (user took recommendations)

1. ~~Two separate shortcuts?~~ YES — D1: two live slots, fixed modes.
2. ~~Defaults?~~ D2: hold = Right Option, hands-free = Dictation/F5.
3. ~~Recorder scope?~~ D3: combo-only + presets per slot, zero new rules.
4. ~~Delete-clears globally?~~ D4: yes, single `enabled`, no per-slot toggle —
   plus fix F1 (fresh assignment re-enables; today's Delete is a one-way door
   with no UI recovery — verified, not assumed).

   Rejected alternative (recorded, not planned): one shared key where
   tap-vs-hold picks the mode — needs a disambiguation timer and new failure
   modes.
