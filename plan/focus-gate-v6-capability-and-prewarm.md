# Focus gate v6 — capability-first classification + session prewarm

Status: **executed, 2026-10-19** (user authorised: "do the decision that will
solve the problem … do the recommended"). Build and unit tests green; device
matrix still to run (§9).
Supersedes the option ranking in `chromium-focus-divert-analysis.md` §8 and
executes the recommended subset of `focus-detection-release-audit.md`
(Phases 0, 1, 2, 4 + 5), with two deliberate deviations recorded in §5.

---

## 0. New evidence this change is built on (2026-10-19, this Mac)

Both failure shapes are now measured in the field, in one run:

**Claude — Shape A (app publishes nothing).**
```
focus pid=61805 app=com.anthropic.claudefordesktop attempt=1 verdict=noField axerr=-25212
focus pid=61805 app=com.anthropic.claudefordesktop attempt=2 verdict=noField axerr=-25212
focus pid=61805 app=com.anthropic.claudefordesktop attempt=3 verdict=noField axerr=-25212
diverted: no editable focus … insert=441ms
```

**Muse — Shape A → B inside 100 ms (app publishes a *coarse* element).**
```
focus pid=61947 app=com.meta.endo attempt=1 verdict=noField axerr=-25212
focus pid=61947 app=com.meta.endo attempt=2 verdict=noField axerr=nil
diverted: no editable focus … insert=271ms
```
Attempt 2 has **no AX error**, so the read *succeeded* and returned an element
whose role is not a text role. Because the retry condition requires
`axError == .noValue`, the loop settled there and diverted — with a perfectly
good answer in hand. `sel=false` says the element does not expose selection
either, i.e. it is a container, not the caret.

Conclusion: **the gate asks the wrong question.** It asks "is the focused role
exactly `AXTextField`/`AXTextArea`?" — a question two of the three reported
apps cannot answer even when they are behaving perfectly. It should ask "is
there positive evidence this is *not* editable?" and otherwise proceed.

---

## 1. Decision

**Divert only on positive evidence of a non-editable focus. Proceed on silence,
errors, containers, and unknown roles.**

Three consequences, each deliberate:

1. **`kAXErrorNoValue` stops meaning "nowhere to paste".** It means "the app did
   not answer". Claude's `-25212` on a live caret is the proof. It diverts only
   for bare desktop shells (Finder, Dock, SystemUIServer, Control Center) where
   "no field" is the true state and the catcher was built for.
2. **Role matching inverts.** A known non-editable *widget* role (button, menu
   item, static text, slider…) is positive evidence → divert. A *container* role
   (`AXGroup`, `AXWebArea`, `AXScrollArea`, `AXLayoutArea`, tables, lists) is
   ambiguous — a caret can live inside it → proceed. Anything unrecognised →
   proceed.
3. **The terminal/canvas allowlists go away.** They existed to patch exactly the
   two rules above; with the default inverted they are redundant, and keeping
   them would leave two mechanisms claiming one failure mode. Their measured
   cases (terminals publish focus transiently; Figma draws its own caret) are
   covered by the general rule, which is stronger: it needs no bundle list.

Plus the cause-level piece the user approved: **arm the target's AX tree at
session start**, so the app answers at all instead of relying on the permissive
default.

---

## 2. Why this is the sustainable answer, not a patch

- It removes app knowledge from the gate. After this change there is exactly one
  bundle-ID list left in the product, and it lists the *desktop*, not an app
  class. New web-rendered editors work without a code change — the failure mode
  the audit called "allowlist brittleness" disappears.
- It makes the gate's two error paths agree. Before: an answered read diverted
  (strict) while a timeout proceeded (permissive), so a slower read made
  dictation *work*. After: `noValue`, timeout, and any other error all land on
  `.unknown` → proceed. No inversion, no perverse incentive to tune timings.
- It keeps the safety property that matters: a truly fieldless *widget* still
  diverts, the transcript is always kept, the clipboard is never touched on a
  divert, and `Retry paste` still bypasses the gate.
- The accepted cost is stated plainly in §6.

---

## 3. Facts verified against the local SDK / bundles (not memory)

| Fact | Source |
|---|---|
| `kAXErrorNoValue = -25212`, `CannotComplete = -25204`, `AttributeUnsupported = -25205`, `APIDisabled = -25211` | `MacOSX27.0.sdk/…/HIServices.framework/Headers/AXError.h:73,49,52,70` |
| Role constants used by the table all exist (`AXTextField`, `AXTextArea`, `AXComboBox`, `AXButton`, `AXStaticText`, `AXHeading`, `AXImage`, `AXSlider`, `AXDockItem`, …) | `AXRoleConstants.h` (grep, this session) |
| **No** `AXLinkRole`, **no** `AXWebArea` constant in the SDK | `AXRoleConstants.h` grep → 0 hits; role strings are used verbatim |
| `kAXFocusedUIElementAttribute`, `kAXRoleAttribute`, `kAXChildrenAttribute` exist | `AXAttributeConstants.h:1009,210,532` |
| `AXManualAccessibility` is **not** an SDK constant — it is Electron's documented third-party switch | `grep` over all HIServices headers → 0 hits; electronjs.org accessibility docs |
| Claude bundle contains both `AXManualAccessibility` and `AXEnhancedUserInterface`; Codex/ChatGPT contains only `AXEnhancedUserInterface` | `strings` on the bundles (recorded in `focus-detection-release-audit.md` §3.1) |
| Project uses file-system-synchronised groups, so a new file needs no `project.pbxproj` edit | `grep fileSystemSynchronized project.pbxproj` → 3 |

---

## 4. Exact file changes

### 4.1 `Oto/Services/EditableFocusCheck.swift` (rewrite of the policy core)

- `EditableFocus.classify(role:subrole:pidMatches:)`
  - text roles (incl. `AXComboBox`, `AXDateField`, `AXTimeField`) → `.editable`;
    secure subrole wins first → `.secureField`;
  - `nonEditableRoles` (widget allowlist) → `.noField`;
  - **everything else → `.unknown`** (containers, web areas, unknown strings).
- `EditableFocus.verdictForFocusError(_:bundleID:)`
  - `.noValue` → `.noField` **only** for `VoidShells`; every other error or
    bundle → `.unknown`.
- New `VoidShells` (Finder, Dock, SystemUIServer, Control Center) with
  `isVoidShell(bundleID:)`.
- New `FocusRead` struct carrying `verdict`, `axError`, `hasSelectedText`,
  `role`, `source` — this is Phase 0 instrumentation (`role=` and `src=`
  appear in every verdict line).
- `liveRead` reads system-wide, then the app-level fallback, and takes the
  **more informative** answer (Phase 5) so the weaker read can no longer win.
- `editableFocus(for:)`: **single read**, removing the 3-attempt loop. With
  `noValue` no longer diverting, the loop has nothing left to protect; keeping
  it would only add latency to a decision that is already permissive.
  The 700 ms timeout race stays (a hung AX call must never hang dictation).
- Delete `TerminalEmulators`, `CanvasEditors`, `resolveWithSelectionProbe`.
  Add `FocusBundle.bundleID(for:)` for pid → bundle lookup.
- `selectedTextPresent` stays, now diagnostic only (`sel=`).

### 4.2 `Oto/Services/AccessibilityPrewarm.swift` (new)

`arm(pid:bundleID:)`: gated on `AXIsProcessTrusted()`, sets
`AXManualAccessibility` (Electron) and `AXEnhancedUserInterface`
(Chromium-family / AppKit-WebKit) to `kCFBooleanTrue` on the **target app
element**, then performs one `AXFocusedUIElement` read to pull the lazy
enable. Returns an outcome struct and logs one `focus arm …` line.
`armInBackground` dispatches it off the press path. Never throws, never
prompts, never downloads; `-25205` for apps that don't implement the
attributes is expected and logged as such.

### 4.3 `Oto/Coordinator/DictationCoordinator.swift`

`begin()` calls `prewarmAccessibility(for: target)` right after the target is
captured and logged — the same free window `prewarmForSession()` already uses
for the language model. Nothing is added to the insertion path.

### 4.4 Tests

- `OtoTests/FocusProbeTests.swift` — rewritten as the new policy table
  (widgets divert, containers proceed, secure wins, void shells only).
- `OtoTests/FocusRetryTests.swift` — rewritten: one read, no retry; `noValue`
  in an ordinary app proceeds; `noValue` in Finder diverts; a widget diverts.
- `OtoTests/RealTextInsertionTests.swift` — update the three pinned tables
  (`AXWebArea` → `.unknown`, `noValue` → `.unknown`, Finder → `.noField`);
  delete the three `TerminalEmulators` tests.
- New: `AccessibilityPrewarm` never traps on a bogus pid.

---

## 5. Deviations from `focus-detection-release-audit.md` (and why)

1. **Phase 3 (patience) is not implemented; the retry loop is removed.**
   Phase 3 existed to stop `.noField`-from-an-answer diverting earlier than
   `.noField`-from-a-timeout. Phase 1 already collapses both onto `.unknown`, so
   there is nothing left to order. Adding patience on top would pay 200 ms per
   verdict to reach the same decision.
2. **The audit's `AXIsEditable` / ancestor-walk capability ladder is reduced to
   a pure role table.** Once containers default to `.unknown` (proceed), the
   only thing the gate still needs is "positive evidence of a non-editable
   widget". `AXIsEditable` would upgrade `.unknown` → `.editable`, which changes
   no outcome and costs an extra AX round-trip on every paste. Rejected as
   cost without behaviour. The audit's Phase 2 goal (Shape B stops diverting) is
   met by the inverted default, not by more probes.
3. **`AXManualAccessibility` is kept even though Codex lacks it**, because the
   arm sets *both* documented/observed flags and ignores `-25205`. The audit's
   correction (it is Electron-only) is respected by not relying on it.
4. **"Nil focused window ⇒ void" is rejected** (audit §6 leans yes). An app with
   its AX engine off can plausibly fail the window read too — that is Claude's
   case, and treating it as a void would recreate the bug we are fixing.
   Unverifiable today; the void-shell list is the conservative answer.

---

## 6. The cost, stated plainly

A genuinely fieldless app that is **not** in the void-shell list and reports
**no** focused widget will now proceed to paste and show no catcher. Nothing is
lost — the transcript stays recoverable, the clipboard is restored, and `Retry
paste` exists — but the user gets "inserted" and no text. That is pre-v5
behaviour, and it is the correct direction for this bug: a missed catcher is
recoverable, a false catcher makes the product look broken in the apps people
actually use.

Residual risk: a container role that is in fact a non-text surface (e.g. a web
page body) will now proceed instead of catching. Accepted, for the same reason.

---

## 7. Verification

1. `xcodebuild -scheme Oto -destination 'platform=macOS' build`
2. `xcodebuild test -scheme Oto -destination 'platform=macOS'`
3. Packaged `.app` only (TCC/AX are meaningless from a raw executable):
   dictate once into Claude, Muse, Conductor, Safari (page body), Finder
   desktop, TextEdit. Read
   `log show --last 30m --info --predicate 'subsystem == "app.Oto" AND category == "focus"'`.
   Expected: Claude/Muse `verdict=editable` (prewarm) or `verdict=unknown`
   (proceed); Finder desktop `verdict=noField` + catcher; page body no catcher.

---

## 8. Deferred

- Whether `AXEnhancedUserInterface` alone wakes Codex, and whether the pull-read
  is needed at all (Phase 4 measurement).
- Per-app "Always paste here" escape hatch (audit Phase 6) — only if the matrix
  finds an app that still diverts wrongly.
- Privacy copy for the cross-process AX handshake (no content is read).
- Separate defect observed in the same log, **out of scope**: two Xcode sessions
  completed with `chars=0` / `delivered=2 … chars=0`, i.e. speech delivered
  nothing. Unrelated to focus; needs its own trail.

---

## 9. What shipped (verification record, 2026-10-19)

Files:

| File | Change |
|---|---|
| `Oto/Services/EditableFocusCheck.swift` | rewritten policy core: `classify` inverted to a widget denylist, `verdictForFocusError` gated on `VoidShells`, `FocusRead` + `FocusSource` instrumentation, two-read reconciliation, single read, allowlists removed (-547/+287 overall) |
| `Oto/Services/AccessibilityPrewarm.swift` | new: `AXManualAccessibility` + `AXEnhancedUserInterface` + one pull-read, trust-gated, off the press path |
| `Oto/Coordinator/DictationCoordinator.swift` | +12 lines: `prewarmAccessibility(for:)` at `begin()` |
| `OtoTests/FocusPolicyTests.swift` | new: role table, void shells, no-value mapping, prewarm dead-pid |
| `OtoTests/FocusTimeoutTests.swift` | new: pass-through, single read, hung-read timeout (replaces `FocusRetryTests`) |
| `OtoTests/FocusProbeTests.swift` | deleted (the probe upgrade it tested no longer exists) |
| `OtoTests/RealTextInsertionTests.swift` | pinned tables updated; three terminal-allowlist tests deleted |

Commands run:

- `xcodebuild -scheme Oto -destination 'platform=macOS' build` → **BUILD
  SUCCEEDED**, no warnings from the changed files.
- `xcodebuild test -scheme Oto -destination 'platform=macOS' -only-testing:OtoTests`
  → **536 tests in 57 suites passed** (23.7 s).
- `xcodebuild test` (full, includes UI tests) → one failure:
  `SettingsUITests.testSettingsOpensAsOneNativeWindow` — *"Dictation must
  expose the catcher toggle"*. **Pre-existing and unrelated**: the test queries
  `settingsWindow.toggles["CatcherToggle"]` while `DictationPane` renders a
  custom `OtoSwitch` (a Capsule with `.accessibilityAddTraits(.isToggle)`, not a
  `Toggle`). Verified by stashing this entire change set and re-running that one
  test at HEAD — it fails identically (`git stash push -u`, run, `git stash
  pop`). Both files were last touched in `d79ea94`, before this work.

Still open: the packaged-app matrix in §7 (TCC/AX are only meaningful in the
signed `.app`), and the read of the new `role=` / `src=` fields on the next real
dictation.

---

## 10. v6.1 — Muse's composer is an `AXButton` (2026-10-19)

The first device run of `431f912` split the two apps cleanly:

```
Claude  arm manual=0 enhanced=-25208 pull=-25212   →   focus verdict=unknown axerr=-25212 role=nil
        arm manual=0 enhanced=-25208 pull=0        →   focus verdict=editable role=AXTextArea sel=true
Muse    arm manual=-25205 enhanced=-25208 pull=0   →   focus verdict=noField axerr=nil role=AXButton ×2
```

So the prewarm works (Claude's tree wakes between sessions and the second read
is exact), and the gate was not lying about Muse: **Muse really does report a
button**. No `focus alt` line appeared, so the system-wide read and Muse's own
read agreed.

That still looked wrong, because the user was typing in a composer. Reading
Muse's tree settles it. Muse is a native AppKit shell around a `WKWebView`
(`AXWebArea desc="Hatch"`, `markdown-editor.html`), and its message composer is
exposed as a single leaf:

```
depth=8  role=AXButton title="Message Attach file Dictate a message Se" kids=0
depth=6  role=AXWebArea desc="Hatch"
```

The title is the composer's placeholders concatenated ("Message", "Attach file",
"Dictate a message", "Send"), and there is no `AXTextArea` anywhere in the
window except the sidebar search field. WebKit collapsed the contenteditable
into one button-ish leaf. **`role=AXButton` was the field.**

### The rule this buys

A widget role is evidence only on **native** content. Inside web-rendered
surfaces the role is the host's mapping of DOM semantics, so a divert there is
a guess, not evidence. `EditableFocus.webContentHidesEditable(element:)` now
runs on the divert path only:

1. `AXEditableAncestor` answers with an element → inside an editable region;
2. otherwise walk `AXParent` up to 8 hops looking for `AXWebArea` / `AXBrowser`
   (Muse needs 2; the bound is headroom for deeper DOM wrappers).

Either one demotes `.noField` to `.unknown`, i.e. **proceed and paste**, because
a missed catcher is recoverable and a false catcher breaks the feature. Cost is
zero on the common `.editable` path and ≤ 17 read-only attribute calls when a
widget role would otherwise divert.

Native widgets keep their meaning: a focused toolbar button in a native app
still diverts, because there is no web area above it and no editable ancestor.

### Diagnostic seam kept

`Oto/Support/AXDump.swift` — `--ax-dump[=<bundle-id>|pid]`, opt-in launch
argument, prints the target's focused element, ancestor chain and window tree,
then exits in `OtoApp.init()` before any scene exists. It is the only way to
inspect another app's AX tree on this Mac: shell/probe binaries are AX-untrusted
(`-25211`) and Oto is the trusted binary. Same explicit-opt-in shape as
`-OtoCleanSlate`; read-only, touches no Oto state.

Note for future triage: launch it through LaunchServices
(`open -n -a …/Oto.app --stderr /tmp/ax.txt --args --ax-dump=com.meta.endo`).
Run directly from a shell, TCC attributes the process to the shell and reports
`trusted=false`.

### Verification

- `xcodebuild … build` → **BUILD SUCCEEDED**.
- `xcodebuild test … -only-testing:OtoTests` → **539 tests in 57 suites
  passed**; new: `webContentRolesAreIdentified` (set membership) and
  `webContentCheckNeverTrapsHeadless` (bounded, no trap).
- On device dump of Muse: `webContentHidesEditable` returns **true** for the
  composer node, 2 hops below `AXWebArea` — the guard fires on the real tree.
- End-to-end paste into Muse still needs one real dictation; that is the only
  step that cannot be reproduced without audio.
