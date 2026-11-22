# Phase 4 follow-up — direct-post insertion + clipboard discipline on refusals
(EXECUTED 2026-09-20, awaiting device matrix)

Status: VERIFIED COMPLETE 2026-09-20. Device matrix all green (user-reported):
hold-to-talk + hands-free auto-paste with SENTINEL restore (TextEdit),
Electron repeat (Conductor), switch-mid-record → fail-closed "no longer in
front" + Retry lands it, password field → secure-input fail + clipboard
untouched + copy-recovery works. `xcodebuild test` → TEST SUCCEEDED, exit 0.

## 0. Ground truth (verified 2026-09-20, not from transcript)

- **The workspace does not build.** `xcodebuild build -scheme Oto` fails:
  `Oto/Services/RealTextInsertion.swift:60:69: error: extra argument 'to' in call`.
  The `postToProcess` seam field + its `Self.postFullCommandV(to: pid)` call site
  landed **without the `to:` overload**. Any app currently running on the user's
  Mac therefore **predates this source** — it cannot contain the latest fixes.
  This alone explains "still not resolved" for both reported issues: the user
  tested a stale build.
- **Tests are broken too.** `OtoTests/RealTextInsertionTests.swift:19`
  `scriptedEvents()` passes 8 of 9 `InsertionEvents` fields (`postToProcess`
  missing) — struct memberwise init requires all 9, so the test target will not
  compile either.
- Prior "77/77 green, relaunched" claims cannot have been against this file
  state. Trust only fresh `xcodebuild` output from here on (§5).

## 1. Issue A — app-switch never delivers anywhere

**Root cause (device-proven + doc-backed, not guessed):**
device logs showed `activate=false` on all 8 `confirmTarget` attempts, including
the Finder control probe. `NSRunningApplication.activate()` from a background
`MenuBarExtra` app carries no activation context — Apple's cooperative-activation
doc (via ACP `DocumentationSearch`, AppKit) states **only the active app can
yield**, and Oto is never active. The WindowServer refuses; retries cannot fix a
refusal. So after any mid-session switch, `confirmTarget` always fails closed →
nothing pasted in either app. The code works as written; the strategy is wrong.

**Fix — addressed delivery, no activation (recommended):**
`CGEventPostToPid(pid, event)` (`CGEvent.h:362`, `API_AVAILABLE(macos(10.11))`,
non-deprecated; `CGEventPostToPSN` is deprecated in its favor — verified in the
local `MacOSX27.0.sdk`, not from memory). Deliver the same full 4-event Cmd-V
(private source, genuine Command down + `NX_DEVICELCMDKEYMASK`, per the adopted
Yap pattern) **directly to the captured pid**. Consequences:

- No `activate()`, no focus race, `frontmostPID` becomes irrelevant.
- Wrong-app paste is **structurally impossible** (events are addressed to the
  target pid, not to "whoever is frontmost") instead of hopefully avoided.
- Same `AXIsProcessTrusted()` gate already covers posting permission; sandboxed
  event *posting* is already proven (normal paste works) — only *activation*
  was refused.
- `postToProcess` already exists in the `InsertionEvents` seam (currently dead
  code) — the architecture anticipated this; we wire it.

**Honest unknown:** no Apple doc guarantees a *background* app acts on Cmd-V
key events delivered via `PostToPid`. Must prove on device (§6). Fallbacks, in
order: (1) sandbox OFF, Yap-parity (makes `activate()` work; standalone
signing/TCC decision, not taken here); (2) AX selected-text insertion layer
(`kAXSelectedTextAttribute` exists per `AXAttributeConstants.h:80`, but
per-app settability is undefined and Electron reports no focused element —
likely fails exactly where it matters).

## 2. Issue B — refusal paths overwrite the user's clipboard

**Current behavior:** `refuseUntrusted` and `refuseSecureInput` both call
`placeOnClipboard(text)` with **no snapshot** — the user's prior clipboard is
destroyed (unrecoverable loss) plus a ghost transcript entry in manager history
("recorded words second in line"). The give-up path was already fixed to
confirm-before-write; refusals still write.

**Spec check:** `02_RECORDING_WORKFLOWS.md:127-136` recovery table — AX-denied
recovery is user-triggered "**Copy**, Scratchpad, Open Accessibility Settings";
secure-input is "Text remains **local**/clipboard-only". The coordinator already
preserves `recoveryTranscript` on every `recoverableFailure`
(`DictationCoordinator.swift:289`). Auto-overwrite is **not** spec-required;
explicit copy is spec-listed. And `IsSecureEventInputEnabled()` is a *global*
boolean (`CarbonEventsCore.h:3064`) — any background holder (Terminal sudo,
1Password) trips the gate, making silent clipboard destruction worse.

**Fix (recommended):** refusal paths return `recoverableFailure` **without
touching the pasteboard**; transcript stays in `recoveryTranscript`; add a
DEBUG "Copy recovery transcript" menu button (dies in Phase 5 with the rest of
DEBUG) so recovery is reachable before the Phase 6 Flow Bar. Result: clipboard
pristine on every failure mode; manager history untouched. Success path keeps
clipboard+guarded-restore (one history entry is inherent to paste semantics —
stated plainly; a future AX-insertion layer could remove it).

## 3. Exact file changes — SUPERSEDED by §9 (kept for history; what was built
differs: no direct-post, HID reverted, retry added — see §9)

1. `Oto/Services/RealTextInsertion.swift`
   - Add `postFullCommandV(to pid: pid_t, step:)` overload: same 4 events, each
     posted via `CGEventPostToPid(pid, event)`; keep HID-tap `postFullCommandV(step:)`
     (normal path proven; direct-post proven by matrix before any removal).
   - `InsertionEvents.live.postToProcess` → calls the new overload (fixes the
     build break; the current `to:` call site then resolves).
   - `insert()`: refusal branches drop `placeOnClipboard`; reason strings say
     "transcript kept for recovery". Proceed path: keep snapshot → clipboard
     write → pre-paste delay; replace `postPaste()` with
     `postToProcess(target pid)`; demote `confirmTarget` from hard gate to
     best-effort single reactivate attempt + logging (no longer load-bearing;
     dead-target case still guarded by coordinator `isAlive`).
2. `Oto/Coordinator/DictationCoordinator.swift` — add `func recoveryText() ->
   String?` accessor (no state-machine change).
3. `Oto/UI/OtoMenuBarView.swift` — DEBUG "Copy recovery transcript" button
   (writes `recoveryText()` to `.general`, shows copied/empty feedback).
4. `OtoTests/RealTextInsertionTests.swift` — `scriptedEvents` gains
   `postToProcess` hook; rename/retarget the two refusal tests to assert
   **clipboard untouched**; new tests: direct-post addressed to original pid
   while frontmost is elsewhere; no post on refusals.
5. No coordinator/speech/shortcut/entitlement/sandbox changes. No System Events
   (grep gate holds). No AX value-set writing.

## 4. Assumptions questioned (per working agreement)

- "More reactivate retries will fix the switch" — disproven by `activate=false`
  logs; refusal is policy, not timing.
- "Frontmost-gating is what makes paste safe" — addressed delivery is strictly
  stronger (impossible vs unlikely).
- "Leave-on-clipboard is required recovery" — spec lists explicit Copy;
  coordinator already preserves the transcript. Auto-overwrite destroys user
  data for zero spec gain.
- "Prior green claims carry over" — disproven by today's red build. Fresh
  `xcodebuild` is the only gate.

## 5. Verification

- ACP `BuildProject` green; `xcodebuild test -scheme Oto` green (updated suites).
- Grep gates: `NSAppleScript` → 0; `post(tap: .cghidEventTap)` retained only in
  the proven normal path.
- Device matrix (user, packaged signed app): TextEdit/Safari paste + prior
  clipboard restored; VS Code/Slack paste; **switch-mid-record lands in the
  ORIGINAL app** (the fix's proof); password field → `failed` + clipboard
  byte-identical + Copy-recovery pastes manually; AX-revoked via combo →
  `failed` + clipboard untouched.

## 6. Risks / deferred

- `PostToPid`-to-background may be ignored by some apps (no readback exists for
  posted Cmd-V — Yap parity, structural guarantee only). Matrix decides; the
  sandbox-OFF contingency is documented, not built.
- Success-path clipboard history entry remains (inherent; documented).
- Hold watchdog (lost-key-up) still deferred per Phase 3 risk log.

## 8. §8 answers (superseded — see §9)

Pristine-clipboard refusals: KEPT (device-approved). Confirm demotion: discarded
— the confirm concept is gone entirely, replaced by §9 gates. Fallback order:
moot until sandbox-OFF is tabled; `activateIgnoringOtherApps` is dead (see §9).

## 9. Core-issue analysis (2026-09-20, post-device-evidence — READ FIRST)

**Corrections to my own prior claims:**
- The "background dispatch" explanation for the `postToPid` failure is WITHDRAWN
  as insufficient: Safari sessions were frontmost (`reactivate=true`) and still
  pasted nothing. Candidate mechanisms (sandbox WindowServer policy on directed
  posts; directed posts skipping session annotation) are UNVERIFIED — stated as
  unknown, not as fact. The load-bearing datum is device-observed outcome only:
  addressed Cmd-V drives no paste anywhere → revert to the empirically proven
  HID-tap path.
- The `activateIgnoringOtherApps` experiment is CANCELLED without being built:
  `NSRunningApplication.h:27` (local SDK) marks it `API_DEPRECATED("ignoringOtherApps
  is deprecated in macOS 14 and will have no effect")`. Force-activation does not
  exist on our deployment target (27). The only modern API is
  `activate(from:options:)` (macOS 14+, `:144`), which requires the ACTIVE app to
  yield first — Oto, never active, can never arrange that. Conclusion, verified
  against headers not memory: **in-sandbox automatic reactivation is structurally
  unavailable.** Switch recovery is fail-closed + user-driven retry until a
  sandbox-OFF decision. No more retries, no more probes of activation.

**Resulting design (executed below):**
- Delivery: HID tap only. `postToProcess` + `postFullCommandV(to:)` DELETED
  (dead theories leave the codebase, not relics).
- Proceed gates, in order: AX trust → secure input → (pid nil → fail) →
  best-effort reactivate, `false` → fail closed (sandbox-valid proxy: `true`
  ⟺ already frontmost ⟺ HID post safe; non-sandboxed future: Yap behavior) →
  modifiers drain → snapshot → clipboard write → BOUNDED WRITE-VERIFY POLL
  (fail closed on timeout — a post ahead of an invisible write is how stale
  content gets pasted) → single-read frontmost micro-verify (fail closed +
  synchronous restore — covers the mid-settle race, no retry loop) → HID post →
  guarded restore → `.inserted`.
- `retryPostToFrontmost(_:)`: gates deliberately absent — the user, having
  switched back manually, IS the check. Clipboard discipline + restore kept.
- Logging honesty: the post line reads "posted HID Cmd-V (delivery unverified)".
  Terminal `.inserted` never again implies per-keystroke proof.
- Menu: "Retry paste to frontmost app" button; feedback-flicker fix (button
  feedback carries a 2s expiry the 500ms poll respects).

## 11. Close-out micro-fix (EXECUTED 2026-09-20): disambiguated fail reasons

Device matrix showed the "no longer in front" reason fires in two
user-indistinguishable situations: (a) Oto itself is frontmost (menu/Settings
open — the Phase-3 watch-the-menu habit), fixable by closing Oto UI + Retry;
(b) a genuine app switch, fixable by switching back + Retry. One generic line
wastes a debug cycle every time.

Change (minimal, tested): `InsertionEvents` gains `otoFrontmost`
(scripted in tests; live reads `NSWorkspace.frontmostApplication` vs
`Bundle.main.bundleIdentifier`). Both fail-closed branches (reactivate-refused,
race-lost) route their reason through `frontmostFailureReason()`, which names
the Oto-frontmost case explicitly. No gate logic touched. Tests: Oto-frontmost
vs genuine-switch reason assertions. Next phase after this: Phase 5 (native
Settings product) per `START_HERE_PRODUCT.md:255`.

## 10. Original §7 questions — SUPERSEDED (kept for history, do not answer)

1. ~~Refusal clipboard: pristine + explicit copy vs Yap-style auto-place~~ →
   RESOLVED: pristine + copy, device-approved.
2. ~~Confirm demotion vs 8-attempt gate alongside direct-post~~ → RESOLVED:
   both gone; §9 gates instead.
3. ~~Direct-post fallback order~~ → RESOLVED: direct-post itself failed and was
   reverted; next lever is sandbox-OFF, tabled as a standalone decision.
