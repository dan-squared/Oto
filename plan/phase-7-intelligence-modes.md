# Phase 7 v2: Intelligence pane + Clean up in three modes (Manual → Upgrade-if-fast → Automatic)

> Supersedes `plan/phase-7-cleanup-action.md` (History-only draft — leave that
> file untouched as history; THIS file is the live plan). What changed and why: conversation review chose (1) both auto
> behaviors behind a picker with Upgrade-if-fast default, (2) a dedicated
> Intelligence sidebar pane instead of History-tucked settings, (3) undo via
> Flow Bar beat + hold-key double-press. Manual first so output quality is
> judged before any auto behavior touches insertion.

## Goal

Ship one Intelligence action — **Clean up** (grammar + filler removal,
meaning-preserving, same language) — in three user-selectable modes, defaulting
to the frictionless one, with raw text always recoverable and dictation
provably untouched when Intelligence is off or unavailable. Three shippable
slices; safe to stop after any of them.

## Spec sources

- `Docs/START_HERE_PRODUCT.md` Phase 7 + Intelligence rules (canonical):
  post-transcript only, finalized text only, reversible draft, never on the
  mic path, unavailable ⇒ dictation works, one feature at a time with
  availability explanation + offline test, never overwrite raw without
  preview/undo, never store prompt traces. The doc *anticipates* adding an
  `Intelligence` sidebar destination when the first feature ships — this plan
  does exactly that.
- Local SDK truth (this session, `MacOSX27.0.sdk` — never memory):
  `SystemLanguageModel` (`Sendable`, `Observable`, `static .default`),
  `availability` / `isAvailable`, reasons incl. `deviceNotEligible`,
  `appleIntelligenceNotEnabled`, `modelNotReady`;
  `LanguageModelSession(model:instructions:)` (String-instructions overload,
  no tools); `streamResponse(to:) -> ResponseStream<String>` (`AsyncSequence`);
  `session.prewarm(promptPrefix:)`; `GenerationOptions.temperature` +
  `.maximumResponseTokens`; `PrivateCloudComputeLanguageModel` exists and is
  banned. Deployment target 27.0 ⇒ no `#available` needed.
- Resolved research: the `fm` CLI license is machine-wide and CLI-only —
  framework users need nothing but Apple Intelligence on + model present
  (verified: `fm available` → "System model available", read-only, nothing
  agreed). The app must never shell out to `fm` (grep-gated).

## Product decisions (locked from conversation)

- **Modes** (`IntelligenceMode: off | manual | upgrade | automatic`;
  persisted, default **upgrade**; master toggle = mode != off):
  - *Manual*: Clean up button on History rows → streaming sheet → Keep
    (clipboard; entry keeps raw) / Use original. Zero insertion-path contact.
  - *Upgrade if fast* (default): raw inserts instantly (today's behavior);
    if polish finishes while the swap window holds, it swaps in with a
    shimmer; otherwise polished waits in History. Model failure degrades to
    today's app for free.
  - *Automatic* (opt-1): insertion waits for polish (bounded timeout, then
    raw + note); polished lands directly.
- **Swap window (option 5, strict by default):** no input events observed since
  insertion (dispatch generation unchanged) + frontmost app unchanged + field
  re-checks editable + ≤2s elapsed. Any violation ⇒ no swap, polished waits
  in History. Strictness is matrix-tuned (may relax only with evidence).
- **Undo:** Flow Bar post-insert beat ("Cleaned up · Revert", click re-pastes
  raw) + hold-key double-press toggles raw↔polished within the revert window
  (reuses the double-tap machinery). Window ends at next session begin.
  Undo failure must never lose words: if re-paste can't be guarded, it
  refuses and raw stays reachable in History/menu.
- **Keep semantics:** clipboard only (no replace-entry — that overwrites raw
  and needs its own undo design; explicit v2).
- **Catcher integration:** explicit v2 — V6 footer math stays untouched.
- **No second action, no prompt box, no sliders, no model picker.** If the
  Intelligence pane ever grows those, the design has failed.

## Slice A — Service + Manual + Intelligence pane (no auto behavior)

**Files:**
1. New `Oto/Services/WritingPolishService.swift` — `PolishServing: Sendable`
   (`availability()`, `streamCleanup(_:) -> AsyncStream<String>`) + live impl
   (pinned instructions/temperature/token cap; cancel on task cancel) + fake
   (scripted chunks/errors/cancel). Ban comments + grep gates: no
   `PrivateCloudComputeLanguageModel`, no `/usr/bin/fm` / `fm respond` /
   `fm serve` in `Oto/`.
2. Availability→copy mapper (pure, same file): every `UnavailableReason` → one
   honest line; unknown → generic "not available".
3. New `Oto/Settings/IntelligencePane.swift` — status card (mapper copy),
   master toggle, behavior picker (`OtoSegmented`, three modes). Prefs:
   `app.Oto.intelligenceEnabled` (default true — OS-level AI opt-in already
   happened if the model exists), `app.Oto.intelligenceMode` (default upgrade).
4. `SettingsPane` (+`Intelligence`, "sparkles") in `SettingsRoot.swift:18-49`,
   `content` switch (`:210-253`), `OtoApp.swift` wiring (construct service once,
   pass down the existing `SettingsRoot → HistoryPane` chain).
5. `HistoryPane.swift:65-71` row actions: `OtoQuick("Clean up")` beside
   Copy/Delete → streaming sheet (Keep/User-original; dismiss cancels).
   `HistoryStore.record(_:)` untouched; polish writes nothing to history.
6. `SettingsUITests.swift:50-55` sidebar loop gains "Intelligence" (it
   currently pins six names — update or it fails).

**Tests (all real):** mapper truth-table (every reason covered); fake
streaming order + mid-stream cancel + error-with-raw-intact; no-persistence
(history file byte-identical after polish); unavailable ⇒ no Clean up
affordance + explanation line present; Manual sheet Keep copies polished to
scratch pasteboard while entry keeps raw.

## Slice B — Upgrade-if-fast (default auto behavior)

**Mechanics:** coordinator `finalizeSession` (post-`.inserting` success) races
polish against the swap window; on success calls new
`TextInserting.replaceLast(_:into:)` (guarded re-paste: target alive +
frontmost-PID match + trust + editable re-check + clipboard-ownership
discipline identical to `insert` in `RealTextInsertion.swift:182-260`);
publishes `lastPolish` (raw + polished + deadline) for the beat/undo.
Window violation or polish failure ⇒ raw stands, polished waits in History.

**Files:** `RealTextInsertion.swift` (+`replaceLast`, same timing/guard
vocabulary as `InsertionTimings`), `TextInserting` protocol + fakes,
coordinator finalize path (mode branch; session-ID discipline unchanged),
Flow Bar beat state (transient, derived from `lastPolish`; cleared on next
`begin`), double-press toggle wiring through existing double-tap path,
shimmer affordance on swap.

**Tests:** replaceLast refuses on frontmost-mismatch / revoked trust / secure
field (clipboard untouched, all fail-closed); swap rule matrix (event
generation moved / frontmost changed / >2s / slow polish ⇒ no swap call);
beat clears on next session; full-suite regression (insertion path untouched
for Manual/Off).

## Slice C — Automatic (choosable wait-and-insert)

**Mechanics:** mode==automatic ⇒ `finalizeSession` awaits polish bounded by a
timeout (matrix-tuned, ~2.5s starting value) → insert polished (raw kept in
`lastPolish` for Revert) → completed. Timeout/error/unavailable ⇒ insert raw
+ one honest note (never blocks insertion). Flow Bar shows "Polishing…"
shimmer while waiting (same pill, new transient state).

**Tests:** slow-polish ⇒ raw inserted + note (fake with delayed chunks);
polish error ⇒ raw inserted; unavailable/off ⇒ byte-identical behavior to
today (coordinator test pins insertion result unchanged); timeout value pinned.

## Cross-slice verification

- [ ] Build green; grep gates (PCC 0, `fm` 0, no new `Timer`/logging/unwraps)
- [ ] Slice unit tests green isolated + full `xcodebuild test` calm (known
  focus trio excluded as environmental)
- [ ] Matrix A (device): `availability` probe + `fm available` cross-check;
  first-token/total timings per entry length; over-edit/language-drift
  judgment on real outputs (Manual first — auto slices wait for this verdict)
- [ ] Matrix A2 (clean account, never `sudo fm license`): framework works
  independent of the CLI gate
- [ ] Matrix B (offline, networking disabled): dictation inserts + Manual
  streams (on-device proof); Upgrade/Automatic behave per spec
- [ ] Eyes-on per slice: Manual sheet → Keep/Discard; Upgrade swap + shimmer
  + Revert + double-press toggle; Automatic wait + timeout-fallback; Off mode
  = today's app exactly

## Risks

- Swap/undo in foreign apps (Electron, VMs, terminals): strict refusal rules
  contain it — worst case is raw-stands, never words-lost. Matrix must cover
  the user's actual apps.
- Model quality (over-editing): judged in Manual before auto slices build.
- Haunted-swap feel: motion design + strict window; relax only with evidence.
- Prewarm memory while preview/beat visible: accepted, never on mic path.

## Open questions

1. Keep = clipboard only to start — acceptable, or is replace-entry needed
   sooner? (Recommendation: clipboard; replacement is its own undo design.)
2. Default mode upgrade vs automatic as the shipped statement?
   (Recommendation: upgrade — immediacy is the product's founding feeling.)
3. Revert window length + swap 2s bound: matrix-tune, starting values above.
