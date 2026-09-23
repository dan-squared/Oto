# Production-readiness audit — findings + fix batch — PLAN ONLY

Status: AUDIT DOCUMENT. No code changed. Awaiting `execute` on §5.
Method: four parallel read-only subsystem audits (coordinator,
insertion+focus, duck+composition, UI) + my own cross-check of every
load-bearing claim against the tree. SDK claims below re-verified
against MacOSX27.0.sdk headers this session (Xcode 27.0, Swift 6.0,
default MainActor, InferIsolatedConformances +
NonisolatedNonsendingByDefault). Unbiased by construction: §7 lists
what I downgraded or kept, with reasons.

## 1. Verdict

No ship-blocker of the crash/data-loss class found: no force unwraps
in product code, wrong-app insertion structurally excluded
(start-pinned target + liveness + no frontmost substitution, tested),
clipboard discipline structural (pre-clipboard returns +
marker/count-guarded restore, tested via changeCount), history
bounded + opt-in. What the audits DID find: one narrow-screen
usability break, several cancel-race status lies, false-success
claims in the insertion path, a fail-open trust hole in retry, and
sandbox leftovers from the unsandboxing — all fixable in one batch
(§5), none requiring redesign. Deferred items (§6) are real but
bounded and honest.

## 2. SDK re-verification (this session, exact)

| Claim | Header proof | Standing |
|---|---|---|
| `AudioObject{Get,Set,Has}PropertyData`, `IsPropertySettable` current | `CoreAudio/AudioHardware.h:220,236,291,324`, availability-only, no deprecation | MediaDuck API choice correct; `IsPropertySettable` available and UNUSED (fix F5) |
| `vmvc` current; only `VirtualMaster*` aliases deprecated | `AudioToolbox/AudioHardwareService.h:70` vs `:71,74` | correct |
| `AudioHardwareService*` functions deprecated since 10.11 | same header (`"no longer supported", macos(10.5,10.11)`) | avoidance correct |
| AX focus/role constants + `AXUIElementCopyAttributeValue` semantics | `HIServices AXAttributeConstants.h:1009/:45`, `AXRoleConstants.h:360-361`, `AXUIElement.h:148` | correct |
| `kAXErrorNoValue` = "attribute does not have a value"; `-25204` = `kAXErrorCannotComplete` (messaging failed, busy/unresponsive); `-25211` = `kAXErrorAPIDisabled`; `-25212` = NoValue | `AXError.h` + `AXUIElement.h:140-148` | mappings correct; apiDisabled hole real (F3) |
| `AXTextField`/`AXTextArea` exist; `AXComboBox`, `AXUnknownRole`, `AXSecureTextField` subrole, separate web roles exist | `AXRoleConstants.h:350,131-136,408`, `AXWebConstants.h` | allowlist narrow by design; combo/web rows belong in matrix, not code (rejected scope creep) |
| `NX_DEVICELCMDKEYMASK` value `0x8` for Chromium modifier rebuild | `IOLLEvent.h:256` | correct, unasserted (test gap §6) |

## 3. Must-fix batch (§5 details) — severity-ordered

- **F1. Narrow-screen Copy amputation (usability break).** 464pt
  SwiftUI content in a clamped 384pt frame clips trailing Copy
  (`NoTargetModal.swift:314-317` vs `FlowBarPosition.swift:51`,
  pinned by the test itself). Fix: floor the catcher frame at
  464×168 (accept explicit edge overflow) OR flexible content;
  plus content≤frame invariant test.
- **F2. Coordinator terminal-state overwrite (cancel-wins lie).**
  Five finalize paths `await restoreMedia` BEFORE nil/state
  (`DictationCoordinator.swift:347-356,362-375,382-388,405-411,
  417-419`); cancel interleaves and gets overwritten. Fix:
  set nil + terminal state first, then restore (cancel path's own
  order, `:164-169`). Plus the prepare-fail twin: guard after
  `await audio.stop()` (`:277-291`).
- **F3. Retry posts without trust (false success).** `retryPostTo
  Frontmost` never checks `isTrusted` yet returns true; the suite
  enshrines it (`RealTextInsertionTests.swift:334-353`). Fix:
  `guard events.isTrusted() else { return false }` + update test.
  (Skipping FOCUS gates stays — user is the check; trust is physics.)
- **F4. Secure-input + trust TOCTOU before post.** Gates run
  hundreds of ms before `postPaste` (settle + drain + focus +
  verify windows). Fix: re-check `secureInputEnabled()` (+
  `isTrusted()`) immediately pre-post, fail closed. Plus map
  `.apiDisabled` focus errors to fail-closed (mid-flight revocation
  currently proceeds).
- **F5. Silent post failures claim `.inserted`.** `CGEventSource`/
  `CGEvent` creation failures return void; `postPaste: () async ->
  Void` can't report. Fix: `Bool` return, fail closed on false.
- **F6. Duck restore ignores session + clears before attempting.**
  `MediaDuck.swift:166-189`: no `duckedSessionID` check (cross-
  session wipe, unreachable today, wrong contract); slot cleared
  pre-set (transient failure = muted until relaunch despite kept
  flag); `deviceHasVolumeControl` never checks settability (fix
  with the confirmed-current `AudioObjectIsPropertySettable`).
- **F7. Sandbox leftovers.** `ShortcutRecorder isDisallowedIn
  Sandbox` blocks ⌘Space with a now-false message (`:99-126`):
  reword version-neutral + matrix row to decide allow vs block
  (do NOT silently unblock — deliverability unproven). One-shot
  migration of the 4 `app.Oto.mediaDuck*` keys on first
  unsandboxed launch (muted-with-invisible-backstop window is the
  exact outcome the flag prevents). Drop no-op project keys
  (`ENABLE_USER_SELECTED_FILES`, `REGISTER_APP_GROUPS`, empty
  entitlements reference — or document why kept). Refresh stale
  sandbox comments (AX/activation/HAL mental model).
- **F8. UI robustness bundle (all cheap).** Mask retry/generation
  (single-shot `scheduleContentMask` never recovers); mask/frame/
  content triple-drift on clamp; `show()` RM gate (fallback path
  animates under Reduce Motion); `copy()` timer generation guard;
  ✕ accessibility label; Copy ≥44pt target; ghost `orderOut`
  generation guard; `stop()` route-key reset; modifier-drain
  silent give-up → fail closed or `log.error`.

## 4. Test additions (with the batch)

Finalize-cancel concurrency (gated fakes: finish/insert gates +
cancel-mid-finalize ⇒ cancelled + zero inserts — the highest-value
test, proves F2); the four untested failure branches (audio-start
throw, prepare generic/denied throws, finish non-`noAudioCaptured`
throws); LiveFocusCheck machine (double-resume, late-loser order —
currently only a constant literal is pinned); FakeHAL failure
modes (get-OK/set-fail, read-only vmvc, flap); restore-failure
flag retention; key-literal pins for crash/saved keys; content≤
frame + dismissal-lifecycle + mask-installed tests; stop/start key
staleness. Stays device-only (stated, not faked): BT absolute
volume, read-only vmvc, hung-target timeout, combo/web role
matrix, AX5 type sizes, notarization/TCC copy.

## 5. Execution authorized (on `execute`)

In order: F2 → F3/F4/F5 (insertion contract) → F6 → F1/F8 (UI) →
F7 (leftovers + migration) → §4 tests → full suite green TWICE +
gates → commit + push. Then the banked device matrices re-run
(void/editor/rename/password/AX/matrix + catcher shots + duck/
restore + BT). Merge only after.

## 6. Deferred honestly (not hidden)

- Service-level session IDs (cancel→begin teardown race;
  services take no ID — needs service API change, backlog).
- Hung-target worker-thread parking (one thread per hung
  insertion, bounded by rarity; consider a dedicated serial
  queue later).
- Wall-clock verify budget, ghost/mask micro-races, log-gate
  taxonomy erosion (`localizedDescription` bucketing) — polish.
- Mid-session editing, scratchpad, Phase 7 — unchanged roadmap.

## 7. Downgraded / kept as designed (bias control)

- Catcher never hides (auditor P0): DOWNGRADED to accepted design.
  Retention is load-bearing (only copy survives next `begin`
  with History off); staleness is inherent, harmless (Copy still
  works), and hiding on begin would reintroduce loss. No change.
- Mask-vs-clamp drift beyond F1/F8: covered by fixes, not separate.
- ComboBox/web-role expansion: rejected (matrix rows, not code;
  bias-toward-catcher is the safe direction and retry skips the
  gate anyway).
- `pollForMatch` wall-clock, `shouldRestore` duplication,
  per-call clock construction: noted, not batched (no user impact
  evidenced).

## 8. Open questions — none. Three strongest aspects on record:
start-pinned target + liveness without exception; finish-during-
starting armed-not-cancelled (tested); clipboard discipline +
read-only AX + log privacy (no transcript text anywhere, verified
by grep). `execute` builds §5 + §4.
