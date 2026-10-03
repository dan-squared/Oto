# Phase 7b: Tune-up (speed + prompt + symmetric clipboard) → Slice B (Upgrade-if-fast + picker)

> Follows Slice A (`37cdf4a`, Matrix A passed: wording excellent, offline OK,
> speed slower than hoped). Two parts, in order: (1) a Manual-only tune-up
> batch with timing instrumentation so the next change targets the measured
> bottleneck, not vibes; (2) Slice B auto behavior. Slice C (Automatic)
> stays a separate future slice.

## Spec sources

- `Docs/START_HERE_PRODUCT.md` Phase 7 rules (canonical — unchanged).
- `plan/phase-7-intelligence-modes.md` (live plan: modes, strict swap window,
  undo, picker deferred to B — this file executes that deferral).
- Local SDK truth (this session, `MacOSX27.0.sdk`): `GenerationOptions.init(
  samplingMode:temperature:maximumResponseTokens:)` (all optional);
  `ResponseStream<String>.Snapshot.content: String`; `Availability` reasons
  exactly `deviceNotEligible / appleIntelligenceNotEnabled / modelNotReady`
  (+ `@unknown`); `session.prewarm()`; `OtoSegmented(options:selection:)`
  takes `[(Option, String)]` + binding (`OtoControls.swift`, `GeneralPane:92`).

## Part 1 — Tune-up batch (Manual only, no new surface)

1. **Timing instrumentation** (`WritingPolishService.swift` + `PolishSheet.swift`):
   `streamCleanup` records start, first-yield, and finish wall times plus
   input/output word counts. Surfaced TWO ways: (a) a small muted caption
   in the sheet under the draft ("Cleaned in 1.4s · 38 words") — the user
   never opens Console, they just read it or screenshot it; (b) the same
   line at `log.debug` as backup. No behavior change, nothing stored.
   Unit tests assert the caption inputs (elapsed/word counts) are computed,
   not the timings themselves.
2. **Token cap scaled to input** (same file): fixed 512 → dynamic
   `min(512, max(128, text.count / 2))`. Principle: cleanup output ≈ input
   size, so the cap tracks the job instead of taxing short entries for long
   ones (200 chars → 128; 5000 chars → 512, unchanged). Short entries finish
   sooner; long entries unaffected.
3. **Instructions v2** (same file, test pin updated with it): keep the
   meaning-lock, add register preservation — casual stays casual, formal
   stays formal; still output-only. Matrix re-judges pairs before Slice B
   builds on them.
4. **Symmetric clipboard** (`PolishSheet.swift`): Use original now copies the
   RAW to the clipboard (today it writes nothing, so a previous Keep's
   polished text survives — the exact confusion from Matrix A). After this,
   paste always reflects the last decision: Keep→polished, Original→raw.
   +1 unit test (scratch board gets raw after Use-original path).

## Part 2 — Slice B: Upgrade-if-fast + behavior picker (default)

**Mechanics** (strict by default, matrix-tunes only with evidence):
- Coordinator `finalizeSession`, post-`.inserting` success, mode==upgrade:
  race polish against the swap window; on success call new
  `TextInserting.replaceLast(_:into:)`; publish `lastPolish` (raw + polished)
  for the menu Revert row. Window violation or polish failure ⇒ raw
  stands, polish task cancelled, nothing stored anywhere.
- **Swap window (all must hold):** dispatch event-generation unchanged since
  insertion + frontmost app unchanged + field re-checks editable + ≤2s
  elapsed. Secure fields / moved carets / slow model ⇒ no swap, ever.
- **Beat:** Flow Bar post-insert transient ("Cleaned up · Revert", click
  re-pastes raw via `coordinator.revertLastPolish()`, idempotent, clears
  `lastPolish`). Window ends at next session begin. Double-press toggle is
  explicitly NOT in Slice B (hijacks double-tap semantics — separate decision).
- **Mode fallback rule:** off/manual behave as today; `automatic` value (not
  yet built) falls back to manual — future values can never trigger
  unbuilt behavior. Pinned by test.

**Exact file changes:**
1. `TextInsertionService.swift`: `replaceLast(_:into:)` on the protocol +
   `FakeTextInsertion` recording (same calls shape as `insert`).
2. `RealTextInsertion.swift`: `replaceLast` implementation reusing the
   guarded `insert` vocabulary (`InsertionTimings`, frontmost-PID check,
   trust re-gate, secure-field refusal, change-count-guarded restore).
   New method, zero changes to `insert`.
3. `HIDEventMonitor`/`ShortcutDispatch`: monotonic `eventCount`, bumped on
   every routed physical event entry point (`receive`, `receiveFnHold`,
   `receiveEscape`); coordinator receives an `eventClock` closure
   (`@Sendable () -> UInt64`) at construction — no new references, no
   lifetime change.
4. `DictationCoordinator`: `polish` service + `behaviorProvider`
   (`@Sendable () -> PolishBehavior`, UserDefaults-backed, read per session)
   injected; `finalizeSession` upgrade branch (session-ID discipline
   unchanged — the race DETACHES via unstructured Task so a parked stream
   never wedges finish(); state guards veto stale swaps); `lastPolish` +
   `revertLastPolish()` idempotent; `canRevertPolish()` for the menu;
   physical-input clock (`noteInput`, bumped per tap event via
   `dispatch.setInputClock`, cleared per session window by snapshot).
5. `IntelligencePane.swift`: behavior picker (`OtoSegmented`, Manual +
   Upgrade-if-fast only — Automatic appears with Slice C, same no-dead-
   controls rule that deferred the picker from Slice A) + `intelligenceMode`
   pref (default upgrade).
6. Undo surface: MENU row, not Flow Bar beat (corrected during build — the
   pill deliberately shows no end-state pixels per v6/v7 house rules, and
   errors never touch the pill). `OtoMenuBarView` gains "Revert to original
   wording" iff `canRevertPolish()` (one-shot read per open, same pattern
   as recovery rows; feedback line on success/failure). No FlowBar changes.

**Tests (all real):** `replaceLast` refuses on frontmost-mismatch / revoked
trust / secure field (clipboard untouched, fail-closed — same table as
`insert`); swap-rule matrix (clock moved / frontmost changed / >2s / slow
polish ⇒ `replaceLast` never called); beat clears on next `begin`;
mode-fallback (automatic/off/manual ⇒ insertion byte-identical to today);
timeout path (polish slower than window ⇒ raw stands, task cancelled).

## Verification

- [ ] Build green; grep gates (PCC 0, `fm` 0, no new `Timer`/logging-above-
  debug/unwraps in prod)
- [ ] Part 1 unit (symmetric-clipboard test) + full `xcodebuild test` calm
- [ ] Matrix T (user, Manual re-check): read the in-sheet caption per entry
  ("Cleaned in Xs · N words" — just tell me the numbers, or screenshot);
  pairs judged on instructions v2; Release-vs-Debug feel noted;
  Use-original→paste gives raw
- [ ] Matrix B (user, Slice B): dictation in real apps (Electron, browser,
  notes) — swap hits when fast, never haunts (moved caret ⇒ no swap);
  Revert restores raw; slow-model dictation degrades to today; secure field
  never swaps
- [ ] Matrix B-offline: networking disabled ⇒ dictation inserts + Manual
  streams (re-proven after tune-up)

## Risks

- Swap/re-paste in foreign apps is the riskiest code in this plan: strict
  refusal rules contain it (worst case raw-stands, never words-lost), but the
  matrix must cover the user's actual apps before Slice C is even discussed.
- Timing logs are debug-only and Matrix-read; they assert nothing in unit tests.
- If Matrix T shows first-token (not output length) dominating, the cap change
  buys little — then prewarm placement and Release-vs-Debug are the levers,
  and Slice B's swap window may need widening with evidence.

## Open questions

1. Swap 2s bound + Revert window length: starting values, matrix-tunes.
2. Double-press raw↔polished toggle: deferred past Slice B — want it in C?
3. `intelligenceMode` default upgrade — confirm, or ship Manual-first?
