# fn-as-keyDown capture (keyCode 63) in the shortcut recorder

Status: PLAN ONLY. Nothing implemented. Awaiting `execute`.

## 0. The hole (proven in code, not reported vaguely)

On keyboards where `fn` arrives as `keyDown` (code 63, no modifiers)
instead of `flagsChanged`, pressing fn in a recorder field hits
`ShortcutRecorderRules.classify` (`ShortcutRecorder.swift:195-197`):
not Escape/Delete, not in `functionKeyCodes` (F1–F12 only), no real
modifier → `.invalid(.plainKey)` → the nonsense "Letters need a
modifier…" capsule. The flags path (`FlagsCaptureState`) never arms
because no `flagsChanged` fires. Result: fn-hold is unstageable on
those machines, with a lying message.

## 1. Spec sources + SDK facts (verified 2026-10-01, never from memory)

- ACP log: `XcodeOpenWorkspace` → `workspace-7Wcy8gsDOc`, scheme Oto
  (only scheme), targets Oto/OtoTests/OtoUITests; Xcode 27.0,
  deployment target 27.0 (project).
- `kVK_Function = 0x3F` (63) — `Carbon.framework/.../HIToolbox/Events.h:280`.
- `NSEvent.ModifierFlags.function` exists (used by `nsFlag`, `ShortcutRecorder.swift:137`).
- Monitor order is load-bearing and already documented: keyDown
  monitor disarms via `stepKeyDown()` FIRST (`ShortcutRecorderField.swift:251`),
  then classifies; Tab bubbles, everything else consumed.
- Downstream needs nothing: both modal (`captureModifier`) and
  onboarding route bare-modifier capture to `stage(.modifierHold)`
  today — the new outcome reuses that callback verbatim.

## 2. Exact changes (3 small edits, 1 file + tests)

1. `ShortcutRecorder.swift` — new outcome case + `==` arm:
   `case captureModifier(code: UInt16)` ("fn arrived as keyDown:
   stage exactly like the flags path"). Doc comment on the case.
2. `classify`, right after the Delete block, before the combo gate:
   ```swift
   // Bare fn as keyDown (code 63, external keyboards): no flagsChanged
   // ever fires, so the flags path can't arm. Stage it exactly like a
   // flags capture. With other modifiers held, fall through to the
   // combo path unchanged.
   if keyCode == UInt16(kVK_Function), relevant.isEmpty {
       return .captureModifier(code: keyCode)
   }
   ```
   Boundary (deliberate, narrow): bare only. fn+letter, fn+shift etc.
   keep today's behavior — no combo-rule churn in this change.
3. `ShortcutRecorderField.swift` keyDown switch (+2 lines):
   ```swift
   case .captureModifier(let code):
       onCaptureModifier(code)
   ```
   No modal/onboarding/view changes — their `onCaptureModifier`
   already suspends, stops recording, and stages.
4. Header comment on `FlagsCaptureState` (+2 lines): fn-as-keyDown
   noted as the second arrival path.

Why this can't double-stage or strand: first arrival (either path)
stops recording via the existing callbacks, which removes both
monitors; a flags-up after a keyDown-capture finds no arm (`.none`,
`stepKeyDown` disarmed first); a keyDown after a flags-capture finds
no monitor. Each path is single-shot by construction — the new tests
pin the interleaving, not just each half.

## 3. Tests (`ShortcutRecorderTests.swift`, style as-is)

1. `fnKeyDownCapturesModifier` — `classify(63, []) == .captureModifier(code: 63)`.
2. `fnKeyDownWithFunctionFlagStillBare` — `classify(63, [.function])`
   stages too (the flag alone is not a combo).
3. `fnKeyDownWithCommandStaysCombo` — `classify(63, [.command])`
   still `.captured` with code 63 (boundary pinned: combos untouched).
4. `fnKeyDownDisarmsThenStagesOnce` — composition: `stepFlagsDown(fn)`
   arms → `stepKeyDown()` disarms → `classify(63, [])` stages →
   `stepFlagsUp(fn)` is `.none` (no double).
5. Existing pins untouched and must stay green — especially
   `plainLetterIsInvalid`, `bareShiftIsInvalid`,
   `functionKeyCapturesBare` (grep confirms zero existing tests
   assert on code 63, so nothing can silently flip meaning).

## 4. Verification

- Build green; new tests green; full suite green twice.
- Device matrix (needs a 63-keyboard; flags-path keyboards are the
  regression control): press fn in the modal recorder → staged fn
  hold with sided chip + capture-log line (no message, no beep);
  tap ctrl → staged as before; Escape cancels, Delete clears, Tab
  bubbles; fn+letter behavior byte-identical to today.

## 5. Explicit non-goals (separate leftovers, untouched)

- HID/dispatch/fn-confirm/hands-free gate: downstream already owns
  bare fn end-to-end — zero changes there.
- System fn-usage probe + dynamic copy; the 241 mystery key.
- No new dependencies, no entitlements, no plist changes.

## 6. Risks

- Low: pure rules + one switch arm + tests; UI callbacks reused
  unmodified. The only behavioral delta is a path that today
  refuses with a wrong message.
