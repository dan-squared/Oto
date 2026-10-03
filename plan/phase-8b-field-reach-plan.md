# Phase 8b: field reach (Figma et al.) + insertion steal-list — plan

> Follow-up to 8a (Hex-parity analysis — design record, untouched). This
> plan implements the steal-list (no policy change: every refusal, divert,
> and recovery path stays) PLUS the Figma-class miss fix. Nothing
> implemented yet.

## Goal

Dictation lands in materially more apps — Figma first — with zero change
to refusal semantics: secure fields still refuse, true voids still divert
to the catcher, trust still gates, recovery still keeps every transcript.
Reach improves by fixing MISCLASSIFICATION (confident `.noField` verdicts
that are actually editable), never by posting blind.

## Spec sources

- `plan/phase-8a-hex-parity-analysis.md` (steal-list C/B/E + marker item;
  Rule F rejected there — this plan honors that).
- Hex local checkout (`conductor/repos/hex`, 2.1.18): `accessibility.rs`
  `selected_text()` reads `AXSelectedText` from the focused element for
  context — the probe this plan adopts as an editable signal;
  `keyboard.rs` UCKeyTranslate layout resolution; `paste.rs` 100 ms
  settle + 500 ms linger (A/B inputs, not adoptions).
- Local SDK truth (this session, `MacOSX27.0.sdk` — never memory):
  `kAXSelectedTextAttribute` + `kAXSelectedTextRangeAttribute` exist in
  `HIServices/AXAttributeConstants.h` (documented constants — the probe
  uses real API); `kCGEventSourceUserData = 42` in `CGEventTypes.h`;
  `TISCopyCurrentKeyboardLayoutInputSource()` in
  `HIToolbox/TextInputSources.h`; `UCKeyTranslate` declared in
  `CarbonCore/UnicodeUtilities.h` (import path — `import Carbon` vs
  `Carbon.HIToolbox` — verified at build time, hardcoded-V fallback
  stands by).
- Local app facts (this Mac): Figma installed,
  bundle `com.figma.Desktop` (read via mdls — the bundle-table key);
  Ghostty present (terminal-treaty precedent already in tree).
- Codebase seams (re-read): `LiveFocusCheck` (700 ms budget, 3 attempts,
  transient-`noValue` patience, `TerminalEmulators` bundle-table
  precedent with `proceedsVoid`); `EditableFocus.classify` (role-gated)
  + `verdictForFocusError` (`.noValue` ⇒ `.noField` — the aggressive
  rule this plan narrows); `InsertionTimings` (30/300/100/600/120/10 ms);
  `postFullCommandV` (private source, 10 ms steps, device bit);
  `FlowBarController` focus log (`focus` category — the Figma-facts
  source for matrix step 0).

## Product decisions (locked)

- Missed fields are a CLASSIFICATION bug, not a policy debate. The fix
  direction is: fewer confident `.noField` verdicts, more `.unknown`
  (legacy proceed) — `.unknown` already proceeds exactly like before,
  so widening it changes nothing except reach.
- Three mechanisms, in order: (1) selected-text probe (generic — helps
  every canvas editor, not just Figma); (2) canvas-editor bundle table
  (Figma first, modeled on `TerminalEmulators`); (3) steal-list A/Bs.
- No prompt, no UI, no settings for any of this (detection is invisible
  infrastructure). The only visible change is fewer catcher diverts.

## Assumptions questioned (and answered)

- *"Just post like Hex when unsure."* That IS what `.unknown` does —
  the plan widens `unknown`, never bypasses the verdict. A confident
  `noField` (real void: Finder, desktop) still diverts with explanation.
- *"Figma needs a special driver."* No — most likely its canvas caret
  publishes no AX focus (`noValue`) or a non-text role while selected
  text exists. The generic probe (selected text present ⇒ editable)
  covers Figma, Miro, Excalidraw, canvas Docs without per-app drivers;
  the bundle table is the backstop for the true-void canvas case.
- *"Selected-text read is expensive/risky."* One synchronous attribute
  read inside the existing AX worker (same 700 ms budget, same
  ResumeGate discipline — no new threads, no new timeouts). Read-only,
  never logged (content), boolean-ized at the boundary
  (`hasSelectedText: Bool` crosses; strings never leave the reader).
- *"Layout-aware V needs the layout table."* UCKeyTranslate at paste
  time (not cached per layout — layouts switch rarely, translation is
  microseconds; cache invalidation bugs are worse than the cost).
  Fallback: hardcoded `kVK_ANSI_V` whenever translation fails (today's
  behavior — never worse).

## Slice 1 — selected-text probe (generic canvas-editor fix)

**Mechanics.** In `LiveFocusCheck`'s read path, after obtaining the
focused element (both system-wide and per-app branches): attempt
`AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute)` /
`kAXSelectedTextRangeAttribute` (either answering ⇒ text-capable).
Mapping (pure, unit-tested like `classify`):
- element exposes selected text/range ⇒ at least `.unknown` (proceed),
  even when the role read said `noField` (canvas caret case). Never
  upgrades `.secureField` (password fields expose selection too —
  refusal wins, order fixed by test).
- read errors / absent ⇒ verdict unchanged (today's behavior).
- content NEVER leaves the reader: the seam returns
  `hasSelectedText: Bool` alongside the verdict; strings are dropped
  inside the worker. Log line carries presence only (`sel=0/1`).

**Exact file changes:**
1. `Oto/Services/EditableFocusCheck.swift`: `selectedTextProbe(element:)
   -> Bool` (nonisolated, injectable reader for tests — same `reader`
   pattern as `syncCheck`); `classify` gains an overload/threaded
   `hasSelectedText` param (default false — old call sites compile;
   pure table: `secureField` sticks, `noField`+selected ⇒ `unknown`);
   `LiveFocusCheck` calls the probe on both branches inside the
   existing budget/worker (no new timeout, no new queue); focus log
   gains `sel=` bit (presence only).
2. Tests (all real, no AX): probe-upgrade table (every role ×
   sel 0/1 — secure never upgrades, noField+sel upgrades,
   editable/unknown untouched); reader-error ⇒ verdict unchanged;
   log-content test (adversarial transcript ⇒ never in logs —
   assert on the logged fields, not absence of magic strings).

## Slice 2 — canvas-editor bundle table (Figma backstop)

**Mechanics** (`CanvasEditors`, mirroring `TerminalEmulators` exactly —
same file, same shape, same tests shape):
- `bundleIDs = ["com.figma.Desktop"]` (verified locally via mdls; more
  entries ONLY from matrix evidence — Miro/FigJam/Excalidraw candidates
  named, not added).
- Rule: persistent void (`noValue` after max attempts) in a tabled app
  ⇒ `.unknown` (proceed, legacy path) instead of divert. Rationale:
  canvas apps draw their own caret and publish no AX focus in steady
  state — a persistent void there is uninformative, exactly like
  terminal emulators (the accepted precedent).
- `.secureField` still refuses everywhere including tabled apps
  (subrole gate, never the table — pinned by test).
- Terminal fallback untouched (separate enum, no merge — one owner per
  failure mode, existing rule).

**Exact file changes:**
1. `EditableFocusCheck.swift`: `CanvasEditors` enum
   (`bundleIDs`, `isCanvas(bundleID:)`, `fallback(verdict:bundleID:)`
   — void→unknown only, everything else passthrough); wired in
   `syncCheckDetail` + `liveRead` at the same points the terminal
   fallback sits (no new read, no new timing).
2. Tests: table membership; fallback table (void+figma ⇒ unknown,
   void+finder ⇒ noField, secure+figma ⇒ secureField, editable
   untouched); `bundleID(for:)` nil-dead-pid ⇒ fail closed (existing
   terminal precedent).

## Slice 3 — insertion steal-list (no policy change)

1. **Layout-aware V keycode** (the outright bug): `postFullCommandV`
   gains `key: resolvePasteKeyCode()` — UCKeyTranslate over the current
   layout for "v", fallback `kVK_ANSI_V`. Pure function +
   injectable (tests script layouts incl. Dvorak remap + failure
   fallback). ~100 lines + tests. SHIPS FIRST (standalone, no matrix
   beyond a Dvorak check).
2. **Experiment seam for A/Bs** (no UI, no rebuilds): `InsertionExperiment`
   (UserDefaults-backed, three keys with current-value defaults:
   event source private/null, keyStep ns 10M/0, restoreDelay ns
   100M/500M) read once per insertion into `InsertionEvents`/`Timings`
   overrides. Defaults byte-identical to today — the seam itself
   changes nothing (pinned by test); the MATRIX flips values via
   `defaults write` between runs. Synthetic marker
   (`kCGEventSourceUserData` = 42, one line in `postFullCommandV`)
   rides this slice (observability only — device trails distinguish
   Oto keystrokes from hardware; untestable headless by design —
   posting in tests would type on the machine — so code-review +
   trail-verified, stated honestly).
3. **A/B matrix** (user, on their apps): event-source × keyStep × linger
   per app class (slowest Electron app, terminal, browser field,
   Finder-as-void-control — void behavior must NOT change: catcher
   still diverts). Winner becomes the new default in a follow-up;
   losers die with data.

## Verification

- [ ] Build green; grep gates (no transcript content in logs — the
  probe returns Bool by construction, pinned).
- [ ] New unit green isolated + full `xcodebuild test -scheme Oto`
  calm (focus trio excluded only on proven-environmental basis).
- [ ] Matrix step 0 (user, Figma facts): dictate in a Figma text field
  with the debug build → paste the Console `focus` lines (role/axerr/
  sel-bit) → the exact miss shape is confirmed before Slice 2 lands
  (if the probe already fixes it, Slice 2 shrinks to a regression
  table entry).
- [ ] Matrix step 1 (user): Figma insert rate before/after (same 5
  fields × 3 tries); Finder still diverts (policy intact); password
  field still refuses (policy intact); offline dictation unaffected.
- [ ] Matrix step 2 (user, A/Bs): per-app land-rate per experiment
  setting; restoring defaults reproduces today's behavior exactly.

## Risks

- Selected-text probe false-positive direction: an app exposing
  `AXSelectedText` on a non-editable view (readers, previews) would
  now proceed instead of diverting — worst case is today's Hex
  behavior there (a paste that lands nowhere), bounded by the
  unchanged clipboard discipline + recovery. The bundle table scopes
  the void-rule change to named canvas apps only for this reason.
- UCKeyTranslate import path (`import Carbon` vs `Carbon.HIToolbox`)
  verified at build; hardcoded fallback means zero regression risk.
- Experiment keys are hidden by design (no Settings UI): document the
  three `defaults write` lines in the matrix message, nowhere else.
- AX messaging timeout stays 250 ms / 700 ms budget: the probe adds
  one attribute read inside the existing worker — worst case it
  consumes budget and degrades to `.unknown` (proceed), never hangs
  (ResumeGate unchanged).

## Open questions

1. Slice order: probe → table → steal-list? (Recommendation: yes —
   probe first, it may resolve Figma alone and is fully generic.)
2. If Matrix step 0 shows Figma exposes a proper text role and the
   miss is elsewhere (e.g. frontmost-PID race, not focus): pivot the
   slice to the evidenced cause? (Recommendation: yes — facts over
   plan; the plan names this fork explicitly.)
3. Secure-field refusal stands? (Recommendation: yes — the one gate
   with a security story; Hex parity there needs product sign-off,
   per 8a.)
