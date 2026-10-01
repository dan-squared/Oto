# V6d: loader triage, sidebar lock, fn triage + Phase C explained

Status: PLAN ONLY. Nothing implemented. Awaiting `execute`.

## 0. Phase C, explained plainly

Phase C is the follow-up that wires per-option fn copy ("your fn
opens emoji — hold, don't tap" vs "fn is free here"). It is BLOCKED
on your matrix data, not on code: Apple documents nowhere what
`AppleFnUsageType` values mean, so the table can only be filled by
observing YOUR machine (set each "Press fn key to…" option → record
the value). The probe seam + conservative copy already shipped, so
Phase C is a ~15-line diff (pin asserts + copy strings) the moment
you report the pairs. No code can substitute for that observation.

## 1. Loader missing: diagnosis order (do not code first)

Code path audited intact (`PillLayers.swift:436-438,471-472`):
`.dotsSpinner` starts the spinner unless `reduceMotion`, stops +
hides otherwise. Nothing in V6/V7 touched it.

1. **30-second check (you):** System Settings → Accessibility →
   Display → Reduce motion. If ON, the loader is hidden BY CONTRACT
   (frozen statics instead) — working as designed, and it stays that
   way; overriding an OS accessibility contract is not on the table.
2. If OFF: dictate once and watch — finalize/insert may pass too
   fast to notice on short utterances (timing, not a bug). Try a
   10-second talk: loader must show throughout.
3. If still absent with motion on + long talk: trail-check
   (`finalizing`/`inserting` lines prove the states arrive), then a
   code dig at `show()`/`update()` ordering. Only step 3 writes code.

## 2. Sidebar lock (collapse must die)

SDK harvest: the only collapse switch (`IsCollapsibleTraitKey`) is
`internal` — no public API disables NavigationSplitView collapse.
Since the locked widths didn't prevent drag-close either, stop
fighting the component: replace the split with a plain `HStack`
(fixed 210 sidebar + 1pt hairline + detail). The `List` inside stays
native (scroll, rows, hover, tap, AX); only the collapsible
container goes. Consequences, all deletions: `columnVisibility`
state, the edge chevron, the View-menu command, `.toolbar(removing:)`
(no split = no toggle). Divider drag-resize dies with it — as asked.
Net code removal, zero new machinery, nothing left to snap.

## 3. fn still rejected: triage protocol (answer these first)

The shipped fix covers ONE path: bare-fn keyDown in the recorder.
Still-legitimate refusals that look identical from the outside:
1. **Old build?** The fix is in `bc09df1` — relaunch fresh first;
   everything before it still refuses with the old message.
2. **Which slot?** Hands-free fn is refused BY DESIGN (guidance, a
   press can't share the key with system taps) — only the hold slot
   accepts bare fn.
3. **Exact message?** "Letters need a modifier" = old code path;
   anything else names the real gate (conflict/Swap/policy).
4. **Capture log?** With Console open, press fn in the recorder and
   report the `capture` line (codes name the keyboard's arrival
   shape — decides whether this is the fixed path or a new shape).
Report these four and the fix (or the real bug) is one step, not ten.

## 4. Verification

Build green; suite green twice. Matrix: long-talk loader visible
(motion on), sidebar undraggable in both schemes, fn record on a
63-keyboard + ctrl regression, catcher rounds (footer touched).

## 5. Risks / questions

- If Reduce Motion is on and you still want motion: won't happen —
  contract stands. (Q1: confirm your setting?)
- HStack sidebar loses system collapse animation entirely — intended.
- Q2: report the §3 four answers whenever ready; Phase C waits on
  the §0 matrix pairs, unchanged.
