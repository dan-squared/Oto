# Phase 7e: pill-beat, truncation, stale-data, and side-naming fixes

> Follow-up to `phase-7d` (shipped, uncommitted) from the user's live testing:
> (1) second transform press shows no pill, (2) work text truncates with `…`
> instead of the pill widening, (3) stale stored shortcuts confuse (Right ⌥
> hands-free is stored data, never a default) + request for a clean-slate run
> mode, (4) refusal copy doesn't differentiate left/right sides. Four
> surgical fixes, no new features.

## Goal

- Second press (Opt+1 then Opt+2, or any repeat work) always shows the pill.
- Work text never truncates when the pill was measured for it: label width
  derives from the same font metrics as the width math (single source), with
  a headless frame-containment test proving divider/spinner/label fit.
- Stored-data story resolved: document exactly where Oto data lives, add an
  explicit `-OtoCleanSlate` launch argument (wipes domain + files, runs
  clean), enable it in the shared scheme per explicit request (removable in
  Scheme → Run → Arguments).
- Refusal copy names sides: `Too similar to your Push to talk shortcut
  (Right ⌥) — ⌥ shortcuts fire on either Option key and would trigger
  together.` The rule stays family-level (Carbon combos are side-blind —
  physics, not policy); the OUTPUT differentiates left/right.

## Spec sources

- `plan/phase-7d-whisperflow-rework.md` (live plan — this file amends it;
  7d stays untouched as the design record).
- User screenshot (`LLrh2I/image.png`): Push-to-talk = Right ⌘ (new default,
  correct) + Hands-free = Right ⌥ (STORED, never a default — default is
  unassigned). Read as: stale hands-free binding from earlier testing.
- Code facts verified by reading (this session): `FlowBarController.pollOnce`
  state-change gate keys on `"\(state)-\(sessionID)"` only — work
  appear/disappear never invalidates a pending hide, and the
  `restoreContentAlpha` rescue sits inside the same gate (root cause of #1);
  `PillContentView.update()` sizes the work label with `sizeToFit()`
  aftermath while the controller widths with `measureWorkText` — two
  metric sources that can disagree (root cause of #2);
  `DualShortcutConfiguration.defaultsKey =
  "app.Oto.dualShortcutConfiguration"` (+ `ShortcutConfiguration`,
  `TransformShortcuts.defaultsKey`, cleanup/intelligence/history/dock/modal
  keys) in `UserDefaults.standard` (domain `app.Oto` =
  `~/Library/Preferences/app.Oto.plist`); files in
  `~/Library/Application Support/Oto/` (`LocalPersistence.appDirectoryName`,
  `history.v1.json` etc.); bundle ID `app.Oto` (pbxproj), shared scheme
  `Oto.xcscheme` LaunchAction currently arg-free.
- Local SDK truth: unchanged from 7d (no new APIs).

## Assumptions questioned

- *"Cross-family bare holds (Right ⌘ + Right ⌥) should be refused as
  similar."* Investigated, rejected: independent HID codes, zero cross-fire
  (verified in `decideRoutedHold` — per-code `ModifierHoldState`s never
  interact). Refusing technically-sound pairs because they look alike would
  baffle more users than it helps. The screenshot config WORKS; the fix is
  explaining + Reset path, not a Rule C. (If the user still wants it blocked
  after reading this, Rule C is one line in `conflictsWith` + tests.)
- *"Allow cross-side hold/combo (Left-Opt combo + Right-Opt hold)."* Rejected:
  Carbon combos fire on EITHER side, so a left-recorded combo still
  double-fires (stranded, mic-live session) when pressed with the right
  finger. The safe direction is kept (block), the message now teaches sides.
- *"Wipe on every launch automatically."* Rejected as a default: silent data
  loss is never a default. Explicit launch argument only (plus scheme
  enablement per explicit request — one checkbox to remove).

## Exact file changes

1. `Oto/UI/FlowBar/FlowBarController.swift`: read the work feed BEFORE the
   state-change gate; stateKey becomes
   `"\(state)-\(session)-work:\(workText ?? "-")"`; the invalidation block
   runs when `state != .hidden || workText != nil` (pending hides die and
   content alpha restores on work appear/disappear exactly like state
   changes). No other poll logic moves.
2. `Oto/UI/FlowBar/PillLayers.swift`: work label width from
   `ceil(measureWorkText(stringValue))` (same metrics as the controller —
   single source; `sizeToFit` kept for height only); new
   `workLayoutFrames()` test hook (label/divider/spinner frames).
3. `Oto/Support/CleanSlate.swift` (new): `isRequested(arguments:)` pure +
   `wipe(defaults:supportDir:)` (remove domain + delete `Oto/` dir,
   best-effort per store, returns what was removed, never logs content).
   `OtoApp.init` calls `wipeIfRequested()` FIRST (before sandbox migration —
   otherwise migration re-copies cleared data back); migration skipped when
   wiped. Scheme `Oto.xcscheme` LaunchAction gains `-OtoCleanSlate`
   (explicit request; removal documented in the reply + plan).
4. `Oto/Models/ShortcutModels.swift`: `familyGlyph` helper
   (Option→⌥, Command→⌘, Control→⌃, Shift→⇧); `ShortcutRefusalMessage.message`
   names the held side via `KeyNames.holdChip` + teaches side-blindness:
   `"Too similar to your {Purpose} shortcut ({Side chip}) — {glyph}
   shortcuts fire on either {Family} key and would trigger together. Pick a
   different one."` `alreadyInUse` unchanged.
5. Tests: controller `workAllows` unchanged; new `workInvalidatesHide`-style
   coverage via stateKey? (stateKey is private — cover through behavior: hard
   headless. Instead: unit-test the gate condition by extracting pure
   `shouldInvalidateHide(state:workText:lastKey:)`? Minimal churn: test
   `workPillText` (exists) + frame containment (new) + CleanSlate parse/wipe
   (new, temp suite + temp dir) + refusal copy (update pinned strings) +
   label-metrics agreement (controller width − chrome == max label width:
   pure arithmetic test).

## Verification

- [ ] Build green; full `xcodebuild test -scheme Oto` unit green (UI smoke
  stays excluded — proven pre-existing failure on clean tree).
- [ ] New tests green: frame containment (all four labels), CleanSlate
  parse + wipe (temp domain/dir, production untouched), refusal copy pins.
- [ ] Matrix (user): Opt+1 then Opt+2 → pill both times, full words, no
  `…`; stage Left-Opt combo vs Right-Opt hold → refused with the side-naming
  text; fresh `-OtoCleanSlate` run → Push-to-talk Right ⌘, hands-free empty,
  no history; uncheck the arg → data persists again.

## Risks

- Scheme ships with the wipe arg ON: every Xcode Run starts clean (explicit
  request). Release archives via this scheme inherit it ONLY if launched
  with the argument — TestFlight/App Store launches never carry it. Still,
  the reply states removal loudly.
- Side-naming copy changes pinned strings (tests updated in-slice).
- No Rule C (cross-family bare holds stay allowed — deliberate, see above).
