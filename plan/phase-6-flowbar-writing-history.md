# Phase 6 — Flow Bar, dictionary, snippets, history (+ Scratchpad) — PLAN v2 (SECOND PASS)

Status: PLANNING ONLY (2026-09-21, second pass). Nothing implemented.
Awaiting `execute`. v1 (`phase-6-flowbar-writing-history.md` first write) was
correct in shape; this v2 hardens every feature after three parallel deep-checks
against the local SDK, the Docs, and the worktree. If v1 and v2 disagree, v2 wins.
All prior arcs closed on `origin/main` (`47ba310`): Swift 6, BT-flap cure,
installTap-crash fix, dock setting, fail-loud, audit cleanup, S5
`installAudioTap`, buffer 4096.

## 0. Which "Phase 6" this is (numbering conflict, resolved — unchanged from v1)

- `Docs/START_HERE_PRODUCT.md` (CANONICAL): Phase 6 = Flow Bar, dictionary,
  snippets, history. This plan.
- `Docs/OTO_REBUILD_PLAN/09…`: same content is its Phase 3+4; its own "Phase 6"
  is intelligence (post-v1, NOT this plan). Translated on sight.
- Phase 7 (Intelligence) stays parked: no `SystemLanguageModel`, no Smart Mode,
  no tone presets, no cloud. Pipeline stays deterministic.

## 1. Goal (unchanged)

Flow Bar as pure projection of coordinator state + three local writing stores +
Scratchpad, all behind native Settings panes, device-proven, zero changes to the
audio/transcription chain. No user-visible audio/transcript-quality change.

## 2. Spec sources (unchanged from v1 — re-confirmed in second pass)

09 §3.5 (dictionary) / §3.6 (snippets) / §3.7 (Scratchpad) / §3.8 (history) /
§4.5 (detail-pane rules) / §4.7 (Flow Bar) / §5.4–§5.5 (persistence); 06
(visualizer reference); 10 §2 + §5 (Flow Bar correctness + profiling); 02 finish/
cancel/target rules; `plan/phase-5-topbar.md` §7 D3 (flat-four + segmented
pickers); `DictationCoordinator.swift:22` ownership;
`TranscriptPipeline.swift:14-18` seam; `OtoMenuBarView.swift:37-40` recovery home.

## 3. Facts verified against the local SDK — v2 CORRECTIONS APPLIED

Checked 2026-09-21, Xcode 27.0 (`27A266a`), `MacOSX27.0.sdk`, deployment 27.0.
v1 had three wrong citations (found by second pass, fixed here — no behavior
change, citations only):

- V1 ERROR: "`Canvas` in `SwiftUI.swiftmodule/…swiftinterface`". TRUTH:
  `public struct Canvas` count is **0** in `SwiftUI.swiftmodule`, **2** in
  `SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface` (verified by grep).
  `import SwiftUI` re-exports it, so the renderer compiles — citation only.
  Same correction for `accessibilityReduceMotion` / `accessibilityReduceTransparency`
  (both in SwiftUICore `EnvironmentValues`, 2 hits, not the SwiftUI module path).
- V1 ERROR: "`NSPanel` token present in SwiftUI swiftinterface". TRUTH: count **0**
  in both SwiftUI and SwiftUICore swiftinterfaces (verified). Panels are
  AppKit-only; the bridge imports AppKit. Functionally unchanged.
- V1 ERROR: "`StyleMask.nonactivatingPanel` to be confirmed in `AppKit/NSPanel.h`".
  TRUTH: `NSPanel.h` has NO StyleMask. The bit is
  `NSWindowStyleMaskNonactivatingPanel = 1 << 7` in
  `AppKit.framework/Headers/NSWindow.h:66` (verified, `sed` read; doc comment
  `:51`, deprecated alias `:1056`). Swift: `NSWindow.StyleMask.nonactivatingPanel`.
  No build-time confirmation needed.
- RE-CONFIRMED: `NSScreen.screens` / `mainScreen` (`NSScreen.h:30-31`),
  `NSScreen.CGDirectDisplayID` (`NSScreen.h:72-73`, macOS 26+, fine at 27.0),
  `NSDataDetector +dataDetectorWithTypes:` / `checkingTypes`
  (`NSRegularExpression.h:622,632,637`), `+escapedPatternForString:` (`:418`),
  `NSRegularExpressionUseUnicodeWordBoundaries = 1 << 6` (`:32`),
  `fileImporter` (≥2) + `fileExporter` (16 overloads) + `confirmationDialog` +
  `ContentUnavailableView` + `TabView` + `SegmentedPickerStyle` + `Table` +
  `TextEditor` + `LabeledContent` (all present in SwiftUI swiftinterface),
  `FileDocument` protocol present (export needs a wrapper doc — v1 omission fixed
  in §6A.7), `NSEvent.mouseLocation` (`NSEvent.h:527`), floating window levels +
  `collectionBehavior` + `orderFront/orderOut` (`NSWindow.h`),
  `CGDirectDisplayID = uint32_t` (`CGDirectDisplay.h:20`), vecLib/vDSP linkable.
- CLOSED (do not touch): `installAudioTap` (S5 `a8f9cec`), nil-format contract
  (`db695c8`), 4096 + relay 125/25 (`47ba310`), debounce, fail-loud counters.
- Swift 6 ON (`698dc90`): new types `Sendable` + explicit `nonisolated static ==`
  where `@Sendable` closures meet them (`DictationState.swift:20,58,70,88,120`);
  `nonisolated` pure helpers; lock-guarded realtime storage only.
- Settings root TODAY: `TabView` General + Dictation, extensible `SettingsPane`
  (`SettingsRoot.swift:11-30`); D1/D2 settled, sidebar receipts revert-only.
- STRUCTURAL (decides analyzer feed): `AudioBufferRelay.attach` OVERWRITES a
  single `sink` (`AudioBufferRelay.swift:72`) — no fan-out. Any "attach the
  analyzer to the relay" plan would DETACH speech. The only low-risk fork is
  `OtoApp.swift:42-44`'s `bufferHandler` closure (`relay.receive` + analyzer
  `offer`). §6B.14 is written to this — v1's "relay bypass TBD" is replaced.

## 4. Anti-redo list (v1 §4 stands, plus two bindings)

1. `TranscriptPipeline.process(_:for:)` keeps its signature; rules arrive as an
   injected `[DictionaryRule]` value (default `[]`), NOT a store reference
   (v1 wording fix — store crosses isolation, value array preserves
   `nonisolated`/`Sendable` purity).
2. `TargetApplication.bundleIdentifier` + `displayID` / `SessionContext.targetScreen`
   consumed only, never re-captured. Nil bundleID → globals only (fail closed).
3. Coordinator `state` / `recoveryText()` / `lastSessionSummary()` are READ by the
   Flow Bar, never driven. No coordinator edits (no broadcast stream — 4–10 Hz
   snapshot poll owned by the controller, §6B.11).
4. `SettingsPane` gains `.writing` + `.privacyHistory`; segmented sub-switchers
   per D3; no nested `TabView`, no six tabs.
5. Menu one-shot status + conditional recovery STAY until Flow Bar device-proof;
   removal is a later signed decision, never bundled.
6. Greenfield confirmed again: no `Oto/Storage/`, no `UI/FlowBar/`, no
   `UI/Scratchpad/` (verified). Tests mirror source.
7. v1's stray CJK characters in item 14 (relay旁路) removed in v2.

## 5. Hardened feature specs (second-pass depth — replaces v1 generalities)

### 5A. Dictionary (pipeline rules)

- Model: `DictionaryRule {id: UUID, spoken: String (normalized NFC/trim/interior-
  collapse, 1–80), replacement: String (byte-exact person-authored, 1–200),
  bundleID: String? (nil = global; else exact case-sensitive match, "" rejected,
  ≤253), isEnabled: Bool}`. Caps: 500 rules/store. No scope enum, no wildcards.
- Match: per-rule `(?<!\p{L}\p{N}_)<escaped>(?!\p{L}\p{N}_)` with
  `[.caseInsensitive, .useUnicodeWordBoundaries]`; `escapedPattern(for:)` always.
  Case-insensitive, diacritic-SENSITIVE, width-sensitive, locale-independent.
  Never bare `\b` (ASCII-only + inverts on `c++`-style forms).
- Protection: ONE `NSDataDetector(types: [.link])` per `apply` (URLs + emails;
  never Date/Address/Phone — they would protect ordinary prose) + ONE literal
  path regex (`~/`, absolute, `./`, `../`, `file://` leftovers) per call; unioned
  `NSRange`s veto intersecting matches (partial overlap = drop whole match).
  Detector-nil → path-only + metric; both-nil → apply unprotected + metric; never
  crash, never skip dictation.
- Resolution: single pass over ORIGINAL text — collect all enabled in-scope
  matches, sort `(start asc, length desc, app-over-global, id asc)`, greedily
  accept non-overlapping, splice once (emoji-safe via `Range(nsRange,in:)`).
  Replacements never re-scanned (no cascade: `a→b` + `b→a` swaps once).
  App-scoped beats global at identical range. Disabled rules invisible to
  resolution. Nil target → globals only.
- Duplicates: key `(spoken.lowercased(), bundleID ?? global)` — same key reject
  (`"‘{spoken}’ already exists ({Globally|for {bundleID}}). Edit the existing
  rule…" `); same spoken cross-scope allowed with precedence warning
  (`"…rule wins in {app}; global still applies elsewhere."`); replacement==spoken
  warns (`"…changes nothing."`); 500-cap message fixed.
- Preview: `test(sample:for:)` — SAME `apply` path with explicit scope target,
  labeled with evaluated scope (scope-blind preview lies about app rules).
  Sample cap 1000 chars.
- Import/export: versioned JSON `{schemaVersion: 1, rules: […]}`; per-row
  validation; `ImportReport(imported, skippedDuplicates, rejected[(row,reason)])`;
  atomic (validate all → write once); existing store never discarded on bad file.
- Pipeline: `TranscriptPipeline {let dictionaryRules: [DictionaryRule]}` (init
  default `[]`); `process` = trim → `applyDictionaryRules(rules, to:for:)` →
  return. Snippet expansion NEVER in pipeline (explicit action only).
- Residuals (accepted, pinned by test): NFD-transcript vs NFC-rule miss (no
  transcript renormalization — would invalidate `NSRange` splicing); first-call
  detector latency absorbed in finalization.

### 5B. Persistence (one service, all files)

- `actor LocalPersistence`: `~/Library/Application Support/Oto/` via
  `urls(for: .applicationSupportDirectory, in: .userDomainMask)` + create-if-missing;
  files `dictionary.v1.json`, `snippets.v1.json`, `history.v1.json`; envelope
  `VersionedFile{schemaVersion: 1, items}` (never bare arrays); `JSONEncoder`
  (`.sortedKeys`, `.iso8601` dates) → `Data.write(to:options:.atomic)`.
  Protocol seam for in-memory fakes. No `NSLock` for file IO (actor serializes).
- Backups: `Oto/Backups/<base>.<timestamp>.bak.json` (keep newest 3) ONLY on
  `schemaVersion != 1` or `DecodingError`; corrupt JSON → `.corrupt-<ts>` move +
  empty start, never silent delete, counts/pids log only. Greenfield: no real v0
  migration (v1's "v0→v1" means corrupt/unknown → backup + empty).
- Explicit delete only (History Clear; debug file delete). No "clear all personal
  data" conflation.

### 5C. Snippets (manual-only — trigger fields DELETED from v1)

- Model: `Snippet {id: UUID, name: String (1–60, unique case-insensitive),
  expansion: String (1–2000), scope: bundleID? like dictionary}`. NO `trigger`,
  NO `activation` in v1 schema (v1's parked fields invite ambient matching +
  a pointless future migration). Spoken trigger (`"Oto insert [name]"`) is a
  separate follow-up with its own exact-match gate + matrix (Q4).
- Insert is explicit (menu/Scratchpad/Settings button) → `retryPostToFrontmost`
  or `insert(into:)` with live target; never pipeline. Test proves `process`
  ignores snippets. List preview truncates at 120 chars (`+N more`); full text in
  sheet `TextEditor`. Max 500 snippets.

### 5D. History (opt-in, bounded, final-text only)

- `HistoryEntry {id: UUID, finalText: String (1–5000, trimmed, non-empty),
  createdAt: Date (wall-clock — NOT `ContinuousClock.Instant`, which is
  non-Codable/monotonic), bundleIdentifier: String? (display only)}`.
- Flag: `@AppStorage("app.Oto.historyEnabled") = false` (default OFF; precedent
  `DockVisibility` key). Bounds are CONSTANTS, not persisted scalars:
  `maxEntries=200`, `maxAgeDays=30`, `maxTextChars=5000`, enforced synchronously
  on write (filter age → sort `createdAt desc, id asc` → prefix 200). No trim task.
- Record ONLY from `finalizeSession` non-empty `clean` path
  (`DictationCoordinator.swift:270-277`); never on cancel/empty/failure-without-
  text; OFF → never called (fake-wiring test). Stores String, never audio/
  partials/clipboard/target-content (absence by construction + `CodingKeys`
  equality test + log grep gate).
- Reinsert MUST be `retryPostToFrontmost` (user-is-the-check: skips trust/focus
  gates, keeps secure-input refusal + clipboard verify + ownership restore),
  NEVER `insert(into:)` with a reconstructed target (stored bundleID has no pid;
  stale pid always fails or tempts forbidden frontmost fallback). Copy =
  `clearContents` + `setString` (menu precedent). Clear All via
  `confirmationDialog("Delete all history on this Mac? This removes N entries.
  Cannot be undone.")`.

### 5E. Flow Bar (projection — every case mapped, no TBDs)

- `FlowBarState {idle, preparing, recording, processing, success, cancelled,
  failure(message, recoveryAvailable)}` — payload-FREE (v1's level/partial
  payloads dropped: 02's `recording(level:partial:)` has NO producer —
  `onPartial` unwired `AppleSpeechService.swift:114-116`). Level/sample lives on
  the `@MainActor` model as `currentSample`, never in the enum. Pure
  `project(DictationState) -> FlowBarState`, exhaustive + `nonisolated ==`.
- Projection: idle→hidden; starting→preparing ("Preparing…", Cancel only —
  Q7 confirms; key-up finish needs no button); recording→live bars, Stop+Cancel
  (+ hands-free caption); finalizing→"Working…", inserting→"Inserting…" (distinct
  strings, same traveling highlight, Cancel only — `canFinish` false);
  completed→**"Done"** (NEUTRAL — `.completed` covers inserted AND empty, carries
  no insertion proof per 10 §2; forbid "insert"/"✓" by test), auto-dismiss ~1.2s;
  cancelled→"Cancelled", ~0.8s, never saves; failures: micDenied/speechPrep/
  audioCapture/noAudio → honest message + Open Settings or Dismiss, NO dead retry
  buttons; targetGone/insertionFailed → "…text kept." + Copy/Retry/Scratchpad/
  Dismiss, panel HOLDS until user acts or next session; `.failed(nil,_)` handled
  (never force-unwrap); `recoveryAvailable = recoveryText() != nil` re-read while
  failed (success never races recovery — only failure holds it).
- Observation: 100–250 ms snapshot task OWNED BY `FlowBarController`, started on
  show, cancelled BEFORE `orderOut`. Reads `coordinator.state` (+ `recoveryText()`
  when failed) across actor isolation — legal async hop, no coordinator edits, no
  menu poll loop, no per-buffer tasks. AsyncStream broadcast recorded as future
  optimization only.
- Panel: `NSPanel` `[.borderless, .nonactivatingPanel]`, `isFloatingPanel`,
  `level = .floating`, `collectionBehavior [.canJoinAllSpaces,
  .fullScreenAuxiliary]`, `hidesOnDeactivate = false`,
  `becomesKeyOnlyIfNeeded = true` (focus-steal defense, tested: frontmost pid
  unchanged), `animationBehavior = .none`; `NSHostingView` pill, width-driven max
  480pt min ~220pt. Positioning chain (pinned per session, never re-resolved):
  targetScreen→screens match (same `deviceDescription["NSScreenNumber"]` technique
  as `RealTargetCapture`) → mouse-screen (`NSEvent.mouseLocation`) →
  `NSScreen.main` → origin-zero screen. Record which step resolved (single-screen
  sign-off covers fallbacks only).
- Renderer: `Canvas` (SwiftUICore) 15–24 bars (default 18), min/max bounds,
  bottom-align default; `BarSample` fixed-count 0…1 + `VisualizerMath.values`
  (pad 0.12, clamp, reduceMotion→uniform max); `ExponentialSmoother(0.24)`;
  preparing sweep (bounded), recording live, processing highlight, terminal fade.
  NO `TimelineView` (policy ban per 09 §2.2 crash — grep gate, even though the
  symbol exists). Redraws only on new `BarSample` (≤30 Hz).
- Analyzer: fed ONLY by forking `OtoApp`'s `bufferHandler`
  (`relay.receive` + `analyzerBox.offer`, drop-on-full latest-slot/≤4-ring,
  `nonisolated`, never blocks/allocates FFT/touches UI). Own converter instance
  (never shares speech path's), vDSP bands off-thread, ≤30 Hz immutable publish,
  `stop()` guarantees silence after (tested). Zero changes to installTap/relay/
  debounce/`AudioFeedBox`. FALLBACK PRE-APPROVED: ship 6B state-only (static low
  bars) first, analyzer as 6B2 on any profiling flake (Q2 picks the entry point).
- Controller: `@MainActor`, `show(sessionID:screen:)` / `hide`; invariant
  cancel-tasks → await termination → `orderOut` → release (the 09 §2.2 class);
  20× stress across terminal states (no orphans, task baseline, no mid-animation
  crash); new `begin` hides failure panel immediately (recovery cleared).
- A11y: per-state label+value; Stop=Return (`.defaultAction`), Cancel=Escape
  (`.cancelAction`) — double-delivery safe via idempotent `cancel(sessionID)`;
  Reduce Motion → frozen bars, labels intact; Reduce Transparency → opaque fill
  (`opaque:true` Canvas + solid dark).

### 5F. Scratchpad + Settings wiring

- Window: plain `NSWindow` (titled/closable/resizable, standard traffic lights —
  must become key for `TextEditor`; NOT nonactivating). No custom chrome.
- Target source (v1 gloss fixed): coordinator exposes NO `sessionContext` — only
  state-associated contexts. Mid-session open reads target from current state's
  context; post-failure from `.failed(ctx,_)`; nil → Insert degrades to
  `retryPostToFrontmost`. Owner holds the SAME `RealTextInsertion` +
  `TargetCapturing` instances as the coordinator (app-scope injection in
  `OtoApp.swift`, shared-inserter precedent `:34-37`). Insert =
  `isAlive` → `insert` → failure keeps text + reason; never direct paste, never
  frontmost substitution. Close hides (text retained for session); explicit Clear
  with `confirmationDialog`; Copy mirrors menu.
- Settings: `SettingsPane` += `.writing("Writing","text.book.closed")` +
  `.privacyHistory("Privacy & History","clock")`; `WritingPane` (segmented
  Dictionary|Snippets, `Form(.grouped)`, native `List`, sheet Cancel/Save +
  validation + scoped test-preview, `ContentUnavailableView`, `fileImporter([.json])`
  + `fileExporter` via `DictionaryExportDocument: FileDocument`
  (`UTType.json`, `oto-dictionary.json`), `confirmationDialog` for delete/clear);
  `PrivacyHistoryPane` (segmented History|Privacy, toggle + retention statement
  "Kept on this Mac only. Newest 200, 30 days…", Copy/Reinsert/Delete + Clear,
  permission rows reusing `DictationPane.swift:141-153` + System Settings links,
  no new TCC code). Sheet rule: untouched-dismiss needs no confirm; edited-
  discard confirms.

## 6. Exact file changes (three slices, gated — v2 deltas marked ★)

### Slice 6A — Stores + pipeline + panes (no Flow Bar)
1. NEW `Oto/Storage/LocalPersistence.swift` — actor + `VersionedFile` envelope +
   atomic writes + `Backups/` (keep 3) + protocol seam. ★ Envelope + backup
   location + corrupt path specified (v1 vague).
2. NEW `Oto/Storage/DictionaryStore.swift` — §5A model/validation/duplicates/
   `applyDictionaryRules` free function + `test(sample:for:)`. ★ Lookaround
   pattern, Link+path protectors, single-pass resolution, precedence, caps.
3. NEW `Oto/Storage/SnippetStore.swift` — §5C (NO trigger/activation). ★ Fields
   deleted from v1.
4. NEW `Oto/Storage/HistoryStore.swift` — §5D (`Date`, constants, on-write trim).
   ★ Timestamp source + bound placement + Reinsert-via-retry fixed.
5. EDIT `Oto/Services/TranscriptPipeline.swift` — `let dictionaryRules:
   [DictionaryRule]` init (default `[]`); `process` stays `nonisolated`. ★ Value
   array, not store.
6. EDIT `Oto/Settings/SettingsRoot.swift` — two cases + tabs (titles/symbols
   above). Shape unchanged.
7. NEW `Oto/Settings/WritingPane.swift` — §5F (segmented, List, sheet, empty
   states, importer + exporter-DOCUMENT, delete/clear dialogs). ★ Export wrapper
   + truncation + scope-labeled preview specified.
8. NEW `Oto/Settings/PrivacyHistoryPane.swift` — §5D/§5F (toggle + statement +
   list + Clear copy; privacy rows + links). ★ Exact Clear copy + row reuse lines.
9. NEW tests: `DictionaryRuleTests` (28-case matrix §(c)1–28 of pass-1 report:
   case/boundary/injection/Unicode/emoji/longest/no-cascade/disabled/empty,
   URL+email+path+partial+surgical, exact scope + nil-closed + precedence,
   validation/duplicates/import-report/honest-preview, limits),
   `SnippetStoreTests` (CRUD, no-ambient-expansion, 120-truncate, 2000-reject,
   no-trigger-key), `HistoryStoreTests` (OFF default + no-op, ON record shape,
   250→200 newest-first + id tie-break, 31-day eviction, 5000-cap, Delete/Clear,
   retry-path, secure-keep), `HistoryPrivacyTests` (CodingKeys equality, unknown-
   key-throw, String-only API, log gate), `PersistenceTests` +2
   `PersistenceMigrationTests` (round-trip, missing-dir, atomic, backup-only-on-
   mismatch/corrupt, keep-3), `PipelineScopeTests` (trim, empty, scoped isolation),
   `ConcurrencyTests` (10-task write exactness). No assert-nothing templates.

### Slice 6B — Flow Bar + visualizer (no store changes)
10. NEW `Oto/UI/FlowBar/FlowBarState.swift` — §5E payload-free enum + pure
    `project()` + labels/icons. ★ Level/partial payloads removed (no producer).
11. NEW `Oto/UI/FlowBar/FlowBarModel.swift` — `@MainActor` observable (state,
    sample, recoveryAvailable; intents to coordinator/inserter only).
12. NEW `Oto/UI/FlowBar/FlowBarPanel.swift` — §5E panel spec (level, behaviors,
    480/220 widths, 4-step positioning + pinning, shortcuts, a11y fills). ★ All
    values specified (v1 had none).
13. NEW `Oto/UI/FlowBar/BarVisualizer.swift` — §5E (18 default, VisualizerMath,
    smoother, state animations, no TimelineView).
14. NEW `Oto/Services/AudioSpectrumAnalyzer.swift` — §5E (OtoApp-closure fork,
    drop-on-full box, own converter, ≤30 Hz, stop-silence). ★ Feed point FIXED
    (v1 TBD + relay-attach rejected with `AudioBufferRelay.swift:72` proof).
15. NEW `Oto/UI/FlowBar/FlowBarController.swift` — §5E (100–250 ms poll ownership,
    cancel-before-orderOut, 20× stress, failure-hold, auto-dismiss 1.2/0.8s).
    ★ Mechanism FIXED (v1 TBD).
16. `OtoMenuBarView.swift` — untouched (status + recovery stay).

### Slice 6C — Scratchpad + wiring + acceptance
17. NEW `Oto/UI/Scratchpad/ScratchpadWindow.swift` — §5F (plain NSWindow, shared
    inserter/targetService, liveness+ownership via `RealTextInsertion`, nil→retry
    degrade, retain-on-close + confirm-on-clear). ★ Dependencies + degrade path
    specified (v1 unimplementable against coordinator API).
18. EDIT `OtoApp.swift` — app-scope `FlowBarController` + Scratchpad owner,
    same inserter/targetService instances; ownership grep-gate. ★ File + sharing
    named (v1 "file TBD").
19. EDIT `OtoUITests` — 4 tabs, sheets, toggle + Clear copy, segmented switches,
    state labels on deterministic samples, insert-guard; temp-identifier probe
    loop if toolbar labels miss (topbar §4 lesson).

## 7. Verification (gates per slice — standing push rule holds)

- Headless: clean `xcodebuild -scheme Oto -destination 'platform=macOS' build`
  (clean builds tell truth for new modules) + FULL `xcodebuild test` green (118
  today; name-diff new tests, buffer-size lesson). Zero warnings (S5 left zero).
- Grep gates: `downloadAndInstall`→0; views importing audio/speech impls→0;
  `TimelineView`→0 (in `UI/FlowBar/`); `postToPid`→0;
  `titlebarAppearsTransparent`→0; transcript content in logs→0; `trigger` in
  `Storage/Snippet*`→0 (v1-field ban); `Clock.Instant` in `Storage/`→0 (Date rule).
- 6A matrix: rule→preview→dictate (global + app-scoped isolation via switch-app);
  import/export round-trip + bad-row report; history OFF→nothing, ON→entry +
  Copy/Reinsert/Delete + Clear copy; bounds (250→200, 31-day evict).
- 6B matrix: pill on target display (record which positioning step resolved);
  Stop/Cancel; success "Done" auto-dismiss; failure holds + menu parity; Reduce
  Motion→static; BT-kill (app alive + honest message); silent→empty no-failure;
  20× stress (no orphans/tasks baseline); focus-steal (frontmost unchanged).
- 6C matrix: target-gone→Scratchpad→Reinsert; secure-field→kept; close→retained,
  Clear→confirmed. Multi-display availability recorded (single-screen covers
  fallbacks only).
- Push per slice after matrix sign-off; never bundle red with green.

## 8. Risks / deferred (v2 — each with disposition)

- FFT/main-thread load → profile per 10 §5; 6B-without-analyzer fallback
  pre-approved (Q2).
- Unbounded history → closed by 200/30d/5000 on-write trim (§5D).
- Unbounded dictionary → closed by 500/80/200 caps + import report (§5A).
- Spoken-trigger false-fire ("my email") → manual-only v1, trigger fields absent
  by test; follow-up needs exact-match gate + matrix (Q4).
- `completed`-neutrality ("Done") may disappoint ("did it insert?") → alternative
  is a coordinator `lastInsertionOutcome` edit (against the grain); Q8 asks.
- Single-screen testing covers fallbacks only → record step number.
- Intelligence requests mid-review → out of scope, deterministic pipeline only.

## 9. Open questions (v1 Q1–Q6 stand, plus v2 Q7–Q9 from deep-checks)

- Q1. Slice order: 6A→6B→6C (recommended, data before surface) or Flow Bar first?
- Q2. 6B WITH analyzer, or state-only pill first + 6B2? (Recommended: WITH, fallback
  pre-approved — say if you want smaller blast radius first.)
- Q3. Retention 30d + newest-200 + 5000-char cap (recommended) or other?
- Q4. Spoken triggers: defer entirely, no trigger code (recommended) or scaffold gate?
- Q5. Menu recovery: keep alongside Flow Bar (recommended) or remove on proof?
- Q6. Your help: per-slice matrix on built-in + Jabra (cold-link + killer for 6B),
  multi-display availability, answers Q1–Q9.
- Q7 (new). Preparing-state buttons: Cancel-only (recommended — key-up finish needs
  no button) or Stop+Cancel?
- Q8 (new). Success wording: neutral "Done" (recommended — state carries no
  insertion proof) or expose insertion outcome via coordinator edit?
- Q9 (new). If profiling flags the analyzer: auto-fallback to state-only 6B and
  continue, or stop and report first? (Recommended: fallback + report.)

## 10. Traceability

- SDK: `MacOSX27.0.sdk`, Xcode 27.0 `27A266a`, arm64e SwiftUI/SwiftUICore
  swiftinterfaces + AppKit `NSWindow.h:66` / `NSScreen.h:30-31,72-73` /
  `NSEvent.h:527` + Foundation `NSRegularExpression.h:32,418,622,632,637` —
  all grep/`sed`-verified 2026-09-21 in this second pass.
- Closed: `698dc90` (Swift 6 + debounce + fail-loud), `db695c8` (nil-format),
  `a8f9cec` (S5), `47ba310` (4096 + 125/25).
- Navigation D3 (`phase-5-topbar.md` §7); visualizer 06; stores 09 §5.4;
  correctness 10 §2 + profiling §5; finish/cancel 02.
- Non-changes: audio chain, coordinator machine, menu polling, sidebar revival,
  intelligence — each with reason above.
- Second-pass inputs: three parallel deep-checks (dictionary/pipeline,
  stores/history/snippets, FlowBar/visualizer/Scratchpad) — findings folded in,
  v1 citations corrected in §3, TBDs eliminated in §5–§6.
