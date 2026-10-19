# Dictation delivery truth (v7)

Status: **IMPLEMENTED** (2026-10-19). See §10 for the verification record and deviations.

Predecessor: `plan/focus-gate-v6-capability-and-prewarm.md` (shipped as
`1a0e3bd`). v6 fixed losing the text to a false catcher. This plan fixes the
other half: **Oto still cannot tell whether the text arrived, and says
"completed" either way.**

---

## 1. The gap, stated precisely

`InsertionResult.inserted` means "four Cmd-V events were posted into the HID
tap". The same log line is emitted for a session that lands and one that does
not:

```
focus pid=61947 verdict=unknown axerr=nil role=AXButton      ← 2026-10-19 failure
posted HID Cmd-V to frontmost (delivery unverified) for target 61947
completed, inserted 15 chars into com.meta.endo
```

The user sees nothing; the log says success; the transcript exists only in
history (not in front of them). Three concrete costs:

1. **Phantom success.** No failure reaches the catcher, so the person has to
   notice the missing text themselves and find history.
2. **Restore is a guess.** The clipboard is put back 100 ms after posting,
   whatever the app is doing. An app that reads the pasteboard later (slow
   renderer, remote session, cold Electron) pastes stale content or nothing.
3. **Activation is a blind sleep.** `reactivate()` then 120 ms, then a single
   frontmost check that *fails closed*. On a Space switch, a full-screen app,
   or a cold start, the correct outcome is "wait 200 ms longer", not "give up
   and tell the user to switch back".

This is the remaining reason dictation "works in some apps": nothing in the
pipeline observes the effect it claims.

---

## 2. Facts verified against the local SDK

SDK `MacOSX27.0.sdk`, deployment target 27.0 (per `AGENTS.md`, never from
memory):

| Fact | Source |
|---|---|
| `kAXSelectedTextRangeAttribute` = `AXValueRef` of type `kAXValueCFRange`; **"Required for all editable text elements"**; writable | `HIServices/AXAttributeConstants.h:697-709` |
| `kAXNumberOfCharactersAttribute` = `CFNumberRef`; **"Required for editable text elements"**; read-only | `AXAttributeConstants.h:744-754` |
| `AXValueGetValue(AXValueRef, AXValueType, void *) -> Boolean` | `AXValue.h:119` |
| `kAXValueCFRangeType` = `kAXValueTypeCFRange` | `AXValue.h:58` |
| `kAXErrorInvalidUIElement = -25202`, `kAXErrorIllegalArgument = -25201` | `AXError.h:40-43` |
| `CGPreflightPostEventAccess(void) -> bool`, "Checks whether the current process already has event synthesizing access" | `CoreGraphics/CGEvent.h:405` (macOS 10.15+) |
| App is **not** sandboxed (`ENABLE_APP_SANDBOX = NO`), so the preflight is authoritative | `project.pbxproj:467,500` |

Consequence: for every native editable text element, macOS guarantees the two
attributes exist. Delivery can be *proven* there without reading a single
character of content: the selection range is `(location, length)` and the count
is an integer.

Not guaranteed — and therefore unverifiable by design: web-rendered editors.
Muse's composer is an `AXButton` inside `AXWebArea`; `AXSelectedTextRange` is
not required for that role and is not published. This plan does **not** pretend
otherwise.

---

## 3. Assumptions challenged

- **"Delivery can't be verified."** False for native text, and the SDK says so
  in the attribute contract. It is true for web content, which is exactly the
  case v6 taught us to stop guessing about.
- **"A fixed restore delay is safe."** It is an assumption about another
  process's scheduling. Replace it with a restore sequenced *after* the
  delivery decision — no new timing constant, no wider double-paste window.
- **"Auto-retry after a failed paste fixes cold apps."** Rejected. A stale AX
  read would double-paste into the document; that is data corruption, worse
  than a missed paste. Retry stays user-driven, from the catcher.
- **"Wait for an AX focused window before posting."** Rejected: apps that
  publish no AX would pay the full budget on every insertion. Wait on
  activation state only (no AX), which is the real precondition for key events.
- **"Use `AXValue` to check the text landed."** Rejected: that reads document
  content into the process. Range + count answer the same question.

---

## 4. Changes, file by file

### P1 — Posting authorization is checked, not assumed

`Oto/Services/RealTextInsertion.swift`

- `InsertionEvents`: add `postingAuthorized: @Sendable () -> Bool`; `.live`
  wires `CGPreflightPostEventAccess`.
- `InsertionDecision`: add `.refusePostingBlocked`; `next(isTrusted:postingAuthorized:)`.
- Gate it in `readyPID` next to the trust gate, and again in
  `postPlacedText` immediately before `postPaste()` (the same double-check
  pattern trust already uses).
- Refusal copy names the real fix: Accessibility permission, and that nothing
  was pasted.
- Log `post-auth=` on the existing `reactivate:` line.

Why: a dropped synthetic event currently produces `posted … completed`. The
preflight is the OS's own answer to "will this post be delivered to the tap",
and it is cheap and local.

### P2 — Readiness instead of a blind sleep

- New pure seam `Oto/Services/InsertionReadiness.swift`:
  `next(elapsed:isFrontmost:budget:) -> .wait | .post`
  (frontmost → post; elapsed ≥ budget → post; else wait).
- Replace `await events.sleep(timings.reactivateSettle)` in `readyPID` with a
  poll: floor `reactivateSettle` 60 ms, poll 15 ms, budget 400 ms, condition
  `NSWorkspace.frontmostApplication.pid == pid`.
- Advisory only: the budget expiring is **not** a refusal — the existing
  pre-post frontmost guard still fails closed with its better message.
- Log `ready=yes|timeout` with elapsed ms.

Why: activation across Spaces / full-screen / cold start takes longer than
120 ms; the current code turns that into "switch back and Retry".

### P3 — Delivery verification (native text only)

New file `Oto/Services/DeliveryVerification.swift`:

```
struct CaretSample: Equatable, Sendable {
    let location: Int
    let length: Int
    let characters: Int?      // AXNumberOfCharacters when the app publishes it
}

enum DeliveryOutcome: Equatable, Sendable { case landed, notLanded, unverifiable }

protocol DeliveryChecking: Sendable {
    func sample(for pid: pid_t) -> (element: AXUIElement, sample: CaretSample)?
}
```

Pure core (unit-tested):

```
outcome(before:after:sameElement:) -> DeliveryOutcome
  before == nil || after == nil            -> .unverifiable
  !sameElement                              -> .unverifiable
  after.characters differs                  -> .landed
  after.range differs                       -> .landed
  identical                                 -> .notLanded
```

Live reader: system-wide `AXFocusedUIElement`, pid-verified (same rule as the
focus gate), then `AXSelectedTextRange` via `AXValueGetValue(_, .cfRange, _)`
and optionally `AXNumberOfCharacters`. Any AX error, unsupported attribute, or
non-CFRange value ⇒ `nil` ⇒ `.unverifiable`. Retains the `AXUIElement` handle
so the after-read is the *same* element (`CFEqual`), not merely the same app.

Budget: `300 ms + 15 ms/KB of text`, cap `1500 ms`, poll `15 ms`. Only the
final comparison decides — an app that updates late still reads `landed`.

`RealTextInsertion.postPlacedText`: sample before posting, post once, poll for
the decision, then map it.

### P4 — Honest outcomes

- `.landed` / `.unverifiable` → `.inserted` (unchanged UI).
- `.notLanded` → `.recoverableFailure(reason:)` → existing `.insertionFailed`
  → catcher with the transcript kept. Copy: *"The text did not appear in the
  target app. The transcript is kept — copy it, or switch back and press Retry
  paste."*
- Log on every insertion:
  `delivery=landed|not-landed|unverifiable elapsed=…ms chars=…`
  replacing the misleading `(delivery unverified)` line.
- `retryPostToFrontmost` uses the same verification and returns
  `.notDelivered` instead of `.posted` when the range proves nothing landed.

No automatic second paste anywhere. One post per user action, always.

### P5 — Restore follows the decision

`scheduleRestore` keeps its ownership contract (marker + change count) but the
delay becomes the decision's elapsed time:

| Outcome | Restore |
|---|---|
| `landed` | immediately after the decision |
| `unverifiable` | after the existing `restoreDelay` (100 ms) grace |
| `notLanded` | after the poll budget completes (the app has had its chance) |

This removes the "app read the clipboard after Oto restored it" class without
lengthening the window in the common case. A user copy in between still wins
(unchanged guard).

---

## 5. Out of scope, deliberately

- AX value-setting insertion for apps that ignore synthetic paste (rejected in
  v5: whole-value replace risk, undo/IME damage).
- Web-editor delivery proof (no required attribute; would require reading
  content).
- Secure-input gate (unchanged: the OS delivers synthetic paste; password
  *fields* still refuse via `.secureField`).
- Keycode resolution by layout (already implemented with `UCKeyTranslate`).
- Automatic retry (see §3).

---

## 6. Tests

Pure, no hardware:

- `DeliveryVerificationTests`: the full outcome table, including
  character-count-only evidence, range-only evidence, element change,
  missing sample, and "identical" ⇒ `notLanded`.
- `InsertionReadinessTests`: frontmost ⇒ post; budget expiry ⇒ post (never
  refuse); floor respected.
- `InsertionDecisionTests`: posting blocked ⇒ refuse, both gate positions.
- `RealTextInsertionTests`: extend the existing fakes with a delivery checker —
  `landed` returns `.inserted`; `notLanded` returns `.recoverableFailure` and
  the clipboard is restored after the budget; `unverifiable` restores after the
  grace and still returns `.inserted`; retry maps `notLanded` ⇒ `.notDelivered`.
- Existing contract preserved: exactly one `postPaste` per `insert`.

---

## 7. Verification (device, packaged app only)

1. `xcodebuild -scheme Oto -destination 'platform=macOS' build`
2. `xcodebuild test -scheme Oto -destination 'platform=macOS' -only-testing:OtoTests`
3. One dictation per app, then
   `log show --last 10m --info --predicate 'subsystem == "app.Oto"' --style compact | grep -E "delivery=|ready=|post-auth=|focus pid="`

Expected per app: `focus verdict=… → ready=yes → post-auth=true → delivery=landed`.
A working app must never log `delivery=not-landed`; if one does, that is a real
bug with a precise name.

### Matrix to run (report which line each produces)

TextEdit, Notes, Mail, Messages, Safari (address bar + a page textarea),
Chrome (page textarea), Claude, Muse, ChatGPT/Codex, Slack, Discord, Notion,
VS Code, Xcode (editor + rename field), Terminal/iTerm, Word, Excel,
Finder (expect catcher), Desktop (expect catcher), a password field (expect
refusal, no paste).

Known expectation: Muse and other web editors log `delivery=unverifiable` and
behave exactly as today. That is honest, not a regression.

---

## 8. Risks

| Risk | Mitigation |
|---|---|
| A stale AX range reads `notLanded` after a real paste → false catcher (text is present, user is told it isn't) | Decide only at the end of the budget; require the same element handle; keep the transcript and the retry user-driven |
| Verification adds latency | Success resolves on the first changed poll (~15–40 ms); the full budget is paid only when nothing lands |
| `CGPreflightPostEventAccess` disagrees with `AXIsProcessTrusted` on this Mac | Log both; the gate only refuses when the OS says posting is blocked, and the refusal names the permission |
| Apps that publish no `AXSelectedTextRange` (web, Java) | `.unverifiable` ⇒ today's behaviour, no regression |
| Readiness poll never sees frontmost (full-screen Space switch > 400 ms) | Timeout proceeds; the existing pre-post guard still fails closed with the good message |

---

## 9. Open questions for the user

1. On `notLanded`, should the catcher also offer "Paste again" (one extra post,
   user-initiated, because we know the first one did not land)? Proposed: yes,
   but reuse the existing Retry paste rather than adding a second action.
2. Is `delivery=unverifiable` acceptable as the permanent truth for web
   editors (Muse, some Electron apps), or do you want a content-reading
   fallback behind a setting? Proposed: keep it unverifiable; no content reads.

---

## 10. Implementation record (2026-10-19)

Shipped files:

| File | Change |
|---|---|
| `Oto/Services/DeliveryVerification.swift` | new: `CaretSample`, `DeliveryOutcome`, `DeliveryProbe`, `DeliveryChecking`, pure `outcome` / `budget` / `verify`, live reader (`AXSelectedTextRange` + `AXNumberOfCharacters`, pid-verified, system-wide) |
| `Oto/Services/InsertionReadiness.swift` | new: pure `shouldPost(elapsed:floor:budget:isFrontmost:)` |
| `Oto/Services/RealTextInsertion.swift` | posting-authorization gate (pre-flight + pre-post), readiness wait replaces the blind settle, probe → post → verify → outcome, restore keyed to the decision, `delivery=` trail, retry verifies too |
| `Oto/UI/OtoMenuBarView.swift` | Retry feedback for `refusedPostingBlocked` / `notDelivered`; the app name is now computed once for both cases |
| `Oto/Support/AXDump.swift` | prints every element that publishes a caret (`delivery sample=`) — the check that proves which apps are verifiable |
| `OtoTests/DeliveryVerificationTests.swift` | new: outcome table, budget scaling, three `verify` paths, readiness table |
| `OtoTests/RealTextInsertionTests.swift` | new: `StubDeliveryCheck`, landed / not-landed / no-signal / blocked-posting / retry-not-delivered |
| `OtoTests/PasteboardOwnershipTests.swift` | `next(isTrusted:postingAuthorized:)` table |

### Deviations from the plan, and why

1. **`stillFocused` moved to the failure path only.** The probe retains the
   exact `AXUIElement` and re-reads it, so every comparison is already
   same-element by construction; the extra `CFEqual` read now runs only when
   nothing moved (the one case where "focus left" changes the answer). This
   keeps the success path at three AX calls.
2. **Two new `RetryOutcome` cases**, not one: `refusedPostingBlocked` is a
   distinct cause from `notDelivered`, and the menu names the cause.
3. **AXDump gained a caret probe.** Not in the original plan, but it is the
   instrument that settled the web-editor question below; it stays because
   "which elements in this app are verifiable?" is the first question any
   future delivery bug asks.

### Evidence that web editors cannot be falsely failed

Dump of Muse's live tree (`--ax-dump=com.meta.endo`), printing every element
that answers `AXSelectedTextRange`:

```
role=AXTextField title="Search" …  ▸ delivery sample=Optional(CaretSample(location: 0, length: 0, characters: Optional(0)))
```

Exactly **one** element in the window publishes a caret, and it is the sidebar
search field. The composer (`AXButton title="Message Attach file Dictate a
message Se"`) publishes none. So Muse reports `.unverifiable` and keeps its
v6 behaviour; only native text roles are judged. The same dump proves the live
CFRange plumbing works on a real `AXTextField`.

### Commands

- `xcodebuild -scheme Oto -destination 'platform=macOS' build` → **BUILD
  SUCCEEDED** (no warnings from the changed files).
- `xcodebuild test … -only-testing:OtoTests` → **560 tests in 59 suites
  passed** (was 539; +21).
- `xcodebuild test` (full) → only `SettingsUITests.testSettingsOpensAsOneNativeWindow`
  fails, the pre-existing `CatcherToggle` query mismatch already proven at
  HEAD before this work and unrelated to insertion.

### Still open

- The device matrix in §7 (needs one dictation per app; TCC and synthetic
  posting are only meaningful in the packaged app).
- §9 open questions: the `notLanded` catcher reuses Retry paste (implemented
  that way), and web editors stay `unverifiable` (implemented that way).
