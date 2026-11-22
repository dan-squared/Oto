# Why dictation fires the catcher in Chromium/Electron text fields — ANALYSIS ONLY

Status: **ANALYSIS ONLY, 2026-10-17. No source touched, nothing implemented.**
Scope: the reported symptom — "dictation doesn't land in some text fields; the
catcher pops up instead, e.g. Claude, Muse" — root cause, evidence, and the
conflicts in our own record. Options at the end are for a decision *later*.
Sources: live device logs from this Mac (unified log, subsystem `app.Oto`),
`Oto/` sources read line-by-line, `plan/` history, local SDK (`MacOSX27.0.sdk`),
plus Chromium/Electron official docs for the third-party behaviour.

---

## 0. Verdict in one paragraph

The catcher is not a paste failure and it is not "Electron" — it is **Oto's
own pre-paste focus gate refusing to paste**, because a Chromium-rendered app
does not publish a focused accessibility element until its accessibility engine
is switched on, and Chromium switches that engine on lazily (and can revoke it
when idle). Oto reads "no focused element" (`kAXErrorNoValue`, SDK-verified
`-25212`) as **"nowhere to paste"** and diverts to recovery. So in a
Chromium/Electron window the gate converts *"the app hasn't told me about its
caret yet"* into *"there is no text field here"*. Verified on this machine: an
identical session in `com.openai.codex` (Chromium-family) **diverted** when the
AX read returned promptly, and **landed** when the same read timed out —
proving the outcome is decided by the AX read, not by the field. The user's
"it thinks it is Electron apps in general" is directionally right about the
*class of app* (web-rendered editors) but wrong about the *label*: our own
working app (Conductor) is not Electron, and Muse is not Electron either.

---

## 1. What "the catcher fired" actually means (exact code path)

Only three failures route to the catcher. `FlowBarState.swift:199`:

```
case .targetGone, .insertionFailed, .noTextField:  → catcher (if enabled) / auto-copy
```

The one that matches this report is `.noTextField`. Its full chain:

| Step | File:line | What happens |
|---|---|---|
| Focus read | `EditableFocusCheck.swift:365-416` (`liveRead`) | system-wide `kAXFocusedUIElement`; if it errors `noValue` → `.noField`; else per-app fallback `syncCheckDetail`:438 |
| Classify | `EditableFocusCheck.swift:60-70` | only `AXTextField` / `AXTextArea` count as `.editable`; **any other readable role → `.noField`** |
| Patience | `EditableFocusCheck.swift:283-285` | retry **only** when `verdict == .noField` **and** `axError == .noValue` **and** `attempt < 3` |
| Divert | `RealTextInsertion.swift:385-390` | `.noField` → `.noEditableField`, clipboard untouched, nothing posted |
| Keep | `DictationCoordinator.swift:607-616` | transcript kept, state → `.failed(context, .noTextField)` |
| Route | `FlowBarState.swift:192-218` | router → `.catcher` (toggle ON, default) or silent `.autoCopy` (toggle OFF) |

Everything downstream is correct and unit-tested. **The bug, if any, is entirely
inside the verdict that `.noField` is produced for an app with a live caret.**

Two distinct shapes both end here, and they behave differently:

- **Shape A — nothing published**: `kAXErrorNoValue` on the focused-element
  read. Gets patience (3 reads, ~100 ms apart, 700 ms hard budget).
- **Shape B — published but not a text role** (`AXGroup`, `AXWebArea`,
  `AXStaticText`, `AXHeading`…): classifies `.noField` with `axError == nil`,
  so `transientVoid` is **false** → **it diverts on the first read, with zero
  patience.** We are more patient with *errors* than with *answers*.

---

## 2. The measurement (real logs, this Mac)

Pulled from the unified log (`log show --last 10h --info`). The AX verdict is
logged on every attempt by `LiveFocusCheck.logVerdict`. Raw file kept at
`.context/oto-log-10h.txt`.

```
14:44:05.867 insertion reactivate: target 57873 activate=true
14:44:06.031 focus pid=57873 app=com.openai.codex attempt=1 verdict=noField axerr=-25212 sel=false timeout=false
14:44:06.260 focus pid=57873 app=com.openai.codex attempt=2 verdict=noField axerr=-25212 sel=false timeout=false
14:44:06.571 focus pid=57873 app=com.openai.codex attempt=3 verdict=noField axerr=-25212 sel=false timeout=false
14:44:06.571 insertion diverted: no editable focus in target 57873, clipboard untouched
14:44:06.571 coordinator PERF insert=704ms
14:44:06.571 coordinator failed no-text-field, transcript preserved 827198D2
14:44:06.649 catcher catcher show words=2 display=2 size=464x168
```

Same three lines repeat at `14:44:11.685 → 12.000` (second session, `insert=439ms`).

**The crucial counter-example, 7 seconds earlier, same app, same target:**

```
14:43:59.443 focus pid=57873 app=com.openai.codex attempt=2 verdict=noField axerr=-25212
14:43:59.707 focus pid=57873 app=com.openai.codex verdict=unknown axerr=nil timeout=true
14:43:59.782 insertion posted HID Cmd-V to frontmost (delivery unverified) for target 57873
14:43:59.783 coordinator completed, inserted 5 chars into com.openai.codex
```

Read that pairing carefully. **The session that "failed" the check (700 ms
timeout → `.unknown`) is the one that inserted.** The session that "answered"
quickly (`.noField`, three fast reads) is the one that showed the catcher.
The gate's error path is more permissive than its success path — non-monotonic
by construction.

Cost when it fires: `insert=439–704 ms` versus the ~200 ms insert baseline in
the earlier device trails (`.context` transcript, `PERF insert=195–241ms`) — i.e.
the user waits 2–3× longer *and then* gets no text.

`-25212` verified in the SDK, not from memory:
`MacOSX27.0.sdk/.../HIServices.framework/Headers/AXError.h:73` →
`kAXErrorNoValue = -25212`.

**What the app is:** `/Applications/ChatGPT.app`, `com.openai.codex`,
"Codex Framework 155.0.8059.80", helper apps `Codex (Renderer)`,
`Codex (GPU)`, `Codex (Alerts)`, `browser_crashpad_handler`,
`web_app_shortcut_copier` → a **Chromium-family renderer shell** (not Electron
proper, same engine family).

**Limitation, stated honestly:** I could not read the app's AX tree directly
to see what it *would* publish. My processes are untrusted
(`AXIsProcessTrusted() == false` → every read returns `kAXErrorCannotComplete`
`-25204`), the same wall recorded in `plan/browser-void-probe-fix.md`. So the
app-side half below is doc-sourced + inferred from the `noValue` instrument;
the Oto-side half is verified in code and logs.

---

## 3. Root cause

### Layer A — the app: Chromium does not publish a focused element until asked

Chromium's own accessibility design document:

> "For performance reasons Chromium waits until it detects the presence of
> assistive technology before enabling full support for accessibility APIs."
> — chromium.org/developers/design-documents/accessibility

Chromium docs, Accessibility Overview:

> "Accessibility features in Chrome are off by default and enabled automatically
> on-demand."

Electron's docs restate it and hand out the switch:

> "Electron applications will automatically enable accessibility features in the
> presence of assistive technology… On macOS, third-party assistive technology
> can toggle accessibility features inside Electron applications by setting the
> `AXManualAccessibility` attribute programmatically"
> — electronjs.org/docs/latest/tutorial/accessibility

With the engine off (or not yet on), the app publishes no focused element, so
the AX server's `kAXFocusedUIElementAttribute` has **no value** → exactly the
`-25212` we see. Chromium's engine is *usage*-driven and can be torn down again
after idle (`browser_accessibility_state_impl` exposes a
`disable_accessibility_request_time_` for precisely that), which is the most
consistent explanation for "sometimes it works, sometimes it catches" in the
same field.

### Layer B — Oto: "no focused element" is treated as "nowhere to paste"

`EditableFocusCheck.swift` was written for Finder/desktop voids
(`plan/catcher-void-fix-and-scratchpad-v3.md`), where `noValue` genuinely means
nothing to paste into. For an app that simply hasn't enabled AX, the same
signal is a **false positive**, and the failure direction is the expensive one:
the user's words are held back for a field that was there all along.

The patience that was added later for exactly this class
(`plan/focus-and-settings-redo.md`, 3 × ~100 ms) is calibrated in
**hundreds of milliseconds**; Chromium's enable-on-demand is calibrated in
**"the next time someone asks, and not again if I go idle"**. It also cannot
help Shape B at all (zero patience for a readable non-text role), and it
actively cannot help when the read is *slow*, because the timeout path returns
`.unknown`, which proceeds — see §2.

---

## 4. Cross-check: it is **not** "Electron apps in general"

Every claim below verified on this machine, not recalled.

| App | Bundle | What it actually is | Dictation |
|---|---|---|---|
| Conductor | `com.conductor.app` | **Tauri**: `tauri-runtime-wry`, `wry-0.55.1`, `objc2-web-kit` strings; links **WebKit**, no Electron Framework | **works** — trail shows `verdict=editable` for the same app that once diverted |
| Muse | `com.meta.endo` | **native**: AppKit+SwiftUI, links WebKit, ships `markdown-editor.html`, no Electron Framework, universal binary | reported broken — **no log evidence yet** |
| Claude | `com.anthropic.claudefordesktop` | **Electron** (Chromium 152.0.7977.149), `Claude Helper (Renderer)`, `Electron Framework.framework` | reported broken |
| ChatGPT/Codex | `com.openai.codex` | **Chromium-family shell** ("Codex Framework 155…", Renderer/GPU/Alerts helpers) | **broken — measured** (§2) |

So:

1. **Conductor works and is not Electron.** Yet `plan/focus-and-settings-redo.md:38`
   asserts "**Conductor is Electron/Chromium** — its AX tree publishes focus
   asynchronously". That sentence is factually wrong (Conductor is Tauri/WebKit).
   The trail it cites is still valid evidence of a *transient* void, but the
   attribution to Chromium is not, and every later reasoning step that leaned on
   "Chromium" inherited the error.
2. **Muse is not Electron either.** Its brokenness, if real, is a *different*
   cause than Chromium's engine gating (Shape B is the likelier fit for a
   native/WebKit app: a readable but non-text role, which gets zero patience).
3. The common denominator that *actually* holds across Claude + ChatGPT + the
   original Dia report is: **the editable lives inside a web-rendered surface
   whose AX tree the app gates or shapes itself.** "Electron" is a member of
   that class, not the name of it.

---

## 5. Conflicting things found in our own record (the part worth arguing about)

These are genuine contradictions, in date order. They are why a naive fix will
regress something else.

1. **Phase 4 adopted the rule this gate violates.** `plan/phase-4-insertion.md:66`
   lists in the ADOPT column: *"No-editable-element gate (Electron reports none —
   any such check refuses Slack/VS Code)."* Two days later
   `plan/catcher-void-fix-and-scratchpad-v3.md` added exactly that check. Both
   decisions were defensible alone; together they are a contradiction nobody
   reconciled, and the matrix row that would have caught it was never run.
2. **The verification rows were never executed.** `catcher-void-fix-and-scratchpad-v3.md:138-144`
   names "Safari page body, VS Code editor, Terminal, **Slack composer**,
   Chrome omnibox"; `Docs/OTO_REBUILD_PLAN/11_RELIABILITY_TEST_MATRIX.md:41-42`
   names "Slack → Message composer … Electron app → Plain and rich text fields".
   Every one of those is an unchecked aspirational row — I found no recorded
   result anywhere in `plan/` or `Docs/`. The bug you hit is the untested row.
3. **The Dia fix and the Figma fix pull in opposite directions.**
   `plan/browser-void-probe-fix.md` deliberately removed the selection-probe
   upgrade for browser-class bundles so Chromium voids **divert** (fail-closed
   against silent loss). `plan/phase-8b-field-reach-plan.md` added the same
   probe upgrade **only** for `CanvasEditors` (Figma) because a persistent void
   there is uninformative. Both are right locally. The cost is exactly what you
   are feeling: a Chromium-hosted *editor* (an Electron composer, Google Docs,
   a web app's textarea) is treated as a browser void, not as an editor.
4. **That plan's own open question is now answered by your machine.**
   `browser-void-probe-fix.md` Q1: *"does the user dictate in Google Docs or
   other canvas-in-browser editors?"* — the answer is yes: Claude and ChatGPT's
   composers are that shape.
5. **The gate's own risk note assumed the wrong failure mode.**
   `catcher-nofield-fix-v5.md:96-100` reasons that a false divert is cheap
   ("false catcher = Copy click; false void = text gone"). True — **for a real
   void**. It does not consider the case where the app is simply not talking yet,
   where the "cheap" divert is the whole feature failing.
6. **Non-monotonic gate.** As shown in §2, `.unknown` (timeout / unreadable)
   **proceeds** while `.noField` (read succeeded) **diverts**. Any "patience"
   tuning therefore has a perverse edge: making the read *slower* makes dictation
   *work*. This is a design smell independent of Chromium.
7. **Test-only dead ends.** `kAXSearchFieldSubrole` exists in the SDK
   (`AXRoleConstants.h:425`) and is never consulted; `kAXIsEditableAttribute`
   exists (`AXAttributeConstants.h:1293`) and was explicitly deferred
   (`focus-and-settings-redo.md:74-77`) — the two signals that would most
   directly answer "is this thing editable" are unused while role-name matching
   carries the whole decision.

---

## 6. What is *not* the cause (ruled out)

- **Not the paste keystroke.** If Chromium ignored our synthetic ⌘V, the
  coordinator would report `.inserted` and **no catcher** would appear. The
  catcher is proof the paste was never attempted: `clipboard untouched`, nothing
  posted.
- **Not the clipboard.** The write-verify never runs on this path.
- **Not target capture/pid.** `reactivate: target 57873 activate=true` precedes
  every divert; the pid was captured and alive.
- **Not the workspace's recent perf work.** P2 was removed, P3 is flag-off;
  nothing on `main` touches `EditableFocusCheck`.

---

## 7. How to settle the last unknowns (5 minutes, no Console.app needed)

The one thing missing is which *shape* each failing app produces. The `focus`
lines are already sufficient, and they are readable from the log after the fact:

```
log show --last 30m --info --predicate 'subsystem == "app.Oto" AND category == "focus"' --style compact
```

(Info-level entries rotate out fast — read them within the hour.)

Dictate once into Claude and once into Muse, then read:

- `verdict=noField axerr=-25212 sel=false timeout=false` ×3 → **Shape A**
  (Chromium engine not publishing) → Claude confirmed, and Muse joins the same
  class.
- `verdict=noField axerr=nil … role=<something>` (the role itself is not in the
  current log line — see the gap below) → **Shape B**.
- `verdict=unknown … timeout=true` → the read was slow; that session *landed*
  (§2), which is itself the signature of A.
- `verdict=editable` → then the divergence is elsewhere and I re-open the trace.

**Instrumentation gap worth noting:** `logVerdict` logs the verdict and the AX
error code but **never the role string** (`EditableFocusCheck.swift:244-255`).
So Shape B is currently indistinguishable from Shape A in a trail unless the
error code is present. One extra field (`role=`) would make every future
diagnosis of this class a one-line read. That is the smallest observability fix
available and it changes no behaviour.

**Workaround available today, no code change:** when the catcher appears, the
menu-bar item *"Retry paste to frontmost app"* (`OtoMenuBarView.swift:78`,
`RealTextInsertion.retryPostToFrontmost:531`) posts **without** the focus gate —
switch to the field and Retry lands it. Also worth knowing: with
*Settings → Dictation → "Show catcher when there's nowhere to paste"* OFF, this
bug stops being visible and becomes a **silent** no-insert + clipboard copy.

---

## 8. Options for later (ranked; nothing here is approved)

Prices are honest; none of them is "one line" except the instrumentation.

1. **Make the app publish, don't weaken the policy** — at session start, poke
   the *target* app's AX element with `AXManualAccessibility = true`
   (`AXUIElementCreateApplication(pid)` + `AXUIElementSetAttributeValue`), i.e.
   the documented Electron/Chromium switch. **This is the only option that
   fixes the cause instead of the symptom**: Oto's void policy stays byte-identical,
   Finder still diverts, no reach/honesty trade at all. Cost: ~15 lines + a
   settle/wait question (the tree takes time to appear, so it pairs naturally
   with the patience already in the gate) + a real device matrix. Unknown to
   verify: whether all three apps honour it, and whether setting it on a
   non-Electron app returns `kAXErrorAttributeUnsupported` harmlessly (I expect
   yes — fail-closed on any error). **My recommendation for whenever we act.**
2. **Log the role** (`role=` in `logVerdict`) — one field, zero behaviour change,
   makes 1 and 3 measurable. Do this first regardless of which option wins.
3. **Lengthen patience for the void case only** (e.g. more attempts / longer
   budget when `axError == .noValue`, still diverting on a persistent void).
   Cheap, keeps the fail-closed policy, but is a timing bet against an engine
   whose schedule we don't control, and it makes every genuine Finder void
   slower.
4. **Give Shape B patience too** (retry readable-but-non-text roles, then
   divert). Removes the §5.6 inversion. Small, but it widens the window where a
   real void is re-read (bounded, and the divert still fires).
5. **An allowlist entry (Chromium/Electron/`AXWebArea`→`.unknown`)** — the
   Figma/terminal pattern, cheapest to write. I recommend *against* it first:
   `browser-void-probe-fix.md` exists precisely because this widens silences in
   browsers, and a bundle list can never separate an Electron *composer* from an
   Electron *void*. If we take it, gate it on the *role* (`AXWebArea` → `.unknown`),
   not on bundle IDs.
6. **Drop the gate** — reverted in §5.1 for good reason. Not on the table.

---

## 9. Open questions (for the user, not for code)

1. When Muse fails, is it the message composer, or a note/editor surface? The
   answer selects Shape A vs B and I cannot get it from here.
2. Claude: does it fail *every* time in the same field, or only on the first
   dictation after focusing that window? ("Only on the first" is the fingerprint
   of Chromium's on-demand enablement, and strengthens option 1 over option 3.)
3. Do we accept a slower *failing* path (more patience) as the price of keeping
   the no-silent-void policy, or do we want the AX-tree switch so the policy is
   never exercised in these apps at all?

No code will be written until you pick.

---

## 10. Verification attempts made while writing this (all negative — recorded so they aren't repeated)

Cross-checking my own document, not the product:

- **Code line numbers re-verified** against the working tree after §1/§5 were
  written: `classify` `60-70` ✓, `verdictForFocusError` `77-79` ✓ (`.noValue` →
  `.noField`, everything else → `.unknown`), `logVerdict` `244-255` ✓
  (confirmed: no role field is emitted), `transientVoid` `283-285` ✓,
  `liveRead` `365` / role gate `423` / `syncCheckDetail` `438` ✓;
  `RealTextInsertion` divert `390`, `retryPostToFrontmost` `531` ✓;
  `DictationCoordinator` `281`/`615` ✓; `FlowBarState` `199` ✓;
  `OtoMenuBarView` `78` ✓. **No drift** — §1 and §5 stand as written.
- **The unified log is empty for the last 24 h**: `log show --last 24h --info
  --predicate 'subsystem == "app.Oto"'` returns **0 lines**. The trails quoted
  in §2 are the only Oto evidence that exists on this machine, and the app has
  not been exercised since. So the "read it within the hour" advice in §7 is
  moot until a new session is produced.
- **`.context/oto-log-10h.txt` is 29 lines and 100 % `com.openai.codex`** —
  zero `com.meta.endo`, zero `com.anthropic.claudefordesktop`. The Muse and
  Claude rows in §4 are therefore **bundle-verified only, not trail-verified**.
  That is the exact hole §9.1/§9.2 ask you to close.
- **The AX trust wall is unchanged.** `.context/ax-probe/axprobe` re-run against
  the three apps open at the time of writing (Dia, Conductor, Muse):
  `trusted=false`; per-app `AXFocusedUIElement` → `-25211` (`kAXErrorAPIDisabled`),
  system-wide → `-25204` (`kAXErrorCannotComplete`); both confirmed in the SDK
  (`AXError.h:70` and `:49`). So the app-side *shape* of Muse and Claude still
  cannot be read from a shell on this machine — only Oto's own one-line verdict
  (with the `role=` field from §8.2) can, from inside the process that is
  already trusted.

Only action that moves this forward: run one dictation into Claude and one into
Muse with Oto live, then read §7's `focus` predicate.
