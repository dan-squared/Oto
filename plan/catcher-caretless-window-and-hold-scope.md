# Plan — catcher for caret-less windows, scoped hold rule, menu-bar cleanup

Status: **executed 2026-10-29** (build green, 601 unit tests + UI test green).
Date: 2026-10-29. Repo: `p3-verdict-parked` @ `ec1567d` (`origin/main`).

---

## 1. Goal

Three separate defects, one session, ordered by severity:

1. **Phantom success (Windscribe).** Dictating into an app whose focused
   element is a *window* with no caret reports `completed, inserted` and
   shows **no catcher**, even though nothing was pasted. This is the
   report: *"the catcher is failing… on windscribe there is no active
   field but nothing about the catcher is visible"*. Fix the truth, not
   the message: the pre-paste gate must divert.
2. **Over-broad hold rule.** Any keystroke while a bare-modifier hold is
   down marks the hold as "combination use" and swallows its release, so
   a long hold-to-talk is discarded by an unrelated chord (e.g. Right ⌥
   held + ⌘1). The rule must apply only to chords that actually use the
   held modifier.
3. **Menu bar noise.** Remove the status line, the Escape warning and the
   `Copy recovery transcript` / `Retry paste to frontmost app` block from
   the production menu. Recovery is owned by the catcher / auto-copy.

---

## 2. Evidence (verified, not assumed)

### 2.1 Logs (`.context/attachments/JoRo0b`, `Tdro2F`)

Windscribe, `com.windscribe.client` pid 56078:

```
begin 1BE74604 mode=holdToTalk target=com.windscribe.client
speech finished delivered=11 dropped=0 convFail=0 chars=15
ready pid=56078 frontmost=true elapsed=129ms post-auth=true
focus pid=56078 app=com.windscribe.client verdict=unknown axerr=nil role=AXWindow sel=false src=syswide timeout=false
posted HID Cmd-V for target 56078
delivery=unverifiable elapsed=0ms chars=15
completed, inserted 15 chars
```

Finder and Dia on the same build:

```
focus … verdict=unknown … role=AXGroup sel=true
delivery=notLanded elapsed=317ms chars=…
```

So the catcher *does* fire wherever the delivery probe can sample a caret
(`sel=true`). The failure is the app shape where the probe is unavailable
**and** the focus verdict is `.unknown`: the paste is posted, nothing
lands, and `.unverifiable` is treated as success by design
(`DeliveryVerification`).

### 2.2 Live AX dump (`.app` bundle, trusted)

```
$ open -n -W -a …/Debug/Oto.app --stdout … --stderr … --args --ax-dump=com.windscribe.client

focusedElement role=AXWindow sub=AXDialog focused=true selRange=false kids=1
focused editableAncestor=nil
focused focusableAncestor=nil
focused parent=role=AXApplication title="Windscribe" selRange=false kids=4
focused webContent=false
ancestors AXWindow < AXApplication
  role=AXScrollBar focused=false selRange=false
    ▸ delivery sample=CaretSample(location: 0, length: 0, characters: 0)
```

The only caret publisher in the whole window is a scroll bar. The focused
element is the window itself: **nothing inside the app has focus**, so
there is nothing to paste into. `webContent=false`, so this is not the
web-editor ambiguity v6 was protecting.

### 2.3 Code paths confirmed

- `EditableFocus.classify(role:subrole:pidMatches:)` returns `.unknown` for
  `AXWindow` (containers are deliberately absent from `nonEditableRoles`).
- `RealTextInsertion` maps `.noField` → `.noEditableField` (catcher,
  clipboard untouched); `.unknown` proceeds to paste.
- `DeliveryProbe` on the same caret-less element yields no sample →
  `.unverifiable` → success.
- `HIDEventMonitor.markAllHoldsCombinationUse()` runs on **every**
  `keyDown`/`keyUp`/mouse-down, regardless of the event's flags, and
  `ModifierHoldState.step(.otherActivity)` has no parameter, so the hold
  cannot tell a chord-with-its-own-modifier from an unrelated key.
- `TransformRunner` cancels only a *fresh* hold (`< 1 s`) and then vetoes
  while dictation is live — with the old over-broad rule a same-family
  chord could therefore lose both actions.
- `OtoMenuBarView` owns `status`, `escapeUnavailable` and the two recovery
  buttons; `RecoveryRouter` already routes `.noTextField`,
  `.targetGone`, `.insertionFailed` to the catcher / auto-copy.

---

## 3. Root causes

**A. Gate is capability-first, but "focused element is the window itself"
is positive evidence of no field.** v6 diverts only on positive evidence
(widget roles, desktop shells) because containers *can* host a caret.
A window cannot host a caret, and this one publishes no caret either. The
gate has the caret fact available (`selectedTextPresent`) but does not use
it in the verdict.

**B. `.unverifiable` is the only remaining success claim with no evidence.**
For Windscribe the post is posted into a window, and the probe legitimately
has nothing to sample. Turning the gate honest removes this case; the
delivery table stays as-is (web editors depend on it).

**C. Combination rule conflates "another input" with "a chord with this
modifier".** Option-U is a chord with Option; ⌘1 while holding Option is
not. Only the first should disqualify a hold.

---

## 4. Design

### 4.1 Workstream 1 — caret-less window diverts (primary fix)

Add a **caret-presence** input to the pure classifier, defaulted to
"assume caret" so every existing call site and test keeps its behaviour:

```swift
nonisolated static func classify(
    role: String?, subrole: String? = nil, pidMatches: Bool = true,
    publishesCaret: Bool = true
) -> EditableFocus
```

New narrow table — roles that **cannot** take a caret and are not web
containers:

```swift
nonisolated static let caretlessContainerRoles: Set<String> = [
    kAXWindowRole, kAXSheetRole, kAXDrawerRole, kAXScrollAreaRole,
    kAXSplitGroupRole, kAXToolbarRole, kAXTabGroupRole,
]
```

Rule order in `classify`:

1. `pidMatches == false` → `.unknown` (unchanged).
2. text-capable → `.editable` / `.secureField` (unchanged).
3. `nonEditableRoles` → `.noField` (unchanged).
4. **`caretlessContainerRoles.contains(role) && !publishesCaret` → `.noField`** (new).
5. otherwise `.unknown`.

`readFocusedElement` computes `selectedTextPresent(element:)` **once**,
before `classify`, passes it as `publishesCaret`, and reuses it for
`FocusRead.hasSelectedText` (no extra AX round-trips). The existing
`webContentHidesEditable` guard stays exactly where it is and demotes any
`.noField` inside a web area back to `.unknown`, so browsers keep today's
behaviour.

Deliberately **excluded** from the new table (documented in code):
`AXGroup`, `AXLayoutArea`, `AXWebArea`, `AXBrowser`, `AXTable`, `AXList`,
`AXRow`, `AXCell`, content roles. Those are the shapes measured to host
carets without publishing one, and the false-divert risk outweighs the
gain — Finder/Dia already catch through `notLanded`.

Effect on the measured shapes:

| App | focused role | sel | new verdict | result |
|---|---|---|---|---|
| Windscribe | `AXWindow` | false | `.noField` | catcher, no paste |
| Finder | `AXGroup` | true | `.unknown` | unchanged (notLanded) |
| Dia | `AXGroup` | true | `.unknown` | unchanged (notLanded) |
| Native text field | `AXTextField` | — | `.editable` | unchanged |
| Muse composer | `AXButton` in web area | — | `.unknown` | unchanged |
| Chrome page, no field | `AXWebArea` | false | `.unknown` | unchanged (proceeds) |

No change to `DeliveryOutcome`: `.unverifiable` remains success for the
cases that still reach it.

### 4.2 Workstream 2 — scope the hold rule to the held modifier

Replace the parameterless `otherActivity` with an explicit chord signal:

```swift
enum HoldEvent: Equatable, Sendable {
    case flags(down: Bool)
    /// Another input arrived. `usesHeldModifier` is true when that input's
    /// CGEventFlags contain this slot's modifier family — i.e. the modifier
    /// is being consumed as part of a chord (⌥U, ⌘1 while holding ⌘,
    /// ⌥-click). Independent input (⌘1 while holding ⌥, a plain click, a
    /// Shift tap) must not disqualify the hold.
    case otherActivity(usesHeldModifier: Bool)
}
```

`step`: only set `usedInCombination = true` when `isDown && usesHeldModifier`.
A hold that was not disqualified releases cleanly and emits `.keyUp`, so
dictation finishes normally.

`markAllHoldsCombinationUse` becomes
`markHoldsCombinationUse(flags: CGEventFlags)`, and for each held slot asks
`flags.contains(ModifierHoldState.flag(for: code)!)`. Call sites:

- `.keyDown` / `.keyUp`: pass the event's `flags`.
- mouse down: pass the event's `flags` — a modified click (⌥-click) still
  disqualifies; a plain click does not.
- `decide(...)` legacy path: same parameter, same rule.
- Repeats: still evaluated by the same rule (a repeat with the modifier
  flag set is already a chord; no behaviour change).

Escape keeps its own semantics: it cancels via `onEscape` and its
`keyDown` carries no hold flag, so it no longer marks a combination — the
transition machine already ignores the later `keyUp` after `reset`.

Consequence matrix (hold = Right ⌥, transforms = ⌘1…4 — today's defaults):

| input during hold | flags | disqualified? | result |
|---|---|---|---|
| ⌥U (dead key) | ⌥ | yes | dictation discarded (dead-key protection kept) |
| ⌘1 transform | ⌘ | no | dictation continues; transform vetoed while live |
| Shift tap | ⇧ | no | dictation continues |
| ⌥-click | ⌥ | yes | dictation discarded |
| plain click | — | no | dictation continues, target still captured at start |
| Escape | — | no | Escape cancels (unchanged) |

If the user re-binds hold = Right ⌘ and keeps ⌘1…4, the matrix inverts
correctly: ⌘1 then disqualifies the hold (same family) and the transform
wins.

### 4.3 Workstream 2b — make "combo wins" deterministic (same family)

With the scoped rule the only remaining combo-vs-hold race is the
same-family one, where the chord *should* win. Today
`TransformRunner` sleeps `comboSettle` (100 ms), calls
`cancelFreshHoldMicroSession(olderThan: 1 s)` and then vetoes on
`dictationLive()`. A long hold cancelled by `.combinationBegan` may still
be live at the 100 ms mark → the transform vetoes and the dictation was
already discarded: both actions lost.

Change: replace the age-bounded cancel with an any-age hold cancel that
awaits completion:

- `DictationCoordinator.cancelHoldForCombination() async -> Bool` —
  cancels only a live `holdToTalk` session (any age, starting or
  recording), returns whether it cancelled. Hands-free, finalizing and
  inserting sessions are untouched.
- `TransformRunner` calls it after `comboSettle`, then keeps the existing
  `dictationLive()` veto for everything else.

Rationale: the combination event already proves the user pressed a chord
with the held modifier; the hold lost by definition, so its age is
irrelevant.

### 4.4 Workstream 3 — production menu bar

`Oto/UI/OtoMenuBarView.swift` becomes:

```
Show onboarding…     ← proposed removal, see open question 1
Settings…
────────
Quit Oto
```

Removed: `status`/`feedback` state and the `.task` that reads
`lastSessionSummary()`/`recoveryText()`, the Escape-unavailable row, and
the whole recovery block (copy + retry + `Divider`). `inserter` and
`onboarding`/`dispatch` parameters shrink accordingly; call sites in
`OtoApp` update. Nothing is lost: `RecoveryRouter` already sends
`.noTextField`, `.targetGone`, `.insertionFailed` to `NoTargetModal`
(copy) or auto-copy, and the pill owns live state.

### 4.5 Workstream 4 (small) — duplicate SwiftUI IDs in the recorder

The log repeats `ForEach<Array<String>, String, Text>: the ID Right ⌥
occurs multiple times`. `shownChips` can contain the same label twice
(e.g. `heldModifierChips` while the recorder is listening), and both
`ForEach(shownChips, id: \.self)` sites (`ShortcutRecorderField.swift`
~377 and ~609) use the string as identity. Fix by enumerating and keying
on offset (`ForEach(Array(shownChips.enumerated()), id: \.offset)`), or by
de-duplicating `heldModifierChips`. Cosmetic, zero behaviour change.

---

## 5. Exact file changes

| File | Change |
|---|---|
| `Oto/Services/EditableFocusCheck.swift` | `classify` gains `publishesCaret: Bool = true`; new `caretlessContainerRoles`; rule 4; `readFocusedElement` computes `selectedTextPresent` once and passes it |
| `Oto/Services/HIDEventMonitor.swift` | `ModifierHoldState.HoldEvent.otherActivity(usesHeldModifier:)`; `markAllHoldsCombinationUse(flags:)`; both `decide` layers pass event flags; mouse path passes flags |
| `Oto/Services/TransformRunner.swift` | call `cancelHoldForCombination()` instead of `cancelFreshHoldMicroSession`; keep `dictationLive()` veto; update injected closure type/name |
| `Oto/Coordinator/DictationCoordinator.swift` | add `cancelHoldForCombination() async -> Bool`; keep `cancelFreshHoldMicroSession` only if still referenced elsewhere (remove if dead) |
| `Oto/UI/OtoMenuBarView.swift` | drop status, escape row, recovery block; drop now-unused parameters |
| `Oto/App/OtoApp.swift` (or wherever the menu is built) | update `OtoMenuBarView` construction |
| `Oto/Settings/ShortcutRecorderField.swift` | stable `ForEach` IDs (both sites) |
| `OtoTests/FocusPolicyTests.swift` | new table cases (window/scroll area with and without caret; group excluded) |
| `OtoTests/RealTextInsertionTests.swift` | `focusRoleMapping` gains the Windscribe shape; existing expectations unchanged |
| `OtoTests/HIDDecideDualTests.swift` | rewrite combination tests around flags: ⌥U disqualifies a Right-⌥ hold; ⌘1 does not; plain click does not; ⌥-click does; fn hold unaffected |
| `OtoTests/HotkeyTransitionStateTests.swift` | unchanged (transition machine already correct) |
| `OtoTests/DictationCoordinatorTests.swift` | `cancelHoldForCombination` cancels an old hold, ignores hands-free/finalizing |

No changes to `DeliveryVerification`, `RealTextInsertion`'s outcome table,
`HotkeyTransitionState`, or the catcher UI.

---

## 6. Tests

New/updated:

1. `classify(role: "AXWindow", publishesCaret: false) == .noField`
2. `classify(role: "AXWindow", publishesCaret: true) == .unknown`
3. `classify(role: "AXScrollArea", publishesCaret: false) == .noField`
4. `classify(role: "AXGroup", publishesCaret: false) == .unknown` (web ambiguity, deliberate)
5. `classify(role: "AXTextField", publishesCaret: false) == .editable` (role wins)
6. `classify(role: nil, publishesCaret: false) == .unknown`
7. Existing `FocusPolicyTests` table unchanged (default argument).
8. `RealTextInsertion`: stub focus `.noField` → `.noEditableField`, no paste posted (already covered; add the Windscribe role comment).
9. HID dual: Right-⌥ down → ⌥U keyDown (flags ⌥) → release swallowed + `.combinationBegan(.hold)`.
10. HID dual: Right-⌥ down → ⌘1 keyDown (flags ⌘) → release emits `.keyUp`, no combination.
11. HID dual: Right-⌘ down → ⌘1 keyDown (flags ⌘) → release swallowed + combination.
12. HID dual: Right-⌥ down → plain click (no flags) → release emits `.keyUp`; ⌥-click → swallowed.
13. HID dual: fn hold + arrow (flags fn) → still combination (regression guard).
14. Coordinator: old (5 s) hold + `cancelHoldForCombination()` → cancelled; hands-free → untouched; finalizing → untouched.
15. Transform: same-family chord cancels an old hold and proceeds (no veto); cross-family chord leaves dictation live (veto, no cancel).
16. Menu: `OtoMenuBarView` no longer references `recoveryText`/`lastSessionSummary` (compile-level; no UI test).

---

## 7. Verification

1. `xcodebuild -scheme Oto -destination 'platform=macOS' build` — green.
2. `xcodebuild test -scheme Oto -destination 'platform=macOS'` — green.
3. Packaged-app check (TCC/shortcut truth only works in the signed bundle):
   - Windscribe frontmost, no field focused, hold Right ⌥, speak, release →
     **catcher appears**, transcript kept, clipboard untouched, log shows
     `focus … verdict=noField role=AXWindow sel=false` and **no**
     `posted HID Cmd-V`.
   - Windscribe with its search/text field focused → inserts normally.
   - TextEdit/Notes: hold Right ⌥ → insert unchanged.
   - Finder desktop → catcher via `notLanded` (unchanged).
   - Dia/Chrome composer → insert unchanged (web path untouched).
4. Hold-rule check: hold Right ⌥ for >1 s, press ⌘1 mid-hold, release ⌥ →
   dictation finishes and inserts (no silent discard); log has no
   `cancelled` for that session.
5. Re-bind hold to Right ⌘ temporarily: hold it, press ⌘1 → dictation
   cancelled once, transform runs (no double loss).
6. Menu bar: open the menu after a failed session → only onboarding (if
   kept), Settings, Quit; recovery is in the catcher.
7. Recorder: open the shortcut recorder → no duplicate-ID warning in the
   log.

---

## 8. Risks and mitigations

| Risk | Mitigation |
|---|---|
| False catcher: an app reports `AXWindow` while a caret lives deeper | Table is window/scroll/toolbar/tab family only; requires `sel == false`; `webContentHidesEditable` still demotes web content; Finder/Dia shapes untouched. Worst case is recoverable (transcript kept, copy available) and strictly better than today's silent loss. |
| Extra AX reads on the success path | One `selectedTextPresent` call replaces the one already made after `classify`; net zero. |
| Cross-family chord now leaves dictation running | Intended. Transform is vetoed while dictation is live (existing behaviour), so nothing is double-inserted. Deferred decision 1 covers the alternative. |
| Plain click no longer cancels | Target is still captured at session start (product rule); insert path reactivates or fails honestly. If this proves wrong in use, re-add a focus-change rule rather than a blanket click rule. |
| `cancelHoldForCombination` too broad | Restricted to `holdToTalk` + starting/recording; hands-free and post-finish states untouched; generation-guarded like `cancel`. |
| Removing menu recovery leaves a dead end | Catcher + auto-copy already own it; verified by existing `FlowBarStateTests`. |

---

## 9. Deferred decisions

1. **Cross-family transform while dictating** currently does nothing (veto).
   Alternatives: finish dictation first, or cancel dictation and run the
   transform. Not doing either now — the user's ask was to stop the hold
   from being discarded, and "while dictating, transforms wait" is the
   existing, predictable rule.
2. **`.unverifiable` as success** stays. Narrowing it (e.g. treat
   unverifiable + caret-less container as not-landed) would duplicate
   workstream 1 after the paste; revisit only if a new phantom shape
   appears outside the window family.
3. **`AXGroup` with `sel == false`** stays `.unknown`. If a second app
   shows the same phantom shape through a group, extend the table with the
   measured evidence rather than guessing now.

---

## 10. Open questions for the user

1. Remove **"Show onboarding…"** from the production menu as well? It is a
   dev/QA entry point (onboarding shows itself on first run). Proposal:
   remove it; keep Settings… and Quit.
2. With hold = Right ⌥ and transforms = ⌘1…4, pressing ⌘1 mid-hold now
   leaves dictation running and the transform is ignored. Accept that, or
   should the transform finish the dictation first?
3. Anything else you want out of the menu (e.g. a "Check for updates"
   placeholder) before I strip it?

---

## 11. Execution record (2026-10-29)

Implemented as designed, with three deviations found during verification:

1. **Open question 1** — "Show onboarding…" kept in the menu (still the only
   on-demand path to the walkthrough while that flow is being refined).
2. **Two pre-existing test failures** blocked "suite green" and were fixed
   (both reproduce on unmodified `ec1567d`):
   - `RealTextInsertionTests.retryPostsWithoutFocusGates` probed the *real*
     frontmost app for delivery, so it asserted machine state (a focused
     caret in whatever app was front) rather than the retry contract. It now
     injects `StubDeliveryCheck(.unavailable)` → unverifiable → posted, the
     same contract shipped for apps that publish no caret.
   - `OtoUITests.SettingsUITests` queried `settingsWindow.toggles["CatcherToggle"]`,
     but SwiftUI renders `Toggle` as an `AXSwitch` on macOS and `.toggles`
     matches nothing (sibling `ShowInDockToggle` already used
     `descendants(matching: .any)`). Now queried by identifier across all
     types, and the round-trip compares numeric state (`value.intValue`)
     instead of "On"/"Off".
3. **`cancelHoldForCombination` returns `Bool`** and reports whether the
   session actually cancelled (state read after `cancel`), so
   `TransformDispatch` can log "transform cancelled a same-family hold and
   won" instead of guessing.

Verification: `xcodebuild build` green; `xcodebuild test` green (601 tests in
62 suites + `SettingsUITests`). Device checks (packaged `.app`, Windscribe /
Finder / Dia / TextEdit / re-bound Right ⌘ hold / recorder duplicate-ID
warning) remain for the user, per section 7.
