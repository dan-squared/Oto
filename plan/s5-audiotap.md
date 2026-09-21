# S5: audio-tap modernization (installAudioTap) — plan (no code changed)

Status: PLANNING ONLY. Nothing implemented. Awaiting `execute`.

## 1. Goal

Replace the deprecated `installTapOnBus:bufferSize:format:block:` with
macOS 27's `installAudioTap`, adapting the new read-only buffer type at
the tap boundary. Relay → feed → converter chain untouched. No behavior
change when stable; deprecation warning gone; throwing install replaces
a void call.

## 2. SDK facts (MacOSX27.0.sdk, read 2026-09-21 — never from memory)

- Swift spelling (AVFAudio.swiftmodule arm64e-apple-macos.swiftinterface):
  `installAudioTap(onBus:bufferSize:format:tapProvider:) throws`,
  macOS 27.0+ (= our deployment target, no gating needed).
  `tapProvider: @Sendable (AVReadOnlyAudioPCMBuffer, AVAudioTime) -> Void`.
- `AVReadOnlyAudioPCMBuffer`: **struct, Sendable**, 27.0+ (same file):
  `format`, `frameCapacity`, `frameLength`, `stride`,
  `channelData(_:)` spans. Crosses into `@Sendable` closures cleanly.
- Sanctioned bridge (same file): `AVAudioPCMBuffer` gains
  `convenience init(copying readOnlyBuffer:)` (27.0+) — and the reverse
  `AVReadOnlyAudioPCMBuffer(copying:)` exists, so the bridge is
  **headless-testable** (mutable → read-only → mutable round-trip).
- Header contract (`AVAudioNode.h:119-160`): `format` nil-able; "If
  non-nil, attempts to apply this as the format… an error will result
  otherwise." Our nil-format strategy (the crash fix) transfers
  verbatim — with nil there is nothing to mismatch.
- `removeTapOnBus:` NOT deprecated (`AVAudioNode.h:162-168`) — removal
  path unchanged.
- No header statement on NSException vs NSError for the new impl:
  residual from installtap-crash.md §5 stands unchanged (nil + guard is
  our protection under both APIs; ObjC helper remains the last resort).
- Deliberate NON-change: `bufferSize: 2048`. The header notes a
  [100, 400] ms supported range (2048f ≈ 43ms@48k — outside it), but
  the value is device-proven and the relay bound (`maximumPending`
  ≈ 10s) assumes it. Touching it couples latency, relay math, and feed
  timing for zero deprecation benefit. Out of scope, stated.

## 3. Assumptions questioned

- "The bridge preserves audio." Not assumed: proven by a headless
  round-trip test with sample-content comparison (bit-exact), plus the
  device matrix.
- "Copy cost is fine." Analysis, not measurement: one 2048-frame copy
  per block (~8–32KB memcpy) on a non-realtime-critical copy path
  (the tap already hands buffers across threads). No perf test needed.
- "`init(copying:)` compiles under Swift 6." Sibling
  `AVAudioPCMBuffer(pcmFormat:frameCapacity:)` already calls from our
  nonisolated converter, so same-family initializers are nonisolated —
  but this is the ONE compile risk: if the new init is MainActor-bound,
  the fallback is a manual span-copy (more code, same test). Build
  decides; fallback recorded, not improvised.
- "New impl can't raise." NOT assumed — see §2 residual.

## 4. Exact file changes (on execute)

1. `Oto/Services/AppleAudioCapture.swift` — `installTap()` body only:
   ```swift
   let handler = bufferHandler
   try input.installAudioTap(onBus: 0, bufferSize: 2048, format: nil) { readOnly, _ in
       handler?(AVAudioPCMBuffer(copying: readOnly))
   }
   ```
   removeTap-first, degenerate guard, restart/teardown/debounce/log
   lines: all untouched. S5-deferral NOTE comment replaced with a
   migration record. `when` param ignored as today.
2. `OtoTests/ReadOnlyBridgeTests.swift` (new):
   - int16 buffer with known samples → read-only → mutable: assert
     format identifier equal, frameLength equal, sample bytes equal.
   - 48k float buffer → read-only: format preserved (proves the
     converter's future input survives the bridge).
   - Uses only the two `init(copying:)`s — no hardware, no tap.
3. `plan/audit-solidify.md` §10: flip to executed (keep the SDK facts).

Explicitly NOT changed: bufferSize, relay, feedBox, converter,
debounce windows, retry/menu, scene code, entitlements.

## 5. Verification

- `xcodebuild build` clean (Swift 6 inventory; fallback only if §3
  risk fires) + `test` green (2–3 new bridge tests).
- Grep: `installTap(` old-variant call sites → 0; deprecation warning
  → 0; `installAudioTap` call sites → 1.
- Device matrix (ears-on, the actual gate):
  1. Built-in mic 20s dictation — transcript complete, quality == pre.
  2. Jabra warm link — same.
  3. Jabra cold link, dictate immediately — first-attempt success
     (debounce + nil format under the new API).
  4. BT-off mid-dictation (the killer) — clean failure, app alive
     (re-proves the crash fix under the new API).
  5. Silent session — honest no-audio failure (unchanged path).
- No push until matrix sign-off (standing rule).

## 6. Risks / deferred

- Residual NSException class (§2) — unchanged by this migration, still
  guarded by nil + degenerate check; ObjC helper stays documented.
- AVAudioConverter input stays `AVAudioPCMBuffer` — the bridge feeds
  exactly what it eats today; converter tests untouched and still valid.
- If the matrix shows ANY quality delta vs pre-migration: revert is one
  hunk (old call + NOTE), bridge tests stay as documentation.

## 7. Open questions

1. Execute as specified (recommended)?
2. Matrix order: killer-retest (4) first (recommended — highest value),
   then 1–3, then 5?
