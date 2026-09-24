# fn-hold confirmation (bare fn coexistence without suppression)

Status: IMPLEMENTED 2026-09-24 (commit on abu-dhabi). Build green,
full suite green repeatedly (358/358: +4 fn tests). Device matrix
below still requires live dictation. Nothing merged.

Edge recorded post-plan: reconfig (or stop/suspend/Escape/monitor-loss)
mid-pending drops the armed press — the continued hold needs a re-press
(Settings visits don't overlap live holds in practice).

## 1. Goal

Bare-fn hold coexists with whatever macOS/the device does with fn taps
(emoji, dictation, remap, nothing) without Oto ever consuming fn and
without assuming any particular system behavior.

Rule: fn taps are the system's — Oto creates no session, no pill, no
duck, no conversion for a sub-threshold tap. A sustained fn hold past
the threshold is Oto's, with zero audio clipping (begin still routes at
confirm time; the user is already holding and speaking).

## 2. Facts

- HID tap never consumes `flagsChanged` (`HIDEventMonitor.swift:295-297`,
  `381-382`); fn pass-through is unconditional — suppression is off the
  table architecturally, not just by request.
- No audio pre-roll exists; delaying `begin` past speech onset would clip.
  Chosen shape avoids it: the session begins AT confirm (user mid-hold),
  never retroactively.
- Threshold matches the existing tap constant
  (`DoubleTapTracker.maxPressDuration` 250 ms): taps (≤250 ms) are the
  system's, holds are Oto's. One story, one number.
- `kVK_Function` is the only modifier with system tap behavior → gate is
  fn-specific; all other holds stay instant.

## 3. Changes

- `ShortcutDispatch`: fn-hold bypasses the shared transition machine
  (which begins instantly). Down arms pending + confirm Task (250 ms);
  early release drops pending silently; confirmed release routes finish
  directly; `stop()`/`receiveEscape`/monitor-loss disarm; refresh guard
  includes physical fn-down; fn events skip `holdTap` (taps belong to
  the system — no double-tap conversion off fn) and skip observation
  until confirmed.
- No coordinator/FlowBar/audio changes. Hands-free-slot fn unchanged
  (explicit press-toggle; documented tradeoff).
- Worst case preserved: if a device fires emoji on press/hold (not tap),
  Oto still can't prevent it without consuming — fallback stays
  fn+letter combo or another hold key.

## 4. Tests

- fn tap → idle, no insert, calibration untouched.
- fn hold (real 350 ms) → normal session + insert.
- fn double-tap → no hands-free conversion.
- Reconfig mid-pending drops it; Right Option instant (existing suites).
