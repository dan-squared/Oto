# Phase 6A follow-ups — PLAN ONLY

Status: PLANNING ONLY (2026-09-21). Nothing implemented. Awaiting `go`.
Batch of three, one build: (A) history pagination [already planned in
`plan/history-pagination.md`, executed in this batch on go], (B) explicit
snippet delete (DB-pollution-proof), (C) empty-state vertical centering.
Snippet insert-to-app stays parked for 6C (see §5) — sticking to the plan.

## A. Pagination — no new planning

`plan/history-pagination.md` stands verbatim (cap 100, 10/page, pure
`HistoryPage`, footer Previous/1…N/Next, clamp rules, statement copy).
Approved ("keep 30 days, execute"). Builds in this batch.

## B. Explicit snippet delete (the meticulous one)

### Problem (from screenshots + message)

Snippet rows delete ONLY via swipe (`onDelete`). In a grouped Form on macOS
that gesture is undiscoverable (no affordance, trackpad-only) — the user
could not find it. History rows already have an explicit Delete button;
snippets must match. Dictionary rows share the same gap but were NOT asked
for — out of scope (stated so nobody expands the batch mid-build).

### DB-pollution analysis (why delete cannot leave orphans)

- Single source of truth: `snippets.v1.json`, rewritten atomically on every
  mutation (`remove` → `removeAll` → `persist` → `.atomic` write). No
  references from anywhere: pipeline never reads snippets (test-pinned),
  coordinator holds no snippet state, history stores no snippet ids.
  Deleting = array removal + full-file rewrite. There is no second table,
  no cache, no index to go stale. The only pollution vector would be a
  crash between removeAll and write — impossible: both are in-memory/file
  steps inside one `await persist()` on the MainActor, and `.atomic` means
  the old file survives a mid-write kill intact (next load reads pre-delete
  state — stale, never corrupt).
- Real flaw found by this plan (not the file): `SnippetStore.update()` and
  `DictionaryStore.update()` return `.emptySpoken` when the id is missing —
  wrong copy for "edited a row deleted elsewhere" (sheet open on two
  windows, or delete-then-save race). Meticulous fix: dedicated `.notFound`
  case ("That entry was deleted.") in both validation enums, returned when
  `firstIndex` misses. Sheet shows it as the error line, no silent recreate.

### Exact changes

1. `Oto/Storage/SnippetStore.swift`: add `SnippetValidationError.notFound`
   ("This snippet was deleted."); `update()` returns it on id miss (was
   `.emptyName` — wrong). Same fix in `DictionaryStore.update()` (was
   `.emptySpoken`): add `DictionaryValidationError.notFound` ("This rule was
   deleted.").
2. `Oto/Settings/WritingPane.swift` snippet section: per-row `HStack` —
   Copy button (existing pasteboard path) + Delete button
   (`role: .destructive`, `.font(.caption)`, `Task { await
   snippets.remove(id:) }`). Swipe `onDelete` stays (both paths call the
   same `remove`, single code path — no divergent logic to drift).
3. `OtoTests/Storage/SnippetStoreTests.swift`: `deletePersistsCleanly` —
   add 2 → remove 1 → NEW store instance loads same file → exactly the
   survivor (proves the file, not just memory); `updateMissingIsNotFound` —
   update random id → `.notFound` (both stores).
4. Grep gate: `emptySpoken`/`emptyName` returned only for genuinely empty
   input (the miss path now owns `.notFound`).

## C. Empty-state vertical centering

### Observation (from the two screenshots)

All three empty states (dictionary, snippets, history off/empty) render
horizontally centered but hug the top of their section, leaving a large void
beneath in the 760×620 window. The user reads that as "not centered." Fix is
vertical presence, not horizontal (already correct — no alignment change).

### Exact changes

`WritingPane` (dictionary + snippets sections) and `PrivacyHistoryPane`
(history off + history empty): append `.frame(maxWidth: .infinity,
minHeight: 240)` to each `ContentUnavailableView`. Rationale: the view
centers its content within its own bounds, so a taller frame centers the
composition in the section instead of top-pinning it; `maxWidth` guards
narrow-window drift. No custom spacers (misbehave in Form), no font/icon
changes, no layout surgery. Four call sites, one modifier each.
Verification is eyes-on (user confirms from screenshots; headless UI tests
cannot assert centering) + build green.

## D. Verification (whole batch)

- `xcodebuild test` green (new: pagination tests, bounds-120→100 test,
  delete-persists-cleanly ×1, notFound ×2).
- UI test untouched (tabs unchanged).
- User matrix: 12+ dictates → 2 pages, footer collapses on delete-to-10,
  Clear resets page; snippet row shows Delete → deletes → relaunch Settings
  → still gone (file clean); empty states vertically centered in screenshots.
- Zero warnings; coordinator/menu/audio untouched.

## E. Risks

- None to dictation (Storage + two panes only).
- `.notFound` copy is new user-visible copy — exact strings above, no
  further review needed.
