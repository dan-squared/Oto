# Remove history Reinsert — PLAN ONLY

Status: PLANNING ONLY (2026-09-22). Nothing implemented. Awaiting `execute`.

## 1. Goal

Remove the per-row **Reinsert** button from history (`PrivacyHistoryPane`), per user directive ("useless"). Copy + Delete stay. The menu-bar **Retry paste** path is a different feature and stays untouched.

## 2. Spec sources

- User directive (2026-09-22): remove Reinsert from history.
- Canonical `Docs/START_HERE_PRODUCT.md` §History (lines 74–80): history is
  "opt-in, local, bounded, and deletable" — mandates Copy-equivalent recall
  implicitly via "deletable/bounded", never mandates Reinsert. No conflict.
- `Docs/OTO_REBUILD_PLAN/09_PRODUCT_DESIGN_AND_EXECUTION_PLAN.md` line 246
  ("Per-entry actions: Copy, Reinsert, Delete") and
  `plan/phase-6-flowbar-writing-history.md` line 183 ("Reinsert MUST be
  `retryPostToFrontmost`") assumed Reinsert. This plan supersedes both lines
  for the history pane only; old plan files are left as history (never
  rewritten per working agreement), supersession is recorded here.
- `Docs/` is otherwise untouched (no instruction to rewrite it).

## 3. Facts verified (local repo, not memory)

- `reinsert(_:)` is private to `PrivacyHistoryPane` (lines 170–179) and its
  only caller is `Button("Reinsert")` (line 116). Grep `Reinsert|reinsert`
  across `Oto/`: remaining hits are (a) `retryPostToFrontmost` in
  `RealTextInsertion.swift` + `OtoMenuBarView.swift` (menu Retry — different
  feature, kept), (b) historical plan/Docs text (left alone).
- `inserter` in `PrivacyHistoryPane` (line 18) is used ONLY by `reinsert(_:)`.
  Removing the button orphans the property.
- `SettingsRoot.inserter` (line 52) is passed ONLY to `PrivacyHistoryPane`
  (lines 71–75). Orphaned in turn — must go, else a dead dependency lingers
  with zero compiler warning (Swift does not warn on unused stored `let`).
- `OtoApp.inserter` stays: `OtoMenuBarView` Retry (line 63) still needs it,
  and the coordinator pipeline holds the same instance (audit S2 shape).
- `feedback` state stays: `copyEntry` (line 164–168) still writes it.
- No test constructs `PrivacyHistoryPane` or `SettingsRoot` (grep: only
  `OtoApp` call site; UI tests use accessibility ids, assert the
  "Privacy & History" tab only). `RealTextInsertionTests` retry tests
  (`retryPostsWithoutPolicyGates`, `retryRefusesUnderSecureInput`) target the
  menu path — unaffected, still must pass.
- No new framework API is introduced (pure deletion). Nothing to verify in
  `MacOSX27.0.sdk`; stated so nobody re-derives it. Remaining buttons
  (`Copy`, `Delete`), `NSPasteboard` copy path, pagination footer, and Clear
  flow are unchanged code.

## 4. Assumptions questioned

- "Just delete the button line?" — Rejected. Leaves `inserter` plumbed
  through three files dead. Meticulous = remove the whole dead chain
  (pane property → SettingsRoot property + call arg → OtoApp Settings arg).
- "Also remove `retryPostToFrontmost`?" — Rejected. Menu "Retry paste to
  frontmost app" is the live recovery path for failed insertions (Phase 4
  contract, test-pinned). History Reinsert re-posting stale transcripts was
  the useless part (Copy + manual ⌘V covers it with full user control of
  target and timing). Method, menu, and its tests stay.
- "Also remove Copy?" — Not asked. Copy is the honest recovery primitive
  (explicit user paste, user picks target). Out of scope; stated so nobody
  expands mid-build.
- "Update old plan/Docs text mentioning Reinsert?" — No. Working agreement
  forbids Docs rewrites without explicit instruction; plan files are build
  history. Supersession lives in §2 above.

## 5. Exact file changes (on execute)

1. `Oto/Settings/PrivacyHistoryPane.swift`
   - Header comment (lines 5–8): drop the "Reinsert goes through
     retryPostToFrontmost" clause (now false for this pane).
   - Delete `let inserter: RealTextInsertion` (line 18).
   - Delete `Button("Reinsert") { reinsert(entry) }` (line 116); row keeps
     Copy + Spacer + Delete.
   - Delete `private func reinsert(_:)` (lines 170–179) in full.
   - Everything else untouched (toggle, rows, pagination footer, Clear,
     feedback line now Copy-only, privacy section).
2. `Oto/Settings/SettingsRoot.swift`
   - Delete `let inserter: RealTextInsertion` (line 52).
   - Delete `inserter: inserter,` arg at the `PrivacyHistoryPane(` call
     (line 73).
3. `Oto/App/OtoApp.swift`
   - Delete `inserter: inserter` arg in the `Settings { SettingsRoot(...) }`
     call (line 103). The `private let inserter` (line 37), its init (line
     53/66), the coordinator wiring, and the `OtoMenuBarView` arg (line 89)
     are untouched.
4. Tests: none to change (no test touches the removed button or the
   removed init params). Full suite must stay green as-is — that IS the
   regression signal.
5. Grep gate on execute: `reinsert(` (lowercase, pane func) → zero hits;
   `Reinsert` → only historical plan/Docs hits + `retryPostToFrontmost`
   (different name, kept); `inserter` → only `OtoApp` (property, init,
   coordinator, menu) + `DictationCoordinator` (pipeline) + `OtoMenuBarView`.

## 6. Verification

- `xcodebuild -scheme Oto -destination 'platform=macOS' build` — zero
  warnings (a leftover reference would fail closed here, not silently).
- `xcodebuild test -scheme Oto -destination 'platform=macOS'` — full suite
  green, same count as before (no tests added/removed; retry tests still
  pass, proving the menu path survived).
- Device check (user, 1 min): Settings → Privacy & History → rows show
  Copy + Delete only; Copy still sets "Copied — paste with ⌘V."; menu-bar
  "Retry paste to frontmost app" still present after a failed insertion.
- Relaunch app from the built commit.

## 7. Risks / deferred

- Risk ~zero to dictation: Settings-scaffold-only change; coordinator,
  audio, insertion engine, stores untouched.
- User-visible copy change: the "Posted — check the frontmost app." /
  "Retry failed…" strings vanish from history (Copy feedback remains).
  No other copy changes.
- Deferred (NOT this task): snippet Insert-to-app (6C), spoken triggers
  (deferred), history search/filter, dictionary-row Delete button (not
  asked — same undiscoverability caveat as snippets had, say the word if
  wanted).

## 8. Open questions

None blocking. One optional, recommend NO: keep the removed-param
initializers source-compatible via defaulted args? No — single production
call site, no external clients; clean removal beats compatibility shims.
