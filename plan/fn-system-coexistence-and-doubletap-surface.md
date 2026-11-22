# fn system coexistence + double-tap surfacing

Status: PLAN ONLY. Nothing implemented. Recommendation: Option A (§4).
Awaiting `execute`.

Reference: `.context/attachments/yGAVYO/image.png` (gitignored) — hands-free
card shows a derived, non-editable `Double tap ⌥ Opt` row above the editable
toggle, plus Reset/Done footer.

## 1. Evidence (verified today, never from memory)

- System fn usage IS observable read-only: `defaults read
  com.apple.HIToolbox AppleFnUsageType` → `0` on this Mac. Value→meaning
  mapping is NOT documented — matrix must record all four Settings options
  (`§7.1`). Unknown/unreadable → conservative copy. No mutation, ever.
- Two distinct fn arrival shapes exist, and only one works today:
  `flagsChanged` (keyCode 63) → `FlagsCaptureState` → staged ✓;
  `keyDown` (keyCode 63, no usable modifiers) → `classify` → `.invalid`
  ("Letters need a modifier") ✗. Device-dependent which shape a Mac
  delivers — this is the "rejects completely" report.
- Current gates (all in-tree): hold-slot fn bypasses the machine with
  250 ms confirm (`ShortcutDispatch.swift:419-498`), never feeds
  `holdTap`; hands-free fn staging refused with guidance
  (`ShortcutModal.swift:291,379,391`); defaults already distinct
  (hold Right Option vs hands-free F5/dictation).
- ACP Xcode: workspace open (scheme Oto, My Mac), no active launch
  session — analysis is code-level.

## 2. Goal

- fn works in the hotkey setting on every device: observable system use
  adapts copy, never behavior-theft; unobservable/missing fn degrades to
  guidance, never a dead control.
- Double-tap of the hold key is the always-on, non-editable,
  non-disableable hands-free trigger for ANY hold key, surfaced as a
  derived row exactly like the reference. The editable toggle stays
  independent (defaults already distinct — no shared-shortcut confusion).

## 3. Spec: double-tap surfacing (reference-shaped) — IMPLEMENTED

- Hands-free card shows a derived, non-editable `Double tap` + live
  hold-chip row (staged or saved — follows any hold key), no recorder,
  no toggle, no state. fn-hold shows a static `Double taps are handled
  by macOS` caption (dynamic copy deferred — needs the §7.1 mapping).
- Conversion fires for every hold kind EXCEPT bare fn (fn presses bypass
  the machine, so no third-tap stop path exists for a converted
  session — plus system double-fire). Covered by
  `fnDoubleTapNeverConverts` + existing convert tests; no new tests
  needed (derivation reuses tested `effectiveKind`).

- Hands-free card gains a derived row above the editable field:
  `Double tap` + live hold chips (e.g. `Double tap Right ⌥`), disabled,
  no pencil/trash/recorder. Follows the hold key live (recompute from
  effective hold kind on every render — zero new state).
- fn-hold: conversion stays OFF (system taps always win ties), so the row
  shows `Double tap fn` + dynamic caption from detection (§5):
  system-owned ("Double taps open macOS Emoji") / free ("fn is free —
  double-tap still reserved by macOS") / unknown (conservative).
- No calibration, no toggle, no recorder on the derived row. Hands-free
  toggle row unchanged.

## 4. Three fn options (recommended: A)

**Option A — confirm-hold + system-aware UI (RECOMMENDED).**
Keep pass-through always; sub-threshold taps never create sessions.
Fix the `keyDown`-63 hole: `classify` gains explicit fn handling
(new `.modifierKey` outcome → same staging as flags path; repeats
ignored; fn+letter stays invalid — Carbon hotkeys can't express fn).
Read `AppleFnUsageType` on modal open (injectable suite) driving copy:
system-owned → "quick taps stay with macOS <X>"; Do Nothing →
"fn is free on this Mac"; unknown → conservative. Convert stays off
for fn; every other hold key converts as today.
Pros: zero suppression, zero mutation, works on all devices, honors
"don't touch native". Cons: 250 ms confirm latency on fn-hold;
cannot prevent press-triggered system UI (documented fallback:
fn+letter combo or another hold key).

**Option B — consume fn while armed (REJECTED).**
Claim fn keyDown/up at the HID tap to block emoji/dictation.
Pros: total control. Cons: suppresses native behavior globally while
running (violates the explicit constraint); breaks fn+arrows/click
unless re-posted, and re-posted synthetics don't faithfully reproduce
system gestures; violates the never-consume architecture; new TCC-trust
surface. Rejected.

**Option C — remap system fn while open (REJECTED).**
Write `AppleFnUsageType` to Do-Nothing on launch, restore on quit.
Pros: fn fully ours while running. Cons: global mutation affecting all
apps; crash/kill strands mutated state (needs crash-restore machinery);
fights explicit user settings; cfprefsd propagation lag; per-device
variance (external keyboards); review/sandbox posture. At most, offer a
manual hint linking to Settings — user-controlled, never programmatic.
Rejected as designed behavior.

## 5. Exact file changes (Option A)

1. `Oto/Services/ShortcutRecorder.swift`
   - `RecorderOutcome` gains `.modifierKey(code:)`; `classify` takes
     `isRepeat` (defaulted — existing calls compile) and returns it for
     keyCode `kVK_Function` with no usable modifiers; fn+letter stays
     `.invalid` (Carbon has no fn mask — document, don't pretend).
   - `SystemFnUsage` probe (new, pure + injectable defaults suite):
     raw int/nil → `.emoji/.dictation/.inputSource/.none/.unknown`;
     value→meaning table pinned as TBD-verified, matrix fills it (§7.1).
2. `Oto/Settings/ShortcutRecorderField.swift` — keyDown-fn routes to
   `onCaptureModifier` (repeats swallowed); hint text when nothing
   arrives stays as the unobservable-device fallback.
3. `Oto/Settings/ShortcutModal.swift` — derived double-tap row per §3
   (+ fn dynamic caption); hold menu keeps fn; hands-free fn gate
   unchanged; read probe on appear for copy only.
4. `ShortcutDispatch/HID` — untouched (confirm, exclusion, probe all
   already correct and tested).

## 6. Tests (deterministic, no hardware)

- `classify` fn-keyDown matrix (new): bare fn → `.modifierKey`,
  repeat → ignored-equivalent, fn+letter → invalid, fn+real-mods →
  existing combo path.
- `SystemFnUsage` mapping incl. nil/unknown (table asserts updated
  post-matrix).
- Existing fn suites untouched, must stay green.

## 7. Verification

- Build green; full suite green twice.
- Device matrix (packaged Run, console live):
  1. Set each of the 4 macOS fn options → record `AppleFnUsageType`
     value (fills the mapping table) + modal copy asserted per option.
  2. Tap/hold/double-tap fn per option; external keyboard without fn
     (menu path degrades to hint, nothing dead).
  3. Derived row follows hold-key changes incl. fn caption; no controls.
  4. Catcher re-run (recorder touched → full re-run).

## 8. Risks / deferred

- Mapping table ships conservative until §7.1 fills it.
- Press-triggered system fn UI still can't be prevented without
  consuming — documented fallback stands.
- Out of scope: alternate bindings, per-app shortcuts, `AXIsEditable`,
  popover errors, pre-roll audio, programmatic settings mutation.
