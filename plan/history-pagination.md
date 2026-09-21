# History pagination (10/page, cap 100) — PLAN ONLY

Status: PLANNING ONLY (2026-09-21). Nothing implemented. Awaiting `execute`.
Supersedes Phase 6 v2 Q3 numbers (30d + newest-200) on the count bound only:
30 days stays, 200 → 100. Reason recorded in §4.

## 1. Problem

`PrivacyHistoryPane` renders `history.entries` in one `ForEach`. At the
200-entry bound that is a 200-row Form section: slow to scan, slow to scroll,
no way to reach recent entries fast. User directive: cap storage at 100,
show 10 per page, page navigation in the footer.

## 2. Design decisions (questioned before building)

- **Cap 100, page 10 → max 10 pages.** Page size is a VIEW constant, not
  stored: `HistoryPage.pageSize = 10`. Storage bound `HistoryStore.maxEntries`
  200 → 100. The 30-day age bound is untouched (orthogonal axis).
- **Existing over-100 files migrate by themselves.** `HistoryStore.load()`
  already calls `trim()`; first launch after this change trims any 101–200
  file to newest-100 on load, then persists on next write. No migration code,
  no version bump (schema unchanged — same keys, same file). Stated so nobody
  re-derives it.
- **Newest-first paging.** Page 1 = 10 newest. Matches entries ordering
  (`createdAt desc, id tie-break`) — no re-sort, slice only.
- **Pure pagination helper (headless-testable).** View math hides in views;
  senior shape is a tiny pure value:
  ```swift
  struct HistoryPage: Equatable, Sendable {
      nonisolated static let pageSize = 10
      nonisolated static func pageCount(total: Int) -> Int  // ceil(total/10), 0→0
      nonisolated static func slice<T>(items: [T], page: Int) -> [T]  // clamped
      nonisolated static func clampedPage(_ page: Int, total: Int) -> Int
  }
  ```
  Lives in `Oto/Storage/HistoryStore.swift` (same module as the bound) or a
  new `Oto/Storage/HistoryPage.swift` — new file preferred (one owner per file).
  `nonisolated` throughout (Swift 6 pattern; pure integer/array math).
- **Footer controls (all native):** `HStack`: Previous button (disabled on page
  1) + numbered page buttons `1…N` (current rendered `.borderedProminent`,
  others `.link` or plain — decided at build, one line) + Next button
  (disabled on last) + `Text("Page X of N")` caption. No custom page dots,
  no third-party control. Numbers cap at 10 buttons (max 10 pages by
  construction) — no ellipsis logic needed, ever.
- **Page state:** `@State private var historyPage = 1` in
  `PrivacyHistoryPane`. Clamp rules (all in one place, `clampedPage`):
  entries shrink (delete/clear) → clamp on change via `.onChange(of:
  history.entries.count)`; toggle off → reset to 1; Clear → reset to 1.
  Out-of-range page shows nothing — the clamp makes that unreachable, tested.
- **Copy/Reinsert/Delete per row:** unchanged, operate on entry id (page
  agnostic). Reinsert feedback line stays above the footer.
- **Retention statement copy update:** "Kept on this Mac only. Newest 100
  entries, 30 days. …" (was 200). Clear dialog count text unchanged
  (uses live count).

## 3. Exact file changes (on execute)

1. `Oto/Storage/HistoryStore.swift`: `maxEntries` 200 → 100 (+ comment citing
   this plan). Nothing else — trim/load/record paths already bound-driven.
2. NEW `Oto/Storage/HistoryPage.swift`: pure helper above.
3. `Oto/Settings/PrivacyHistoryPane.swift`: history section renders
   `HistoryPage.slice(items: history.entries, page: historyPage)`; footer
   HStack (Previous / 1…N / Next / "Page X of N"); `@State historyPage = 1`;
   `.onChange(of: history.entries.count)` → `historyPage =
   HistoryPage.clampedPage(historyPage, total: history.entries.count)`;
   reset to 1 when toggling off and after Clear All. Retention statement 200 →
   100. Everything else untouched (toggle, rows, dialogs, privacy section).
4. `OtoTests/Storage/HistoryStoreTests.swift`: bounds test 250 → 120 entries
   in, expect 100 out, top is newest; add pagination tests
   (`pageCount`: 0→0, 1→1, 10→1, 11→2, 100→10; `slice`: page 1 newest-10,
   last page remainder, page 0/overflow clamped; clamp keeps selection stable
   after delete-to-shrink).
5. Grep gate: `maxEntries` referenced only in store + pane statement + tests.

## 4. Why 100, not 200 + pages (traceability)

200 stored × 10/page = up to 20 page buttons — footer crowds; and 200 finals
at ~5000 chars is ~1 MB of recall nobody scrolls to. 100 keeps the footer ≤10
buttons (no ellipsis state machine, no truncation design) and matches the
feature's job (recent recall, not archive). If 100 ever chafes, the bound is
one constant + statement copy — reversible in minutes.

## 5. Verification

- `xcodebuild test` green (new pagination tests + updated bounds test by name).
- UI test (existing 4-tab assertion) untouched — no new tabs.
- Device matrix (user, 2 min): enable history, dictate 12+ short lines → two
  pages; page 2 shows older 2; delete down to 10 → footer collapses to "Page 1
  of 1", no empty page; Clear → page resets; statement reads "Newest 100".
- Zero warnings; no audio/coordinator/menu changes (this slice touches Storage
  + one pane only).

## 6. Risks / non-goals

- None to dictation: storage + pane only, coordinator untouched.
- Search/filter is explicitly NOT this fix (would need its own design: scope,
  matching, empty states). Pages solve the reported pain; say the word if you
  want search next.
- Open: keep 30-day age bound as-is? (Recommended yes — proposed above.)
