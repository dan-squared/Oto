# Phase 7 first action: Clean up (Apple Intelligence post-transcript layer)

## Goal

Ship exactly one Intelligence feature — **Clean up** (grammar + filler removal,
meaning-preserving, same language) — as a frictionless native layer: one tap,
streaming preview, Keep / Use original, raw transcript never overwritten, and
ordinary dictation provably unaffected when Intelligence is unavailable.

User ask: implement the recommended first action, meticulously, against the
latest SDK docs; plus answer whether enabling the model needs a CLI `fm`
command + terms agreement.

## Spec sources

- `Docs/START_HERE_PRODUCT.md` Phase 7 + Intelligence rules (canonical):
  post-transcript only, finalized text only, reversible draft, never on the
  mic/insertion path, unavailable ⇒ dictation still works, one feature at a
  time with availability explanation + offline test, never overwrite raw
  without preview/undo, never store prompt traces.
- Local SDK truth (this session, `MacOSX27.0.sdk` swiftinterface — never memory).
  Deployment target 27.0 ⇒ no `#available` needed (APIs below are macOS 26+/27+).

## Facts verified against the local SDK (this session)

| Fact | Evidence (swiftinterface) |
|---|---|
| Entry point | `SystemLanguageModel` — `Sendable` class, `Observable`; `static .default` (session `init(model: .default, …)` default arg) |
| Gate | `var availability`, `var isAvailable: Bool`; `enum Availability`: `.available` / `.unavailable(UnavailableReason)`; reasons incl. `deviceNotEligible`, `appleIntelligenceNotEnabled`, `modelNotReady` |
| Session | `LanguageModelSession(model:instructions:tools:)` — plain-`String` instructions overload exists; `Transcript`-based init exists (v1 doesn't need it); **no tools** (empty default — v1 passes none) |
| Streaming | `streamResponse(to: String, options:) -> ResponseStream<String>`; `ResponseStream` is an `AsyncSequence` — tokens render progressively |
| Prewarm | `session.prewarm(promptPrefix:)` exists — warm while the preview surface is already open (same precedent as the catcher prewarm) |
| Determinism knobs | `GenerationOptions.temperature`, `.maximumResponseTokens` — v1 pins low temperature + a tight token cap (short cleanup, fast finish) |
| Guided output | `GenerationSchema` exists — v1 does NOT need it (plain `String` in/out); recorded as rejected |
| Cloud ban | `PrivateCloudComputeLanguageModel` exists in the same framework — v1 must never reference it (on-device only, product boundary) |
| Scope | `UseCase.general` default; `.contentTagging` exists — v1 uses `.general` (cleanup is open text, not tagging) |

## The `fm` CLI / terms question — RESOLVED (verified, not assumed)

- `fm` exists on this Mac (`/usr/bin/fm`, `man fm`): "command-line interface
  for Apple Foundation Models" with `respond | chat | count-tokens | schema |
  serve | available | license` subcommands. `license` = "Show and agree to the
  Legal Notice & Terms".
- **Users do NOT need the CLI or its terms.** That license is machine-wide
  (`sudo`), gates the CLI itself only, and is not a prerequisite for the
  framework path. The correct consumer path is the Swift Foundation Models
  framework (§Facts above) — same on-device ~3B model, no Terminal, no sudo.
- User-side requirements are exactly the availability reasons: eligible
  device + Apple Intelligence enabled + model present (same bar as any
  Apple Intelligence feature).
- Developer-side obligation (not a user click-through): Apple's Acceptable
  Use policy for the framework (no prohibited content, no guardrail
  circumvention). The v1 narrow cleanup prompt stays inside intended use
  (rewriting/extraction class).
- **Explicit ban (new):** the app must never shell out to `fm respond` /
  `fm serve` — that would trip the CLI's "no programmatic access except as
  expressly permitted" clause AND force the admin-license step on every
  machine. Enforced with a grep gate (`/usr/bin/fm`, `fm respond`,
  `fm serve` → 0 hits in `Oto/`), same pattern as the existing
  `downloadAndInstall` and PCC gates.
- Machine fact (this session, read-only — no license agreed, no sudo run):
  `fm available` → **"System model available"**. So this dev machine can run
  the Matrix A probe today, and `fm available` doubles as the matrix's
  independent cross-check against the in-app `availability` value.

## Latency design (frictionless, native-fast)

- Prewarm the session when the preview surface appears (model already resident
  when the user taps Clean up) — costs memory only while visible + available.
- `streamResponse` renders tokens as they arrive: perceived latency ≈ instant;
  typical on-device first token is sub-second on Apple Silicon with total time
  ~1–2 s for short cleanups. **Exact numbers are matrix-measured on the user's
  Mac (chip-dependent) — the plan records them, never invents them.**
- Tight `maximumResponseTokens` cap: cleanup outputs are short by construction,
  so generation finishes fast and can't ramble.
- Cancel is first-class: dismissing the preview cancels the stream task (same
  idempotent-teardown discipline as the coordinator); no orphaned tasks.
- Zero main-thread work per token beyond appending text (actor-owned draft,
  UI reads on MainActor — same relay pattern as the audio path).

## Surfaces (deliberately narrow)

- **v1 surface = History rows only.** A Clean up action per transcript entry →
  sheet with streaming draft → Keep (copies polished text to clipboard; the
  entry keeps the raw) / Use original (dismiss, nothing written). Rationale:
  history entries are stable + preview-friendly; the signed-off V6 catcher
  layout (`NoTargetModal.swift:389-400` footer math) is NOT churned; the
  dictation path is untouched by construction.
- **Availability explanation** lives as one History header/footer line when
  unavailable, with per-reason copy: not eligible → hardware/Apple
  Intelligence requirement; not enabled → turn it on in Settings; model not
  ready → still preparing, try later. Never a dead button.
- **Explicitly v2 (not this plan):** catcher integration, second action,
  per-entry replacement, any shortcut/trigger for polish.

## Exact file changes

1. **New `Oto/Services/WritingPolishService.swift`** — `PolishServing: Sendable`
   protocol (`availability()`, `streamCleanup(_:) -> AsyncStream<String>`) +
   live impl (session with pinned instructions/temperature/token cap; cancel on
   task cancel) + fake (scripted chunks, scripted errors, cancel point).
   Live impl references `SystemLanguageModel` only — grep-gate comment bans
   `PrivateCloudComputeLanguageModel` (same pattern as the
   `downloadAndInstall` gate in `SpeechAssetPreparer.swift:12-13`).
2. **Availability→copy mapper** (pure, in the service file; unit-tested):
   every `UnavailableReason` maps to one honest line; unknown defaults to a
   generic "not available" (never claims knowledge it lacks — same rule as the
   fn-usage probe seam).
3. **History UI** — row Clean up action + preview sheet (streams via the fake
   seam in tests, live in prod; Keep → clipboard, raw entry untouched;
   dismiss → cancel). `HistoryStore.record(_:)` signature untouched; polish
   writes NOTHING to the history file (pinned by test).
4. **`OtoApp.swift` wiring** — construct the service once, pass down the
   existing `SettingsRoot → HistoryPane` chain (same shape as `historyStore`
   today); prewarm hook on preview appear.
5. **No changes** to coordinator, audio, speech, dispatch, insertion,
   onboarding, catcher, menu. The diff must prove this (review gate).

## Tests (must all be real, none placating)

- Mapper truth-table: every reason → exact copy (pins honesty, not literals —
  copy changes are allowed, missing-reason coverage is not).
- Fake streaming: chunks arrive in order; mid-stream cancel stops delivery;
  error surfaces as recoverable failure with raw intact.
- No-persistence: run polish end-to-end (fake) and assert the history file +
  entry list are byte-identical (raw never overwritten).
- Unavailable-hides-action: availability != .available ⇒ no Clean up affordance,
  explanation line present instead.
- Offline test (matrix, networking disabled): prepared-language dictation still
  inserts AND cleanup still streams — the on-device proof. If either needs
  network, the feature does not ship.

## Verification

- [ ] Build green; grep gates (`PrivateCloudComputeLanguageModel` 0 outside
  the ban comment; no new `Timer`/logging/unwraps in prod)
- [ ] New unit tests green in isolation + full `xcodebuild test` (calm machine;
  known focus trio excluded as environmental)
- [ ] Matrix A (user, device): availability probe output recorded; enablement
  path documented (Settings UI and/or — only if proven — the exact CLI +
  terms transcript); first-token/total timings recorded per entry length
- [ ] Matrix B (user, offline): networking disabled ⇒ dictation inserts +
  cleanup streams; re-enable ⇒ identical behavior
- [ ] Eyes-on: History → Clean up → stream → Keep (clipboard has polished,
  entry keeps raw) → Use original (nothing written); unavailable state shows
  the explanation line; airplane-mode run matches

## Risks / deferred

- Model quality variance (over-editing, language drift): mitigated by pinned
  low temperature + meaning-preserving instructions + mandatory preview; matrix
  judges real outputs before ship.
- Prewarm memory cost while preview open: accepted, recorded; never prewarm
  on the dictation path.
- First-token numbers depend on the user's chip: recorded in matrix, not
  promised here.
- Catcher integration, second action, shortcuts for polish: explicit v2.

## Open questions

1. Keep=copies-to-clipboard only, or also offer replace-entry? (Recommendation:
   clipboard only — replacement overwrites raw and needs its own undo design.)
2. Ship the availability explanation line in History even before first use?
   (Recommendation: yes — it teaches the requirement instead of hiding it.)
3. Enablement documentation: RESOLVED — link to Apple's Settings UI only
   (Apple Intelligence on + model present); never re-implement enablement,
   never reference the CLI in user-facing copy. The remaining matrix work
   is confirming it on a clean account (Matrix A2).
