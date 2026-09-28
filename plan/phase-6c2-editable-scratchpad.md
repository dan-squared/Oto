# Slice 6C2 — editable Scratchpad — PLAN ONLY

Status: PLANNING ONLY. Nothing implemented. Awaiting `execute`.
Merge stays after this slice builds green + device pass (user call:
scratchpad before merge).

## 1. Goal and scope

Give the no-target transcript a key-capable editor. Today the catcher
modal is display-only with 2-line truncation: a long dictate-into-the-
void can only be copied whole, never fixed. 6C2 adds one explicit
surface — a standard titled Scratchpad window with a full-text
`TextEditor`, Copy, Insert, and Clear — reachable only via explicit
Edit affordances. The modal stays exactly as-is (nonactivating,
display-only); one surface visible at a time.

Explicitly OUT: mid-session edit-before-insert (no coordinator state
exists for it — §4 A3), formatting/AI (Phase 7), auto-opening the
scratchpad on any transition, per-app behavior, history writes from
edits (§4 A4).

## 2. Spec sources

- `Docs/OTO_REBUILD_PLAN/09_PRODUCT_DESIGN_AND_EXECUTION_PLAN.md` §3.7
  (canonical shape): safe buffer when the target is unavailable;
  standard utility window/panel with normal titlebar controls, no
  custom chrome; Insert honors target-liveness + clipboard
  protections; close never silently discards (confirm or retain).
- `plan/phase-6-flowbar-writing-history.md` §5F + Slice 6C-17/18
  (still valid): plain NSWindow titled/closable/resizable, must
  become key for TextEditor, NOT nonactivating; owner holds the SAME
  `RealTextInsertion` + `TargetCapturing` instances (app-scope,
  shared-inserter precedent); Insert = isAlive → insert → failure
  keeps text + reason, never direct paste, never frontmost
  substitution; close hides with text retained; explicit Clear with
  `confirmationDialog`; Copy mirrors menu.
- `plan/phase-6c-modal-and-media-duck.md` §2 (6C1 retention rule Q3):
  held text survives the next `begin`, closes only explicitly.
- `Oto/UI/FlowBar/FlowBarController.swift:284-301` (recovery router),
  `Oto/UI/OtoMenuBarView.swift:50-76` (menu Copy/Retry recovery),
  `Oto/UI/Scratchpad/NoTargetModal.swift` (modal to extend with Edit).

## 3. Facts verified against the local SDK (this session)

Toolchain: Xcode 27.0 (27A266a), Swift 6.4, `MacOSX27.0.sdk`.

| # | Claim | Evidence | Verdict |
|---|---|---|---|
| F1 | Nonactivating is what keeps the modal focus-free | `NSWindow.h:51,66`: `NSWindowStyleMaskNonactivatingPanel` = "does not activate the owning application", NSPanel-only | SOLID — and therefore a titled NSPanel WITHOUT that mask activates + takes key: exactly the 6C2 window. No guesswork about focus behavior. |
| F2 | App policy admits a normal key window | Dock default `.regular` (`DockVisibilityTests`: shown→regular); titled/key windows are standard citizen, no activation-policy workaround needed | SOLID |
| F3 | Coordinator exposes what Insert needs, no API change | `state` is `private(set)` with associated contexts (`.failed(ctx,_)` post-failure); `recoveryText()` exists for the menu path | SOLID — but see D1: we snapshot anyway |
| F4 | Shared-instance precedent exists | `OtoApp.swift:66-72` builds one `RealTextInsertion` shared by coordinator + menu Retry (`retryPostToFrontmost`) | SOLID — scratchpad takes the same two instances |
| F5 | `TextEditor` + `confirmationDialog` are plain SwiftUI | No custom text system, no AppKit editor subclass | SOLID; focus-on-open via `@FocusState`, device-verified |

## 4. Load-bearing decisions (assumptions questioned, settled)

- **D1. Snapshot (text, target) at takeText time; never re-read state
  at Insert time.** By Insert o'clock the coordinator may be in a new
  session (new context) or idle — re-reading would insert stale text
  into a live target or, worse, invite frontmost substitution. The
  snapshot IS the 02 liveness rule applied to an editor: the target
  recorded is the only target ever attempted (`isAlive` → insert;
  dead → kept + reason). If the snapshot somehow has no usable
  target, degrade to the menu's `retryPostToFrontmost` with the same
  honest copy — never a silent paste.
- **D2. One surface at a time; scratchpad owns the text after Edit.**
  Modal "Edit" → `takeText(modal.text)` + `modal.hide()`; the modal's
  copy is discarded, no divergence possible. Menu "Edit in
  Scratchpad" (new row next to Copy/Retry recovery) → `takeText` from
  `recoveryText()`. The scratchpad is never auto-shown — explicit
  affordances only, so it can never interrupt dictation.
- **D3. Retention = modal rule (Q3), close = hide + retain, Clear =
  confirm.** ✕ hides, text retained for the session, survives next
  `begin` (same rationale as the modal: killing it would destroy
  unpasted text). Only explicit Clear asks (09 §3.7 allows confirm
  OR retain — retain-on-close + confirm-on-Clear satisfies both
  halves). Escape hides (local, harmless, text retained) — it never
  touches sessions; the global Escape-cancel paths are untouched.
- **D4. No history write from edits.** History already holds the
  session final (recorded at finalize); the scratchpad is a working
  buffer, and re-recording edits would double-count and smuggle
  revisions into a final-text-only store (09 §3.8).
- **D5. Mid-session edit-before-insert stays deferred.** There is no
  coordinator edit state; inventing one pre-merge risks the session
  discipline that everything else stands on. Recovery editing is the
  data-loss case; the rest is a Phase-7-adjacent design, not smuggled
  in here.

## 5. Exact file changes

1. NEW `Oto/UI/Scratchpad/ScratchpadController.swift` — `@MainActor`
   `@Observable` owner (mirrors `NoTargetModalController` shape):
   `takeText(_:target:displayID:)`, `show`/`hide`/`isVisible`,
   `copy()` (same pasteboard discipline), `clear()` (flag for the
   view's `confirmationDialog`; untouched-text needs no confirm),
   `insert()` (D1 flow with feedback string: Inserted / target-closed
   kept / retry-fallback result). Holds `inserter: any TextInserting`
   + `targets: any TargetCapturing` (protocol seams — fakes exist).
   Window: titled `NSPanel` (closable/miniaturizable/resizable,
   standard traffic lights, NO `.nonactivatingPanel`), content =
   `NSHostingView(ScratchpadView)`, centered on the session screen
   via `FlowBarPanel.resolveScreen` (shared chain, no second recipe).
   Built once at app scope (prewarm precedent), `makeKeyAndOrderFront`
   only on explicit open.
2. NEW `Oto/UI/Scratchpad/ScratchpadView.swift` — SwiftUI content:
   full-text `TextEditor` (`@FocusState` on appear), char count
   caption, row: Copy / Insert / Clear + feedback line + ✕ (hide).
   No custom chrome (09 §3.7); sizing ~560×380, resizable.
3. EDIT `Oto/UI/Scratchpad/NoTargetModal.swift` — add "Edit" button
   next to Copy + `onEdit: ((String) -> Void)?` hook (nil in tests).
   ✕/Copy behavior unchanged.
4. EDIT `Oto/App/OtoApp.swift` — app-scope `ScratchpadController`
   with the SAME inserter + `RealTargetCapture()` instances as the
   coordinator; wire `modalController.onEdit` → takeText (with the
   failure context target — see 5) + modal hide. No coordinator
   change (F3: everything needed is already readable).
5. EDIT `Oto/UI/FlowBar/FlowBarController.swift` — expose the failure
   context target for the Edit handoff (the router already has
   `state`; pass `Self.targetScreen`-style context through, or expose
   `lastFailureTarget`). Smallest seam that carries (text, target,
   displayID); one-line amendment here at build start if the seam
   shape changes.
6. EDIT `Oto/UI/OtoMenuBarView.swift` — "Edit in Scratchpad" row in
   the recovery section (visible exactly when Copy/Retry are).
7. NEW `OtoTests/ScratchpadTests.swift` — settings-free (no new
   defaults key): takeText/show/hide/retention across synthetic
   begin, text-ownership (modal copy discarded after Edit — single
   owner), copy writes pasteboard, clear-flag semantics, insert
   routing with fakes (alive → insert called with snapshot text +
   target; dead → kept + reason; no-target → retry degrade, zero
   direct paste), style-bit pins (titled/closable/resizable present,
   `.nonactivatingPanel` ABSENT), key-capability (`canBecomeKey`).
   Focus-on-open is device-matrix, not unit-testable — stated, not
   faked.

## 6. Verification steps

- Build clean, zero warnings; new tests green; full suite green
  TWICE (standing rule).
- Gates: zero unwraps, no banned primitives, session-ID discipline
  untouched (no coordinator edit — verify by diff).
- Device (packaged `.app` only): modal Edit → scratchpad keyed with
  full text, cursor in field; edit → Copy → ⌘V in textbox lands
  edited text; target relaunched → Insert lands it; target still
  dead → honest kept + reason; ✕ → reopen retains; Clear → dialog,
  cancel keeps; next session → text survives; Escape hides, session
  unaffected; menu Edit row visible exactly with recovery; Oto
  activation never steals an in-flight session (scratchpad opens
  only post-failure/explicit).
- Merge preconditions extended: this slice green twice + device
  pass above, then merge rides as planned.

## 7. Risks / deferred

- TextEditor first-responder inside `NSHostingView` on first open:
  `@FocusState` is the standard path, but the matrix proves it —
  fallback is `window.makeFirstResponder(_:)` in `show`.
- Accessory-mode (Dock hidden): titled window still keys; matrix
  covers one accessory-mode open.
- Long-text performance: plain TextEditor, no highlighting —
  non-issue by construction; 50k-char paste is a matrix row, not a
  code path.
- Deferred (unchanged): mid-session edit-before-insert, per-app
  mute exceptions, Phase 7 intelligence (still gated behind the
  release gate + this merge).

## 8. Open questions

1. Insert-success: keep scratchpad open with "Inserted ✓" feedback
   (Copy precedent — user may need more), or auto-hide?
   Recommendation: STAY OPEN (recovery surfaces never dismiss
   themselves; ✕ is one click).
2. Menu row label: "Edit in Scratchpad" vs "Open in Scratchpad"?
   Recommendation: "Edit in Scratchpad" (names the verb).
3. Build 6C2 now pre-merge (this plan), or merge first and build on
   `main`? Recommendation: build HERE (branch already carries the
   modal it extends; one merge, not two) — but merge still waits
   for green + device, unchanged.
