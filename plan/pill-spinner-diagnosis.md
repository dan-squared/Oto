# Pill spinner: diagnosis + prominence fix

Status: PLAN ONLY. Nothing implemented. Awaiting `execute`.

## 0. What was proven (ACP + headless execution, 2026-10-01)

- Ran `PillContentView` live via Xcode (`RunCodeSnippet` in
  `PillLayers.swift` context): bars → `spinnerHidden=true`;
  dotsSpinner → `spinnerHidden=false`. The view logic is CORRECT —
  no logic bug in show/update/hide paths.
- No test pins `spinnerSize` (only behavioral hooks) — resizing is
  test-safe.
- Therefore the spinner is either (a) never reached (states skip
  between polls — the tail in `de06998` already covers completed),
  (b) running an old build, or (c) too small to register (13.2px
  gray on near-black, next to 9 bright chase dots that steal the
  eye). Ordered by likelihood: b, c, then a-residual.

## 1. Step 0 — build freshness (user, 30 seconds)

Relaunch fresh from `de06998`, dictate once, watch finalize: if the
spinner shows, this whole plan is void — it was a stale build.
Report back either way before/after §2 lands.

## 2. Prominence bump (the likely real fix)

- `spinnerSize` 13.2 → **16** (`VisualizerMath.swift:64`).
  Fit proof: dots 55.275 + gap 6.6 + 16 = 77.875 ≤ 92.4 recording
  block; dotsX recenters to 8.91, spinner ends at 86.8 < 95.7 —
  inside by 8.9pt, no overflow, no layout-code change (all derived).
- Keep `.small` control size + spinning style (the Apple loader
  look, as asked) — size does the work, not a redesign.
- Tests: existing `spinnerHidden` pins hold verbatim (behavior
  unchanged, only geometry); `widthsAreMini` untouched (widths
  unchanged).

## 3. If still missing on a fresh build (decisive, not guessing)

Add a one-line trail in `render` when `.dotsSpinner` commits
(visual + `spinner.isHidden` + panel visibility), relaunch, dictate
once, read the line: pixels-committed-but-invisible (rendering/
compositing — dig at `NSHostingView`/layer tree) vs never-committed
(state routing — dig at projection). The line is removed or kept as
the permanent `adopted`-style trail after the verdict; never left
as mystery logging.

## 4. Verification

Build green; suite green twice. Matrix: short talk (tail shows
spinner 0.6s), long talk (spinner throughout finalize/insert),
Reduce Motion still frozen-statics (contract kept), catcher +
over-limit rounds (shared renderer).

## 5. Risks / non-goals

- 16px may still read small next to the chase wave — matrix decides;
  next step would be spacing the dots to give it air, never a second
  spinner kind.
- No state-machine, dispatch, or coordinator changes (already
  covered by the dwell work).
