# Focus detection hardening + shortcut settings redo

Status: PLAN ONLY. Nothing implemented.
Decisions needed on §8 Q1–Q2 (recommendations given). Awaiting `execute`.

## 1. Goal

Two complaints from live testing, one plan:

1. **Focus misses are transient, not real voids.** The trail shows the same
   target diverting then inserting 16 s apart (§2). Make detection smart
   (system-wide focus + pid check) and latent (bounded re-reads inside the
   existing latency budget) without changing any fail-closed policy.
2. **Settings rejects with no path forward.** Same-slot-both-slots saves are
   refused silently (no log line), and bare-modifier/F-key captures just
   beep. Redo the rows: plain names, a capture *field* (not a button),
   staged edits with per-row Save, and a Swap offer so two shortcuts can be
   exchanged instead of refused.

## 2. Log evidence (PID 18155, session `78bba17600`, read 2026-09-24)

- `03:51:20` hands-free begin → `focus pid=50958 verdict=noField
  axerr=-25212` → diverted, transcript preserved (catcher).
- `03:51:36` same app/same pid → `verdict=editable axerr=nil` → posted →
  `completed, inserted 19 chars`.
- Reading: `-25212` (`kAXErrorNoValue`) = **nothing focused in that app's AX
  tree at read time**, not a real void. Conductor is Electron/Chromium —
  its AX tree publishes focus asynchronously, so a single read right after
  reactivate+settle races publication. The fix is patience (re-read), not
  policy change.
- `5× shortcut dispatch started` (`03:52:27`, `03:53:00 ×2`, `03:53:20`,
  `03:53:23`) = applied saves while experimenting with keys. The `.blocked`
  refusals the user felt emit **no log line** — observability gap (fixed in
  §5.2: blocked saves get logged).
- Zero Carbon conflicts, zero AX trust errors on registration. `-10877`
  audio noise is pre-existing.

## 3. Spec sources

- `Docs/START_HERE_PRODUCT.md`: insertion honesty (never claim success from
  a paste alone — kept), native Settings scene (kept, restyled only).
- `Docs/OTO_REBUILD_PLAN/02_RECORDING_WORKFLOWS.md`: recovery rules
  (transcript kept on every failure — untouched).
- Current code: `Oto/Services/EditableFocusCheck.swift` (single per-app
  read, 300 ms timeout, `classify`/`verdictForFocusError` pure),
  `Oto/Services/RealTextInsertion.swift:245-251` (guard site — untouched),
  `Oto/Services/ShortcutDispatch.swift` (gate + F1 — reused),
  `Oto/Settings/DictationPane.swift:64-104` (two rows — restyled),
  `Oto/Settings/ShortcutRecorderField.swift` (recorder machinery — reused).
- `plan/dual-shortcut-hold-and-handsfree.md` (§5 gate, D4, F1 — unchanged).

## 4. Facts verified against the local SDK today (never from memory)

SDK `/Applications/Xcode.app/.../MacOSX27.0.sdk` (Xcode 27.0):

- `AXUIElementCreateSystemWide` (`AXUIElement.h:371`) — WindowServer-level
  focus, immune to stale per-app trees. Primary read.
- `AXUIElementGetPid` (`AXUIElement.h:374`) — attribute-free pid of the
  focused element. Corroborates target ownership.
- `kAXFocusedUIElementAttribute` (`AXAttributeConstants.h:1009`),
  `kAXTextFieldRole`/`kAXTextAreaRole` (`AXRoleConstants.h:360-361`),
  `kAXSecureTextFieldSubrole` (`:408`), `kAXSearchFieldSubrole` (`:425`).
- `kAXIsEditableAttribute` (`AXAttributeConstants.h:1293`) — EXISTS but
  deliberately **not adopted** (§6: no evidence of role-shaped misses;
  all observed misses are noValue-shaped. Revisit only on trail evidence).
- No deprecation on any of the above; nothing new to adopt.

## 5. Assumptions questioned

- **"No retries" is not a recorded policy for the focus *read*.** The code
  comment bans retries for the frontmostPID race guard ("refusals are
  policy, not timing") and activation loops. A bounded re-read of the same
  AX attribute is neither: same check, patient timing, still diverting on a
  persistent void. The distinction is documented in code, not just here.
- **Failure-mode ownership stays single.** Focus check owns "is there a
  field"; the frontmostPID guard keeps owning "are we still in the
  target". Hence pid-mismatch → `.unknown` (legacy proceed), NOT `.noField`
  — the race guard already fails those closed with the better message
  ("lost focus" vs "no text field"). One owner per mode, no double jeopardy.
- **Role mapping is NOT widened.** `classify()` keeps today's exact
  divert set. Only `nil`/unreadable roles stay `.unknown` (legacy
  proceed). Zero regression surface for exotic trees.
- **Secure text fields stay editable.** A password field accepts Cmd-V
  normally; the global secure-input gate still refuses when enabled.
  No behavior change, no scope creep.

## 6. Exact file changes

### 6.1 `Oto/Services/EditableFocusCheck.swift` (the smart+latent layer)

- `classify(role:)` signature kept; ADD `classify(role:pidMatches:)` pure:
  `pidMatches == false` → `.unknown` (§5 ownership rule). Tests updated
  deliberately (they pin our semantics, and the semantics intentionally
  grow one input).
- `LiveFocusCheck.editableFocus`:
  1. Primary: system-wide focused element. Success → pid check → role
     classify. `noValue` → retry (max 3 attempts, 100 ms apart, ≈300 ms —
     inside the existing latency budget; overall timeout raised
     300 → 700 ms to cover attempts + slow trees).
  2. Fallback: legacy per-app read when system-wide errors non-noValue
     (preserves today's `.unknown` degrade path exactly).
  3. Persistent `noValue` → `.noField` (unchanged final semantics —
     `verdictForFocusError` untouched, its tests untouched).
  4. Every attempt logs (`focus` category) with attempt index — trails
     show `attempt=1 verdict=noField` → `attempt=2 verdict=editable`
     instead of today's single ambiguous line.
- Test seam: injectable `reader` (default live) so retry timing is
  deterministic in tests. `FocusChecking` protocol unchanged
  (`StubFocusCheck` untouched).

### 6.2 `Oto/Services/ShortcutDispatch.swift` (swap + observability)

- ADD `swapHoldAndHandsFree()`: cancel session, exchange triggers,
  `enabled = true`, reset both calibrations, `start()`. Always safe: the
  kind *pair* is unchanged, only assignment flips — the gate cannot
  newly fire by construction. Logged.
- `updateSlot` `.blocked` path: `log.info` with both kinds (closes the
  silent-reject gap from §2).
- Updaters, gate, F1, D4 otherwise untouched (Save reuses them).

### 6.3 Settings rows (names + field + staged Save + Swap)

`Oto/Settings/DictationPane.swift`, `Oto/Settings/ShortcutRecorderField.swift`
(recorder rules, local monitor, suspend discipline all reused verbatim):

- **Names.** Rows: "Hold to talk" + subtitle "Hold a key — release to
  insert"; "Hands-free" + subtitle "Press once to start, again to stop".
  Presets: "Right Option — hold" / "Dictation key — F5" /
  "Custom combination". Capture field placeholder: "Click here, then press
  your shortcut…". Live binding shown as a human name (§6.4), never a raw
  keycode.
- **Field, not button.** The capture control becomes a bordered,
  keyboard-focusable field displaying the live binding; click (or Tab +
  Space) arms recording. Same machinery, honest affordance.
- **Staged Save.** Every change (preset pick, capture, clear) stages per
  row; per-row Save enabled only when staged ≠ live. Save → updater →
  applied (unstage, F1 re-enables) / blocked (message + Swap button).
  Staged-clear + Save = today's Delete semantics (kept trigger,
  `setEnabled(false)`, D4).
- **Swap.** Blocked message gains "Swap shortcuts" → single
  `swapHoldAndHandsFree()` call → both rows resync. The exchange flow the
  user asked for, with zero new conflict states.
- **Hints that end the mystery beep.** Under-field caption: combinations
  like ⌘⇧D record here (bare keys live in presets above); Delete clears
  and turns shortcuts off; Escape cancels. `invalid` keeps the beep AND
  sets the hint line to what was wrong (modifier-only / plain key).
- Calibration polling per row unchanged.

### 6.4 Human key names (new, small, pure, tested)

- ADD `KeyNames.describe(modifiers:keyCode:)` (home: `ShortcutRecorderField.swift`
  or models): ANSI letters/digits table + named keys (Space, Tab, Delete,
  Escape, arrows, F1–F12…), `"key <code>"` fallback only when truly
  unknown. Replaces `describeCombo`'s raw `"key 2"` output everywhere
  (recorder labels, conflict messages). `describeCombo` kept as a thin
  wrapper or deleted — implementer's choice, tests pin the new one.

### 6.5 Tests (all deterministic, no hardware)

- `EditableFocusCheck` tests: pid-mismatch → unknown (new); retry-succeeds-
  on-second-read + retry-exhausts→noField via injected reader (new);
  existing `classify`/`verdictForFocusError`/timeout tests updated only
  for the deliberate signature growth.
- `KeyNames` table tests (new).
- Dispatch swap tests (new, fake coordinator): swap exchanges, enables,
  resets both calibrations; swap of identical kinds is a safe no-op…
  (it re-registers; assert state, not cleverness).
- Existing `HotkeyTransitionStateTests`, `HIDDecideTests`,
  `ShortcutRecorderTests`, `EscapeCancelTests`, dual suites — untouched,
  must stay green.

## 7. Verification steps

- `xcodebuild -scheme Oto -destination 'platform=macOS' build` green;
  `xcodebuild test -scheme Oto` full suite green twice.
- Device matrix (packaged/Xcode Run, console live):
  1. Electron same-app re-dictate ×5 into a real field: zero transient
     diverts; any divert must show persistent `noValue` across all attempts.
  2. Finder/desktop void still diverts first-attempt (no patience
     regression for real voids).
  3. Focus-elsewhere race still surfaces "lost focus" (race guard owns it).
  4. Settings exchange flow: stage → Save → blocked → Swap → both live;
     staged-clear + Save → global off → fresh Save re-enables (F1).
  5. Recorder field: invalid capture shows the hint (not just a beep).
  6. Catcher re-run (insertion path touched → full re-run, not spot-check).

## 8. Risks / deferred decisions

- Huge AX trees could make system-wide reads slow: bounded by the 700 ms
  budget → `.unknown` (legacy proceed). Failure direction is always the
  old behavior, never a new divert.
- Focus-proxy apps (IME helpers): pid check degrades to `.unknown`, never
  diverts — watch item for the matrix, not a blocker.
- `kAXIsEditableAttribute` deliberately deferred (§4).
- Out of scope: per-app shortcuts, tap-vs-hold disambiguation, spoken
  triggers.

## 9. Open questions

1. **Uniform staging?** (Recommended: yes — presets stage like captures,
   one Save mental model, one extra click on preset switches.) Alternative:
   presets apply immediately, staging only for captures.
2. **Ambiguous roles** (AXWebArea/AXGroup focused): keep today's divert
   (recommended — zero regression) vs `AXIsEditable`-gated proceed?
