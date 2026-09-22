# Catcher void-case fix + editable Scratchpad (morph) — PLAN ONLY

Status: PLANNING ONLY. Nothing implemented. Awaiting `execute`.
Supersedes `plan/phase-6c2-scratchpad-v2.md` (which stands for the
scratchpad half; §B restates it with deltas). This file adds §A, the
fix the user reported: **the catcher never appears for the primary
no-textbox case**. Both halves build pre-merge, in order A → B
(the scratchpad's Edit entry points assume a catcher that fires).

## A. Root cause: dictating into the void reports success

Code trace (all verified in-tree today, no guessing):

1. Dictate with Finder/desktop (or any live app with no focused
   field) → `RealTargetCapture` captures a live target with a pid.
2. `RealTextInsertion.insert` (`RealTextInsertion.swift:172-256`):
   trusted ✓, no secure input ✓, pid ✓, `reactivate` ✓ (already
   frontmost), clipboard verifies, focus race-guard passes,
   `postPaste()` fires Cmd-V into Finder — which visibly does
   nothing — and line 255 returns `.inserted`.
3. `.inserted` means "posted, never proven" (the file's own comment,
   `:152`). Coordinator → `.completed`. No failure ⇒
   `RecoveryRouter.route` returns nil (`FlowBarState.swift:149+`
   matches ONLY `targetGone`/`insertionFailed` with kept text) ⇒
   **no catcher, ever**, and the clipboard restores 100 ms later —
   the transcript is gone everywhere except opt-in history.

So the 6C routing rule ("nowhere to paste ⇒ targetGone/
insertionFailed") was wrong for the liveness half: a live app with
no editable focus inserts into the void and calls it success. The
6C1 device confirmation covered `targetGone`; the void case was
never in any matrix. That is the whole bug — no other surface is
implicated (audit: run command correct, modal path functions where
its trigger fires, menu recovery functions).

## B. Fix design: editable-focus check before the clipboard is touched

Divert — never fail destructively — when the target has focus but
no editable field holds it. Order inside `insert()`, after
`reactivate` (focus is meaningful only once the target is frontmost),
BEFORE `placeOnClipboard` (clipboard-untouched discipline holds):

```
trusted? → secure? → pid? → reactivate? → FOCUS-CHECK → clipboard → race-guard → post
                                              │
                       .editable → proceed (behavior identical to today)
                       .noField  → return .noEditableField (no paste, clipboard untouched)
                       .unknown  → proceed (old behavior preserved exactly)
```

- Check primitive (public AX only, no new entitlement — runs behind
  the existing trust gate; untrusted fails closed before reaching
  it): `AXUIElementCreateApplication(pid)` → copy
  `kAXFocusedUIElementAttribute` → copy `kAXRoleAttribute` →
  editable iff role ∈ {`AXTextField`, `AXTextArea`} (SDK-verified
  today: `AXAttributeConstants.h:1009` + `:45`,
  `AXRoleConstants.h:360-361`, `AXUIElement.h:148`). Wrapped in a
  ~300 ms timeout → `.unknown` (a hung target can never stall
  finalization; worst case is today's behavior).
- New `InsertionResult.noEditableField` (`Transcript.swift:33-36`;
  additive — fakes flow through). Coordinator maps it to a new
  `DictationFailure.noTextField` (no payload; join the `==`
  no-payload group; `lastSessionSummary` → "no text field focused"),
  keeps `recoveryTranscript`, sets `.failed`. Router extends its
  match to `.noTextField` — the modal's existing hint ("Select a
  textbox first, then dictate") is already word-perfect for this
  case, zero copy change. Exhaustive `switch`es over either enum
  are compiler-caught at build (noted so none are missed:
  `==`, summary, router, plus whatever the build names).
- Seam: `FocusChecking` protocol (fake in tests; live default in
  `RealTextInsertion.init`, same injected-events precedent as
  `InsertionEvents`). No coordinator API change; no entitlement
  change; no AX write anywhere (read-only check + existing
  keystroke post — nothing new for sandbox review beyond what
  ships today; device proves it).
- Bias statement (questioned, settled): on a positive "no field"
  finding we divert to the catcher; on ANY uncertainty we insert
  exactly as today. Cost of a false catcher = one Copy click with
  text preserved; cost of a false void-insert = text gone. The bias
  is data-preserving in the only direction that matters, and the
  timeout+unknown path bounds the exotic-AX-tree blast radius to
  zero behavior change.

## C. Scratchpad (v2 restated with deltas)

Unchanged from v2: Edit affordances (modal "Edit" + menu "Edit in
Scratchpad", visible exactly when recovery is) open a standard
titled key-capable `NSPanel` (no `.nonactivatingPanel`) that MORPHS
from the modal's frame (0.2s easeOut render-server frame morph +
content crossfade; `matchedGeometryEffect` cannot cross NSWindows —
stated, not attempted; prewarmed; Reduce Motion = instant swap);
full-text `TextEditor` with `@FocusState`; Copy + Clear +
Revert-to-original only (NO Insert — v1's inserter/target/
FlowBarController seams stay deleted); immutable `rawText` +
editable `workingText` with a documented (unbuilt) Phase-7 draft
seam, never auto-sent; ONE adaptive palette driving modal +
scratchpad (kills the hardcoded dark card); retention = modal rule
(survives `begin`, ✕ retains, Clear confirms, Escape hides
session-untouched); single owner after Edit; no history writes;
mid-session editing still deferred. Deltas vs v2: NONE except this
file now also owns the §A entry points (the Edit buttons assume a
catcher that fires — hence order A → B).

## D. Exact file changes (both halves)

§A (catcher fix):
1. NEW `Oto/Services/EditableFocusCheck.swift` — `EditableFocus`
   (`editable`/`noField`/`unknown`, pure role mapping, unit-tested),
   `FocusChecking` protocol, live AX implementation + timeout
   wrapper. No prints, no unbounded work, read-only AX.
2. EDIT `Oto/Models/Transcript.swift` — `InsertionResult` +=
   `.noEditableField`.
3. EDIT `Oto/Services/RealTextInsertion.swift` — injected
   `FocusChecking` (default live); check sited per §B; divert
   returns `.noEditableField` pre-clipboard.
4. EDIT `Oto/Models/DictationState.swift` — `DictationFailure` +=
   `.noTextField` (+ `==` group + summary copy).
5. EDIT `Oto/Coordinator/DictationCoordinator.swift` — map
   `.noEditableField` → kept recovery + `.failed(.noTextField)`
   (one branch beside the insert `switch`; session-ID discipline
   identical).
6. EDIT `Oto/UI/FlowBar/FlowBarState.swift` — router matches
   `.noTextField` (modal ON) / auto-copy (OFF, unchanged path).
7. Tests: focus-mapping units (textField/textArea→editable,
   button/static/webArea→noField, error/nil→unknown), fake-focus
   insertion tests (noField→clipboard untouched + zero posts;
   unknown→full legacy path), router `.noTextField` both settings,
   coordinator mapping (failed + kept + insert-attempted-exactly-
   once), summary copy pin.
§B (scratchpad): v2 §5 items 1-4, 6-7 (item 5's FlowBarController
seam stays deleted — no Insert needs no target).

## E. Verification steps

- Build clean zero warnings; new tests green; full suite green
  TWICE; gates (unwraps, banned primitives, coordinator diff shows
  only the mapping branch).
- Device §A (packaged `.app`, AX granted): Finder/desktop focused
  → catcher (was: silent success); Safari page body, VS Code
  editor, Terminal, Slack composer, Chrome omnibox matrix
  (editable→inserts as today; non-editable→catcher); password
  field (secure path unchanged); AX revoked (untrusted path
  unchanged); hung-app timeout row if reproducible; auto-copy OFF
  → clipboard path for the void case too.
- Device §B (v2 §8 verbatim): morph <0.25s no hitch + RM instant;
  light/dark modal/scratchpad/morph; caret on open; edit→Copy→⌘V;
  Revert; Clear dialog; ✕ retains; next-session survives; Escape;
  menu parity; 50k-char scroll.
- Then merge (preconditions: A+B green twice + both matrices).

## F. Risks / deferred

- AX-role exoticism (custom views, Java/Qt, combo boxes): bounded
  by unknown→proceed; matrix rows decide whether `AXComboBox`
  joins the editable set — a data change, not a redesign.
- Sandbox AX-read denial (can't be proven headless): reads degrade
  to `.unknown` ⇒ today's behavior; the matrix proves or kills it
  on the real signed build. No new entitlement exists for this —
  same trust as the shipping keystroke path.
- Morph interruption + accessory mode + focus fallback: v2 §9
  verbatim.
- Deferred (unchanged): mid-session editing, Insert-from-scratchpad
  (cut), Phase 7 (seam ready), per-app mute exceptions.

## G. Open questions — none. Order A → B, build pre-merge, merge on
green + matrices. The only decision left is `execute`.
