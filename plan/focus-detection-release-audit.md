# Focus-detection release audit — why live dictation diverts on real fields

Status: **plan only. No source changed.** `git status` clean except the prior
untracked `plan/chromium-focus-divert-analysis.md` (which this file corrects and
supersedes).

Scope: the whole pre-paste focus path, not just the Chromium case. Deliverable
is a decision: which of the phased changes to authorise.

---

## 0. TL;DR

The catcher is Oto's own pre-paste gate (`EditableFocusCheck`), not a paste
failure and not a permissions failure. Four independent defects compound:

1. **The gate only accepts two roles** (`AXTextField`, `AXTextArea`) and gives
   every other present-but-non-text role **zero patience** — it diverts on the
   first read. Web editors legitimately expose `AXGroup`, `AXWebArea`,
   `AXComboBox`, or a text role on a child rather than the focused node.
2. **`kAXErrorNoValue` (`-25212`) is mapped to `.noField`** — "the app did not
   answer" is treated as "the app answered: nothing is here." That is the
   catastrophic inversion: the *slower/quieter* path (timeout → `.unknown`)
   inserts, the *faster* path (answer `-25212`) diverts. Making the read slower
   makes dictation work.
3. **Chromium/Electron don't publish a focused AX element at all until their
   accessibility engine is switched on**, which is lazy and, in Chromium,
   debounced by ~2 s. Oto never asks — `prewarmForSession()` only warms the
   language model, never AX.
4. **No role logging** — every verdict line records `axerr=` but not the role it
   saw, so a "wrong role" divert is indistinguishable from a "void" divert in
   the log. This is why the class has stayed undiagnosable.

The prior analysis's headline recommendation (poke `AXManualAccessibility`) is
**correct for genuine Electron (Claude) but will silently do nothing for
ChatGPT/Codex**, whose bundle contains `AXEnhancedUserInterface` but **zero
occurrences of `AXManualAccessibility`**. Fixing the gate's error mapping and its
role patience is the change that works everywhere; the prewarm is a
belt-and-braces extra.

Recommended minimum for release: **Phase 1 + Phase 2 + Phase 4** (≈ half a day,
no policy risk), then the rest behind the packaged-app matrix.

---

## 1. Evidence base (what is verified vs inferred)

| Fact | Source | Verified how |
| --- | --- | --- |
| `kAXErrorNoValue = -25212` | `MacOSX27.0.sdk/.../HIServices.framework/Headers/AXError.h:73` | `grep` on local SDK |
| `kAXErrorAttributeUnsupported = -25205`, `-25204 CannotComplete`, `-25211 APIDisabled` | `AXError.h:49,52,70` | local SDK |
| `kAXIsEditableAttribute` exists | `AXAttributeConstants.h:1293` | local SDK |
| `AXEditableAncestor` / `AXFocusableAncestor` exist | `AXWebConstants.h:112,124` | local SDK |
| `AXGroup=348`, `AXComboBox=350`, `AXTextField=360`, `AXTextArea=361`, `AXSecureTextField=408` | `AXRoleConstants.h` | local SDK |
| `AXUIElementCopyAttributeNames` / `IsAttributeSettable` / `SetMessagingTimeout` exist | `AXUIElement.h:130,204,402` | local SDK |
| **No `AXManualAccessibility` or `AXEnhancedUserInterface` constant in the public SDK** | `grep` over all HIServices headers → 0 hits | local SDK |
| **No `AXWebArea` constant in the public SDK** | `grep "WebArea" *.h` → 0 hits | local SDK |
| Codex/ChatGPT bundle: 0 × `AXManualAccessibility`, 2 × `AXEnhancedUserInterface` | `/Applications/ChatGPT.app` (`com.openai.codex`, "Codex Framework 155.0.8059.80") | `strings` + bundle read |
| Claude: both strings present (genuine Electron) | `/Applications/Claude.app` (`com.anthropic.claudefordesktop`) | `strings` |
| Muse: native AppKit/SwiftUI + WebKit, not Electron | `/Applications/Muse.app` | bundle read |
| Only Oto focus trail on this machine: 29 lines, 100 % `com.openai.codex`, `verdict=noField axerr=-25212` ×3 then divert; a prior session timed out → `.unknown` → inserted | `.context/oto-log-10h.txt` | read |
| No Oto logs exist after 2026-10-17 | `log show` empty for 24 h | ran |
| Shell is AX-untrusted (`AXIsProcessTrusted() == false`), so live trees of Claude/Muse could not be read | `-25211`/`-25204` on every shell read | ran |

Inferred (not verified, flagged as such): the *app-side shape* for Claude and
Muse. Claude's failure mode is unconfirmed; Muse's is unconfirmed. Everything
Oto-side below is code- and log-verified.

Constraint we cannot lift from here: the confirms need one dictation each into
Claude and Muse with the instrumented build, then reading the focus log. The
user is away from the machine; Phase 2 ships the instrumentation that makes
that a one-line read.

---

## 2. Root-cause taxonomy

Five distinct ways the gate turns "a real field" into "nowhere to paste". They
look identical from the user's side (catcher) and, today, identical in the log.

### Shape A — app publishes nothing (no value / AX off)
Chromium and Electron don't build an accessibility tree until an assistive
client asks. `AXUIElementCopyAttributeValue(sysWide, AXFocusedUIElement, …)`
returns `kAXErrorNoValue` (`-25212`) while the tree is asleep, and the app-level
read (`syncCheckDetail`) returns the same. `EditableFocusCheck.swift:77-79`
maps that to `.noField` → divert. Measured: this is the Codex trail.

### Shape B — app publishes focus but under a non-text role
The focused node is `AXGroup` / `AXWebArea` / `AXComboBox` (or the editor's text
node is a *child* of the focused node). `classify` (`:63-69`) accepts only
`AXTextField`/`AXTextArea`; everything else is `.noField` on the **first** read —
no retry (the retry condition at `:283-285` also requires `axError == .noValue`,
so a successful read with a non-text role is never re-read). Rich editors and
canvas editors land here. `AXComboBox` is the worst case: it is a real, editable
text input (URL bars, search fields) that the gate refuses.

### Shape C — the failure budget is smaller than the success budget
`maxAttempts = 3` × (`retryDelay 100 ms` + read latency ~150-300 ms) plus the
`700 ms` budget (`:212-216`). Logged read timings were ~164/393/704 ms. A
slow tree can therefore *exceed the budget and time out* before it would have
answered — and the timeout path returns `.unknown`, which **proceeds**. So the
gate is non-monotonic: patience failure yields the permissive branch, patience
success yields the strict branch. Any "lengthen patience" change must not make
the divert branch more reachable than it is today.

### Shape D — system-wide vs app-level read disagreement
`liveRead` (`:365-385`) prefers the system-wide focused element, verifies
ownership by pid (`:395-400`), and falls back to the app-level read only for
non-`noValue` errors. In a web app the system-wide element may be owned by a
different pid (a helper/renderer process) → `.unknown` (harmless), or the
system-wide read returns `noValue` while the app-level read would have answered
→ today that short-circuits straight to `.noField` (`:372-384`). The two reads
are not reconciled; the weaker one can win.

### Shape E — fail-closed inversion (the load-bearing bug)
Every ambiguity that a human would call "I don't know" is routed to *divert*
whenever it arrives as `noValue`, and to *proceed* only when it arrives as a
timeout / other error / nil owner. The design's own comment claims
"`kAXErrorNoValue` on the focus read IS the void case" (`:13-14`) — that premise
is false for lazily-enabled web trees, and it is the premise the whole gate
rests on. `catcher-nofield-fix-v5.md` introduced it to stop void-pasting into
Finder; that goal is legitimate but the implementation over-reached.

### Contributing: allowlist brittleness
`TerminalEmulators` and `CanvasEditors` (`:119-207`) are bundle-ID allowlists —
the Figma/terminal precedent. They cannot express "this app renders its editor
in a web surface", so every new web-rendered app (Muse, Conductor/Tauri,
Slack, VS Code, Linear, Notion…) needs a code change. This is what makes "bad
field detection" feel arbitrary and app-specific to the user.

---

## 3. Corrections to the prior record

These are explicit because they change what we build.

1. **`AXManualAccessibility` is not a general fix.** `/Applications/ChatGPT.app`
   contains **zero** occurrences of the string; only `AXEnhancedUserInterface`
   (×2). It is genuine Electron (Claude) that implements
   `AXManualAccessibility`. Recommendation in
   `chromium-focus-divert-analysis.md:304,313` must be read as *Electron-only*
   with a Chromium-family second path, not as one switch for all.
2. **Neither string is an SDK constant.** Both are app-defined attributes;
   `grep` over `HIServices.framework/Headers/*.h` returns 0 hits. Any setter
   must pass `CFSTR("AXManualAccessibility")` / `CFSTR("AXEnhancedUserInterface")`
   and must treat `kAXErrorAttributeUnsupported` (`-25205`) as the expected,
   harmless answer for apps that don't implement them. This bounds the risk.
3. **`AXEnhancedUserInterface` is debounced (~2 s) inside Chromium** and only
   then walks the full tree. Setting it at insertion time is too late; it must
   be set at **session start** (press), which is also exactly when
   `prewarmForSession()` already runs (`DictationCoordinator.swift:315`). That
   is the natural hook, and it is free — the user is about to speak anyway.
4. **`accessibilityRole` (Chromium, Sonoma+) enables `kNativeAPIs`, not
   necessarily the full web content tree.** So even after poking the app, the
   *focused element* read may still be shallow. This is the argument for doing
   Phase 4 (error mapping) regardless: never depend on the app having answered.
5. **`plan/focus-and-settings-redo.md:38` claims Conductor is Electron.** It is
   Tauri/WebKit and it *works*; presenting it as "Electron works too" corrupts
   the diagnosis. Correct the record when the plan is revised.
6. **The verification matrix rows that would have caught this** — Slack
   composer, VS Code editor — were written into `catcher-void-fix-and-scratchpad-v3.md`
   and never run. The bug is an untested row, not an unforeseen one.
7. **The 3× retry added by `focus-and-settings-redo.md` only fires on
   `noValue`** (Shape A). Shape B (readable non-text role) still gets zero
   patience. The retry is narrower than its description implies.

---

## 4. Phased plan (authorise any subset)

Each phase is independently shippable and independently revertible. Order is by
value ÷ risk.

### Phase 0 — instrument (must ship first, zero behaviour change)
Add to every verdict log line, from `logVerdict` (`EditableFocusCheck.swift:244-255`):
- `role=` and `subrole=` as read (or `nil`);
- `src=` which read answered (`syswide` | `app` | `timeout` | `error`);
- `source=` whether the element came from `AXFocusedUIElement`, an ancestor
  walk, or a fallback read;
- keep `axerr=` raw code and `sel=`.

No verdict changes. Ship this alone first if you want tomorrow's session to be
conclusive. Cost: ~10 lines, ~zero risk. Also add `cap=` booleans (see Phase 3)
behind the same line so the next session can discriminate Shapes A vs B.

### Phase 1 — never treat "no answer" as "nothing there" (the load-bearing fix)
Change `verdictForFocusError` (`:77-79`) so `kAXErrorNoValue` maps to `.unknown`
**by default**, and to `.noField` only for an explicit, verified void-shell
allowlist (Finder `com.apple.finder`, Dock `com.apple.dock`, SystemUIServer
`com.apple.systemuiserver`) or when the *focused window* read is also nil/void
(a nil focused window is a genuinely fieldless app state).

Consequence: a web app that hasn't answered yet no longer diverts; it proceeds
exactly like today's timeout path, which is the path the user *expects*. The
Finder/Dock void protection that motivated v5 is retained — those are the only
cases with measured void pain (`catcher-void-fix-and-scratchpad-v3.md`).
Trade honestly stated: if a new, genuinely fieldless app arrives on the noValue
path, it silently proceeds (same behaviour as any AX error today) instead of
showing the catcher. That is the pre-v5 behaviour, and it is the correct risk
direction for a release: a missed catcher is recoverable (transcript is kept,
and Retry paste exists); a false catcher is a broken app.

Must land with tests that rewrite the pinned expectations in
`OtoTests/FocusRetryTests.swift`, `OtoTests/FocusProbeTests.swift`, and
`OtoTests/RealTextInsertionTests.swift` (the `noValue → noField` pins).

### Phase 2 — capability-based classification (fixes Shape B and the "dumb detection")
Replace the two-role test in `classify` (`:63-69`) with a capability ladder that
returns `.editable` when **any** holds:
- role ∈ {`AXTextField`, `AXTextArea`} (as today), minus `AXSecureTextField`;
- role == `AXComboBox` **and** `AXIsAttributeSettable(AXValue)` (a real editable
  combo, not a popup button) — check settability with
  `AXUIElementIsAttributeSettable` (`AXUIElement.h:204`) rather than assuming;
- the focused element is not text but **an ancestor or descendant in the focus
  chain is** — walk a bounded number of hops (e.g. ≤ 3) using `AXEditableAncestor`
  / `AXFocusableAncestor` (`AXWebConstants.h:112,124`) and parent/child reads,
  stopping at the first text-capable node;
- `AXIsEditable` (`AXAttributeConstants.h:1293`) is true on the element.

Return `.noField` only when the element is present, is not text-capable, has no
text-capable ancestor within the hop budget, **and** reports `AXIsEditable ==
false` — i.e. a positive answer that it is not editable. Otherwise `.unknown`.
This is what makes detection "smart": it asks *is this editable?* instead of
*is this exactly one of two roles?*

Keep `AXSecureTextField` refusal first and unconditional.

### Phase 3 — give Shape B patience too
Extend the retry condition (`:283-285`) so any `.noField` from a *successful*
read is re-read for the bounded budget, not only `noValue` ones. Cancel the
non-monotonicity (Shape C): the permissive `timeout → .unknown` branch must not
be reachable *faster* than the strict branch. Concretely: raise the budget
(e.g. `1.2 s`) and/or reduce per-attempt latency, and set a per-call
`AXUIElementSetMessagingTimeout` (`AXUIElement.h:402`) on the app element so one
slow read can't eat the whole budget. Whatever the numbers, add a test that the
strict and permissive branches are ordered sanely (a "the read got slower, does
it still divert?" regression test).

### Phase 4 — session-start AX prewarm (fixes Shape A at the source)
In `prewarmForSession()` (`DictationCoordinator.swift:459-465`), after the
existing model warm, on a background task, poke the captured target:
1. `AXUIElementCreateApplication(pid)`;
2. `AXUIElementSetAttributeValue(app, CFSTR("AXManualAccessibility"), kCFBooleanTrue)`
   — Electron path (Claude);
3. `AXUIElementSetAttributeValue(app, CFSTR("AXEnhancedUserInterface"), kCFBooleanTrue)`
   — Chromium-family path (Codex); harmless `-25205` for apps that lack it;
4. read `AXFocusedUIElement` once to *pull* the lazy enable (Chromium enables on
   a *read*, per its own design doc).

Fire-and-forget, never on the press path, never a prompt, never a download,
gated behind the existing AX-trust check. It exists to make the *insertion-time*
read answer; Phase 1 makes a non-answer safe regardless. If it does nothing for
an app, that app is covered by Phase 1/2 anyway — so its only failure mode is
"no improvement."

Do **not** put this on the insertion path: 2 s debounce + a read there is a
latency regression and a race, and the insertion gate already ran at press time.

### Phase 5 — reconcile the two reads (Shape D)
In `liveRead` (`:365-385`), when the system-wide read returns `noValue` **or**
ownership fails, fall through to `syncCheckDetail` and take the *more
informative* verdict (a text-capable answer from either read wins; only if
**both** are void is it a void). Today the weaker read can win.

### Phase 6 — per-app "Always paste" safety valve (optional, release insurance)
A settings row: "If Oto keeps showing the catcher in <App>, always paste here."
Stored as a bundle-ID set; a member bypasses the gate (`.unknown`). This is the
only change that lets a user un-break a specific app **without a code update**,
which matters for a release you can't hot-fix from a library. Prefer this over
widening `CanvasEditors`/`TerminalEmulators` further — those are the same idea
but hard-coded. Explicitly opt-in, so the fail-closed default is unchanged.

### Explicitly NOT doing
- Dropping the gate (reverted for cause). Note `phase-4-insertion.md:66` already
  recorded that a no-editable-element check "refuses Slack/VS Code" — the class
  was known before the gate shipped; the fix is to make the gate smarter, not to
  remove it.
- Broad bundle-ID allowlists for "Chromium/Electron".
- Setting anything on the insertion path.

---

## 5. Tests and verification

Unit (deterministic, no AX):
- `classify` table: text roles → editable; `AXComboBox` settable → editable;
  `AXComboBox` non-settable → noField; `AXGroup` with editable flag → editable;
  secure subrole → secureField (unchanged, still first).
- `verdictForFocusError`: `noValue` → `.unknown` for a normal app; `noValue` →
  `.noField` for Finder/Dock; `attributeUnsupported`/`cannotComplete` →
  `.unknown`.
- retry loop: `noValue` and non-text-role verdicts both re-read up to the
  budget; persistent void still diverts; ordering test for Phase 3.
- ancestor walk: bounded, never infinite; text descendant found; nothing found →
  `.noField` only on positive non-editable evidence.
- prewarm: no AX write when untrusted; `-25205` swallowed; never throws into
  the press path.

Integration (packaged, signed `.app` only — TCC and AX are meaningless from a
raw executable):
- Matrix: Finder (void → catcher held), Dock, desktop, Preview (no field), a
  plain `NSTextView` app (Pages/TextEdit), Safari (address bar + a web
  contenteditable), Claude composer, Codex/ChatGPT composer, Muse composer,
  Conductor editor, Slack composer, VS Code editor.
- For each: does it insert, and what does the focus line say
  (`role=/subrole=/src=/cap=`)? The matrix rows that don't exist today are the
  cells that were never tested.
- Regression: the catcher must still fire in Finder/Dock (the v5 goal), and
  Retry paste must still work from the catcher.

Log read for the session (once instrumented):
`log show --last 30m --info --predicate 'subsystem == "app.Oto" AND category == "focus"' --style compact`

---

## 6. Risks / deferred decisions

- **Scope of the void allowlist (Phase 1).** Fewer entries = more silent
  proceeds in genuinely fieldless apps; more entries = closer to today's
  false-divert. Recommended: Finder + Dock + SystemUIServer only, expand from
  measured trails. Deferred: whether "nil focused window" should also count as
  void (I lean yes — it is a real fieldless state, not a lazy tree).
- **Ancestor-walk distance (Phase 2).** Too shallow misses deep web trees; too
  deep costs latency on the press path. Recommended ≤ 3 hops, measured against
  the matrix. Deferred: whether to use `AXEditableAncestor` (fast, Chromium-only)
  vs a generic parent walk.
- **Prewarm may be a no-op on some apps** (Codex lacks `AXManualAccessibility`).
  Accepted: Phase 1/2 carry it. Deferred: measure whether `AXEnhancedUserInterface`
  alone wakes Codex, and whether the read-to-pull step is needed at all.
- **Privacy copy.** Prewarm writes *to other apps'* AX objects. It is a standard
  assistive-technology handshake and no content is read, but the privacy note
  and the App Store / notarisation story should say so explicitly. Deferred:
  wording.
- **Phase 3 timing is a bet** against an engine whose schedule we don't control.
  If it doesn't settle, Phase 1 already makes the divert path unreachable for
  `noValue`, so Phase 3 is polish, not safety.
- **Release sequencing.** If time is short: ship Phase 0 + 1 + 2 (+ Phase 6 as
  insurance) and defer 3/4/5. If a specific app still fails after that, Phase 6
  unbreaks it in the field.

---

## 7. Open questions for the user (decide before execute)

1. Phase 1 changes the fail-closed posture for unknown web apps — do we accept
   `.unknown` (proceed) as the default for `-25212`, with a Finder/Dock-only
   void allowlist? (This is the release-critical decision; everything else is
   additive.)
2. Which subset to authorise now: the recommended **0 + 1 + 2**, or the fuller
   0-5?
3. For Phase 6: settings-based "Always paste here" — wanted, or too much surface
   for this release?
4. Who runs the packaged-app matrix, and on which apps must it pass before ship?
