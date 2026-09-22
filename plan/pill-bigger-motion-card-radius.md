# Pill +10%, coordinated motion, permission-card radius — plan

## Goal

Three items, one release, in this order:
1. **Pill 10% bigger** — every linear pill constant ×1.1; drag/ghosts/snap follow automatically (all derive from the constants).
2. **Bars move together, the right amount** — neighbor-coupled smoothing ("aware of each other") + slightly livelier voice snap and idle sway. Pure functions, test-pinned; render path untouched.
3. **Permission card less round, like the reference** — card 24→16, button 12→8 (measured from the reference image, see below).

## Spec sources

- User notes (this session) + reference `/.context/attachments/WIgOZ4/image.png` (button radius measured, not eyeballed — §Facts).
- `Docs/START_HERE_PRODUCT.md` canonical on conflict.
- Current code: `VisualizerMath` constants (`VisualizerMath.swift:54-100`), coupling point `FlowBarModel.applyLevels` (`FlowBarModel.swift:44-54`), sway `PillLayers.swift:332-356`, card radii `PermissionModal.swift:58-64`.

## Facts verified against the local SDK / repo (never from memory)

- **Reference button radius (measured with stdlib PNG parsing, scale-free):** cream button is 128px tall with a 28px corner arc → r/height ≈ 0.22. Current button is 12/36 = 0.33; current card is 24/60 = 0.40. So the reference button is materially less round than ours. Target: button 8/36 ≈ 0.22 (exact match), card 24→16 (0.27) per the explicit "decrease" — card corners are cropped out of the reference, so the card value follows the user's word, the button value follows the pixels.
- **Why bars feel dead (traced, not guessed):** tap is `bufferSize 4096` (`AppleAudioCapture.swift:151`) → at 48 kHz device rate each buffer spans ~85 ms, so spectrum *targets* refresh at ~12 Hz while the 16 ms drain smooths toward them. Bars therefore glide in small steps toward near-static targets — plus each of the 8 bands is smoothed independently, so neighbors never move as a wave. Fix = couple neighbors + snap faster between target updates (jitter risk is low: faster attack can't invent data, it only reaches the 12 Hz target sooner).
- **10% scaling is safe by construction:** ghosts use `currentWidth`/`pillHeight` (`FlowBarPanel.swift:205-234`), snap indicator radius is `h/2` (`PillLayers.swift:164-167`), slot margins (12/28) are screen offsets — none need edits. Same precedent as the ×0.75 pass.
- **No third-party packages** (Accelerate/AVFoundation/AppKit/QuartzCore only) → no `context7` needed.

## Assumptions questioned

- "10% bigger view frame only" — rejected: widths, bars, dots, ghosts all derive from `VisualizerMath`; scaling constants scales drag too (×0.75 precedent).
- "More motion = higher attack only" — rejected: attack alone makes bars jumpy-but-independent. Coordination comes from neighbor coupling; attack/sway bumps are the seasoning, kept small per "not a lot".
- "Keep button = card − 12 concentric" — rejected: 16 − 12 = 4 would be far sharper than the measured reference (8). The formula relaxes to `card − 8`; concentricity is approximate at this radius and the reference pixels win.
- Card height (60), button height (36), layout, colors, copy, 5 s fade — all untouched. Only radii change.

## Exact file changes

**A. Pill ×1.1 (`VisualizerMath` + `PillLayers`, constants only).**
1. `VisualizerMath.swift`: `pillHeight` 24→26.4; `barWidth` 2.625→2.8875; `barPitch` 6.375→7.0125; `recordDot` 6→6.6; `chaseDot` 2.25→2.475; `chasePitch` 6→6.6; `spinnerSize` 12→13.2; `panelWidth` preparing/recording 84→92.4, finalizing/inserting 87→95.7; `noticeWidth` 150→165. Counts (`barCount` 8, `dotCount` 9), `floor`, `swayThreshold` unchanged. Full precision kept (×0.75 precedent: 2.625, 6.375).
2. `PillLayers.swift`: `barFullHeight` 15→16.5; `padding` 7.5→8.25; record gap 4.5→4.95; chase/spinner gap 6→6.6. Radius/drag/snap code untouched (derives from constants).
3. Tests: `VisualizerMathTests.widthsAreMini` new pins; `PillLayersTests` frames → 92.4×26.4 / 95.7×26.4 / 150→165 notice; `FlowBarPositionTests` slot widths 84→92.4.

**B. Coordinated motion (pure model, render path untouched).**
4. `VisualizerMath.swift`: new pure `couple(_ levels: [Float]) -> [Float]` — `out[i] = 0.7·self + 0.15·(left + right)` (edge bars: 0.7·self + 0.3·sole neighbor; weights sum to 1, never clip). Neighbors rise and fall as a wave instead of 8 strangers.
5. `FlowBarModel.applyLevels`: `smoothStep` per band (unchanged) → `couple` → `displayValue` mapping (unchanged). Two lines; sway/threshold/gate logic untouched.
6. Feel bumps (small, per "just the right amount"): `attack` 0.45→0.55 (≈13 ms snap between the ~12 Hz target updates), `release` 0.08→0.10 (decay grace kept); sway peak `floor+0.14`→`floor+0.18`, `swayCycle` 1.8→1.6 s. Floor 0.30 and `swayThreshold` 0.40 kept (v7 silence contract stands).
7. Tests: `couple` pins (uniform in → uniform out; single-hot-band spreads 0.15 to each neighbor; edges; output never exceeds input max); `smoothStep` pins updated to 0.55/0.90-fall; sway peak pin `floor+0.18`; headless presence tests (`swayHasAnimation` etc.) unchanged.

**C. Permission-card radius (match reference).**
8. `PermissionModal.swift`: `cardRadius` 24→16; `buttonRadius` formula `max(4, cardRadius − 12)` → `max(4, cardRadius − 8)` (= 8, the measured 0.22 ratio). Header comment radii updated.
9. Tests: `PermissionModalTests` radius pins updated (16/8); width/ceiling/appearance tests untouched (layout math unchanged).

## Verification steps

- `xcodebuild -scheme Oto -destination 'platform=macOS' build` clean + full suite green (new/updated pins incl.).
- Grep gates: no new force unwraps; no NSEvent monitors; no coordinator/dispatch/panel edits (this change touches constants + model + card only).
- Packaged signed `.app` only: deny mic → dictate → card visibly less round, button matches reference; dictate → pill ~10% larger, ghosts/snap track the new size top↔bottom; voice moves bars as a coordinated wave (quiet room: gentle joint sway; normal voice: wave jumps within 1–2 frames, decays gracefully); Reduce Motion still freezes everything.
- Feel matrix is the user's call: if the wave wants one more nudge after testing, attack/coupling weights get one retune pass max before re-pinning.

## Risks / deferred

- Coupling softens sharp single-band peaks slightly (0.7 self-weight keeps the peak band dominant — pinned by test); if voice character feels smeared, drop to 0.8/0.1 weights, one-line change.
- Attack 0.55 at the 16 ms clock is snappy by design; if quiet-room jitter appears, it means the noise floor (not the coefficient) needs the gate — fall back to 0.45, don't touch the drain.
- Catcher modal work stays deferred; permission-card layout/widths already signed off.

## Open questions

1. Card 16/button 8 is my read of "decrease … like this image" (button measured, card inferred). If you wanted the card even flatter (12?) or the button fully capsule, say so — one-line change each.
2. Coupling weights 0.7/0.15 are the starting point; the feel matrix decides whether they stay.
