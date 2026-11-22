# Browser-void probe fix (Dia silent loss)

Status: implemented 2026-10-09 (Path B ruled out by user — catcher
enabled; Path C weakened statically — resolveScreen has 5 fallbacks and
fails only with zero screens; live AX probing from here blocked — no
assistive access for my processes, and granting it needs the user in
Settings). Implemented on elimination + mechanism match.

## Goal

Dictating in Dia (Chromium) with no text field focused loses the
transcript in total silence — no recovery, no catcher. Safari behaves
(fires the catcher). Make Chromium behave like Safari: a browser void
diverts to recovery instead of laundering a paste into it.

## Diagnosis (verified, not guessed)

- Chain: page body focused → AX role is a web area (non-text) →
  `classify` returns `.noField` (`EditableFocusCheck.swift:60-70`) →
  `finalize` (`:333-349`) runs the selected-text probe
  (`selectedTextPresent`, `:318-326`: answers `AXSelectedText` /
  `AXSelectedTextRange`, presence-only) → `resolveWithSelectionProbe`
  flips `.noField` → `.unknown` on any success → `.unknown` proceeds
  down the legacy path (`RealTextInsertion.swift:385-387`) → Cmd-V
  fires into the void → keystroke "succeeds" (delivery unverified by
  design) → `.inserted` → nothing kept, nothing shown.
- Why Safari works: its web AX tree does not answer the probe
  attributes on void areas, so it diverts. Chromium answers them
  (empty range still returns `.success` — presence, not content), so
  the flip fires constantly and the catcher can never trigger.
- Evidence: user report (total silence in Dia, catcher fine in Safari)
  matches the mechanism exactly; Dia bundle ID verified on this Mac via
  PlistBuddy: `company.thebrowser.dia` (never hardcoded from memory —
  the code reads it live per pid via the existing
  `TerminalEmulators.bundleID(for:)` path).
- The probe rule exists for canvas editors (Figma precedent), where a
  selection means text-capable. In a browser, selected static text (or
  an empty range) means nothing editable.

## Spec sources (canonical first)

- `Docs/START_HERE_PRODUCT.md`: every uncertain result recoverable; never
  claim success from a paste event alone. Silent loss is the exact
  violation — the fix direction is fail-closed (catcher card) over
  fail-open (phantom insert).
- House precedent: nil bundle never proceeds; true void diverts;
  TerminalEmulators/CanvasEditors are same-shape allowlists with tests.

## Facts verified against the local SDK / tree (never from memory)

- `finalize` is the single funnel (one caller of the probe rule);
  `resolveWithSelectionProbe` callers: `finalize` + `FocusProbeTests`
  (3 tests). Signature change is contained.
- `CanvasEditors.bundleIDs` today: `com.figma.Desktop` only
  (`EditableFocusCheck.swift:173-176`).
- `logVerdict` already logs `selected` per attempt — the confirmation
  trail exists; the plan adds bundleID to that line.
- No new framework APIs. No bundle ID is hardcoded from memory: Dia's
  was read from `/Applications/Dia.app` on this machine; the code path
  resolves per pid at runtime.

## Assumptions questioned

1. "Google Docs needs the flip." Unknown headless — Docs draws its own
   editing surface inside a browser bundle, so no bundle rule can ever
   separate Docs from a static page. If Docs' focused element exposes
   text roles (likely — it maintains a real AX text tree), nothing
   changes there. The matrix proves it; the fallback is recorded below.
2. "Browsers should be denylisted." Rejected in favor of allowlisting
   the flip to canvas editors: a denylist needs every browser enumerated
   (and the next Chromium fork reopens the hole), while an allowlist
   fixes the whole class (PDF readers, viewers, future browsers) and
   matches the codebase's fail-closed bias. Worst case of over-diverting
   is a catcher card (recoverable); worst case of under-diverting is
   today's silent loss.
3. "Presence-only probe must stay dumb." Kept — reading range lengths
   would narrow the trigger but weakens the "content never crosses"
   guarantee for a partial win (lingering real selections still flip).
   Not worth it.

## Design (decisions + reasons)

- `resolveWithSelectionProbe(verdict:hasSelectedText:)` gains the
  owning `bundleID`: the `.noField` → `.unknown` upgrade fires only
  when `CanvasEditors.isCanvas(bundleID)` is true. Everywhere else a
  selection never upgrades — the void diverts to recovery and the
  catcher fires, Safari-style.
- Terminals untouched (separate fallback, separate tests). Secure
  fields untouched (refusal wins, pinned). `proceedsVoid` untouched.
- `logVerdict` gains the bundle ID (log-only; future diagnosis like
  this one reads it straight from the trail).
- No behavior change for: text fields (editable path), true voids
  (already divert), terminals, Figma, secure fields.

## Exact file changes

1. `Oto/Services/EditableFocusCheck.swift` — probe signature +
   canvas-gated flip in `finalize`; bundle ID in `logVerdict` line.
2. `OtoTests/FocusProbeTests.swift` — matrix gains bundle dimension:
   canvas + selection → `.unknown`; browser (Dia/Chrome IDs) +
   selection → `.noField`; nil bundle + selection → `.noField`
   (fail-closed, house rule); all existing no-selection pins unchanged.
3. No controller/coordinator/menu changes (the divert path already
   keeps recovery and routes the catcher — it was starved, not broken).

## Verification steps

- `xcodebuild -scheme Oto -destination 'platform=macOS' build` green;
  `xcodebuild test` green (updated pins + new browser cases).
- Live matrix (packaged app, Dia): page body focused, nothing selected
  → dictate → catcher card with full text; page body with selected
  static text → same card (previously silent loss); address bar
  focused → inserts, no card; Google Docs with selected text →
  inserts (if this diverts instead, stop — fallback below).
- Console trail confirms: verdict `.noField`, `selected` may read true,
  route `.catcher`.

## Risks / deferred decisions

- Google Docs regression (unknown headless). Fallback, in order:
  (a) check Docs' focused role live — if text roles, no code change,
  the matrix was just proving it; (b) role-aware refinement (never
  bundle-aware — Docs shares the browser bundle); (c) full revert
  (one-function diff).
- Over-diversion in exotic editors (probe previously laundered them):
  accepted — a catcher card beats silent loss, and the matrix item for
  the user's own editors covers it.
- Deferred: empty-vs-nonempty range distinction (privacy cost, partial
  win); browser denylist (obsoleted by the allowlist).

## Open questions

- Q1 (for the matrix, not code): does the user dictate in Google Docs
  or other canvas-in-browser editors? Names decide matrix coverage.
