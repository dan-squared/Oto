# 241-key identification protocol

Status: PLAN ONLY. Nothing implemented. Awaiting `execute`.

## 0. Background (what is established)

- Key 241 (`0xF1`) surfaced in the shortcut recorder and renders as
  the honest fallback `"key 241"` (`KeyNames.keyName`,
  `Oto/Settings/ShortcutRecorderField.swift:63-66`). The `KeyNames`
  table (`:154-201`) is pure `kVK_` constants — F1–F20, JIS extras,
  media (Volume/Mute) included — and contains no 241. Prior research
  (`plan/recorder-modifiers-stutter-keynames.md`) found 241 in no
  `kVK_` header: it is not an Apple virtual keycode.
- Routing today (verified in code): 241 is not in
  `functionKeyCodes` (F1–F12 only,
  `Oto/Services/ShortcutRecorder.swift:231-238`) and matches no
  modifier flag, so a bare press falls to
  `.invalid(.plainKey)` (`:211-215`) → modal beeps + "Letters need a
  modifier" (`ShortcutModal.swift:245-248`).
- **Load-bearing gap:** the `capture mods=… key=…` log line
  (`ShortcutModal.swift:409-412`) fires ONLY on the combo path. The
  invalid path logs nothing — so today the mystery key leaves NO
  trace. Step 1 (instrumentation) is prerequisite to everything else.

## 1. Ranked hypotheses (each with its disproof)

- **H1 — external/vendor keyboard key.** A non-Apple keyboard whose
  driver delivers raw codes ≥ 0xF0. Disproof: quit all remappers,
  unplug external keyboards, press every key on the built-in
  keyboard in the recorder — 241 never appears.
- **H2 — media/special key as raw keyDown.** A key (eject? assistant?
  vendor hotkey) delivered without modifiers. Disproof: same device
  round as H1 identifies WHICH physical key produces it; if none
  does, H2 falls with H1.
- **H3 — remapper ghost.** Karabiner/BetterTouchTool/etc. synthesizing
  or leaking a code. Disproof: quit every remapper/HID tool, re-press;
  241 gone → culprit named, no Oto change at all.
- **H4 — JIS/extended-layout spillover.** Ruled unlikely already
  (table covers JIS_Yen/Eisu/Underscore/KeypadComma) but kept until
  the device round names the key.

## 2. Exact work

**Step 1 — instrument the invalid path (tiny, safe, required).**
Log invalid captures with the same privacy as the combo line (key
metadata only — codes, never streams), e.g. in the modal's
`onInvalid` or beside `capture(...)`: codes + modifiers + reason.
Deterministic unit pin: `classify` with keyCode 241 + empty
modifiers → `.invalid(.plainKey)` (documents current routing; pure,
no hardware). No behavior change: beep + message stay identical.

**Step 2 — device round (user, packaged Run, console live).**
Open the recorder, press the mystery key, copy the console line(s).
Report alongside: keyboard hardware (built-in only? external
make/model), every remapper/HID tool running (quit them all and
re-press per H3), and what the key types in TextEdit (a character?
nothing? a system action?). FlagsChanged watch: press/hold it and
check for flags traffic too (rules out modifier-like delivery).

**Step 3 — SDK cross-check (MacOSX27.0.sdk, never memory).**
Grep HIToolbox (`kVK_` range ceiling), AppKit NSEvent keyCode notes,
and IOKit `IOHIDKeys` usage-page tables for 241/`0xF1` — a vendor
driver may be delivering a raw HID usage ID. Record hits or the
explicit absence.

**Step 4 — decision table (evidence decides, never guesses).**
| Finding | Change |
|---|---|
| SDK-mappable real name AND Carbon-hotkey-registrable | Table entry + literal test pin; chip shows the name |
| Vendor-specific, stable on user's hardware, NOT registrable as a hotkey | Option A: honest `"key 241"` stays (zero code — naming a key you can't record is cosmetic). Option B: table exception with a vendor comment (breaks the table's kVK-pure invariant — needs explicit user sign-off) |
| H3 (remapper ghost) | No Oto change; document the culprit |
| Nothing reproducible | Close as unreproducible; instrumentation stays as the standing trap |

Bias to the honest fallback: the table's "never hand-written hex"
invariant is worth more than one chip label.

## 3. Verification

- Build green; full suite green twice (proven flakes excepted).
- New unit pin (Step 1) green; existing recorder/classify suites
  untouched and green.
- Device: re-press the key → console line present with code 241;
  modal shows the same honest UI as before (or the named chip, per
  the Step-4 row taken); screenshot of the chip.
- Recorder matrix spot-check (combos, modifiers, Escape/Delete
  priority unchanged — the invalid path gained logging only).

## 4. Risks

- **Never guess the name.** A wrong label on a keycap chip is worse
  than "key 241" — it teaches a lie the user will rely on when
  binding shortcuts.
- **Single-device vendor codes must not pollute the shared table.**
  Without a vendor-detection gate, a hardcoded vendor label is wrong
  on every other Mac. Default is the fallback; exceptions need
  sign-off.
- **Remapper interference first.** Any table change before the H3
  round risks canonizing a ghost. H3 is a gate, not a suggestion.
- **Carbon registrability bounds usefulness.** Even a perfectly named
  241 may be unusable in combos (hotkey registration is Apple's —
  verify before promising recordability in any message copy).
- Out of scope: filling other table gaps (punctuation/keypad/nav
  noted in the parent plan), per-app shortcuts, alternate bindings.
