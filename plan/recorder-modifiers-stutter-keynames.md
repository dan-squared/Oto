# Bare-modifier capture + pill/duck anti-flicker + KeyNames hardening

Status: IMPLEMENTED 2026-09-24 (commit on abu-dhabi). Build green,
full suite green repeatedly (354/354). Device matrix (§7 + §7.8) still
requires a packaged/Xcode Run with live dictation + screenshots — not
runnable headless. Nothing merged.

## 1. Goal

Four live-testing complaints, one plan:

1. **Recorder ignores lone modifiers.** Pressing ctrl/fn alone does
   literally nothing — the local monitor matches `.keyDown` only, and
   bare modifiers emit `flagsChanged`, never keyDown. Not even the beep
   fires. Fix: capture lone-modifier press+release as `modifierHold`.
2. **Double-tap pill flicker.** The micro flashes the pill (~87 ms in the
   trail) then hide→melt→show. Fix: split fade from `hideNow` with an
   adoption window + duck-restore grace. No present-delay (real sessions
   stay instant).
3. **`key 241` + missing names.** The table lacks all punctuation, keypad,
   nav, JIS, and media names; 241 (`0xF1`) is not a `kVK_` code at all
   (SDK max is `0x7E`), so its source key is unidentified. Fix: complete
   the table, log every capture, keep an honest fallback.
4. **Left/Right ambiguity.** Both Options render `⌥`. Fix: sided chips
   and labels everywhere.

## 2. Log evidence (PID 10522, session `78b10aa880`, read 2026-09-24)

- **Conversion proven live.** `05:38:07.038` begin DFDE7719 hold →
  `.125` cancelled → speech cancelled → `.179` begin 077D4A5F hands-free.
  Same shape at `05:38:10.582→.658→.727`. Micro discarded pre-insertion,
  hands-free begins. The mechanism is correct; only its pixels stutter.
- **Flicker window.** Micro life 87 ms, never reached recording (no
  `ducked DFDE7719` — duck is recording-gated). Pill shows at `starting`
  (projection `.preparing` is visible), so show→cancel→melt→show all fire
  inside ~300 ms. Five `shortcut dispatch started` clusters (`05:39:55`–
  `05:40:54`) are settings saves; zero `save blocked` lines → the
  rejects were recorder-level (invalid/dead), never gate-level.
- **No focus lines** (all sessions empty — tap testing, no speech), no
  Carbon/AX errors. `-10877` + task-port + ViewBridge noise pre-existing.
- The `WarnOnce layoutSubtreeIfNeeded` + ViewBridge lines are sheet/modal
  teardown noise until proven otherwise (§8 investigation rule).

## 3. Spec sources

- Current code: `ShortcutRecorderField.swift` (keyDown-only monitor),
  `ShortcutModal.swift` (capsule area exists), `KeyNames` table (letters/
  digits/F-keys/arrows/Space/Tab/Delete/Escape/fn only),
  `FlowBarController.swift:26-31,118-206` (150 ms poll, 140 ms melt,
  generation-guarded hide), `MediaDuck.swift:149-205` (session slot +
  crash flag set-at-duck/cleared-at-restore).
- `Docs/START_HERE_PRODUCT.md`: insertion honesty (kept), native
  Settings only (kept).
- SDK re-verified today (`MacOSX27.0.sdk`): full `kVK_` enum
  (`Events.h:197-327`) — the gap list in §6.3 is quoted from it; nothing
  at `0xF1`. No new API adopted.

## 4. Facts verified today (never from memory)

- Bare modifiers emit `flagsChanged` with the modifier's own keyCode and
  no `keyDown` (platform behavior — the dead-silence mechanism); a local
  monitor can match `.flagsChanged` alongside `.keyDown` (same API,
  already imported).
- `ModifierHoldState.flag(for:)` covers all 9 sided codes + fn — every
  capturable lone modifier is already trackable downstream.
- Pill shows at `starting`; hide = fade (immediate) + `hideNow` (140 ms);
  a state change already cancels a pending hide — adoption fails today
  purely on timing (melt completes before the next visible poll).
- Duck slot + crash flag: flag set at duck, cleared only at verified
  restore — a restore grace keeps the flag set throughout (kill-safe).

## 5. Assumptions questioned

- **"Suppress down2 to avoid the micro" — rejected again.** Would break
  tap-then-hold (a held down2 must dictate). The micro is load-bearing
  honesty: it exists so holds stay instant. Fix pixels + audio, not
  existence.
- **"Delay the pill for everyone" — rejected.** A present-delay taxes
  every real session; adoption-only costs nothing when unneeded.
- **"Popover for capture errors" — already rejected** (prior plan); the
  capsule covers the new chord case too.
- **241 is not mappable from headers.** No guessing: log it, name what
  the SDK names, fallback honestly, identify the key on-device (§7.4).

## 6. Exact file changes

### 6.1 Bare-modifier capture (`ShortcutRecorderField.swift` + rules)

- Monitor mask gains `.flagsChanged`. New pure `FlagsCaptureState`
  (tested matrix, codebase precedent): `flagsDown(code)` arms pending;
  second modifier while armed → chord; `flagsUp(code)` matching pending
  with no intervening keyDown → emit capture; any keyDown disarms
  (Escape/Delete/Tab/combo priority unchanged — checked first, as today).
- `RecorderOutcome` gains `case modifier(code: UInt16)`? NO — reuse:
  the modifier callback is separate (`onCaptureModifier(code:)`) so combo
  validation is untouched. Codes qualify iff `flag(for:) != nil`
  (CapsLock → falls through to existing invalid — untrackable on HID,
  honest message).
- Chord-alone on release → new `RecorderInvalidReason.chordOnly`:
  "One key at a time — chords need a letter." Single lone modifier →
  stage `.modifierHold(code)` through the existing advisory gate.
- No arm timeout (a held-then-released ctrl IS a ctrl hold — correct);
  mouse blindness documented (not monitored, pre-existing).
- Known overlap (documented, not solved): fn-hold coexists noisily with
  the system double-fn dictation gesture (HID holds are never consumed).
  The hold menu stays the discoverable path; the recorder is the direct
  path.

### 6.2 Pill adoption + duck grace (no present-delay anywhere)

- `FlowBarController`: split fade (immediate, as today) from `hideNow`
  (delayed to a 400 ms adoption window). Hidden-from-`cancelled` or
  `completed` (pixel-silent terminals only — never `failed`/notice
  states) parks instead of melting: a visible projection for a new
  session inside the window adopts (existing cancel-hide + show path,
  plus an `adopted X over Y` trail log) — `hideNow` never runs, no
  show-from-hidden, no flicker. Expiry → today's melt. Drag/mic/card
  guards untouched.
- `MediaDuck.restore`: 250 ms cancellable grace — slot moves to
  `restoring`, flag STAYS set; `duck(new)` inside grace absorbs (slot
  transfers, `restore absorbed` logged, volume never pumps); expiry
  restores as today. Kill-in-grace → relaunch restores (safe direction).
  Uniform cost: every clean restore lands ≤250 ms later — documented,
  imperceptible, crash-safe.
- Pure `HideAdoption` decision extracted for unit tests; headless
  `pollOnce` suites stay green; continuity proven on-device (§7).

### 6.3 KeyNames hardening + sided identity + trail logging

- Table gains ALL missing `kVK_` groups (values quoted from §3 SDK read):
  punctuation `= - [ ] ' ; \ , / . \`` (0x18/1B/21/1E/27/29/2A/2B/2C/2F/32),
  keypad 0–9 + Decimal/Multiply/Plus/Clear/Divide/Enter/Minus/Equals,
  Home/End/PageUp/PageDown/Help/ContextualMenu("Menu"), JIS
  Section(§)/Yen(¥)/Underscore/KeypadComma/Eisu, VolumeUp/Down/Mute,
  CapsLock("Caps Lock").
- Sided chips: `modifierHold` → "Left ⌥"/"Right ⌥"/"fn"/… (word-first,
  Space precedent); `shortLabel` sided too ("Hold Right ⌥ and speak.").
  Existing chip tests updated deliberately (`["⌥"]` → `["Right ⌥"]`).
- Unknown codes: honest `"key N"` fallback kept + capture logging added
  (keyCode + modifiers + outcome per capture/clear/invalid/chord —
  metadata only). Blocked-save log finally names both kinds (closes the
  §2 gap from the prior plan: comment promised, code logged slot only).

### 6.4 Remove the "Copied — paste with ⌘V" pill notice (user-ordered)

Source: `FlowBarController.syncRecovery` autoCopy branch writes the
clipboard AND shows the v7 wide pill (`model.showNotice`). The clipboard
write stays (it is the catcher-off toggle's promise, captioned in
Settings); the notice, its state, and its render path go — menu status +
Copy/Retry remain the recovery home (audit: status owns errors).

- `FlowBarController.swift`: autoCopy branch keeps pasteboard write,
  drops `showNotice`; delete `hasNotice` logic (≈lines 139,174,178,213,
  218-225), notice render branch (≈259-266), `syncDeadlines` notice
  branch + `noticeDeadline`/`noticeDuration` + call site (≈51,153,
  271-286); live branch takes `text: nil, centerText: false`.
- `FlowBarModel.swift`: delete `notice` + `showNotice`/`clearNotice`.
- `VisualizerMath.swift`: delete `noticeWidth` + fix the comment (≈72).
- `FlowBarPanel.render` → `PillLayers.update`: delete `centerText`
  (only ever true for notices — dead-parameter theater, audit-D4 rule).
- Tests (deliberate): `FlowBarControllerTests:125` rewritten (clipboard
  written, no notice state, no rewrite on second poll);
  `VisualizerMathTests:135` deleted with the constant; `PillLayersTests`
  `centerText` args removed (compiler-guided).

### 6.5 Tests (deterministic, no hardware)

- `FlagsCaptureState` matrix (new): arm → release captures sided code;
  chord → invalid; keyDown disarms; Escape/Delete priority; CapsLock
  untrackable; release-without-arm silent.
- Adoption/grace pure tests (new): inside-window adopts, expiry melts,
  failed never adopts, duck-absorb transfers slot, kill-in-grace keeps
  flag (assert flag, not volume).
- KeyNames: every new group spot-checked; sided chips/labels; fallback.
- Existing suites untouched, must stay green (chip-test updates are
  deliberate, not regressions).

## 7. Verification steps

- Build green; full suite green twice.
- Device matrix (packaged/Xcode Run, console live):
  1. Tap each of the 9 modifiers in the recorder → staged with sided chip.
  2. Chord-alone → chord capsule; modifier+letter → combo (unchanged);
     Escape/Delete priority unchanged.
  3. Fast double-tap → ONE continuous pill (no `hideNow` between
     cancel and hands-free-show in trail; `adopted` line present).
  4. Slow double-tap (micro records) → no volume pump (`restore
     absorbed` line, single duck span).
  5. Mystery key → read the new capture log line, name it if SDK-named.
  6. Sided screenshot: Left vs Right Option distinguishable.
  7. Catcher re-run (dispatch/focus untouched, but recorder + UI changed
     around them — full re-run, not spot-check).

## 8. Risks / deferred decisions

- 241 stays unidentified until §7.5 names it (external/vendor-code
  hypothesis recorded, not asserted).
- Layout-recursion warning: reproduce-check only (open/close modal ×3 +
  convert ×3, watch recurrence + pixels); touch code only with a visible
  symptom. Currently presumed benign teardown noise.
- fn-hold vs system double-fn overlap documented in §6.1, unsolved by
  design (holds never consume).
- Out of scope (restated): alternate bindings, per-app shortcuts, spoken
  triggers, `AXIsEditable`, present-delay pills.
