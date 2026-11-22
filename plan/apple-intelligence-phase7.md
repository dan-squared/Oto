# Phase 7 — Apple Intelligence, post-transcript layer

Status: PLAN ONLY. Nothing implemented. Awaiting `execute` + the §5
answers (especially first-slice pick).

Product boundary (canonical: `Docs/START_HERE_PRODUCT.md`
"Intelligence" + "Phase 7"): Apple on-device Foundation Models only
— never Whisper/Parakeet/MLX/GGUF/cloud. Post-transcript layer:
finalized text in, reversible draft out, never on the mic or
insertion path, dictation unaffected when unavailable. One feature
at a time, each with availability explanation + offline tests. Never
overwrite raw without preview/undo. No prompt traces in history.
Sidebar gains `Intelligence` only when the first feature ships.

## 1. SDK facts (MacOSX27.0.sdk, never memory)

- `FoundationModels.framework` present with macOS swiftinterface.
- `LanguageModelSession(model:instructions:)` (+ transcript +
  InstructionsBuilder overloads); 20× `respond` overloads;
  streaming supported (25 stream mentions in the interface).
- `SystemLanguageModel.availability` enum incl: `available`,
  `unavailable`, `deviceNotEligible`, `assetsUnavailable`,
  `unsupportedLanguageOrLocale`, `rateLimited`,
  `concurrentRequests`. Every case needs a UI state — the
  availability explanation the product doc demands.
- Load-bearing constraints from the enum: the model may be
  ENGLISH-ONLY for the user (`unsupportedLanguageOrLocale`),
  may need a download (`assetsUnavailable`), requires an
  eligible device with Apple Intelligence enabled
  (`deviceNotEligible`), and throttles (`rateLimited`,
  `concurrentRequests` → serialize drafts, one at a time).

## 2. Recommended first slice: Cleanup draft

Why this one: smallest blast radius, no taste judgments (no tone),
reversible by construction, useful daily. The session gets fixed
cleanup instructions (fillers, punctuation, truecasing — exact
prompt at implementation, frozen in a test pin so it can't drift
silently). Later queue (doc order, one at a time): tone modes →
list/table structure → summaries/action items → voice edit
commands. Each is its own plan + matrix; none is approved here.

## 3. Architecture (all slices)

- New seam (e.g. `Oto/Services/WritingDraft.swift`): availability
  check → session → streaming `respond` → draft + cancel +
  timeout budget. The model boundary is protocol-injected so tests
  NEVER call the model (offline tests per the doc).
- Trigger is EXPLICIT user action only (button, never automatic):
  raw transcript inserts exactly as today; the draft is offered
  after. Insertion path gains zero branches, zero latency.
- Preview + undo: draft renders beside the raw (recommended:
  catcher, which already owns recovery + copy) with
  Accept-draft / Keep-original. Raw is preserved either way.
- History ban: drafts and prompt traces are never stored
  (test-pinned: history write-path rejects them).

## 4. Slice-1 file changes (sketch — firmed at execute)

1. New intelligence seam (availability mapping incl. every §1
   case → user-facing state; fixed cleanup instructions;
   stream + cancel + budget).
2. Trigger affordance (recommended: catcher draft button —
   needs the §5 design answer first).
3. Preview UI (recommended: catcher side-by-side + Accept/Keep).
4. Tests: availability-case table; seam tests with a scripted
   model (stream chunks, cancel mid-stream, timeout, rate-limit
   mapping); prompt-trace ban test; instruction-literal pin.
   Zero live-model tests (device matrix covers reality).
5. Nothing else: pipeline, insertion, coordinator untouched
   (compiler proves it — no call-site changes).

## 5. Verification (slice 1)

- Build green; full suite green twice (proven flakes excepted).
- Device matrix, packaged Run: English cleanup quality (5 varied
  samples incl. fillers, run-ons, casing); user's non-English
  language (message shown? draft offered? — behavior recorded,
  never assumed); Apple Intelligence disabled (feature hidden
  WITH explanation, dictation untouched); offline/airplane
  (model on-device — works; assets-missing shows download
  guidance); long transcript (budget/chunk behavior); cancel
  mid-stream (instant, no partial paste); rate-limit path (if
  inducible, else code-reviewed).
- Privacy spot-check: history contains raw transcript only.

## 6. Risks

- **Locale is the top risk.** If the user's languages are
  unsupported, slice 1 is English-only with an honest message —
  confirm §5 Q1 before building or scope is fiction.
- **Latency perception.** Streaming + instant cancel required;
  a non-streaming implementation that blocks the UI is a
  reject-at-review defect. Budget pinned in tests.
- **Assets download.** `assetsUnavailable` must explain + deep-link,
  never spin silently. Verify on a machine without the model.
- **Prompt drift.** Instructions frozen as a test-pinned literal;
  any wording change is a deliberate diff, never drive-by.
- **Scope creep into the critical path.** Any proposal to
  auto-enhance before insertion violates the product doc — refuse
  it in review, regardless of demo appeal.
- Out of scope: second speech engine (banned list stands),
  cloud anything, sidebar page (appears WITH slice 1, not before),
  voice commands, modes beyond cleanup.

## 7. Open questions (answer to unlock execute)

1. First slice = cleanup draft? (recommended) or jump the queue?
2. Which languages do you dictate? (determines locale testing +
   whether slice 1 serves you day one.)
3. Preview home: catcher side-by-side? (recommended — owns
   recovery/copy already) or elsewhere?
4. Trigger: per-session button after insert? (recommended — zero
   insertion risk) or pre-insertion pause?
