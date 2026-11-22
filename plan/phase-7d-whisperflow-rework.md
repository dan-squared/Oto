# Phase 7d: Whisperflow rework — Auto Cleanup (None/Light/Medium) + Transforms via shortcut

> Supersedes the *timing* model of `plan/phase-7-intelligence-modes.md` (Manual /
> Upgrade-if-fast / Automatic) and `plan/phase-7b-tuneup-and-upgrade.md` (Slice B
> swap race) — leave those files untouched as history; THIS file is the live plan.
> `plan/phase-7c-longform-delivery.md` (notify-when-ready for long text) stays
> deferred, not deleted: this rework may make it unnecessary, and that call is
> made from matrix evidence, not theory.
>
> Replan note (pill + shortcuts + settings, from the user's `Using Polish`
> screenshot): the pill is an expanding dark capsule — working-text left
> (`Using Polish`), thin vertical divider, native spinner right. While Auto
> Cleanup runs it reads `Cleaning up` in the same shape, so the user always
> sees the model working and never wonders. Shortcuts are one-per-preset,
> defaults `Opt+1 / Opt+2 / Opt+3`. Slice E2 below is rewritten to this spec:
> three fixed presets, the responsive pill, the shortcut system, and the
> full Intelligence-pane layout. E1 (Auto Cleanup) is unchanged.
>
> Replan note 2 (shortcut conflict policy, user's "already in use" ask):
> same-or-similar bindings across different purposes are refused at
> record/save time with an `Already in use by …` message (§Conflict policy).
> This exposed a factory-default collision — right-Option hold vs `Opt+1/2/3`
> share the Option family — so the default hold key moves to Right Command
> and the refusal rule covers all five purposes. Details in §Conflict policy;
> E2 shortcut ownership + defaults + tests updated to match.
>
> Why rework: the user's Whisperflow study names the exact fix for our exact
> pain. Slice B's post-insert swap (`maybeUpgradePolished` + `replaceLast` inside
> a 2s window) produced the reported flakiness — worked once, then a long
> sentence missed, then a short phrase missed, with silence either way. The swap
> races a cold model against a fixed clock inside a foreign app; every miss looks
> identical to "broken". Whisperflow separates the two jobs and kills the race:
> (1) lightweight Auto Cleanup applied *before* insertion, every time, no user
> action; (2) heavier rewrites as explicit presets the user fires with a shortcut
> on selected text, with a "Using X" pill while it runs. No swap, no window, no
> mystery. This plan brings exactly that to Oto, Oto-natively.

## Goal

Every dictation gets exactly one predictable behavior, understandable by a
non-technical user with zero configuration — and power users get explicit
shortcut-driven rewrites on any selected text:

- **Auto Cleanup** (None / Light / Medium, default Light): runs *before*
  insertion as part of finalization. Light = filler removal + grammar + simple
  punctuation, meaning-preserving, same language, register-preserving (casual
  stays casual). Medium = Light + clarity/conciseness (allows light rewording,
  still meaning-preserving). None = raw inserts, zero model contact. The cleaned
  text is what inserts — once. There is no second write, no swap, no haunted
  text. Raw is always preserved (History + Undo — below).
- **Transforms** (three fixed presets, one shortcut each): the user selects text
  in any app and presses that preset's shortcut — `Opt+1` Polish (clarity +
  conciseness), `Opt+2` Concise (shorten, same meaning), `Opt+3` Professional
  (work-ready tone). All re-recordable, `Reset to defaults` included. While one
  runs, the pill expands to `Using <Preset>` + divider + spinner (the
  screenshot's shape, §E2 pill spec), then melts out. Fired only by the user,
  never automatically. Custom prompts are explicitly deferred (see §Deferred).
- **Original never lost**: every AI-touched dictation keeps its raw text —
  History stores both, the menu keeps `Revert to original wording` (already
  built), and History rows gain `Undo AI edit` (Whisperflow's three-dots
  equivalent). `Use original` copies raw (symmetric-clipboard rule from 7b,
  carried forward).

Two shippable slices, safe to stop after E1. E1 alone fixes the reported
flakiness and delivers the 90% case. E2 is the power-user layer.

## Spec sources

- `Docs/START_HERE_PRODUCT.md` Phase 7 + Intelligence rules (canonical,
  unchanged): post-transcript only, finalized text only, reversible draft,
  never on the mic path, unavailable ⇒ dictation works, one feature at a time
  with availability explanation + offline test, never overwrite raw without a
  preview/undo path, never store prompt traces. The doc anticipates an
  `Intelligence` sidebar destination when the first feature ships — already
  shipped (Slice A), this plan reworks its contents.
- User's Whisperflow study (this session's attachments): three screenshots +
  transcript. auto-cleanup card (`None`/`Light`/`Medium`, "applies to all your
  dictations", "original never lost, Undo AI edit"), Transforms page (`Opt in`
  master toggle, `Auto Apply After Dictation` + preset dropdown + toggle OFF by
  default, `My Transforms`: Polish `Opt+1`, second preset `Opt+2`, `Create your
  own`), pill (`Using Polish` + spinner). Interpreted, not copied: Oto gets the
  two-layer shape and the pill beat, not Whisperflow's copy, presets, or IA.
- Pill screenshot analysis (this replan, `ckNUNW/image.png`, read pixel-level):
  near-black rounded capsule on a blue field; working text left in muted
  gray-white (`Using Polish`); a thin vertical divider separating text from a
  native macOS spinner (light variant) pinned right. The capsule width fits its
  content — it is NOT the fixed 92.4/95.7 dictation width: `Using Polish` +
  divider + spinner needs roughly twice the recording pill. So the work pill
  must measure its text and expand/contract (animated, existing 0.15s easeOut
  chrome morph), not reuse a fixed-width table entry. Same shape carries the
  Auto Cleanup beat with the text `Cleaning up`.
- Tap/transition mechanics verified by reading (this replan — the finding
  that forces §Conflict policy): `ModifierHoldState.step(.flags(down: true))`
  emits `.keyDown` instantly (`HIDEventMonitor.swift:424-442`), and the
  transition machine begins on it (`HotkeyTransitionState.swift:44-48`) — so a
  hold `begin` fires on modifier-down BEFORE any combo can complete.
  Combination-use only swallows the RELEASE (`usedInCombination ? nil : .keyUp`),
  never the begin. Consequence: same-family bindings across purposes (e.g.
  Option-hold + any Opt-combo) double-fire — a stranded hold micro-session
  plus the combo action — and the old "combo wins by construction" comment
  (`ShortcutModels.swift:135-145`) is wrong about `begin`. Today's peace
  treaty is side-specific HID codes (right-Option hold ignores left-Option
  presses) against side-blind Carbon combos (either Option fires) — which is
  exactly why curation can't save factory defaults and refusal must.
- Pill seams verified by reading (this replan): `PillVisual.forState`
  (`PillLayers.swift:34` — preparing/recording→bars, finalizing/inserting→
  dotsSpinner, message→controller-latched notice; failures never map — v7 rule);
  `PillContentView` (label + spinner subviews already exist but are laid out for
  separate visuals — label fills padding-to-padding for `.message`, spinner sits
  right of chase dots for `.dotsSpinner`; the work visual needs a NEW joint
  layout: label left, divider layer, spinner right); `VisualizerMath.panelWidth`
  (fixed per-state table 92.4/95.7 — the work pill does NOT fit this table, it
  needs measured dynamic width); `FlowBarPanel.show/resize` (animated AppKit
  frame + 0.15s bg-path morph already handle width changes — reuse, no new
  motion language); `FlowBarController.pollOnce` (150 ms poll already merges a
  second read — `recoveryText()` — with the state projection; work-text merges
  the same way, no `DictationState` change); `FlowBarProjection.project()`
  (pill is payload-free by house rule; `.message` is controller-latched, never
  coordinator-produced; failures never touch the pill — v6/v7 rules stand and
  the work beat complies: transient working state, same family as
  preparing/recording/finalizing, never an end-state or error pixel).
- Prior plans as history (behavior being replaced, not the rules): `phase-7b`
  (swap race, symmetric clipboard, timing captions — captions + clipboard rule
  survive), `phase-7-intelligence-modes` (mode picker Manual/Upgrade/Automatic —
  replaced by cleanup levels; the `automatic`-falls-back-to-manual guard
  precedent is reused for unknown cleanup values).
- Local SDK truth (this session, `MacOSX27.0.sdk` — never memory; verified via
  `arm64e-apple-macos.swiftinterface` before writing):
  - `SystemLanguageModel.Availability.UnavailableReason` is exactly
    `deviceNotEligible / appleIntelligenceNotEnabled / modelNotReady`
    (+ `@unknown`). `systemNotReady` is PCC-only (banned path) — the old
    Slice-A grep catch stands.
  - `LanguageModelSession(model:instructions: String?)`,
    `session.prewarm(promptPrefix:)`, `streamResponse(to: String,
    options:)` returning `ResponseStream<String>` (`AsyncSequence` of
    snapshots with `.content`), `GenerationOptions(temperature:,
    maximumResponseTokens:)` (+ `samplingMode`). Deployment target 27.0 ⇒ no
    `#available` needed.
  - `LanguageModelSession.GenerationError` cases include
    `exceededContextWindowSize, assetsUnavailable, guardrailViolation,
    unsupportedGuide, unsupportedLanguageOrLocale, decodingFailure,
    rateLimited, concurrentRequests, refusal` (each with context). No
    pre-checkable context budget exists — over-context arrives as a catchable
    error (7c precedent: fail open to raw, no retry).
  - No `fm` symbol in the framework; the `fm` CLI license is CLI-only (resolved
    pre-7b, unchanged). Ban stands: the app never shells out to `fm`.
- Codebase seams verified by reading (not memory): `DictationCoordinator`
  (`finalizeSession`, detached `maybeUpgradePolished` race, `lastPolish` +
  `revertLastPolish`, `noteInput` clock); `RealTextInsertion`
  (`insert`/`replaceLast` sharing `readyPID` + `postPlacedText`, `InsertionEvents`,
  `InsertionTimings`, focus-check + secure-field vocabulary); `LiveFocusCheck`
  (read-only AX, `.secureField` subrole-gated, `.unknown` degrades to legacy
  path); `ShortcutDispatch` + `CarbonHotKey` (combo path = Carbon, no AX needed;
  `conflictsWith` matrix; suspend-during-recording); `TranscriptPipeline`
  (pure trim + dictionary, target-aware); `HistoryStore`/`HistoryEntry`
  (Codable, `finalText` only today); `IntelligencePane` (status + toggle +
  Manual/Upgrade segmented); `HistoryPane` (Clean up button + `PolishSheet`);
  `FlowBarState.project()` (pill is payload-free by house rule; `message` is
  controller-latched, never coordinator-produced; failures never touch the
  pill — v6/v7 rules stand).

## Product decisions (locked for this plan)

- **Auto Cleanup replaces the timing modes.** The `Manual / Upgrade-if-fast /
  Automatic` picker goes away (it asked users a timing question they cannot
  answer). The new question is a *writing* question anyone answers in one
  glance: None (exact words) / Light (fillers + grammar) / Medium (clearer +
  conciser). Default **Light**. Master toggle stays on top (Off = today's app
  exactly, zero model contact).
- **Cleanup runs pre-insertion, bounded, fail-open.** After
  `pipeline.process` yields non-empty clean text: if level is None, or
  disabled, or unavailable ⇒ insert raw (today's path, byte-identical). Else
  race cleanup against a bounded timeout; winner inserts (cleaned), timeout /
  error / empty / meaning-violation ⇒ raw inserts with zero ceremony. One
  insert, ever — `replaceLast` is NEVER on the auto path again. The timeout is
  the only clock, and missing it is invisible (raw stands), not mysterious.
- **Transforms are explicit, selection-scoped, three fixed presets.**
  `Opt+1` Polish (improve clarity and conciseness), `Opt+2` Concise (shorten,
  keep every fact), `Opt+3` Professional (work-ready tone, same meaning).
  Each fires only on its keypress, only when enabled + available, and each
  shortcut is re-recordable (recorder refuses type-while-you-type bindings and
  conflicting ones with guidance — existing `classify` + `conflictsWith` UX).
  While one runs the pill expands to `Using <Preset>` + divider + spinner
  (screenshot shape, §E2 pill spec — a transient working state, same family as
  preparing/recording, so the v6/v7 house rules allow it). While Auto Cleanup
  runs (inside finalization) the same pill shape reads `Cleaning up` — the
  user always sees the model working, never wonders, never touches Console.
  Success replaces the selection (transforms) or inserts once (cleanup);
  failure leaves everything untouched and speaks only through menu/status,
  never the pill. No custom prompts, no `Auto Apply After Dictation` in v1
  (both deferred with reasons — §Deferred). The dropdown-plus-OFF-toggle shape
  from the screenshot is noted and deliberately NOT shipped: an OFF control
  that does nothing is a dead control, and the no-dead-controls rule already
  deferred the Slice-A picker once for the same reason.
- **Raw always survives, two doors.** History entries store `finalText`
  (what inserted) + optional `rawText` (what was said; nil for pre-rework and
  None-level entries). Row shows final text + `Undo AI edit` affordance when
  `rawText` exists (Whisperflow's three-dots → Undo equivalent, Oto-styled as
  the existing `OtoQuick` row actions). Menu `Revert to original wording`
  (built) keeps working for the just-inserted dictation. `PolishSheet`'s
  symmetric clipboard (Keep→polished, Use-original→raw) is unchanged.
- **No second model, no cloud, no CLI, no prompt box, no sliders, no model
  picker.** If the Intelligence pane ever grows those, the design has failed
  (standing rule, repeated because it keeps needing to be).

## Assumptions questioned (and answered)

- *"Light cleanup needs no AI — do it with rules?"* Tempting (deterministic,
  instant, offline-free). Rejected for v1: filler removal + punctuation across
  real speech (repairs, repeats, casing, "comma/period" words vs literal) is
  exactly what the on-device model already does well (Matrix A verdict:
  "wording excellent"), and `TranscriptPipeline` dictionary rules stay for the
  deterministic layer underneath. The model stays, but the *prompt* is minimal
  (Light) so outputs are short and fast. If matrix timings show Light still
  slow, the lever is prompt/cap/prewarm/Release — not a rules rewrite.
- *"Why not keep the swap and just widen the window to 5s?"* Because the user
  already proved the failure mode: cold model + long text + fixed clock =
  unpredictable. Widening moves the absurdity (7c's own words about fixed
  windows). Pre-insertion has no window to miss — slow means raw, always, and
  the user can never distinguish "slow" from "broken" because there is nothing
  to distinguish. Predictability is the $1B property, not speed.
- *"Selection extraction via AX selected-text read?"* Desirable (no clipboard
  disturbance) but coverage varies by app (Chromium/Electron/terminals all
  differ — the focus-check file is a catalog of exactly these differences).
  V1 uses the **clipboard grab** (`Cmd+C` synthesis → read → transform →
  `Cmd+V` over the still-selected range), reusing the full insertion
  vocabulary (trust gates, clipboard ownership + guarded restore,
  secure-field refusal, frontmost-PID race guard). AX-read is the recorded
  alternative if matrix shows clipboard-grab annoying real apps — not built.
- *"Doesn't pre-insertion cleanup tax every dictation with model latency?"*
  Yes — boundedly, and that is the honest trade Whisperflow also makes ("applies
  to all your dictations"). The bound is the product: Light is the default
  because it is the shortest job (output ≈ input, minimal rewrite); the
  timeout caps the worst case; None exists for latency-sensitive users; Release
  builds are faster than the Debug runs timed so far. The old swap taxed every
  dictation too (a detached task + a 2s uncertainty window) while *looking*
  instant — this tax is visible, bounded, and predictable instead.

## Conflict policy (Rule B) + factory defaults — user's "already in use" ask

Five purposes share the global keyspace: Push to talk (hold), Hands-free,
Polish, Concise, Professional. Double-tap is EXEMPT by user call — it derives
from the hold key and serves the same purpose (dictation), so it is never a
cross-purpose collision.

- **Rule A (exact — existing, copy refreshed):** same kind + codes in two
  different purposes → blocked at record/save time. Message:
  `"Already in use by {Purpose} — pick a different one."` (+ Swap offer only
  between Push-to-talk ↔ Hands-free, existing — cross-family Swap is not
  offered: exchanging a hold key for a transform combo across purposes is
  meaningless motion, the message + Reset carry those cases).
- **Rule B (similar — NEW, the user's ask):** a bare-modifier hold and a combo
  sharing that modifier's family across different purposes → blocked, even
  when codes differ. Concretely: Option-family hold (left OR right — Carbon
  combos are side-blind, so family-level is the only honest granularity) vs
  ANY Opt-combo in any other purpose (dictation or transform). Same for
  Command/Control/Shift families. Mapping is pure and testable: hold code →
  `ModifierHoldState.flag(for:)` mask vs combo `carbonMask` (recorder's
  `carbonMask` covers command/shift/option/control; fn-hold maps to nothing
  there, so fn-hold never Rule-B-conflicts with combos — sound, since fn is
  not a combo modifier in practice). Message:
  `"Too similar to your {Purpose} shortcut — both use {Option} and would fire
  together. Pick a different one."` (modifier display reuses `KeyNames`
  short labels: Option/Command/Control/Shift).
- **Explicitly ALLOWED:** transform siblings sharing a modifier with different
  digits (`Opt+1` vs `Opt+2` vs `Opt+3` — Carbon distinguishes by keyCode, no
  double-fire; this is why the trio works); `unassigned` vs anything;
  double-tap vs everything. The old combo-vs-combo conservatism (same keyCode
  blocks even with disjoint modifiers) stays, extended purpose-aware across
  all five slots.
- **Enforcement points (all three, same pure function):** (1) dispatch save
  gate (`updateSlot`-family — strengthened `Kind.conflictsWith`, so Done
  blocks exactly like today); (2) record-time advisory (`refreshAdvisory`
  pattern + the new transform-chip staging in `IntelligencePane` — same
  message text before Done); (3) load-time posture for grandfathered configs:
  `validate()` flags stored violating pairs as a non-blocking advisory
  (`"Already in use by …"` on the offending card, data preserved, nothing
  silently cleared) — new saves are blocked, old sins are named. One matrix
  item covers an upgraded violating config.
- **Factory-default change (forced by Rule B):** default hold moves from
  Right Option to **Right Command**. Right-Option hold + default `Opt+1/2/3`
  would ship violating the new rule on first launch (either Option side fires
  the combos; the hold side can't dodge). Right Command keeps the treaty
  pattern (left-Cmd owns app shortcuts; right-Cmd hold rarely collides),
  preserves double-tap-to-hands-free (non-fn key), needs no AX beyond today's
  HID path, and matches hold ergonomics (mirror position). Fresh installs get
  it; existing stored configs are NEVER silently migrated (load-time advisory
  instead). All tests/presets/onboarding pinning the right-Option default move
  with it (`DualShortcutConfiguration.default`, `defaultHoldToTalk`,
  `SlotKindChoice` hold-key preset staging right-Command, modal/preset copy,
  holdOptions menu default).
- **Copy updates:** modal + onboarding `.blocked` messages adopt the
  `Already in use by …` wording (purpose names: "Push to talk",
  "Hands-free", "Polish", "Concise", "Professional"); transform rows show the
  same advisory inline under the row (existing ⚠ wash-pill pattern from
  `ShortcutModal.slotCard`).

## Slice E1 — Auto Cleanup (None/Light/Medium) pre-insertion; swap race deleted

**Mechanics.** In `finalizeSession`, after `pipeline.process` yields non-empty
`clean` and after the history-record + target-alive gates (order unchanged —
target capture, liveness, and recovery semantics are untouched):
1. Resolve `cleanup = CleanupBehavior.current()` (enabled + level; unknown
   level strings fall back to None — future values can never trigger unbuilt
   behavior; same precedent as the old mode fallback, pinned by test).
2. Level None / disabled / unavailable ⇒ `insert(clean)` — byte-identical to
   today.
3. Else prewarm-hit `streamCleanup(clean, level:)` raced against
   `autoCleanupTimeout` (starting value 3.0s, matrix-tunes; single value, not
   length-scaled for v1 — length-gating is 7c's job if E1 matrix demands it).
   First non-empty snapshot stream is collected to completion *or* timeout,
   whichever first. Winner non-empty and ≠ clean ⇒ `insert(polished)`, record
   `lastPolish(raw: clean, polished:)` for Revert, history stores both.
   Anything else (timeout, error, empty, identical) ⇒ `insert(clean)`, no
   `lastPolish`, no note, no pill change. Cancellation (new begin, toggle-off)
   cancels the stream (existing `.task`-death / structured-task discipline).
4. Pill: transient working beat while awaiting cleanup *only if* the wait
   exceeds the pill's existing finalizing beat — no new pill state if the
   existing finalizing visuals already cover it (controller decides; the
   coordinator publishes no new state for this — it stays inside
   finalizing/inserting). Errors never touch the pill (house rule).
5. Prewarm moves to where the free seconds are: at every record start (model
   warms while the user speaks) + app launch (gated on enabled + available,
   both sync reads). History-`.onAppear` prewarm stays (harmless, helps Manual).

**Prompts (pinned instructions, test-locked like v2 was).**
- Light: `"Remove filler words (um, uh, like, you know) and fix grammar and
  simple punctuation. Preserve the meaning exactly. Write as the speaker
  would: casual stays casual, formal stays formal. Keep the same language.
  Output only the cleaned text, no commentary."`
- Medium: Light + `" You may lightly reword for clarity and conciseness, but
  change nothing substantive."` (one sentence of extra license — the entire
  difference between the levels).
- Token cap: existing scaled cap reused (`min(512, max(128, count/2 + 64))`)
  — Light outputs are short by construction; Medium uses the same cap (no new
  tuning without matrix numbers).

**Exact file changes:**
1. `Oto/Services/WritingPolishService.swift`: `CleanupLevel: none | light |
   medium` (+ `Equatable` explicit, `Sendable`); `CleanupBehavior` (enabled +
   level, `current(defaults:)` with absent-key ⇒ Light default, unknown-string
   ⇒ None/fail-safe + test); `CleanupSettings` keys (`app.Oto.cleanupEnabled`
   — NEW key so the old `intelligenceEnabled` can migrate cleanly — plus
   `app.Oto.cleanupLevel`); `streamCleanup(_:level:)` on the protocol (level
   selects instructions; default arg keeps old call sites compiling during the
   migration); live impl level→instructions + existing scaled cap; fake
   per-level scripted chunks (tests assert Light vs Medium prompts differ);
   `cleanupVisible`-style helper if the pane needs it. Migration helper:
   `migrateLegacyMode(_:)` (old `.manual`→None, `.upgrade`→Light,
   `.automatic`→Medium — one-shot, tested) OR clean default if legacy absent.
2. `Oto/Coordinator/DictationCoordinator.swift`: delete `maybeUpgradePolished`
   + `upgradeWindowSeconds` + `inputClock`/`noteInput` wiring iff no other
   caller needs it (verify: `dispatch.setInputClock` call site in `OtoApp` —
   remove both together or keep the clock only if a live consumer remains;
   no orphaned wiring); add pre-insertion cleanup race in `finalizeSession`
   (session-ID discipline unchanged — every `await` re-checks identity;
   detached-task precedent NOT reused here because the race is *inside*
   finalization before insert, so a parked stream must never wedge finish —
   use `withThrowingTaskGroup` / `withTimeout` structured race, cancel on
   timeout); `autoCleanupTimeout` constant (3.0s starting value); prewarm on
   `begin()` (gated: behavior enabled + `polish.availability() == .available`
   — both sync, no prompt, no download); `lastPolish` + `revertLastPolish`
   + `canRevertPolish` UNCHANGED (Revert still pastes raw via `replaceLast` —
   the only surviving `replaceLast` caller on the dictation path).
3. `Oto/Services/TextInsertionService.swift` + `RealTextInsertion.swift`:
   NO changes (`replaceLast` stays exactly for Revert). Any test referencing
   swap-only `replaceLast` flows is updated to Revert flows.
4. `Oto/Storage/HistoryStore.swift` + `HistoryEntry`: add
   `rawText: String? = nil` + `wasCleaned: Bool = false` (both optional with
   defaults ⇒ old JSON decodes; CodingKeys pinned by test — adding keys is a
   privacy decision recorded here: raw text is the user's own dictation, same
   class as finalText, same bounds/caps/retention/deletion); `record(finalText:rawText:wasCleaned:bundleID:)`
   (new params defaulted so old call sites compile; trims + caps both texts;
   no-op when history off — unchanged); `undoCleanup(id:)` (sets
   `finalText = rawText`, clears `rawText`/`wasCleaned`, persists — the
   History-side Undo AI edit).
5. `Oto/Settings/IntelligencePane.swift`: rework to Whisperflow-readable —
   status card (unchanged mapper copy), master toggle (NEW cleanup key, with
   one-shot migration from the old key), `Auto Cleanup` segmented
   (None/Light/Medium with one-line descriptions + the Whisperflow-grade
   example pair: raw `"hey joey, we still on for coffee or? … um be traffic"`
   → Light vs Medium — static strings, not live model output), `Transforms`
   card pointing at E2 ("Polish via Opt+1 — coming in the next slice" placeholder
   row ONLY if E2 ships in the same release; otherwise no dead rows — the pane
   shows exactly what exists). Old Manual/Upgrade segmented + `intelligenceMode`
   pref removed (migration covers stored values).
6. `Oto/Settings/HistoryPane.swift`: row actions gain `Undo AI edit` (visible
   iff `entry.rawText != nil`; calls `history.undoCleanup(id:)` + feedback
   line); `Clean up` (Manual `PolishSheet`) STAYS for v1 (it is the judging
   rig for prompt changes + the fallback when Auto is None/off — removal is
   an E2+ decision with matrix evidence, not this slice).
7. `Oto/Settings/PolishSheet.swift`: instructions caption gains level tag
   ("Cleaned with Light in 1.4s · 38 words" — caption helper extended, pure,
   tested); NO behavior change otherwise.
8. `Oto/App/OtoApp.swift`: launch prewarm (gated) + coordinator `begin`
   prewarm path needs no new wiring (coordinator holds `polish` already);
   REMOVE `dispatch.setInputClock` iff the clock dies with the swap (see #2);
   nothing else.
9. `Oto/UI/OtoMenuBarView.swift`: unchanged (Revert row already correct).
10. Grep-gate comments: PCC ban + `fm` ban comments move with the service edit
    (same wording, same gate pattern as `SpeechAssetPreparer`).

**Tests (all real, no Console, no TCC):**
- `CleanupBehavior.current`: absent keys ⇒ (enabled, Light); unknown level
  string ⇒ None-safe; legacy migration table (manual→None, upgrade→Light,
  automatic→Medium).
- Mapper truth-table unchanged (every reason covered) + level→instructions
  table (Light prompt ≠ Medium prompt; both contain meaning-lock + same-
  language + output-only; Medium contains the clarity-license sentence).
- Coordinator: None/disabled/unavailable ⇒ `insert` called with raw,
  `replaceLast` NEVER called, `lastPolish` nil; Light fast-polish ⇒ `insert`
  called with polished (once — assert `insert.calls.count == 1` and
  `replaceCalls.isEmpty`); slow-polish (fake gate parked past timeout) ⇒ raw
  inserted, stream cancelled, nothing stored; polish-error/empty/identical ⇒
  raw inserted; cancel-during-cleanup ⇒ nothing inserted (cancel-wins,
  identity re-check); secure-field/untrusted ⇒ existing refusal tables
  unchanged (cleanup never bypasses gates — it only changes *what* inserts).
- History: record with raw round-trips both texts; old JSON (no new keys)
  decodes with nils; `undoCleanup` swaps + clears + persists; off ⇒ no-op
  (both texts); caps apply to both; no-persistence extended (polish run
  writes no new file content beyond the entry itself).
- Sheet caption: level tag formats (pure test, no timings asserted).
- Full-suite regression: insertion path for None == today's app byte-identical.

## Slice E2 — Three transforms (Opt+1/2/3) + responsive work pill + Settings listing

**Mechanics (explicit, user-fired, selection-scoped).**
1. Three global hotkeys, defaults `Opt+1 / Opt+2 / Opt+3` (Carbon combos — no
   AX needed to *receive* them; `ShortcutTrigger.Kind.combo(modifiers: option,
   keyCode: 18/19/20)`). Press ⇒ snapshot frontmost app/pid (target-capture
   vocabulary, captured synchronously at press — never re-resolved later),
   grab selection via synthesized `Cmd+C` (new `SelectionGrabber` seam:
   snapshot clipboard → post `Cmd+C` through the existing HID `postPaste`-
   family route (new `postCopy` event on `InsertionEvents`, same 4-event
   construction, `C` key) → read string → restore-or-keep clipboard by
   ownership), refuse-first rules (untrusted / no pid / secure field / empty
   selection / Oto-frontmost ⇒ abort: menu/status line, never the pill;
   clipboard restored).
2. Transform = `streamCleanup(selection, preset:)` with per-preset pinned
   instructions (test-locked, judged in matrix):
   - Polish: `"Improve clarity and conciseness. Preserve the meaning exactly.
     Same language. Output only the rewritten text, no commentary."`
   - Concise: Polish + `" Shorten substantially: cut redundancy, keep every
     fact and number."`
   - Professional: Polish + `" Lift the tone to work-ready: direct, polite,
     confident. Change nothing substantive."`
   Bounded (6s starting value — selection jobs are user-waited, so a longer
   honest bound than auto; matrix-tunes). Timeout/error/empty ⇒ selection
   untouched, clipboard restored, menu-grade note only.
3. Replace: `insert`-vocabulary `Cmd+V` over the still-selected range (the
   selection from step 1 is still selected — no select-all needed) via the
   existing `postPlacedText` tail (write-verify, frontmost-PID race guard,
   trust re-gate, guarded restore). Undo: native `Cmd+Z` works (it is a normal
   paste), PLUS menu `Revert` if we store last-transform (defer unless free —
   native undo is the primary path here, unlike dictation).
4. Shortcut ownership: new `TransformDispatch` (or 3rd/4th/5th slots on
   `ShortcutDispatch` — implementer picks the smaller diff that keeps the
   two-slot dictation invariants untouched; the plan pins behavior, not the
   struct name): registers all three combos at launch (persisted keys
   `app.Oto.transformShortcut.polish/concise/professional`, defaults
   Opt+1/2/3, each re-recordable via the existing recorder UI);
   suspended while a dictation session is live (transforms never interleave
   with recording — press during recording is ignored, tested). Every save
   passes the §Conflict policy gate (Rules A+B across all five purposes —
   the strengthened `Kind.conflictsWith` + `enabledSystemShortcuts` +
   recorder `describe`); transform-chip staging previews against the other
   four slots' effective values and shows the `Already in use by …` advisory
   inline (modal `refreshAdvisory` pattern reused, no cross-family Swap —
   message + `Reset to defaults` only). Fresh-install defaults MUST satisfy
   the policy (pinned: assert no pair among right-Cmd hold + unassigned
   hands-free + Opt+1/2/3 conflicts). `Reset to defaults` restores all three
   transform shortcuts (tested) — dictation defaults reset stays in the
   Shortcuts modal as today.
5. Work-state publishing (pill feed, NOT dictation state): whoever runs the
   work (coordinator cleanup branch for `Cleaning up`, `TransformRunner` for
   `Using <Preset>`) publishes a lightweight `currentWork: WorkLabel?`
   (`nil` idle, `.cleaningUp`, `.preset(name)`). The controller reads it each
   poll next to its existing `recoveryText()` read — `DictationState`,
   `FlowBarState.project()`, and the coordinator state machine are untouched.

**Pill design (the screenshot, built to fit).** New `PillVisual.work`
(joint layout, not a reuse of `.message` or `.dotsSpinner`):
- Content: working-text left (`Cleaning up` / `Using Polish` / `Using Concise`
  / `Using Professional`), thin vertical divider, native spinner right
  (existing `NSProgressIndicator`, forced dark appearance — already correct on
  the near-black pill). Text: 12pt system, white/muted-white, truncating-tail.
- Width: MEASURED per label, not table-fixed. Pure helper
  `VisualizerMath.workPillWidth(for:text, font:)` =
  `ceil(textWidth) + padding×2 + dividerGap×2 + dividerWidth + spinnerGap +
  spinnerSize`, clamped to `[workMinWidth, workMaxWidth]` (starting values 120
  / 260, matrix-tunes from screenshots; longest label `Using Professional`
  must fit untruncated at default font size — assert in test with the real
  font metrics). Beyond max: truncating-tail (never overflow — v5 F1
  `masksToBounds` + `clipsToBounds` precedent stays).
- Motion: width changes ride the EXISTING paths — `FlowBarPanel.show/resize`
  AppKit frame animator (`snapDuration` easeOut) + `PillContentView.layout`
  0.15s bg-path morph. No new animation, no new timing constant. The pill
  expands when work starts and contracts when it melts out — the "sweets/
  responsive" feel is the existing liquid-chrome path fed a new width.
- Lifecycle: work visual shows while `currentWork != nil`, melts out on
  completion/failure/cancel exactly like every transient (adoption/park +
  `scheduleHide` paths reused; controller-owned latch, same pattern as the
  `message` latch — the coordinator owns no pill state). Errors NEVER render
  (house rule — failure melts to hidden, menu/status owns the words).
- Reduced motion / transparency: spinner hidden + static label when
  `accessibilityDisplayShouldReduceMotion` (existing `motionFrozen` contract);
  no shadow/plate changes (existing panel recipe untouched).
- Controller precedence: `workText != nil` overrides the state visual for
  finalizing/inserting/hidden (cleanup runs inside finalizing — the dots give
  way to the words). Recording/starting never show work (transforms are
  suspended while recording; cleanup never runs while recording).

**Settings IA (Intelligence pane — everything listed, everything tunable).**
One pane, four cards, top to bottom, zero dead rows:
1. `Apple Intelligence` status card (unchanged mapper copy: Ready / turn-on
   guidance / preparing / not-supported) + master `Opt in` toggle (one switch
   for all Intelligence; off = today's app exactly, zero model contact; flips
   hide every dependent row via existing `.disabled` + opacity pattern — no
   dead controls).
2. `Auto Cleanup` card: `None / Light / Medium` segmented (existing
   `OtoSegmented` pattern) with one-line descriptions (None: "Exact words,
   always"; Light: "Fixes fillers and grammar automatically"; Medium: "Also
   tightens for clarity") + static example triplet (raw
   `"hey joey, we still on for coffee or? … um be traffic"` → Light →
   Medium — static strings, not live output) + microcopy "Applies to every
   dictation. Your original words are never lost — Undo AI edit in History."
3. `My Transforms` card: three rows, each = name + one-line description +
   shortcut chip (`Opt 1` style, existing `OtoKey` chip) that re-records
   through the existing modal machinery (conflict guidance included) +
   `Reset to defaults` footer. Rows render ONLY for shipped presets (three
   here — if a preset ever unships, its row goes with it; the rule that
   deferred the Slice-A picker).
4. Footnote (existing copy, kept): "On-device only — transcripts and prompts
   never leave this Mac."
   Accessibility: every row is a native control with a VoiceOver label
   (`Preset Polish, shortcut Option 1, activates recorder` pattern); chips are
   buttons (keyboard-activatable, not tap-only); segmented + switches are the
   existing `OtoSwitch`/`OtoSegmented` (no custom toggles per product rules);
   full keyboard path (Tab to chip, Space to re-record, Escape cancels —
   recorder already supports Escape-to-cancel).

**Exact file changes:**
1. `WritingPolishService.swift`: three preset instruction sets (pinned above)
   + `streamCleanup(_:preset:)` / level-param extension (implementer picks;
   tests pin each preset prompt contains its license + shared meaning-lock +
   same-language + output-only); `TransformPreset: polish | concise |
   professional` enum (explicit `Equatable`, `Sendable`); `presetName` for the
   pill (`"Polish"` etc. — pill text is `"Using \(name)"`, pure + tested).
2. New `Oto/Services/SelectionGrabber.swift` (protocol + live + fake):
   `grabSelection(frontmostPID:) -> String?` (clipboard snapshot → `postCopy`
   → bounded read → restore decision; ALL refusal reasons enumerated, all
   fail-closed with clipboard restored; NEVER logs content).
3. `InsertionEvents`: add `postCopy` (`Cmd+C` 4-event, same construction as
   `postPaste` with `kVK_ANSI_C`); `RealTextInsertion`: `replaceSelection(_:into:)`
   (reuse `readyPID` + `postPlacedText` tails; NO undo step — the selection is
   still selected, plain `Cmd+V` overwrites it; context `.replaceSelection`
   gets its own honest failure words).
4. Transform runner: new `TransformRunner` actor (or coordinator extension —
   implementer picks; constraint: NEVER touches dictation `state`; owns its
   task lifetime for the pill latch + cancellation on second press /
   app-switch / toggle-off) + publishes `currentWork`.
5. Coordinator: E1 cleanup branch publishes `.cleaningUp` for its duration
   (set before the race, cleared after — `defer`, session-ID-checked);
   prewarm paths unchanged from E1.
6. Shortcuts: `TransformDispatch` (or extended `ShortcutDispatch`): three-combo
   registration (Carbon path), suspend-during-recording, §Conflict policy
   gate on every save (Rules A+B, five purposes), persistence + migration
   (absent ⇒ Opt+1/2/3), `Reset to defaults`.
7. Conflict policy core (`Oto/Models/ShortcutModels.swift`): `Kind` gains a
   family helper (hold code / combo mask → modifier family via the existing
   `ModifierHoldState.flag(for:)` ↔ `carbonMask` mapping); `conflictsWith`
   extended with Rule B (same-family hold-vs-combo across purposes conflicts;
   sibling transform combos with different keyCodes explicitly allowed);
   purpose display names (`Push to talk`, `Hands-free`, `Polish`, `Concise`,
   `Professional`) + `Already in use by …` / `Too similar … both use …`
   message builders (pure, tested — copy lives next to the rule, never
   scattered in views). Existing tests asserting hold-vs-combo non-conflict
   FLIP to the new rule (listed deliberately — no silent test edits).
8. Defaults + staging: `DualShortcutConfiguration.default` + `defaultHoldToTalk`
   move to Right Command (fresh installs); `SlotKindChoice` hold-key preset
   stages Right Command; `ShortcutStaging.donePreview` generalized or a new
   five-slot staging type previews transform chips vs the other four slots;
   `validate()` load-time advisory for grandfathered violating pairs
   (non-blocking, data-preserving).
9. UI copy: `ShortcutModal` (`refreshAdvisory`, `applyDone`, Swap stays
   hold↔hands-free only) + `OnboardingView` `.blocked` branch adopt the new
   wording; `IntelligencePane` transform rows show the inline ⚠ advisory
   (existing wash-pill pattern) + per-row recorder + reset.
10. Pill: `PillVisual.work` + `forState` stays total (work is controller-
   latched, never state-mapped — same as `.message`); `PillContentView` gains
   divider layer + joint label/divider/spinner layout + `update(workText:)`
   path; `VisualizerMath.workPillWidth` (pure, tested) + clamp constants;
   `FlowBarProjection` gains `workText: String?` (controller-composed, not
   `project()`-derived); `FlowBarController.pollOnce` reads `currentWork`,
   overrides visual + dynamic width, owns latch + melt-out.
8. `IntelligencePane`: four-card layout above (status + Opt-in, Auto Cleanup,
   My Transforms ×3 + reset, footnote); old Manual/Upgrade segmented +
   `intelligenceMode` pref removed (E1 migration covers stored values).
9. `OtoApp`: construct + wire runner/grabber/dispatch/pill feed; nothing else.
10. `OtoMenuBarView`: unchanged (Revert row already correct).
11. Old "combo wins by construction" doc comment (`ShortcutModels.swift:132-145`)
    rewritten to the Rule A/B policy (stale theory must not survive beside the
    new gate).

**Tests:** grabber refusals (untrusted/secure/empty/Oto-frontmost ⇒ nil +
clipboard byte-identical); replace-selection refuses on frontmost-mismatch /
revoked trust / secure field (clipboard untouched, fail-closed); press-during-
recording ignored (no grab, no stream); unknown stored preset/shortcut ⇒
no-op (same future-proof rule); pill: `workPillWidth` pins all four labels fit
untruncated + clamps at max (headless, real font metrics) + truncation never
overflows; projection override (work beats finalizing dots; recording never
shows work); latch melts on success/failure/cancel (controller tests, no
window); per-preset prompt pins (each contains its license + shared locks);
conflict policy: Rule A exact-dup table (all five purposes) + Rule B family
matrix (Option/Command/Control/Shift hold vs same-family combos blocked both
directions; left/right sides grouped — family-level; fn-hold vs combos never
conflicts; sibling Opt+1/2/3 allowed; unassigned never conflicts; double-tap
has no kind and never participates); message-builder table (purpose names +
modifier names render); staging preview (staged transform combo vs live
dictation pair ⇒ `.blocked` + advisory text; staged sibling digit ⇒ allowed);
dispatch gate (transform save vs violating hold ⇒ `.blocked`, old trigger
kept); fresh-defaults assertion (right-Cmd hold + unassigned hands-free +
Opt+1/2/3 ⇒ zero conflicts — pins the default move); load-time `validate`
(grandfathered violating pair ⇒ advisory, values preserved); reset-to-defaults
round-trip (all three + dictation); no-persistence (transform writes
no history/file); offline (transform streams with networking disabled —
same on-device proof as Manual).

## Verification (both slices)

- [ ] Build green; grep gates (PCC 0, `fm`/`fm respond`/`fm serve` 0, prompt
  traces in history/notification/log strings 0, no new `Timer`/polls/logging-
  above-debug/unwraps in prod)
- [ ] New unit tests green isolated + full `xcodebuild test -scheme Oto`
  calm (known focus-environmental trio excluded only if identical to the
  pre-change baseline and green in isolation)
- [ ] Matrix E1 (user, live): Dictation in TextEdit + 2 real apps with Light:
  raw messy speech (`"um so I was like thinking we should uh probably meet
  tomorrow"`) inserts cleaned in one step — no visible swap, ever; None-level
  == today's app exactly; Medium on the same sentence is visibly clearer than
  Light; master-off == today's app; secure field never transforms (raw kept);
  offline (Wi-Fi off) dictation + cleanup both work; timings read from Manual
  sheet captions per entry length (no Console); over-context/long dictation
  (2+ min) degrades to raw silently (7c question answered with data: does E1
  alone cover longform acceptably?).
- [ ] Matrix E2 (user, live): select a messy paragraph in 2 real apps →
  `Opt+1` → pill expands to `Using Polish` + divider + spinner → selection
  replaced with cleaner text; `Opt+2`/`Opt+3` ditto with their labels;
  `Cmd+Z` restores; press with empty selection / in password field /
  during recording ⇒ nothing happens (and nothing lost); offline works;
  re-recorded shortcut fires, conflicting shortcut refused with guidance.
  Conflict check: stage an Option-hold for Push-to-talk while Polish sits on
  Opt+1 ⇒ refused with the `Too similar … both use Option` text (nothing
  saved); stage Opt+1 for Polish while Opt+2 sits on Concise ⇒ allowed; on a
  fresh profile (right-Cmd hold + Opt+1/2/3) press each transform with EITHER
  Option side ⇒ transform only, never a dictation flash.
- [ ] Eyes-on per slice: Intelligence pane reads like the screenshots'
  promise (status line honest, None/Light/Medium instantly legible,
  My Transforms lists all three presets with live shortcut chips, full
  keyboard + VoiceOver pass); pill screenshots per label (`Cleaning up`,
  `Using Polish/Concise/Professional` — divider visible, spinner spinning,
  no clip/overflow, expand/contract animation smooth, reduced-motion static);
  History `Undo AI edit` restores raw; menu Revert works for the
  just-inserted dictation; no dead controls anywhere.

## Risks

- Selection-grab via synthesized `Cmd+C` disturbs the clipboard by design:
  contained by snapshot + ownership-verified restore (existing discipline),
  but a user copy landing mid-grab wins and aborts the transform (correct:
  user data beats ours — tested, messaged as "selection changed, nothing
  done"). If matrix shows real-app annoyance, the recorded alternative is an
  AX selected-text read spike — NOT built in this plan.
- Pre-insertion cleanup adds bounded latency to every AI-on dictation (the
  honest Whisperflow trade). Contained by: Light default (shortest job),
  prewarm-while-speaking, scaled cap, 3s bound, None escape hatch, Release-vs-
  Debug note in matrix. If E1 matrix says Light still feels slow, the next
  lever is prompt-shortening + cap-tightening from measured captions — never
  a return to post-insert swapping.
- `replaceLast` survives for Revert only: its undo-step risk (unverifiable
  undo top) is now confined to an explicit user-pressed Revert within one
  dictation of the swap — the strictest, most comprehensible window it ever
  had. No auto path can invoke it.
- Opt+number combos may collide with real apps (browsers, IDEs use them):
  Carbon registration fails closed with guidance (existing calibration UX),
  and each shortcut is re-recordable. Matrix must include the user's actual
  Opt+1/2/3 consumer apps — three combos triple the collision surface vs one.
  Separate from this: same-family bindings across OTO purposes are now refused
  by policy (§Conflict policy) regardless of app collisions.
- Default hold key moves Right Option → Right Command (Rule B forces it —
  factory defaults must satisfy the policy). Contained by: fresh-installs
  only, stored configs never silently migrated (load-time advisory instead),
  all pinning tests move together (mechanical), onboarding/modal copy updated
  in the same slice. If matrix says Right Command feels wrong as a hold key,
  the fallback is fn-hold default — but that kills double-tap-to-hands-free
  by default (fn taps belong to macOS), so Command stays the pick.
- Grandfathered violating pairs (stored before this policy, e.g. an Opt-combo
  hands-free under an Option hold) keep today's behavior — still double-fire
  prone — but are now NAMED by the load-time advisory instead of silent. No
  silent data change, ever; the user clears or re-records by choice.
- Dynamic pill width adds a layout path beside the fixed table: contained by
  measuring once per label (pure helper, headless-tested with real font
  metrics), clamping to [120, 260], and reusing the existing frame animator +
  bg-morph (no new motion). If matrix screenshots show expand/contract jank,
  the lever is width-quantization (round to 4pt steps), never a new animator.
- History schema addition (`rawText`, `wasCleaned`) is a privacy-shape change:
  same data class as existing transcripts (user's own dictation, same caps,
  retention, deletion), no audio/partials/clipboard/app-content/prompt traces
  — but it is called out here deliberately so review sees it.

## Deferred (named, not built, with the reason)

- Custom prompts / `Create your own` free-text prompt box: needs prompt
  storage, safety review, per-preset shortcut + conflict UX, and quality
  judgment per user-written prompt (untestable by us). Ship three excellent
  fixed presets before a shelf of unjudged custom ones; revisit only with
  matrix evidence that fixed presets aren't enough.
- `Auto Apply After Dictation` (screenshot's dropdown + OFF toggle): with Auto
  Cleanup covering the auto case, this is a second auto path competing for
  the same moment. Revisit only if E1+E2 matrix shows users wanting full-Polish
  on every dictation (evidence, not symmetry).
- `Opt+O to view changes` diff view: needs diff UX + per-word revert design
  (the old option-3 inline-diff idea). Undo AI edit covers the need at 1/10th
  the surface.
- 7c notify-when-ready for longform: E1's timeout-to-raw may already be the
  acceptable longform behavior (raw stands, Manual polishes later). Build it
  only if E1 matrix shows long dictations hurting.
- Double-press raw↔polished toggle: already rejected (hijacks double-tap
  semantics) — stays rejected.
- Automatic/wait-then-insert as a *mode*: E1's bounded pre-insertion cleanup
  IS the honest version of it (one bound, one behavior, no picker). The old
  three-mode picker does not return.

## Open questions (plain words, recommendations marked)

1. **Cleanup default: Light?** Three choices in plain terms: None (exact words
   always — today's app), Light (fillers + grammar fixed automatically —
   my pick), Medium (also tightened up — more rewriting, slightly slower).
   *Recommendation: Light.* It is the screenshot's selected card, the fastest
   AI job, and the smallest surprise for existing users. Medium is one tap
   away for people who want it.
2. **How long may Auto Cleanup wait before giving up and inserting raw?**
   Plain terms: after you stop speaking, the app may hold your text briefly
   to clean it. Too short = long sentences never get cleaned; too long =
   every dictation feels delayed. *Recommendation: 3 seconds, then raw.* The
   old 2s window was tuned for post-insert swapping; pre-insertion deserves
   one honest second more because there is no second chance — and missing it
   is invisible (raw inserts, nobody waits longer than 3s, ever).
3. **Should the old Manual `Clean up` button stay in History?** Plain terms:
   keep the per-entry Clean up sheet (streaming preview + Keep/Use-original)
   alongside Auto Cleanup, or remove it now that cleaning is automatic?
   *Recommendation: keep it for v1.* It is the prompt-judging rig (every
   instruction change is judged there first), the fallback when Auto is None/
   off, and the only preview surface. Removal is an E2+ decision with matrix
   evidence.
4. **Polish shortcut default: Opt+1?** Plain terms: which keys fire the Polish
   transform out of the box. *Recommendation: Opt+1, re-recordable*, matching
   the screenshot and the Carbon combo path (no Accessibility needed to
   receive it). If your actual apps eat Opt+1, the matrix will say so and the
   default moves — the recorder + conflict guidance already handle that.
   Same pattern for Concise Opt+2, Professional Opt+3.
5. **Preset trio: Polish / Concise / Professional?** Plain terms: the three
   rewrite buttons. Polish = clearer + conciser (the safe all-rounder);
   Concise = shorter, facts kept (for long rambles); Professional = work-ready
   tone (for messages to people you impress). *Recommendation: these three.*
   They cover the screenshot's "alter the sentences" need with zero
   configuration, and each is one tap away. The alternative — slot 3 as
   `Create your own` custom prompt — needs prompt storage + safety review and
   ships unjudged; take it only if you type custom instructions more than you
   press tone buttons.
6. **Pill wording: `Cleaning up` and `Using <Preset>`?** Plain terms: the words
   inside the working pill. *Recommendation: exactly those* — `Cleaning up`
   while Auto Cleanup runs, `Using Polish` / `Using Concise` /
   `Using Professional` while a transform runs. Same shape (text + divider +
   spinner) both times, so one glance always means "the model is working".
   If `Cleaning up` ever feels noisy on every dictation, the fallback is dots
   only for cleanup (screenshot shape kept for transforms) — matrix decides.
7. **Refuse similar shortcuts + move default hold to Right Command?** Plain
   terms: today the app lets you save an Option-hold for talking and an
   Opt-combo for something else, and pressing either fires both (a stuck
   recording plus the other action). The plan refuses such pairs with
   `Already in use by …` / `Too similar … both use Option`, and moves the
   fresh-install hold key to Right Command so the out-of-box setup obeys its
   own rule. *Recommendation: yes to both.* Double-tap stays exempt (same
   purpose, your call), sibling Opt+1/2/3 stay allowed (different digits, no
   double-fire), stored setups are never silently changed (advisory only).
   The only alternative — keeping Right Option as default — ships the new
   transforms broken-by-default for right-side typists, so it is not really
   an alternative.
