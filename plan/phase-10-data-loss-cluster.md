# Phase 10 — data-loss cluster (recovery + clipboard honesty)

## Goal

Close the five audit P0s where Oto can lose user data while promising
recoverability: catcher Copy truncating long transcripts, clipboard
writes with no ownership discipline, the unconditional "never lost"
promise, History-off retention surprise, and unbounded Cmd-Z revert.
Small, headless-testable, no new frameworks, no behavior change except
where the current behavior destroys data.

## Spec sources (canonical first)

- `Docs/START_HERE_PRODUCT.md`: every uncertain result remains
  recoverable; never claim success from a paste event alone. These five
  items are the places the product currently violates its own sentence.
- Current code truth (read 2026-10-06):
  `Oto/UI/Scratchpad/NoTargetModal.swift:30-52` (display cap),
  `:102` (`text`), `:149-193` (`show`), `:205-251` (`showFromPill`),
  `:336-354` (`copy`); `Oto/UI/OtoMenuBarView.swift:55-83` (recovery
  Copy/Retry); `Oto/Settings/HistoryPane.swift:12-38` (toggle + copy),
  `:131-160` (disable path, Clear dialog precedent), `:162-166`
  (`copyEntry`); `Oto/Settings/SnippetsPane.swift:125-147`
  (`copyDraft`); `Oto/Settings/PolishSheet.swift:14-18`
  (`placePolishedOnClipboard`), `:59-73` (both footers write);
  `Oto/Settings/IntelligencePane.swift:58` (promise copy);
  `Oto/Storage/HistoryStore.swift:97-155` (record gate, `setEnabled`,
  `clearAll`); `Oto/Services/PasteboardOwnership.swift:21-68`
  (receipt + snapshot machinery); `Oto/Services/RealTextInsertion.swift:540-545`
  (manual-marker precedent); `Oto/Coordinator/DictationCoordinator.swift:560-584`
  (`canRevertPolish`, `revertLastPolish`, `LastPolish.at`).

## Facts verified against the local SDK (never from memory)

- ACP connected this session: workspace `Oto.xcodeproj`, scheme `Oto`,
  dest `My Mac`. Toolchain Xcode 27.0 (27A266a), Swift 6.4,
  `MacOSX27.0.sdk`, deployment target 27.0.
- This plan adopts **zero new framework APIs**: `NSAlert`,
  `.confirmationDialog`, `@AppStorage`, `PasteboardSnapshot`, and the
  `markerType` pattern are all already in-tree. No "What's new" surface.
- `LastPolish.at` is already a `Date` (wall-clock appropriate: the
  window is user-perceived minutes, not monotonic intervals).

## Assumptions questioned

1. "`showFromPill` routes through `show()`." FALSE — verified: it
   duplicates the truncation at `:215` instead of calling `show()`.
   Both entry points must store full text, ideally via one shared
   helper, or the morph path stays lossy while the plain path is fixed.
2. "Confirm dialogs fight the focus-steal defense." No — the defense
   covers *uninvited* UI. All five writes happen on explicit user
   clicks, where brief modality is standard macOS behavior.
3. "Snapshot-and-restore is safer than confirm." No — snapshots create
   restore-UX debt (where does restore live? how long is a password
   kept?). Confirm-then-write keeps the clipboard model obvious. (Q1.)
4. "The revert window needs input-quiet detection." Out of scope: no
   keystroke counter exists, and a timestamp window already converts
   unbounded risk into a 60-second one. Note as future work, not this
   phase.

## Design (decisions + reasons)

**A. Catcher full-text Copy (P0-1).**
- Controller gains `private(set) var fullText = ""` plus `private func
  store(_ text: String)` setting both `fullText` (full) and `text`
  (display-capped). `show()` AND `showFromPill()` call it (the dual
  entry points are the load-bearing detail). Card height, logs, and
  pixels keep using display text. `copy()` pastes `fullText` (fallback
  to `text` if empty — defensive; copy only fires post-show).
- The `CatcherText` header promise ("data never truncates") becomes
  true again; no comment change needed. No extra "full text" UI: "…"
  already signals more, and Copy doing the full thing is least
  surprise (matrix confirms).

**B. Clipboard-write discipline (P0-2 family).**
- New pure helper in `PasteboardOwnership.swift`:
  `ClipboardOverwriteGuard.shouldConfirm(board:) -> Bool` — true iff
  the board holds a non-empty string AND carries no Oto marker.
  Assumption stated: marker presence ⟺ Oto was the last writer (any
  user copy clears all types including the marker; freak apps
  preserving unknown types are negligible).
- All five manual writers set a fresh marker UUID alongside content
  (insertion-path precedent, `:544`): menu recovery Copy, catcher
  `copy()`, history `copyEntry`, snippet `copyDraft`, sheet
  Keep/Original. Marker-vs-receipt safety proven: receipts compare
  their own UUID strings; a manual marker can never equal a live
  receipt, and `placeOnClipboard` overwrites it on the next insertion.
- Confirm UI by surface kind: SwiftUI (history, snippet editor, sheet
  both buttons) → `.confirmationDialog("Replace clipboard contents?")`
  with "Replace"/Cancel, shown only when the guard is true (empty or
  Oto boards keep zero-friction writes). AppKit (menu, catcher) →
  `NSAlert` before `clearContents`; Cancel returns early with no
  state change (catcher: no generation bump, no auto-close).

**C. History-off promise (P0-3, product call).**
- Recommended: conditional copy, not unconditional and NOT silent raw
  retention (recording while History is off would violate off-means-off
  — rejected explicitly). `IntelligencePane` reads the same
  `historyEnabled` key (`HistoryPane.swift:16` precedent); footnote
  becomes pure `cleanupFooting(historyEnabled:)` — on: current
  sentence; off: "Your original words are only kept while History is
  on — turn it on in History to keep originals." Unit-tested pure
  function; matrix flips the toggle.

**D. History disable disclosure (P0-4).**
- Intercept toggle-off in `HistoryPane`: entries exist → confirm
  dialog ("Turn off History?", "Off stops new saves. N existing
  entries stay on this Mac until cleared.", buttons: "Delete N
  entries" destructive → `clearAll` + flip; "Turn off, keep entries"
  → flip; Cancel). Empty → flip directly, no dialog. Detail copy
  gains "; existing entries stay until cleared." Store behavior
  (`setEnabled` never deletes) pinned by explicit test — the dialog
  owns deletion, documented as such. Page-reset interplay unchanged.

**E. Revert path deletion (P0-9 — decided: delete, not window).**
- Remove the menu "Revert to original wording" row, its polling
  (`canRevertPolish`), its feedback copy, the coordinator's
  `revertLastPolish`/`canRevertPolish`/`lastPolish` state and the
  `LastPolish` struct. The OS owns undo (Cmd-Z/Cmd-Shift-Z); History's
  Undo AI edit + Copy remains the single raw-recovery path.
- Rationale recorded 2026-10-06: don't build a second undo stack on top
  of the OS one. Deletion removes the footgun class instead of
  mitigating it with a timer (no window logic left to be buggy).
  Accepted cost: with History off there is no in-app raw recovery —
  consistent with the P0-3 bargain (off means nothing is kept), now
  stated honestly instead of implied.
- Tests: retire the coordinator revert tests; assert removal by
  compilation (no references to `revertLastPolish`/`canRevertPolish`/
  `lastPolish` remain — grep-verified); History Undo tests stay as the
  pinned single path.

## Exact file changes

1. `Oto/UI/Scratchpad/NoTargetModal.swift` — `fullText` + `store()`;
   both `show()` and `showFromPill()` route through it; `copy()`
   pastes full (fallback display).
2. `Oto/Services/PasteboardOwnership.swift` — `ClipboardOverwriteGuard`
   pure helper (+ tests: empty→false, foreign→true, Oto-marked→false).
3. `Oto/UI/OtoMenuBarView.swift` — marker on recovery Copy + NSAlert
   confirm on guard-true.
4. `Oto/UI/Scratchpad/NoTargetModal.swift` (`copy`) — marker + NSAlert
   confirm; cancel path leaves card open, untouched.
5. `Oto/Settings/HistoryPane.swift` (`copyEntry`) — marker +
   confirmationDialog on guard-true.
6. `Oto/Settings/SnippetsPane.swift` (`copyDraft`) — marker +
   confirmationDialog on guard-true.
7. `Oto/Settings/PolishSheet.swift` (both buttons) — marker +
   confirmationDialog on guard-true. (Also fixes the stale header:
   "Use original / dismiss writes nothing" is false — Original writes
   raw. Correct the comment in passing.)
8. `Oto/Settings/IntelligencePane.swift` — conditional footnote via
   pure `cleanupFooting(historyEnabled:)` (+ new `OtoTests/
   IntelligencePaneTests.swift` — or nearest existing home at
   implement time; pure function, no hardware).
9. `Oto/Settings/HistoryPane.swift` (toggle) — disable-confirm dialog
   + detail-copy update.
10. `Oto/Storage/HistoryStore.swift` — no behavior change; add explicit
    test pinning `setEnabled(false)` preserves entries.
11. `Oto/Coordinator/DictationCoordinator.swift` — `revertWindow` +
    time-aware `canRevertPolish(now:)`; `revertLastPolish` honors it.
    Tests: boundary via injected `now` (59 s available / 61 s expired —
    thin live-Date seam inside `revertLastPolish` stated as accepted).
12. `OtoTests/NoTargetModalTests.swift` (verify name at implement time)
    — long-text Copy round-trip through BOTH `show()` and
    `showFromPill()`: full string lands, display stays capped.

## Verification steps

- `xcodebuild -scheme Oto -destination 'platform=macOS' build` green;
  `xcodebuild test -scheme Oto` green (new: catcher long-copy ×2
  entries, guard matrix, footing strings, store no-delete pin, revert
  boundaries; all existing pins incl. fixed-preset strings).
- ACP `RunSomeTests` on the touched suites.
- Live matrix (packaged app for clipboard-focus truth):
  1. Long dictation → void → catcher Copy → full paste; card still capped.
  2. Foreign clipboard (password) + each of the 5 Copy paths → confirm
     appears; Cancel preserves; Replace writes.
  3. Oto-marked board + Copy paths → no confirm (zero friction).
  4. History off/on → footnote flips; off disables raw retention
     (nothing recorded — verify via store file).
  5. Disable with N entries → dialog Delete/Keep/Cancel all correct.
  6. Revert row gone from menu; grep proves zero references to
     `revertLastPolish`/`canRevertPolish`/`lastPolish`; History Undo +
     Copy remains the recovery path.

## Risks / deferred decisions

- NSAlert modality vs focus defense: explicit-click-only, stated
  acceptable. If matrix shows focus weirdness, fall back to
  confirm-later design (deferred, not planned).
- Marker types ride along in snapshots/restores (full-fidelity capture
  keeps all types) — harmless: receipts pair marker+changeCount they
  create; stale manual markers never match.
- Revert deletion is total (no window value to tune, no timer to be
  buggy); History-off users rely on the P0-3 honest copy.
- PolishSheet header comment corrected as a drive-by (stale claim).
- Deferred: input-quiet detection for revert, snapshot-restore
  alternative (rejected, Q1), per-surface "full text" affordances
  (rejected, matrix confirms).

## Open questions (recommendations marked)

- Q1 Confirm-vs-snapshot for clipboard writes? (Recommended: confirm —
  snapshots create retention/restore UX debt.)
- Q2 Revert window 60 s vs 120 s? (Recommended: 60; matrix judges.)
- Q3 Extra "full text copies" disclosure on the catcher card?
  (Recommended: no — "…" suffices; matrix confirms.)
