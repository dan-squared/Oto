# Phase 9 — Custom transform prompt ("Create your own") — verified plan

Status: planning finished, no code touched. Re-verified 2026-10-09 via
Xcode ACP against the merged tree (`83cc7ec`) — every reference below
was read this session, never recalled.

## Goal

One user-defined transform preset: the user writes their own rewrite
instruction (e.g. "rewrite as 3 bullet points", "translate to German"),
names it, fires it on selected text in any app with its own shortcut
(factory `Cmd+4`), and the pill + Settings treat it exactly like the three
fixed presets. No second auto path, no diff view (both stay deferred).

Plain-words behavior when done:

1. Settings → Intelligence → My Transforms gains a 4th row: Name field +
   instruction editor + shortcut chip (`Cmd+4` factory) + Reset.
2. User writes instruction, selects text in any app, presses the shortcut →
   pill shows the custom working label + spinner → selection replaced.
3. `Cmd+Z` in the target app restores (same as fixed presets). Empty
   instruction / empty selection / unavailable model / disabled master
   toggle → nothing happens, silently (existing transform contract).

## Spec sources (canonical first)

- `Docs/START_HERE_PRODUCT.md` (canonical on conflict): Intelligence is a
  post-transcript layer, `SystemLanguageModel` only, reversible drafts, raw
  preserved, never on the mic/insertion path; one native Settings scene;
  History never stores prompt traces; coordinator owns session state.
- `plan/phase-7d-whisperflow-rework.md` §Deferred: custom prompts deferred
  for "prompt storage + safety review + per-preset shortcut/conflict UX +
  quality judgment per user-written prompt". This plan answers each:
  storage = UserDefaults setting (not transcript); safety = on-device-only,
  same grep bans, user text never logged/stored in History; shortcut/UX =
  4th slot under the existing Rule A/B gate; quality = fixed locks wrap the
  user instruction + test-locked, matrix-judged.

## Facts verified via Xcode ACP + local SDK (never from memory)

- ACP: workspace `Oto.xcodeproj` opened (id `workspace-qzTeFLOXzv`),
  scheme `Oto`, dest `My Mac`. `GetTargetBuildSettings` confirms:
  `SWIFT_VERSION` 6.0 (language mode; toolchain Xcode 27.0 `27A266a`
  via `xcodebuild -version`), `MACOSX_DEPLOYMENT_TARGET` 27.0,
  `SWIFT_DEFAULT_ACTOR_ISOLATION` MainActor,
  `SWIFT_STRICT_CONCURRENCY` complete, `ENABLE_APP_SANDBOX` NO,
  bundle `app.Oto`. Consequence: every new type needs the project's
  explicit-`nonisolated` discipline (the hand-written `==` pattern) and
  exhaustive switches (the compiler is the anti-crash device).
- SDK `MacOSX27.0.sdk`, `FoundationModels.swiftinterface` re-checked:
  `LanguageModelSession` inits with `instructions:` (3 overloads),
  `GenerationOptions.maximumResponseTokens` (7 refs), all three
  `Availability` cases (`deviceNotEligible`, `appleIntelligenceNotEnabled`,
  `modelNotReady`) present — the existing `@unknown default` mapping
  already future-proofs. Consequence: custom instructions ride the
  existing verified path. **Zero new framework APIs.**
- `kVK_ANSI_4 = 0x15` confirmed in Carbon `Events.h` — factory `Cmd+4`
  needs no new key machinery; sibling-digit coexistence is proven by the
  existing rule (combo-vs-combo conflicts on same keyCode only;
  `siblingTransformCombosStayAllowed` test exists).
- Current code truth (merged tree):
  `Oto/Services/WritingPolishService.swift:145` (`TransformPreset`,
  3 cases), `:367` (`instructions(for:)` — fixed branches + locks),
  `:402` (token-cap math 128–512), `:414` (single-slot `warmSession`,
  invalidated after one use), `:446` (prewarm);
  `Oto/Services/TransformRunner.swift:51` (`execute` gate order:
  enabled → availability → capture → alive → work → grab),
  `:92` (`TransformDispatch`, `start()` loops `allCases` at `:141`,
  `resetToDefaults` at `:221`, `clearShortcut` at `:228`);
  `Oto/Models/ShortcutModels.swift:635` (`TransformShortcuts`, 3 Kinds),
  `:677` (`load()` — falls back to `.default()` on ANY decode failure),
  `:694` (audit, five slots), `:727` (gate, `allCases` sibling loop);
  `Oto/Settings/IntelligencePane.swift:94` (rows loop `allCases`,
  Reset at `:99` calls `transforms.resetToDefaults()`);
  `Oto/UI/FlowBar/FlowBarState.swift:51` (`workPillText`, one verb max).
- No new entitlements, no new Info.plist keys (mic/speech descriptions
  already ship; Foundation Models needs neither).

## Assumptions questioned

1. "Custom needs its own runner." No — `TransformRunner.execute(preset:)`
   is preset-agnostic; only the job's instructions differ. One new enum
   case flows through runner, dispatch, settle, suspend, 6s bound untouched.
2. "Custom instruction replaces the fixed locks." No — unjudged user text
   still gets the output-only + meaning locks (test-locked). Only the
   same-language lock is dropped (a translate instruction must be allowed
   to change language) — Q2 confirms.
3. "Old stored shortcut blobs keep working." NOT assumed — adding a 4th
   Codable field breaks `JSONDecoder` on old 3-key blobs, and the current
   `load()` (`:677-681`) falls back to `.default()`, which would **wipe
   the user's re-recorded Cmd+1/2/3**. This is the plan's load-bearing
   risk: a tolerant decoder is mandatory (History tolerant-decoder
   precedent; DualShortcutConfiguration `decodeIfPresent` precedent
   from Phase 12).
4. "The pill can show the custom name." Constrained: pill labels are
   one-word hug-measured (`VisualizerMath` measures any text, so any label
   fits — no layout risk). Wording is Q1; mechanics are safe either way.

## Design (decisions + reasons)

- `TransformPreset` gains `case custom` (`rawValue "custom"`). All
  `allCases` loops (dispatch `start()`, pane rows, gate sibling check,
  audit slots five→six) flow automatically. The compiler enforces the new
  branches in `displayName`/`tagline`/`pillVerb`/`kind`/`set` (exhaustive
  switches — a missed site is a build error, never a runtime surprise).
- `displayName` = stored custom name (fallback `"Custom"`); `tagline` =
  `"Your own instruction"`; `pillVerb` = fixed `"Custom"` (Q1
  alternative: user name).
- `CustomPrompt` struct: `{ name, instruction }`, UserDefaults keys
  `app.Oto.customPromptName` / `app.Oto.customPromptInstruction`. Caps:
  name trimmed ≤ 24 chars, instruction trimmed ≤ 500 chars, whitespace
  collapsed; empty instruction ⇒ `execute()` returns early (fail-closed,
  same as empty selection, placed right after the availability gate,
  before target capture — cheapest order). Store read via
  `CustomPrompt.load(defaults:)` default-parameter (CleanupBehavior
  precedent — tests inject).
- `LivePolishService.instructions(for:job:custom:)` custom branch:
  `"<instruction>\n\nRewrite the selected text accordingly. Preserve the
  meaning exactly. Output only the rewritten text, no commentary."`
  (same-language lock deliberately absent — Q2). Fixed-preset branches
  byte-identical (existing pinning tests untouched). Keep old
  `instructions(for:)` as forwarding overload so existing call
  sites/tests compile.
- `TransformShortcuts` gains `custom` field; factory `Cmd+4`
  (command + `kVK_ANSI_4`). Sibling-digit rule explicitly allows
  Cmd+1/2/3/4 coexistence (test-pinned). Known cost, stated in UI copy:
  global Cmd+4 preempts per-app Cmd+4 while Oto runs; re-recordable.
- Tolerant `load()`: decode old 3-key blob ⇒ keep trio + default custom
  (never `.default()`-wipe). New key unknown ⇒ default custom only.
- Privacy: instruction lives in UserDefaults (a setting, not a
  transcript); never written to History; never interpolated into any
  `os_log` line; `FakePolishService.recordedJobs` carries the enum (no
  user text). Grep bans unchanged.
- No prewarm for custom (instruction is editable; first run pays full
  latency — accepted, stated). Timeout 6s, combo settle 100ms, suspend
  logic, availability + master-toggle gates: all reused untouched.
- Settings row: Name `TextField` + instruction `TextEditor` bound to
  `CustomPrompt` store (debounced save, not per-keystroke), shortcut
  chip reusing `transformRow` recorder path, guidance copy when
  instruction empty ("Write your instruction — `Cmd+4` stays idle
  until you do."). `recording`/`messages` dicts already keyed by
  preset (flow automatically). Reset covers four (existing
  `resetToDefaults` + `refreshTransforms` path untouched).
- Native controls only; VoiceOver labels (`"Custom transform
  shortcut, …"`, `"Custom transform name"`, `"Custom transform
  instruction"`); full keyboard path; no new card, no second window
  (product-doc IA preserved).

## Exact file changes

1. `Oto/Services/WritingPolishService.swift`
   - `TransformPreset`: add `custom`; `displayName`/`pillVerb` custom
     branches; `tagline` custom → `"Your own instruction"`.
   - New `CustomPrompt` struct + keys + `load`/`save` + caps/sanitize
     (pure, unit-tested; `Sendable` + explicit `nonisolated ==` per
     project discipline).
   - `instructions(for:job:custom:)`: custom branch per Design; fixed
     branches untouched. Keep old `instructions(for:)` as forwarding
     overload.
2. `Oto/Models/ShortcutModels.swift`
   - `TransformShortcuts`: add `custom: Kind`; factory `Cmd+4`;
     `kind(for:)`/`set(_:for:)` custom branches; tolerant `load()`
     (3-key fallback — the load-bearing change).
   - `ShortcutAudit.violations`: slots five→six (`.transform(.custom)`).
   - `TransformShortcutGate.advisory`: flows via `allCases` (no logic
     change; sibling-digit test gains Cmd+4 case).
3. `Oto/Services/TransformRunner.swift`
   - `execute()`: early return when `.custom` and stored instruction
     empty (after the enabled/availability gates, before target
     capture). Nothing else changes.
4. `Oto/Settings/IntelligencePane.swift`
   - Custom row: name field + instruction editor (debounced save),
     shortcut chip reusing `transformRow` recorder path, guidance copy
     when instruction empty. `recording`/`messages` dicts flow by preset
     key. Reset covers four via the existing path.
5. `Oto/UI/FlowBar/FlowBarState.swift` (or wherever `workPillText` lives)
   - Custom label (Q1 outcome); width math untouched (measures any text).
6. Tests (`OtoTests/`)
   - `PolishServiceTests`: custom instruction wrapped with locks;
     same-language lock absent; empty-instruction guard test;
     caps/sanitize round-trip; fixed-preset strings byte-identical.
   - `TransformTests`: gate six slots (factory clean; Cmd+4 sibling
     allowed; exact-dup names Custom); tolerant decode (3-key blob →
     trio kept + default custom; corrupt blob → default, same as today);
     empty-instruction no-grab test (no target capture, no pill);
     pill label pin (custom label); runner custom end-to-end via fake
     (press → replaced; `Cmd+Z` is target-native, matrix).
   - Update `instructionsDifferPerJob` loop + `workTextAndGate` +
     `workWidthFitsLabelsAndClamps` for the 4th case (extend, not
     weaken).
7. Grep bans: no new patterns needed; `conflictsWith`/`familyName` logic
   untouched.

## Verification steps

- ACP `BuildProject` green (structured errors, not log-scraping).
- `xcodebuild test -scheme Oto -destination 'platform=macOS'` green
  (new tests + all existing pins, incl. fixed-preset strings).
- ACP `RunSomeTests`-equivalent on PolishService + Transform suites
  (or `xcodebuild -only-testing`).
- Live matrix (fresh Xcode Run):
  1. Write "rewrite as 3 bullets" → select paragraph → `Cmd+4` → pill
     shows custom label → replaced; `Cmd+Z` restores.
  2. Empty instruction → `Cmd+4` → nothing happens, no pill.
  3. Empty selection / password field / recording → nothing happens.
  4. Model unavailable (Apple Intelligence off) → nothing happens.
  5. Re-record custom to `Ctrl+4` → fires; stage `Opt+4` vs Right-Opt
     hold → refused with `Too similar` text, nothing saved.
  6. Upgrade check: seed old 3-key blob → launch → trio preserved,
     custom at defaults (no wipe).
  7. Fresh profile → custom row shows `Cmd+4` + empty editors + guidance.
- Eyes-on: custom row reads clean (native fields, VoiceOver, keyboard
  path); pill label full-word, spinner snug; no dead rows.

## Risks / deferred decisions

- **Old-blob wipe (load-bearing, mitigated):** tolerant decode + dedicated
  test; matrix item 6 proves it on device. Re-verified the hazard is
  real in the merged tree (`load()` `:677-681` falls back to
  `.default()` on any failure).
- **Cmd+4 preempts per-app Cmd+4** while Oto runs (same stated cost as
  1/2/3 tab-switch preempt). Re-recordable; copy states it.
- **Unjudged prompt quality:** user text wrapped in locks + matrix-judged;
  revisit caps only with evidence. No content filtering (own instruction
  → own on-device model; no new exfil surface).
- **No prewarm for custom:** first-run latency accepted; add only with
  timing evidence.
- Deferred (unchanged): Auto-Apply, diff view, Automatic mode, second
  custom slot, prompt sharing/sync.

## Open questions (recommendations marked)

- **Q1 Pill label: fixed `"Custom"`?** (Recommended.) Verb-pattern break
  is honest — no verb can be derived from arbitrary text. Alternative:
  user name (one word enforced) — prettier, but a name like "Monday"
  in the pill teaches nothing.
- **Q2 Drop same-language lock for custom?** (Recommended yes.) Keeps
  meaning + output-only locks; translation must be allowed to change
  language. Alternative: keep all locks (kills translate jobs).
- **Q3 Factory `Cmd+4` vs unassigned?** (Recommended `Cmd+4`.) Sibling
  rule proves zero cross-fire; idle-until-instruction-written means it
  never surprises. Alternative: unassigned (user must discover + record).
- **Q4 Caps 24 / 500 chars?** (Recommended.) Keeps token-cap math sane
  and rows compact. Alternative: higher with matrix evidence.
