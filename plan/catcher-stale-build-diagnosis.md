# Catcher not updating on-device: build-identity + geometry trail plan

Status: PLAN ONLY. Nothing implemented. Awaiting `execute`.

Reference: `.context/attachments/rDRsyE/image.png` (desired alignment
mockup — full wrap, X clear of text, Copy bottom-right) +
`.context/attachments/OxWB6X/pasted_text_2026-09-24_20-55-29.txt`
(its CSS: 926px-wide card at 2x ≈ our 464pt; X 30px box; Copy
121×48 r10; text 26px/125% — spacing intent only, never radii/icons).

## 1. Diagnosis (verified, not assumed)

- Current sources CANNOT render the reported screenshot: `lineLimit` /
  `truncationMode` are deleted, height is measured, X zone/padding/hit
  circle/copyBackground are in-tree (verified by grep: `xZoneReserve`,
  `Circle().inset`, `padding(12)`, `copyBackground` all present, 0 NULs,
  449-line file intact).
- The dots require the OLD view; the short card requires the OLD fixed
  168 height. Therefore the on-screen catcher came from a stale build:
  either Xcode ran a stale DerivedData product (observed before:
  mixed old/new `.o` in one link) or a second Oto instance (old
  archive, login item) owns the visible catcher while the trailed PID
  is current. The expired session can't adjudicate after the fact.
- The stroke frame matches the known hosting-root opaque-rect class
  (v6 variant A/B history) — consistent with a stale build predating
  the mask work, not a new failure mode. No new theory invented.

## 2. Fix, in order (identity first, pixels second)

1. **Build-identity + geometry trail.** Log at every catcher show:
   words, display words, card size, `autoCopied`, mask installed vs
   skipped (with reason: layer-nil retries exhausted vs size-unchanged
   skip). One `flowbar`/`catcher` line per appearance — every future
   screenshot must have a matching trail line, or the process is stale
   by construction. No more ambiguity, ever.
2. **Single-instance clean relaunch.** List Oto processes, kill strays;
   `clean` build folder (DerivedData staleness is proven, not
   suspected); rebuild; RunProject; assert the launch marker + one
   catcher show line before any pixel judgment.
3. **Alignment pass against the mockup** (only if the fresh trail +
   fresh pixels still disagree): X-zone reserve, 12pt X padding,
   20/14/18/44/20 rhythm, Copy black-on-light — adjust numbers only
   with a screenshot diff in hand. Radii, icons, elements, copy: frozen.
4. **Mask fallback hardening** (only if the trail shows mask-skipped
   with a live layer): force `wantsLayer` policy review + retry budget
   bump. Not before evidence — the current recipe is proven on prior
   builds.

## 3. Verification

- Build green (clean folder); full suite green twice.
- Device matrix: each catcher appearance correlated 1:1 with a trail
  line (words/size/autoCopied/mask); short text wraps both slots; X
  zone clear + fat click; 101-word auto-copy + Copied + close;
  screenshot per round (new screenshots only — priors are stale-build
  contaminated).
- Explicit non-goal this round: no layout redesign, no new surfaces.

## 4. Risks / deferred

- If the stale instance is a login-item release build, killing it is
  the user's call — flag, don't touch their login items programmatically.
- Out of scope: editable transcript, notice system, pre-roll, per-app
  shortcuts.
