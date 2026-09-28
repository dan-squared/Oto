# Slice 6C2 v2 — editable Scratchpad with pill-lineage morph — PLAN ONLY

Status: PLANNING ONLY. Nothing implemented. Awaiting `execute`.
Supersedes `plan/phase-6c2-editable-scratchpad.md` v1 (Insert-based):
user cuts applied — NO Insert button (Copy + Clear only), morph
animation required, AI-ready architecture required, appearance-aware
required, all v1 recommendations adopted. Merge still waits for green
+ device pass.

## 1. Main issue: why no scratchpad functions today

Audited prior AI deliverables (plans, code, run/test commands) against
the tree — findings with evidence:

| # | Prior AI output | Audit verdict |
|---|---|---|
| A1 | Run-app command (`pkill` + build + `open` the signed `.app`) | CORRECT — launches the packaged app; TCC/AX valid. Not the cause. |
| A2 | 6C1 catcher modal (`NoTargetModal.swift`, router, tests) | FUNCTIONS — suite green, device-confirmed. Display-only by design. |
| A3 | Menu Copy/Retry recovery (`OtoMenuBarView.swift:50-76`) | FUNCTIONS — tested, honest failure copy. |
| A4 | 6C2 v1 plan (this slice, Insert + coordinator seam) | SUPERSEDED — never built (planning only), and its Insert design is now cut by the user. This v2 replaces it. |

**Root cause (structural, not a bug): no editable scratchpad exists
anywhere in the tree** — grep for `ScratchpadWindow`,
`ScratchpadController`, `ScratchpadView`, `onEdit` across `Oto/` +
`OtoTests/` returns ZERO hits; `Oto/UI/Scratchpad/` holds only
`NoTargetModal.swift`. And one cannot be bolted onto the modal: the
shared panel recipe (`FlowBarPanel.swift:54-76`, styleMask
`[.borderless, .nonactivatingPanel]`, `becomesKeyOnlyIfNeeded = true`)
makes key status impossible — `.nonactivatingPanel` means "does not
activate the owning application" (`NSWindow.h:51,66`). No key window
⇒ no focus ⇒ no `TextEditor` ⇒ no editing, ever, on the current
surface. A separate key-capable window is mandatory, not optional.
Contributing defect: the modal hardcodes its dark card
(`NoTargetModal.swift:111-113`, `Color(red:0.055,…)`), so it is blind
to appearance — fixed for both surfaces by the shared palette (§5).

## 2. Goal and scope (v2 deltas marked ★)

Explicit Edit affordances (catcher-modal "Edit" + menu "Edit in
Scratchpad") open a standard key-capable Scratchpad window that
★MORPHS out of the pill lineage: the modal's floating panel grows
into the editor in one fast native animation. Editor holds full text
with Copy + Clear (+ ★Revert to original — the AI undo anchor, not
insertion). ★No Insert button anywhere (user cut — this deletes v1's
inserter wiring, target snapshot, and FlowBarController seam: the
diff shrinks to modal + menu + two new files). ★Appearance-aware
modal AND scratchpad via one shared adaptive palette. ★AI-ready by
construction: immutable `rawText` + editable `workingText` with a
documented transform seam for Phase 7 (§4 D5), nothing AI built now.

OUT: Insert/retry from scratchpad (menu Retry stays the insert path),
mid-session editing (still deferred — §4 A3 stands), auto-open,
formatting, history writes from edits.

## 3. Spec sources

- 09 §3.7 (canonical): standard window, normal titlebar, no custom
  chrome; close retains or confirms; Insert honors liveness (moot —
  no Insert; Copy/Retry paths already honor it).
- Phase-6 §5F window half (titled/closable/resizable, must key, close
  hides + retains, Clear confirms, Copy mirrors menu) — insert half
  DROPPED per user cut.
- 6C1 Q3 retention (survives next `begin`), modal file for the Edit
  hook + palette fix, menu file for the Edit row.
- 02 recovery table (Copy/Scratchpad as the named outcomes).

## 4. SDK facts verified (this session; Xcode 27.0, MacOSX27.0.sdk)

- F1: `.nonactivatingPanel` ⇒ no activation (`NSWindow.h:51,66`);
  therefore a titled `NSPanel` WITHOUT the mask activates + keys —
  the 6C2 window. Same citation as v1, unchanged.
- F2: Frame + alpha are render-server animatable via the `animator()`
  proxy (codebase precedent: modal `show`, pill resize/land,
  ghost fade — all `NSAnimationContext` + `.animator()`). The morph
  needs no new animation primitive: it composes two proven ones.
- F3 (honest limit): SwiftUI `matchedGeometryEffect` CANNOT cross
  `NSWindow`s — the morph is an AppKit frame morph + SwiftUI content
  crossfade timed as one gesture, NOT a matched-geometry morph.
  Stated so nobody reaches for the impossible.
- F4: Dock `.regular` default — titled key window is a standard
  citizen, no policy workaround.

## 5. Exact file changes

1. NEW `Oto/UI/Scratchpad/ScratchpadController.swift` — `@MainActor`
   `@Observable` (modal-controller shape): `rawText` (immutable
   session final, the future-AI input + Revert source), `workingText`
   (editable; Copy reads this), `takeText(_:displayID:)`,
   `show`/`hide`/`isVisible`, `copy()` (pasteboard discipline +
   "Copied" feedback, stays open), `revert()` (working ← raw),
   `clear()` (arms the view's `confirmationDialog`). Window: titled
   `NSPanel` (closable/miniaturizable/resizable, standard lights,
   NO `.nonactivatingPanel`; `.floating` level +
   `[.canJoinAllSpaces, .fullScreenAuxiliary]` + `hidesOnDeactivate
   = false` so it stays while the user clicks a textbox),
   `NSHostingView(ScratchpadView)`, prewarmed at app scope (modal
   prewarm precedent — the morph can never wait on construction).
   ★AI seam (documented, unbuilt): Phase 7 adds
   `draft(_:)` producing a reversible third value from `workingText`
   with undo back through `[working, raw]`; scratchpad text is NEVER
   auto-sent (09: explicit opt-in).
2. NEW `Oto/UI/Scratchpad/ScratchpadView.swift` — full-text
   `TextEditor` with `@FocusState` on appear, char-count caption,
   buttons Copy / Revert / Clear + feedback + ✕. Adaptive palette
   (§6), ~560×380, resizable.
3. NEW `Oto/UI/Scratchpad/ScratchpadPalette.swift` — ★one adaptive
   palette struct owned by NOBODY's view: card fill, text, hint,
   button tint for `.light`/`.dark`. Both modal + scratchpad render
   through it (no drift, ever). Pure → unit-tested (dark≠light,
   sane contrast both).
4. EDIT `NoTargetModal.swift` — render through palette (fixes the
   hardcoded dark card); add "Edit" button + `onEdit: ((String)
   -> Void)?` (nil in tests); Copy/✕/retention unchanged.
5. EDIT `OtoApp.swift` — app-scope `ScratchpadController`;
   `modalController.onEdit` → `scratchpad.takeText` + `modal.hide()`
   + ★`morphFromModal()` (§7). No coordinator change, no inserter
   wiring (no Insert — v1's two hardest seams deleted).
6. EDIT `OtoMenuBarView.swift` — "Edit in Scratchpad" recovery row
   (visible exactly when Copy/Retry are) → same `takeText`.
7. NEW `OtoTests/ScratchpadTests.swift` — takeText/show/hide,
   retention across synthetic begin, single-owner (modal copy dead
   after Edit), raw/working split + revert, copy writes working
   text, clear-flag semantics, NO-insert pin (no inserter reference
   — compile-level guarantee), palette tests, style-bit pins
   (titled/closable/resizable present, `.nonactivatingPanel`
   ABSENT, `canBecomeKey`). Morph timing/focus-on-open are
   device-matrix (stated, not faked).

## 6. Appearance (★user requirement)

Palette drives both surfaces; matrix covers light + dark for modal,
scratchpad, and the morph between them. Dark keeps the current
near-black card (reference look, pinned by palette test); light gets
a system-card equivalent with dark text. No hardcoded fills remain
(grep-gate).

## 7. Morph animation (★user requirement — fast, native, no lag)

Choreography on Edit (single 0.2s `.easeOut` gesture, render-server
only — the same animator path as pill land + modal show, zero new
primitives, zero layout passes mid-flight):
1. Scratchpad prewarmed (hidden) at build — never constructed
   on the gesture (the lag source this preempts).
2. Start frame = modal's current frame, alpha 0 → `orderFront`
   (no key yet) → animate frame to the centered 560×380 end frame
   + alpha → 1, while modal content alpha → 0 → `orderOut` at
   completion → `makeKeyAndOrderFront` + `@FocusState` lands the
   caret. One surface grows out of the other; nothing flashes,
   nothing travels across the screen.
3. Lineage note (honest): the pill itself is already gone at
   failure time (v6 vanish path — keeping it alive would break the
   no-end-state-pixels rule), so the morph grows the modal, which
   IS the pill's descendant on the same session screen. A literal
   pill→editor morph would require resurrecting the pill behind
   the modal — considered, rejected (breaks v6, gains nothing
   visually since modal≡pill-lineage).
4. Reduce Motion: instant swap, no travel (codebase honors it in
   the pill; same gate here) — device matrix row.

## 8. Verification steps

- Build clean zero warnings; new tests green; full suite green
  TWICE; gates (unwraps, banned primitives, no-coordinator-diff).
- Device (packaged `.app`): morph feels instant (<0.25s, no hitch
  on repeat Edit), Reduce Motion swaps instantly; light + dark
  modal/scratchpad/morph; caret in field on open; edit → Copy →
  ⌘V lands edited text; Revert restores raw; Clear dialogs,
  cancel keeps; ✕ retains; next session survives; Escape hides,
  session untouched; menu Edit row parity; Oto activation never
  disturbs a live session (scratchpad opens post-failure/explicit
  only); 50k-char paste scrolls, no beachball.
- Then merge (preconditions: this slice green twice + this matrix).

## 9. Risks / deferred

- `@FocusState` in hosting on first key: matrix proves; fallback
  `window.makeFirstResponder(_:)` in `show` (no extra build).
- Accessory-mode open: one matrix row.
- Morph interrupted (Edit twice fast): idempotent `takeText` +
  generation guard on the animation (pill melt precedent).
- Deferred (unchanged): mid-session editing, Insert-from-scratchpad
  (cut, not deferred — menu Retry is the path), Phase 7 drafts
  (seam ready, §5.1), per-app mute exceptions.

## 10. Open questions — none. All v1 questions adopted as
recommended (stay-open feedback, "Edit in Scratchpad", build here
pre-merge), Insert cut per user, morph/AI/appearance specified
above. The only decision left is `execute`.
