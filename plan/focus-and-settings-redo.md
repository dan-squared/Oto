# Focus detection hardening + shortcut settings redo (modal)

Status: PLAN ONLY. Nothing implemented.
Decisions locked 2026-09-24 (user took all recommendations, §9 resolved).
Awaiting `execute`.

Reference UI (attached, gitignored under `.context/attachments/`): Wispr
Flow-style Shortcuts — a summary card ("Hold fn and speak." + Change
button) opening a `Shortcuts` modal with one card per action, keycap-chip
fields with pencil/trash affordances, `Reset to default` + `Done` footer.
Oto adopts this shape with exactly one binding per slot (the reference's
`+` alternate-binding buttons are out of scope, §8).

## 1. Goal

Two complaints from live testing, one plan:

1. **Focus misses are transient, not real voids.** The trail shows the same
   target diverting then inserting 16 s apart (§2). Make detection smart
   (system-wide focus + pid check) and latent (bounded re-reads inside the
   existing latency budget) without changing any fail-closed policy.
2. **Settings rejects with no path forward.** Same-slot-both-slots saves are
   refused silently (no log line), and bare-modifier/F-key captures just
   beep. Redo settings as a summary row + `Shortcuts` modal per the
   reference: plain names, keycap-chip fields, staged edits applied by
   Done, and a Swap offer so two shortcuts can be exchanged instead of
   refused. The sheet must not nest another rectangle frame inside itself
   (§6.3 frameless rule).

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

### 6.3 Settings: summary row + Shortcuts modal (reference-shaped)

`Oto/Settings/DictationPane.swift`, `Oto/Settings/ShortcutRecorderField.swift`,
plus new `Oto/Settings/ShortcutModal.swift` (the modal is a self-contained
surface, not pane chrome — this is also what keeps it out of the pane's
`Form`, see the frameless rule below). Recorder rules, local monitor, and
the suspend-while-recording discipline are reused verbatim; only the
surface changes.

**Summary row (replaces today's two inline `ShortcutSlotRow`s).** One card
in the Shortcut section: title "Shortcuts", subtitle "Hold ⌥ and speak."
(the hold binding's human name, dynamic — §6.4), combined status
(`dispatch.calibrationText` worst-of, already derived), and a Change
button. No "Learn more" link — dead controls are banned (pane rule: rows
without backends do not exist). Tapping Change presents the sheet with a
snapshot of both live triggers.

**Modal layout (mirrors the reference).** Header: "Shortcuts" + subtitle
"Choose your preferred shortcuts for Oto." + ✕ (discard staged, dismiss).
One card per slot — "Push to talk" / "Hold to say something short" and
"Hands-free mode" / "Press once to start, press again to stop" (these
names replace "Hold to talk"/"Hands-free" everywhere in Settings). Each
card: keycap-chip field (§6.4) with pencil (arm recording) and trash
(stage clear) affordances, a one-line status caption (per-slot
calibration — the AX troubleshooting signal stays, minimized), and the
recorder hint line while armed ("Combinations like ⌘⇧D — bare keys live
in presets below. Delete clears, Escape cancels."). A kind preset row per
card ("Right Option — hold" / "Dictation key — F5" / "Custom combination")
stages the preset; presets are NOT a second recorder. Footer: `Reset to
default` (applies factory defaults immediately via the existing updaters
— provably non-conflicting — clears staged, resyncs) and `Done` (applies
staged through the gate; any blocked entry keeps its old value with
message + Swap, modal stays open; clean → dismiss).

**Staging model (pure, tested — §6.5).** `ShortcutStaging` value type:
live config + per-slot staged kinds. Effective value = staged ?? live.
Done gates each staged slot against the OTHER slot's *effective* value
(staged if present, else live). Blocked → inline message + Swap button;
Swap exchanges the two LIVE values (clearing both staged) via the new
atomic dispatch call — the pair multiset never changes, so the gate
cannot newly fire. Staged-clear + Done = today's Delete semantics (kept
trigger, `setEnabled(false)`, D4); F1 re-enable rides the existing
updaters. ✕/sheet-ESC discards staged. `onDisappear` resumes dispatch if
a recording was armed (safety; the recorder's own Escape-cancel already
resumes on the armed path, so no double-resume: `setSuspended(false)` is
idempotent by guard).

**Frameless-sheet rule (the no-nested-rectangle requirement).** The sheet
window already provides the outer frame — the content adds NONE of its
own:
- FORBIDDEN inside the sheet: `Form`, `GroupBox`, `List`, or any
  full-bleed background panel behind the cards (each renders its own
  grouped rectangle on macOS → the doubled frame in the complaint).
- Shape: `ScrollView` + `VStack` + plain cards (`RoundedRectangle` fill
  `Color(nsColor: .controlBackgroundColor)`, radius 12 — the reference's
  subtle card tone), 24 pt padding, fixed `minWidth: 560`.
- Dismiss via `@Environment(\.dismiss)` only. No custom traffic lights,
  no second window (house rule: Flow Bar is the only custom surface).
- No new API adopted (`.sheet`, `dismiss`, `controlBackgroundColor` are
  long-standing; `defaultSize` precedent already in `OtoApp.swift`).
- Proof is visual: device-matrix screenshot (§7) must show sheet chrome
  exactly once.

**Explicitly out of scope:** the reference's `+` alternate-binding buttons
(a second binding per slot doubles transition machines and the conflict
matrix for zero asked value — one binding per slot stands); double-tap
gestures (no disambiguation timer, per the dual plan's rejected
alternative); spoken triggers; per-app shortcuts.

### 6.4 Human key names + keycap chips (new, small, pure, tested)

- ADD `KeyNames.describe(modifiers:keyCode:)` (home: `ShortcutRecorderField.swift`
  or models): ANSI letters/digits table + named keys (Space, Tab, Delete,
  Escape, arrows, F1–F12, `fn` for `kVK_Function 0x3F`…), `"key <code>"`
  fallback only when truly unknown. Replaces `describeCombo`'s raw
  `"key 2"` output everywhere (recorder labels, conflict messages).
  `describeCombo` kept as a thin wrapper or deleted — implementer's
  choice, tests pin the new one.
- ADD `KeycapField` view (home: `ShortcutModal.swift`): chips for the
  effective binding — modifier glyphs ⌃⌥⇧⌘ + key name chips (`fn`,
  `Space`, `D`…) in `RoundedRectangle` borders exactly like the reference.
  Multi-code `functionKey` sets render as one honest label: the factory
  dictation set (`F5`+`176`) shows "Dictation key"; any other set joins
  chip names. Recording state shows the placeholder
  "Press your shortcut…" in place of chips. Pencil arms, trash stages
  clear; the field disables while the other card records.

### 6.5 Tests (all deterministic, no hardware)

- `EditableFocusCheck` tests: pid-mismatch → unknown (new); retry-succeeds-
  on-second-read + retry-exhausts→noField via injected reader (new);
  existing `classify`/`verdictForFocusError`/timeout tests updated only
  for the deliberate signature growth.
- `KeyNames` table + dictation-set label tests (new).
- `ShortcutStaging` pure tests (new): effective values, Done-gate preview
  (applied + blocked against the other's effective value), Swap clears
  staged, staged-clear semantics.
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

## 9. Open questions — ALL RESOLVED 2026-09-24 (user took recommendations)

1. ~~Uniform staging?~~ YES — and it fits the modal even better than
   per-row Save: everything stages, Done is the single Save. No extra
   per-row buttons, one mental model.
2. ~~Ambiguous roles?~~ Keep today's divert. `AXIsEditable` stays deferred
   per §4.
