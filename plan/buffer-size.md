# Buffer-size compliance (2048 → 4096) — plan (no code changed)

Status: PLANNING ONLY. Nothing implemented. Awaiting `execute`.

## 1. Goal

Move the tap `bufferSize` into closer compliance with the documented
[100, 400] ms request range while preserving the device-tuned time
behavior exactly. Single value change + rescaled bounds + tests. No
behavioral ambition beyond compliance.

## 2. SDK facts (MacOSX27.0.sdk, read 2026-09-21)

- `AVAudioNode.h` (installTap docs): bufferSize is "the **requested**
  size of the incoming buffers… Supported range is [100, 400] ms."
  It is a request, not a guarantee — the engine may deliver other
  sizes, and our chain already handles arbitrary sizes (converter is
  frameLength-dynamic; relay counts buffers).
- Speech side (`Speech.swiftmodule` macos swiftinterface): no chunk
  guidance — `AnalyzerInput(buffer:)` takes any buffer. No consumer
  constraint on size.
- `removeTapOnBus:` unaffected. Swift 6 impact: none (same types).

## 3. Candidate math (ms per buffer)

| size | 48 kHz in | 44.1 kHz in | 16 kHz BT in |
|------|-----------|-------------|--------------|
| 2048 (now) | 43 ✗ | 46 ✗ | 128 ✓ |
| 4096 | 85 (~15% under) | 93 (~under) | 256 ✓ |
| 6144 | 128 ✓ | 139 ✓ | 384 ✓ |
| 8192 | 171 ✓ | 186 ✓ | 512 ✗ over |

- 6144 satisfies the range everywhere but is non-power-of-2 and
  rescales bounds to non-integers (83.3/16.7) — rounding decisions for
  zero benefit, since the engine adjusts actuals anyway.
- 8192 breaks the BT rate upward (512 ms chunks = laggy session starts
  where our problem rate lives).
- **4096 recommended:** power-of-2 convention, clean halving of both
  bounds (250→125, 50→25 — exact time-equivalence at the tuned 48 kHz:
  ≈10.6 s pending, ≈2.1 s drop tolerance), inside range for the BT
  rate, 15% under at 48 kHz (within any reasonable tolerance, and the
  engine adjusts actuals regardless).

## 4. Assumptions questioned

- "Compliance changes audio." No: same hardware format, same tap, same
  chain — only chunking granularity changes (43→85 ms @48k). Relay
  still prevents first-word loss (it buffers pre-attach regardless of
  size); converter math is per-buffer dynamic.
- "Bounds must change." Yes, but ONLY by exact time-equivalence
  (halving), never by feel: 125 pending / 25 drops. Comments updated
  with the time math so the next reader never re-derives it.
- "Tests cover it." Relay tests reference the constants (auto-adapt);
  no test hardcodes 2048. No new unit test needed — the change is a
  value, and its coverage IS the device matrix. Stated, not hidden.

## 5. Exact file changes (on execute)

1. `Oto/Services/AppleAudioCapture.swift`: `bufferSize: 2048` → `4096`
   (+ one-line comment citing this plan).
2. `Oto/Support/AudioBufferRelay.swift`: `maximumPending` 250 → 125,
   `maximumDroppedBeforeFailure` 50 → 25, comments rewritten with the
   time math (≈10.6 s / ≈2.1 s @48 kHz, the tuned rate).
3. Nothing else. Converter, feed, debounce, retry, tests, scenes,
   entitlements: untouched.

## 6. Verification

- `xcodebuild build` + `test` green (Swift 6 inventory; relay tests
  auto-adapt via constants).
- Grep: `2048` remaining only in comments/history + Carbon masks
  (unrelated `option = 2048`).
- Device matrix (the actual gate — size affects only live audio):
  built-in 20 s + Jabra warm (quality == pre-change), cold-link first
  attempt, BT-off killer (clean failure, app alive), silent session
  (honest no-audio), SENTINEL restore. Stream confirms rebuild/finish
  lines unchanged in shape.
- No push until matrix sign-off (standing rule).

## 7. Risks / deferred

- If the matrix shows ANY quality/latency delta: revert is two values;
  2048 stays device-proven and the deprecation never mentioned size.
- 16 kHz time math was already imprecise (32 s pending) and stays
  proportionally so — pre-existing imprecision, scaled not fixed.
- Long-term exactness (per-rate adaptive bounds) explicitly rejected:
  complexity for no device-observed need.

## 8. Open questions

1. Execute at 4096 as specified (recommended)?
2. Or keep 2048 — state that the range is advisory and the value is
   proven (also defensible; say so explicitly)?
