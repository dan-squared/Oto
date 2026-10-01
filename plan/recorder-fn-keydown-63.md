# fn-as-keyDown capture (63) + fn-usage seam + 241 protocol

Status: PLAN ONLY (v2 supersolid). Nothing implemented. Awaiting `execute`.

v2 changes vs v1: scope now includes the fn-usage probe seam and the
241 identification protocol (both researched below); one correction —
the old coexistence plan claimed "fn+letter stays `.invalid`", but
current `classify` (`ShortcutRecorder.swift:194-196`) sends
fn+real-modifiers down the COMBO path, so this plan pins that path
unchanged instead of repeating the wrong claim; outcome named
`.captureModifier` (not old `.modifierKey`) to match the consumer
callback it routes to.

## 0. The hole (proven in code)

On keyboards where `fn` arrives as `keyDown` (code 63, no modifiers)
instead of `flagsChanged`, pressing fn in a recorder hits the
`hasRealModifier || isFunction` gate (`ShortcutRecorder.swift:195`)
with both false (F1–F12 only; empty relevant set) →
`.invalid(.plainKey)` → lying "Letters need a modifier…" capsule.
`FlagsCaptureState` never arms (no `flagsChanged` fires). fn-hold is
unstageable on those machines.

## 1. Verification table (all re-checked 2026-10-01)

| Claim | Source | Status |
|---|---|---|
| `kVK_Function = 0x3F` (63) | `HIToolbox/Events.h:280` via `xcrun --sdk macosx` | confirmed |
| Gate at `:195`, switch at `:262-271` (`ShortcutRecorderField`) | file read | confirmed, unmoved since plan v1 (`git log` clean) |
| Only ONE exhaustive `RecorderOutcome` switch in prod | grep `case .captured`/`RecorderOutcome` | confirmed — edit surface is one arm |
| Both modal (`:236-237`→`captureModifier(code:slot:)` at `:420`) and onboarding (`:232-233`→`:345`) stop recording + stage on `onCaptureModifier` | file reads | confirmed — zero UI changes needed |
| `captureModifier` stops monitors synchronously, so held-key repeats can't recur (first event is never a repeat; repeat events arrive after monitor removal) | `ShortcutModal.swift:420-425`, monitor `stop()` | confirmed — old plan's `isRepeat` param rejected as unnecessary (no signature churn); reasoning recorded here instead |
| `addLocalMonitorForEvents` current, un-deprecated | `NSEvent.h:554` (`API_AVAILABLE(macos(10.6))`, no `DEPRECATED`) | confirmed |
| No test pins code 63 today | grep `63\|kVK_Function` in `OtoTests` (only HID/KeyNames/config uses) | confirmed — nothing silently flips |
| Xcode 27.0 (27A266a), scheme Oto, 1 scheme + 3 targets | ACP `XcodeOpenWorkspace`→`workspace-7Wcy8gsDOc` + lists | confirmed |
| `AppleFnUsageType` value→meaning | NOT in SDK (prefs key, undocumented); web research twice unavailable (network) | unknown by construction → matrix owns it (§5) |
| 241 in `KeyNames.table` | grep `241\|0xF1` in `ShortcutRecorderField.swift` | absent — still unidentified, as reported |

## 2. Phase A — code now (63 fix + seams)

1. `ShortcutRecorder.swift`: `RecorderOutcome.captureModifier(code:)`
   + `==` arm + case docs.
2. `classify`, after Delete block, before combo gate:
   `keyCode == kVK_Function && relevant.isEmpty` →
   `.captureModifier(code:)`. Bare-only boundary: fn+real-modifiers
   keep today's combo path (pinned, not altered); fn+shift keeps
   `.modifiersOnly`.
3. `ShortcutRecorderField.swift` keyDown switch (+2 lines):
   `case .captureModifier(let code): onCaptureModifier(code)`.
4. `FlagsCaptureState` header (+2 lines): fn-as-keyDown noted as the
   second arrival path.
5. `SystemFnUsage` probe (new, ~25 lines, `ShortcutRecorder.swift`
   or adjacent): `enum { unknown }` + `read(defaults:)` from the
   `com.apple.HIToolbox` suite (`object(forKey:)` nil-check first —
   `integer(forKey:)` lies 0-when-absent; `NoTargetModalSettings`
   precedent). Value table EMPTY pending §5 matrix; all ints map to
   `.unknown` for now (honest scaffolding, zero visual change).
6. One shared caption helper; modal derived-row fn caption +
   onboarding fn caption derive from it (today's strings, moved
   verbatim — behavior identical, single source for Phase C).

Single-shot argument (pinned by test 4): first arrival stops both
monitors synchronously via existing callbacks; a flags-up after a
keyDown-capture finds no arm; a keyDown after a flags-capture finds
no monitor.

## 3. Phase A tests (`ShortcutRecorderTests.swift` style as-is)

1. `fnKeyDownCapturesModifier` — `(63, [])` → `.captureModifier(63)`.
2. `fnKeyDownWithFunctionFlagStillBare` — `(63, [.function])` → stages
   (flag alone is not a combo; `.function` never enters `relevant`).
3. `fnKeyDownWithCommandStaysCombo` — `(63, [.command])` → `.captured`
   code 63 (boundary pinned unchanged).
4. `fnKeyDownDisarmsThenStagesOnce` — flags-arm → `stepKeyDown()` →
   classify stages → flags-up is `.none`.
5. Probe: nil domain → `.unknown`; suite-injected ints → `.unknown`
   (structural; per-value asserts are Phase C).
6. Seam caption test: `.unknown` renders today's copy verbatim.
7. Existing pins green — esp. `plainLetterIsInvalid`,
   `bareShiftIsInvalid`, `functionKeyCapturesBare`.

## 4. Phase B — user matrix (no code; exact steps)

1. System Settings → Keyboard → each "Press fn key to" option in
   turn → run `defaults read com.apple.HIToolbox AppleFnUsageType`
   → report option↔value pairs (fills the §2 table; also note if
   the key is absent for any option).
2. Recorder + Console open: press the mystery key → report the
   `capture mods=… key=…` line (closes 241: mappable → table entry;
   vendor-reserved → documented, fallback copy already honest).
3. On a 63-keyboard: record fn in modal → staged fn hold + sided
   chip, no message/beep; regression on flags-keyboard: tap ctrl.

## 5. Phase C — follow-up execute (after B, ~15 lines)

Pin table asserts for confirmed values; per-option copy
(system-owned → "quick taps stay with macOS <X>"; Do Nothing →
"fn is free here"; unknown → conservative as today). Nothing else.

## 6. Verification

Build green; new tests green; full suite green twice. Matrix per
§4 (packaged Run, console live); catcher full re-run (recorder
touched). Phase C re-verified after B.

## 7. Risks

- HIToolbox live reads may lag Settings changes (cfprefsd) — copy
  is advisory-only and fails to conservative; never load-bearing.
  Suite-injected defaults bypass this by design.
- `UserDefaults(suiteName:)` is failable — nil suite → `.unknown`,
  never a crash (test the nil path).
- No entitlements/plist/dependency changes; backends untouched
  (HID, dispatch, confirm, hands-free gate all downstream-correct
  already).
