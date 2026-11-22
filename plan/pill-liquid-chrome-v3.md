# Pill chrome v3 — no outline, no clip, more liquid

Status: implemented with this plan (user asked "solve this problem for me",
2026-11-01 17:2x). Supersedes the rim/sheen half of `plan/pill-red-glass.md`
§4 and §11; the ramp stops, widths and Reduce-Transparency rules there stand.

## 1. What the user reported

> "the black stroking is still there … so why is it, uh, there, and also, if
> you see, it is clipped … and also can we make the glass more like liquid
> glass like liquidy"

Three complaints: (a) a black stroke hugging the capsule, (b) that stroke is
visibly **cut** at some point, (c) the material should read more like liquid
glass.

## 2. Verified facts (local measurements, not guesses)

1. **The image the user attached is our own headless probe, not the app.**
   `.context/attachments/GAnh77/image.png` is byte-identical (md5
   `13ccbd01…`) to `/…/T/opencode/pillrender/noglass.png` — the second render
   of yesterday's 6× offscreen probe. It is not a screen capture.
2. **In that probe, the black ring is 100 % the system glass failing to
   rasterise offscreen.** `NSGlassEffectView` has no WindowServer behind it
   in `cacheDisplay(in:to:)`, so it draws an **opaque black capsule**. Bisect
   (`.context` harness, 6×, reduce-transparency path so the artwork is
   opaque):
   - hide `bg` → ring stays (952 dark px → 956)
   - hide `tintGradient` → ring stays (and the black capsule behind shows
     through, 66 572 dark px)
   - hide `topSheen` / `rimGradient` → ring stays (952 / 944)
   - **remove the `NSGlassEffectView` from the superview → 0 dark px.**
   Our artwork contains no dark pixel at all. The ring is the material's
   black stand-in showing through the artwork's antialiased edge: the ramp is
   opaque in this path, so black only leaks at the 1-device-px AA rim — which
   is why it is thick at the caps (diagonal coverage) and absent at the
   left/right extremes (vertical edge, full coverage).
3. **The "clipped" look is the same artifact's other half.** The probe's
   black capsule is clipped by `PillContentView.clipsToBounds` at the
   capsule's widest points, so the ring stops dead there (sampled: no dark
   pixel at the vertical centre row, dense at every other row).
4. **`screencapture` / ScreenCaptureKit are TCC-denied to the agent shell**
   (`SCStreamErrorDomain -3801`, "user declined TCCs"), and
   `CGWindowListCreateImage` is obsoleted in macOS 15. There is therefore no
   agent-side path to real on-screen pixels on this Mac; the honest ceiling
   is "our artwork, verified layer by layer" plus the user's eyes.
5. Window shadow is already off for the pill (`makePanel(shadow: false)`,
   working tree), so the ring is not the WindowServer shadow.

## 3. Diagnosis, separated from the artifact

The probe's ring cannot be reproduced in the app (the material is real
there). But two things in the *code* can still produce an outlined /
hard-edged pill on device, and both are worth removing on their own merits:

- **D1 — a hard 1 pt stroke on the silhouette.** `rimGradient` is a
  gradient masked by `rimStroke`, a 1 pt inset capsule stroke. That is a
  hard-edged band exactly on the rim: at 26.4 pt tall the rim is a third of
  the perceived colour, so any mismatch between our stroke and the
  material's own edge treatment reads as a drawn outline (and the bottom
  stop, `rimBottom` at 0.55 alpha of a dark red, is *darker* than the body
  beside it — literally a dark line).
- **D2 — a rectangular clip on a round object.** `clipsToBounds` +
  `masksToBounds` cut the pill view at its bounding rect. The glass capsule
  touches that rect at the left/right extremes, so the material's own outer
  edge — the one thing that should soften the pill into the wallpaper — is
  exactly what gets chopped.
- **D3 — a dark capsule edge of our own.** `bg` (the scrim) is a full-size
  capsule filled with a near-black red, drawn *under* a translucent ramp.
  Where the ramp's mask is partially covered (the rim), the scrim is what
  the pixel is made of, so the rim trends dark instead of pale.

## 4. The design rule for v3

**No stroked layer may touch the silhouette. Every chrome edge is either a
mask's antialiasing or a gradient stop.** Plus: the dark veil never reaches
the edge, and nothing rectangular clips a capsule.

Stack, bottom → top, inside `ink` (unchanged hierarchy; see
`PillLayers.swift:13-27`):

```
ink                       mask = inkMask (capsule) — cages overflow, round
├── bg                    capsule inset 1 pt  (scrim; solid under Reduce Transparency)
└── tintGradient          axial pale → deep → pale red ramp, mask = capsuleMask
    └── sheen             ONE vertical white gradient: top rim → body
                          highlight → nothing → reflected bottom rim
bars, chase dots, label, shine, spinner   (unchanged)
```

`rimGradient` + `rimStroke` are deleted. The bright rim they drew is folded
into `sheen`, which has no inner hard edge (its stops feather out) and no
outer edge of its own (it inherits the capsule mask).

## 5. Exact changes

`Oto/UI/FlowBar/PillLayers.swift`

1. `PillChrome`: `scrimAlpha` 0.14 → 0.12, `scrimColor` lifted to a red-black
   (0.16, 0.02, 0.03) so the veil is red density, never grey; new
   `scrimInset = 1`; `rimTop/rimBottom/sheenTop/sheenMid/sheenBottom` replaced
   by the four `sheen*` stops; `glassTint` lightened to (0.95, 0.10, 0.15).
2. `PillContentView`: delete `rimGradient`, `rimStroke`; add `inkMask`
   (capsule on `ink.layer.mask`) and `sheen`; drop `clipsToBounds` and
   `layer.masksToBounds` on the pill itself; keep `ink.layer.masksToBounds`.
3. `syncChromePaths()`: one capsule path source → `capsuleMask` (body),
   `inkMask` (cage), `bg` (inset 1 pt).
4. `layout(width:)`: the 0.15 s silhouette morph now moves all three paths in
   the same transaction.
5. `layoutChrome()`: frame list is `[tintGradient, sheen]`.
6. `applyChrome()`: unchanged behaviour, same `scrimAlpha` contract.
7. Test hooks: `inkMaskIsCapsule()`, `chromeHasNoStrokedOutline()`.

`OtoTests/FlowBar/PillLayersTests.swift`

8. `contentClipsSoOverflowIsImpossible` → `contentCagesOverflowWithoutClipping
   theSilhouette`: the pill must **not** mask to bounds (D2), and the ink must
   carry a capsule mask whose path is the pill's capsule (the overflow cage).
9. New `chromeHasNoStrokedOutline()` + `inkMaskIsCapsule()` assertions.

## 6. Verification

1. `xcodebuild -scheme Oto -destination 'platform=macOS' build`.
2. `xcodebuild test -scheme Oto -destination 'platform=macOS'`.
3. Offscreen artwork probe **with the glass removed** (the only honest mode):
   expect **0** near-black pixels, and the pill body unchanged in geometry
   (80.85 × 26.4, 10 bars centred).
4. Blurred-backdrop composite probe (`.context/`): renders our artwork over a
   blurred, tinted backdrop so the gradient/liquidity can be judged without
   the material artifact.
5. On device (user): pill over a dark and a light wallpaper — no dark line at
   any edge, nothing cut at the left/right extremes.

## 7. Risks / deferred

- **The material's own edge is not measurable here.** If it still reads as a
  dark rim on device, the next step is not another layer: it is a 2 pt
  transparent margin (window 4 pt wider/taller, pill inset) so the material's
  outer edge has room and is never coincident with our silhouette. Deferred
  until the user has seen a real build.
- Truly *feathered* body edges would need a blur mask (`CIGaussianBlur` on a
  mask layer) — rejected: cost per layout, and the material should own the
  outer falloff.
- Catcher/permission cards keep their own chrome; this is pill-only.
