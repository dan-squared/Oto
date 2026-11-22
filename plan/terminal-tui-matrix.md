# Terminal TUI dictation: diagnosis + matrix plan

Status: PLAN ONLY. Nothing implemented. Awaiting `execute` (+ your answers in §4).

ACP: workspace open (`workspace-pRKw5BVS6J`, scheme Oto) — used for
live AX probing below, not for code (no code changes proposed yet
beyond §3 instrumentation, deliberately).

## 0. Load-bearing finding (live-probed 2026-10-01, not assumed)

Ghostty frontmost reports focused role **`AXTextArea`** (verified via
direct AX reads: `focusErr=0`, role exact). `classify` already maps
that to `.editable`. Conclusion: **the focus gate was never
Ghostty's problem** — on the current build it proceeds. Any Ghostty
failure happens DOWNSTREAM (paste delivery/verification) or OUTSIDE
(frontmost race, secure input, config). The just-shipped terminal
fallback is therefore load-bearing only for emulators that DON'T
publish text roles (Alacritty/kitty/WezTerm/Warp/iTerm2 — each
verified separately in §3) and for unfocused-edge cases; it changes
nothing for frontmost Ghostty. Do not "fix" focus again.

## 1. Ranked hypotheses for Ghostty (each with its proof)

- **H1 — paste swallowed by config.** Ghostty is hyper-configurable;
  a remapped paste binding (or `macos-option-as-alt` interplay)
  eats synthetic Cmd+V. Proof: manual Cmd+V in THEIR Ghostty
  works/doesn't (ask), plus their `~/.config/ghostty/config`
  keybind lines (ask them to paste — don't go reading dotfiles
  uninvited).
- **H2 — success claimed, text lost.** `RealTextInsertion` returns
  `.inserted` on post ("posted, never proven" —
  `RealTextInsertion.swift:159`). If Ghostty drops the synthetic
  V, the user sees success with no text. Proof: after such a
  dictation, is the transcript in History/recovery? Yes + no text
  in terminal = H2. Fix direction (design, not decided): post-paste
  readback (AX value length delta — expensive on scrollback
  buffers, needs a budget) or explicit unproven-success copy.
  No code until proven.
- **H3 — focus race.** Target captured, Ghostty loses key before the
  post (tmux pane switch, another app steals). Proof: menu Retry
  (user-facing target, no race) works where hotkey fails.
- **H4 — secure input.** Refusal names the holder; ask what message
  (if any) they see. Ghostty has a secure-entry feature — if
  engaged, refusal is CORRECT behavior, message says so.

## 2. Triage questions (answer these, no console needed)

1. After a Ghostty dictation, WHAT happens: catcher pops / error
   message (exact words + where) / nothing at all?
2. Is the transcript recoverable after (History menu / recovery)?
3. Does manual Cmd+V paste work in YOUR Ghostty?
4. Ghostty plain shell, or inside tmux/screen/ssh/mosh?
5. Does the menu Retry button succeed where the hotkey fails?

## 3. Terminal matrix (per emulator, after §2 answers)

Ghostty, Alacritty, kitty, WezTerm, Warp, iTerm2, Terminal.app ×
(plain shell / tmux): record focused role (probe recipe from this
investigation), dictate, record outcome. Extends the bundle set
only with evidence; each addition is one line + one test.

## 4. Verification

Build green; suite green twice. No code changes ship from this
plan except what §2 answers justify (H1=config (theirs), H2=readback
design, H3=timing fix, H4=correct-as-is). Matrix re-run per
terminal after any fix.

## 5. Risks

- Do NOT touch the focus gate again on a hunch — it is proven
  innocent for Ghostty; further widening only risks pasting into
  truly wrong places (the vim-normal-mode class).
- Readback verification on terminal buffers is the expensive,
  risky direction — budgeted, bounded, and only if H2 is proven.
