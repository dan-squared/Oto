# Pill: coloured glass gradient, in red — plan

Status: implemented 2026-11-01 with the device correction recorded in §11
(the first literal reading of §3 came out maroon and was fixed there). The
rim/sheen half was later superseded by `plan/pill-liquid-chrome-v3.md`; the
ramp, tint and "self-luminous, never wallpaper-dependent" rule below still
stand, and the same recipe is now the generalised `PillPalette`
(`plan/pill-color-palette.md`).

User ask (2026-11-01): *"some sort of gradient kind of thing, but it has
colour. It is glass, made with colour. Can we implement that in the pill?
In the state of blue it is, we will make it red."* The image is a Pinterest
inspiration, **not** a Wispr Flow surface (confirmed by the user), so this
is a design borrowing, not a parity port.

## 1. What the inspiration actually is (measured)

Source: `.context/attachments/gJdlNm/file-0e196858ce7e351398efeb5b937d6202.png`
(1200×1200, sRGB). Capsule body bbox `x 269…863, y 495…880` → 595 × 386 px
(aspect 1.54), so it is a wide capsule with a large corner radius.

Sampled profiles (raw sRGB bytes):

- **Horizontal**, row 90 px above centre: red channel 198 at the left edge
  → 95 at the centre → 213 at the right edge. Symmetric: pale ends, deep
  middle.
- **Vertical**, 190 px left of centre: `y495` background → `y513`
  (123,217,253) rim → `y529-537` (186,227,247) palest band *just under the
  rim* → deepening to (156,219,250) at the middle → (188,230,252) near the
  bottom → `y857` (135,210,250) rim.
- **Rim**, centre column: background → `y495` (212,245,255) 1 px light
  outer line → `y496-511` (93,205,245) → (125,215,250) saturated stroke
  ≈ 15 px → body (143,219,253). The bottom rim mirrors it (body → (114,202,248)
  at the outer edge).
- **Bloom**: a soft white halo outside the capsule, strongest at the two
  left/right shoulders, ~10–25 px.

So the composition is four things, in this order:

1. an **elliptical gradient**: the hue is constant (≈200°, saturation
   80–96 %) and only *lightness* moves — 0.68 at the core, 0.86–0.89 at the
   capsule ends, 0.79 in the pale band under the top rim;
2. a **saturated rim stroke** on the top and bottom edges (same hue,
   darker/deeper than the body beside it), independent of the horizontal
   gradient — the edge colour is identical at both left and right ends;
3. a **1 px light outer line** at the silhouette edge;
4. an **outer bloom** in the background's direction.

## 2. The hard truth about porting it

The inspiration is a **light-on-light** design: its capsule *ends* are
paler than its core. Oto's pill is near-black with white bars, so a literal
port puts near-white pixels directly behind white artwork — the bars would
vanish at the ends.

So we keep the **structure** (constant hue, value ramp, saturated rim,
light edge) and flip the **value polarity**: ends darkest, core most
saturated. That is also what preserves the pill's identity — a dark
capsule — which every previous round of this project has protected.

## 3. Palette (proposed, dark-first)

`sRGB`, alpha 1 unless stated. Hue 355°; the numbers are HSL-derived so the
family stays coherent (contrast vs white bars quoted:

| role | colour | notes |
|---|---|---|
| body core (t=0) | `rgb(163, 20, 31)` | saturated crimson; **7.6 : 1** vs white |
| body mid (t=0.5) | `rgb(92, 7, 16)` | |
| body end (t=1) | `rgb(32, 3, 6)` | near-black with a red cast |
| top rim | `rgb(255, 94, 99)` @ 0.55 | the specular edge |
| bottom rim | `rgb(196, 36, 51)` @ 0.35 | reflected edge, dimmer |
| top sheen band | white @ 0.09 → 0 | glass highlight, ~35 % of the height |
| outer bloom | `rgb(255, 70, 76)` @ 0.18 | needs geometry (§7, deferred) |

## 4. Layer stack

Inside `ink` (the glass's content view — the only place AppKit guarantees
our artwork sits, `PillLayers.swift:13-21`), bottom → top:

```
ink
├── bg            CAShapeLayer    capsule, scrim #0E0E11 @ 45 %   (exists)
├── tintGradient  CAGradientLayer .radial, 3 stops, capsule-masked  (new)
├── topSheen      CAGradientLayer .axial,  white 0.09 → 0, masked   (new)
├── rim           CAGradientLayer .axial, masked by a 1 pt inset
│                 capsule stroke                                    (new)
└── recordDot, 10 bars, 9 chase dots, label, shine, spinner        (exists)
```

Geometry, in the pill's coordinates (92.4 × 26.4):

- `tintGradient.frame = ink.bounds`; `type = .radial`;
  `startPoint (0.5, 0.5)`, `endPoint (1.0, 0.5)`; `locations [0, 0.5, 1]`.
  `CAGradientLayer` evaluates the radial distance in *unit* space, so on a
  92.4 × 26.4 layer the falloff renders as an ellipse of 46 pt × 13.2 pt —
  the reference's "pale under the rim, deep at the waist" without a second
  gradient. (Assert the rendered ellipse in the probe; if the layer turns
  out to be isotropic in points, fall back to a `.radial` masked by the
  capsule plus a vertical `.axial` for the rim band.)
- `topSheen`: same frame, `startPoint (0.5, 1.0)` → `endPoint (0.5, 0.6)`
  (top in `ink`'s non-flipped space), stops white 0.09 → white 0.
- `rim`: same frame, `startPoint (0.5, 1.0)` → `endPoint (0.5, 0.0)`,
  stops [top rim, clear @ 0.45, bottom rim]; **mask** = a shape layer with
  the capsule path inset by 0.5 pt, `lineWidth 1`, `fillColor = nil`,
  `strokeColor = black`.
- All three get the same capsule **mask** as `bg` (a shape layer holding
  the current path), refreshed in `layoutChrome()` and `layout(width:)` so
  a width change can never leave a rectangular gradient over the corners.

Composition note: the scrim stays *under* the gradient. The gradient is the
design; the scrim is the legibility floor that keeps the wallpaper from
washing the red out. `NSGlassEffectView.tintColor` stays **nil** — one red
source, predictable across wallpapers (`tintColor` exists on macOS 26.0,
verified in `MacOSX27.0.sdk/.../NSGlassEffectView.h`, but its result is
Apple-managed and would double up with the gradient).

## 5. States and fallbacks

- The gradient is **constant chrome** — present whenever the pill is
  visible (preparing/recording/message/work). No per-state colour
  animation: a fade on every state change would flicker between the
  loader and the message.
- **Reduce Transparency** (`PillLayers.swift:669-674`): glass hides and the
  scrim becomes solid. The gradient keeps working on top of the solid
  near-black — the pill degrades to "flat red glass", not to grey.
- **Reduce Motion**: nothing animates here, so nothing to gate.
- **The recording dot** (`NSColor.systemRed`, `PillLayers.swift:193`) sits
  on the red body and would lose its distinction. Proposed: the dot keeps
  `systemRed`, because its centre sits 12.4 pt from the pill's left edge
  (`recordBlock = 67.65` → block starts at 12.375, dot centre at 15.675),
  i.e. at gradient parameter t ≈ 0.66 — already in the dark end of the
  ramp (~`rgb(60,5,11)`), where a bright `systemRed` still reads. Probe
  decides; fallback is a white dot while the red glass is live.

## 6. Probe first (throwaway, precedent: `.context/glass-probe/`)

Before touching the pill: extend the existing probe with a red grid —
3 backgrounds (vivid wallpaper / white / near-black) × 2 red designs
(polarity-flipped R1 above; literal light-port R2 for comparison) ×
2 scrim alphas (0.45, 0.55). Screenshot the grid, pick one, record the
choice in this plan. Acceptance criteria:

1. white 2.5 pt bars keep crisp edges over the *entire* gradient;
2. the red never reads brown;
3. the capsule still reads as a capsule (rim visible at both corners);
4. text (`message`/`work` states) stays legible.

## 7. Exact file changes

1. `Oto/UI/FlowBar/PillLayers.swift`
   - `PillChrome`: add the gradient stops/points above as named constants +
     `rimCGColors`, `sheenCGColors` (one place, like `scrimAlpha`).
   - `PillContentView`: create `tintGradient`, `topSheen`, `rim` (+ its
     stroke mask, + the shared capsule mask), insert after `bg` in `init`.
   - `layoutChrome()`: keep every new layer's `frame = ink.bounds` and
     refresh the mask path (one path source with `bg`).
   - `layout(width:)`: extend the existing 0.15 s animated path change to
     the mask path so the silhouette morph stays one gesture.
   - `applyChrome()`: under Reduce Transparency keep the gradient (no
     opacity change) — add a comment saying why (the flat fallback is
     *red* glass, not grey).
   - Test hooks: `gradientIsRadial()`, `rimMaskIsStroke()`.
2. `Oto/UI/FlowBar/PillChromeTests.swift` (new) — **deferred** with the rest
   of the tests per user instruction.
3. `.context/glass-probe/` — throwaway probe script + `out/red-grid.png`.

## 8. Verification (no test run, per user)

1. `xcodebuild -scheme Oto -destination 'platform=macOS' build`.
2. Run the packaged app over three wallpapers; screenshot the pill in
   preparing, recording and message states; check bars, dot, text.
3. Toggle Reduce Transparency and re-screenshot.
4. Compare against the probe grid; if the core reads too bright, drop the
   core to `rgb(140, 16, 26)`; if it reads brown, raise blue by 4–6.

## 9. Risks / deferred

- **Legibility** is the only real risk; the 7.6 : 1 core is the guard rail.
- **Bloom** (the reference's outer white halo) needs room outside the
  silhouette, which the pill's window does not have (`masksToBounds` +
  window == bounds). Deferred: it would mean growing the panel by ~8 pt and
  insetting the content — a geometry change worth doing only if the
  gradient alone reads flat.
- Glass `contentView` rendering is already proven (the bars live there);
  a `CAGradientLayer` is no different, but the probe confirms the glass
  does not dim it.

## 10. Open questions

1. R1 (dark ends → crimson core, recommended) or a more literal, lighter
   red capsule (R2)?
2. Dot: keep `systemRed` or go white while the glass is red?
3. Same treatment on the catcher card and the permission card later, or
   pill-only? (Plan scope: pill only.)

---

## 11. Implemented + device correction (2026-11-01, after first run)

The first build followed §3 literally and **read as maroon on device** — the
user's screenshot at 16:26 is unambiguous. Cause, in order of weight:

1. `scrimAlpha 0.45` of near-black sat *under* a ramp whose own alphas were
   0.62/0.58/0.92, so the red only ever showed at ~40 % strength over a
   darkened backdrop — a dark-red-brown, not red.
2. The core `rgb(163,20,31)` is itself a *dark* crimson once composited at
   62 % over a dark base.
3. `glass.tintColor` was planned as nil (one red source); the user asked for
   the frost itself to be red, so the tint is on — but at the maroon value
   it added depth, not light.

Corrections now in `PillChrome` (this supersedes §3's table):

| role | now | was |
|---|---|---|
| scrim | `rgb(26,3,5)` @ **0.22** | `rgb(14,14,17)` @ 0.45 |
| glass tint | `rgb(224,18,28)` | `rgb(128,13,23)` (and originally nil) |
| body core | `rgb(242,23,33)` @ 0.90 | `rgb(163,20,31)` @ 0.62 |
| body mid | `rgb(171,8,18)` @ 0.88 | `rgb(92,7,16)` @ 0.58 |
| body end | `rgb(92,3,10)` @ 0.94 | `rgb(32,3,6)` @ 0.92 |
| top rim | `rgb(255,143,148)` @ 0.85 | `rgb(255,94,99)` @ 0.55 |
| bottom rim | `rgb(255,41,61)` @ 0.50 | `rgb(196,36,51)` @ 0.35 |
| sheen | white 0.18 | white 0.09 |

Design rule extracted (worth keeping): **the pill's red must be
self-luminous**. It cannot rely on the wallpaper showing through, because
half the wallpapers are dark; the ramp is ~90 % opaque and the bright core
carries the glow, so the same pixels read red on white and on black. The
scrim is now only a legibility floor for bright wallpapers, never a value
knob.

Rim + sheen are what make it read *lit* rather than painted — at 26 pt tall,
the 1 pt rim is a third of the perceived colour.

Probe note: `screencapture` is denied to the agent shell on this Mac
(Screen Recording TCC), so the pixel-level grid of §6 was replaced by
(a) an analytic composite check over light/dark backdrops — white bars keep
8.7 : 1 and 11.6 : 1 contrast — and (b) the user's own screenshots.

