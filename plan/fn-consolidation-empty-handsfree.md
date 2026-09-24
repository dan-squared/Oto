# fn consolidation + empty-by-default hands-free ("release shortcut")

Status: PLAN ONLY. Nothing implemented. Awaiting approval.
Decisions D1–D5 locked below with rationale; D6 is a one-line alternative.

## 1. Goal (user-ordered)

- Root-fix fn instead of patching it: one model-level policy, one
  confirm path, one copy story — no more fn special-cases scattered
  across dispatch, modal, and captions.
- Hands-free ("release") toggle ships EMPTY: no pre-assigned shortcut,
  user opts in by recording. Double-tap of the hold key is the
  always-on hands-free path (already converts; now surfaced as primary).

## 2. fn-surface decisions (answers "still shows")

| Surface | Decision |
|---|---|
| Hold-key menu fn option | KEEP — works via confirm-hold |
| Recorder bare-fn capture (both arrival shapes) | KEEP |
| `fn` chips/labels | KEEP — a binding must render |
| Derived-row caption (hold=fn) | KEEP, one line, load-bearing |
| Hands-free refusal + guidance | KEEP, fires only on attempt |
| Grandfathered live-fn-handsfree guidance | ELIMINATE via one-shot migration (§5.3) |
| `holdTap` exclusion, pass-through | KEEP, now documented via policy |

D6 alternative: erase every fn word except the hold menu (one line per
site). Not recommended — it re-hides load-bearing behavior.

## 3. Single source of truth (the anti-patch-up core)

`ShortcutTrigger.Kind` gains policy, dispatch/modal derive from it —
no more `kVK_Function` sprinkled at call sites:

- `isSystemTapSensitive: Bool` — bare fn only. Dispatch confirm path,
  tracker exclusion, and captions all read this.
- `supportsHandsFreeToggle: Bool` — everything except bare fn. Modal
  stage gate + guidance read this (replaces the inline code checks).
- Matrix-tested over all 9 modifiers + combos + fn-set + none (§6).

## 4. Empty-by-default hands-free (new `Kind.unassigned`)

- `Kind.unassigned` (no payload): `conflictsWith` false against
  everything both orders; Codable-safe (old payloads still decode;
  case-discriminated, forward-only).
- Factory `default()` hands-free becomes unassigned; stored configs
  (incl. old F5) are NEVER rewritten — migration preserves values.
- Dispatch skips unassigned slots (no HID codes, no Carbon); new
  `ShortcutCalibration.notSet` ("Not set"), rank 0 alongside ready so
  the combined summary follows the live hold slot; `resetCalibration`
  and availability both preserve `notSet` (never degrade to Untested).
- `slotChoice(.unassigned)` → `.combo` (recorder-first; presets replace
  it). Empty field shows "Click to add a shortcut…" (reference copy).
  `chips(.unassigned)` → `[]`; `shortLabel` defensive default.
- `stageClear` on an already-unassigned slot is a message-clear no-op
  (no global disable for emptying emptiness). Swap/reset/migration
  unchanged in shape (pair-multiset + factory rules already cover it).
- Exhaustive-switch audit (compiler-guided): `conflictsWith`,
  `slotChoice`, `chips`, `shortLabel`, `holdMenuLabel`,
  `configureSlot`, `slotBackendsLive` (+ unreachable-but-required arm),
  calibration `describe`/`rank`/`worst`.
- Hands-free card copy: empty toggle + "Double-tap `<hold>` anytime —
  no setup needed." Summary row stays hold-centric.

## 5. Exact file changes

1. `Oto/Models/ShortcutModels.swift` — `Kind.unassigned`;
   `conflictsWith` none-arms first; policy props
   (`isSystemTapSensitive`, `supportsHandsFreeToggle`);
   `DualShortcutConfiguration.default()` hands-free unassigned;
   one-shot migration: stored hands-free-fn → unassigned (logged;
   kills the persistent guidance state); old F5 untouched.
2. `Oto/Services/ShortcutDispatch.swift` — `isFnHold` reads the
   policy prop (same behavior); `configureSlot` + calibration paths
   handle `.unassigned` (skip/preserve `notSet`); `setCalibration`
   untouched; no routing changes (double-tap needs no trigger).
3. `Oto/Settings/ShortcutModal.swift` — stage gate reads
   `supportsHandsFreeToggle`; guidance copy unified to one literal;
   empty-field placeholder; per-slot status shows "Not set" + activate
   hint; `stageClear` empty-guard; derived row unchanged in shape.
4. `Oto/Settings/ShortcutRecorderField.swift` — calibration `describe`
   (+ "Not set"), `rank`/`worst` order (notSet 0, documented:
   deliberate-empty needs no attention).

## 6. Tests (deterministic, no hardware)

- Kind matrix: none-vs-all conflicts false; Codable round-trip incl.
  old payloads (hand-written F5 JSON decodes); policy props over all
  kinds; `worst()` never surfaces notSet over real states.
- Migration: F5 preserved; fn-handsfree → unassigned (+ key left
  intact); fresh default empty.
- Dispatch: unassigned slot registers nothing, calibration stays
  notSet, other slot unaffected; double-tap converts with empty
  toggle; clear-on-empty is a no-op (enabled stays on).
- Staging with none (effective/preview/gate). UI layout via matrix
  screenshot (existing precedent for SwiftUI surfaces).

## 7. Verification

- Build green; full suite green twice.
- Device matrix: fresh install (empty toggle + placeholder, double-tap
  works immediately); record toggle (activates, Ready after a cycle);
  clear toggle (empty again, shortcuts stay on); swap involving empty;
  F5-config migration preserved; fn surfaces screenshot (no stray
  guidance); catcher full re-run.

## 8. Risks / deferred

- `slotBackendsLive` needs an unreachable `.unassigned` arm (documented).
- Dynamic fn copy (system-usage detection) stays deferred per the
  approved coexistence plan; static captions until the mapping matrix
  fills.
- Out of scope: alternate bindings, per-app shortcuts, pre-roll,
  programmatic settings mutation, popover errors.
