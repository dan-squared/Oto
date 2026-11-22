# Flow Bar: real voice wave + frosted glass — plan

Status: implemented 2026-11-01. Glass choice recorded from the look probe:
`NSGlassEffectView` `.regular`, no tint, with a 45% near-black scrim above
the glass (the device-picked "45" variant). Reduce Transparency hides the
glass and makes that scrim solid. The follow-up amplitude work is
`plan/pill-wave-sensitivity.md` (also shipped); the chrome rework that
removed the outline and clip is `plan/pill-liquid-chrome-v3.md`.

## 1. The question

Can we make the pill's wave look and behave like the Wispr Flow pill
(real, voice-reactive, continuously moving), and give the pill a
frosted-glass look, without losing the pill's current smooth
motion/positioning?

Yes. The reference is not a spectrum analyzer. Wispr Flow renders a
single smoothed loudness value through a fixed parabolic bar envelope
plus a permanent, staggered 1 s ripple. That is why it reads as one
coherent wave instead of ten independent frequency bars. Reproducing it
is a small, deterministic math change; the glass is an AppKit chrome
change with one hardware/OS probe and a known fallback.

Two honest caveats:

1. Liquid Glass inside a transparent, borderless floating panel must be
   prototyped on this Mac before we commit. The fallback
   (`NSVisualEffectView` `.hudWindow`) is a proven frosted material.
2. The audio-level calibration (dB floor/ceiling) is microphone- and
   room-dependent. It needs one pass with real speech on this device;
   the math itself is fixed.

## 2. What Wispr Flow actually does (reverse-engineered 2026-11-01)

Source: `/Applications/Wispr Flow.app/Contents/Resources/app.asar`,
extracted read-only to
`.context/reference/whisperflow/asar` (do not ship or commit the 135 MB
copy). The relevant renderer is
`.webpack/renderer/status/index.js`:

- CSS module `60666` — the bar + keyframes.
- Component `w_` (~offset 309,764) — 10 bars, envelope, delay.
- Hook `vl` (~offset 294,772) — audio level → `--audio-scale`.

### 2.1 Visual model

- 10 bars (`barCount: l = 10`).
- Bar CSS: `width: 2px; min-height: 2px; border-radius: .5px;
  background: hsla(0,0%,100%,.4)`; active mic is `#fff`.
- `transform-origin: center`; the bar scales from its center.
- Static envelope per bar:
  `h = abs((n - 1) / 2 - i)`,
  `barHeightScale = max(0, 1 - h² × (bulge / 48))`, `bulge = 1`.
  For 10 bars: `0.995, 0.953, 0.870, 0.745, 0.578` (mirrored).
- Ripple keyframes (`@keyframes __sN13fyFt35sDlqeeLV`):
  `1` at 0%, `1.2` at 20%, `1.5` at 40%, `1.1` at 80%,
  `1.3` at 90%, `1` at 100%;
  `1s infinite ease-in-out`.
- Per-bar phase: `animationDelay = 0.1 × m + "s"`, where
  `m = i < ceil(n/2) ? i : i - n`; for 10 bars:
  `0,1,2,3,4,-5,-4,-3,-2,-1`. This is the traveling ripple.
- Final transform:
  `scaleY(audioScale × barHeightScale × ripple)`.

### 2.2 Audio level

- The renderer receives one `AudioLevel` IPC value in `0...1`
  (`Cr(_t.LF.AudioLevel, …)`); the native computation is not in the JS
  bundle.
- `--audio-scale = max(1, gain × level)`; `gain = 5` for normal
  dictation, `2` for instruct mode. The `max(1, …)` is the resting
  floor.
- Normal-path smoothing is an exact per-frame EMA:
  `smoothed = 0.85 × smoothed + 0.15 × target` (rounded to 0.01).
  At 60 fps that is a ~100 ms time constant. The RAF loop stops once
  target and smoothed are both zero; `paused` forces 0; hidden tabs
  stop the loop.
- The instruct/ticker path uses
  `alpha = 0.85^(Δ / (1000/60))` plus a ±1.6/s slew limit. We do not
  need that path unless Oto adds an instruct mode.

### 2.3 Reference video measurements

`.context/attachments/549gVu/Screen Recording 2026-11-01 at 2.57.15 PM.mov`
(1024×276, 60 fps, 5.35 s; extracted grayscale frames under
`.context/reference/whisperflow/`).

- Exactly 10 bars, 4 px wide at capture scale, 8 px pitch.
- Resting heights: 2–6 px; peaks: 22–25 px while speaking.
- The peak visibly travels across the row over ~1 s; the row is not
  symmetric at any instant because the bars are phase-offset.
- The pill is matte black with a thin border; the glass in this plan is
  Oto's own chrome, not a copy of Wispr's fill.

### 2.4 Consequence

The "real" feel comes from three things, none of which is per-band FFT:

1. one fast, smoothed loudness value;
2. a fixed envelope that makes the row read as one shape;
3. a permanent, staggered ripple that keeps micro-motion alive even at
   silence.

## 3. Why Oto's current pill feels wrong (code-verified)

1. **Loudness is erased.** `VisualizerMath.bandLevels` divides every
   band by the frame's total energy (`e / total`, lines 238–244), then
   log-maps it. A whisper and a shout produce the same normalized
   distribution; only spectral tilt changes bar heights.
2. **The data clock is ~11.6 Hz, the render clock is 60–120 Hz.**
   `AppleAudioCapture` installs a 4096-frame tap
   (`Oto/Services/AppleAudioCapture.swift:206–209`); the analyzer drains
   at 16 ms but only publishes when `SpectrumFeedBox.takeLatest()`
   returns a new buffer (`AudioSpectrumAnalyzer.swift:198–205`). The
   display link then repeats the same `sample.values` every vsync
   (`FlowBarPanel.swift:225–228`). That is visible stepping by
   construction.
3. **Smoothing runs on the wrong clock.** `attack 0.70` / `release
   0.08` (`VisualizerMath.swift:48–51`) are applied once per published
   buffer. At ~11.7 Hz the release time constant is ≈ 1.0 s (the exact
   decay the ear hears); the attack is ≈ 70 ms. Hence the slow, soupy
   decay.
4. **Ten bands fight each other.** `smoothStep` then `couple` then
   `displayValue` (floor 0.16) per band; neighbors borrow only 15%, so
   the row jitters instead of moving as one wave. The separate
   render-server `sway` (`PillLayers.swift:399+`) adds a second,
   unrelated resting motion.
5. **What is already right and must stay:** GPU layer transforms,
   display-link delivery, `setLiveLevels` with actions disabled, the
   0.15 s easeOut width/snap (`FlowBarPosition.snapDuration`,
   `PillContentView.layout`), and finger-owned drag.

## 4. Proposed behavior (exact numbers)

### 4.1 One broadband level

Compute RMS off the converted 16 kHz buffer on the analyzer actor:

```swift
vDSP_rmsqv(samples, 1, &rms, vDSP_Length(frameCount))
let level = VisualizerMath.level(rms: rms)   // 0...1
```

Mapping (starting values, then one device-tuning pass):

```swift
static let levelFloorDB: Float = -55
static let levelCeilingDB: Float = -10

static func level(rms: Float) -> Float {
    guard rms > 0 else { return 0 }
    let db = 20 * log10(rms)
    return min(1, max(0, (db - levelFloorDB) / (levelCeilingDB - levelFloorDB)))
}
```

- Use the whole converted buffer (≈85 ms), not the first 512 frames.
  The buffer cadence is the floor on latency; a shorter RMS window does
  not beat it.
- Smooth at display time, exactly like the reference, but
  frame-rate-compensated:

```swift
static func smoothLevel(current: Float, target: Float, dt: Double) -> Float {
    let alpha = Float(1 - pow(0.85, dt * 60))
    return current + (target - current) * alpha
}
```

  `dt` from `CADisplayLink.timestamp` deltas, clamped to
  `1/240 ... 0.1` s. First frame uses `1/60`.
- No per-band normalization, no coupling, no floor lift.
- Optional single tuning knob if real speech lags: a slightly faster
  attack (`alpha` on rising only). Do not add it before device testing;
  the reference is symmetric.

### 4.2 Bars

```swift
static let audioGain: Float = 5          // Wispr normal mode
static let ripplePeak: Float = 1.5
static let maxBarHeight: CGFloat = 15    // pt; barFullHeight is 16.5
static let rippleStagger: Double = 0.1   // s
static let ripplePeriod: Double = 1.0    // s

// base chosen so the loudest, tallest ripple lands on maxBarHeight
static var barScaleBase: Float {
    Float(maxBarHeight / (barFullHeight * CGFloat(audioGain) * CGFloat(ripplePeak)))
} // 15 / (16.5 * 5 * 1.5) = 0.1212

static func envelope(index: Int, count: Int = barCount) -> Float {
    let h = abs(Float(count - 1) / 2 - Float(index))
    return max(0, 1 - h * h / 48)
}

static func centerOffset(index: Int, count: Int = barCount) -> Int {
    let pivot = (count + 1) / 2
    return index < pivot ? index : index - count
}

static func ripple(phase: Double) -> Float {
    // keyframes [0:1, .2:1.2, .4:1.5, .8:1.1, .9:1.3, 1:1]
    // smoothstep within each segment (CSS ease-in-out approximation)
}

static func barScale(index: Int, level: Float, time: Double) -> Float {
    let m = centerOffset(index: index)
    let phase = (time / ripplePeriod - rippleStagger * Double(m))
        .truncatingRemainder(dividingBy: 1)
    let p = phase < 0 ? phase + 1 : phase
    let audio = max(1, audioGain * level)
    let raw = barScaleBase * audio * envelope(index: index) * ripple(phase: p)
    return min(1, max(0, raw))
}
```

Resulting geometry with Oto's current constants:

- silence (`level = 0`): center `2.0–3.0 pt`, edge `1.2–1.7 pt`;
- loudest ripple peak: center ≈ `14.9 pt`, edge ≈ `8.7 pt`;
- `barFullHeight` stays `16.5` (headroom), `barWidth` `2.5`,
  `barPitch` `5.61`, 10 bars.

The `maxBarHeight` / `barFullHeight` split is deliberate: it preserves
the existing layer geometry while matching the reference's

- resting ≈ 2 px bar,
- peak ≈ 15 px bar at the same 5× gain.

If the current peak height matters more than matching the reference's
15 px, set `maxBarHeight = barFullHeight` (16.5). The formula reduces to
`barScaleBase = 1 / (audioGain × ripplePeak)`; nothing else changes.

### 4.3 Idle and accessibility

- Silence is not still: `audioScale` floors at 1, so the resting dots
  keep the staggered ripple. This replaces the current `sway` entirely.
  (The product already allows "waves move a bit" at silence; this is
  the same promise with one motion model instead of two.)
- Reduce Motion: no ripple, no display-link motion. Hold a static
  shaped row at level `0.3` (envelope only, ripple pinned at 1) so the
  pill keeps its silhouette and never goes blank. The old test's flat
  `barScaleY(0) == 0.3` becomes the shaped expectation.
- Reduce Transparency: hide `NSGlassEffectView`, show the existing
  solid dark `bg` layer. Same silhouette, same bars.
- The red record dot and 10-bar identity stay.

### 4.4 Motion / smoothness

- Keep the vsync display link; it now computes a fresh ripple phase
  and smoothed level every frame. 60 Hz and 120 Hz both get 1:1
  motion with no interpolation smear.
- Keep `setLiveLevels` with `CATransaction.setDisableActions(true)`;
  only 10 transforms per frame, no allocation, no layout.
- Keep the existing 0.15 s `easeOut` width morph, `snapDuration`
  position glide, drag ownership, and fade timings. No retiming in this
  pass — the goal is to fix the wave, not regress the motion the user
  already likes.
- The glass must resize with the same motion: set its frame from the
  content view's `bounds` (layout override + autoresizing), corner
  radius `height / 2`; verify with a width-change recording.

## 5. Frosted glass

### 5.1 API choice (verified against the local SDK)

`MacOSX27.0.sdk` →
`System/Library/Frameworks/AppKit.framework/Headers/NSGlassEffectView.h`:

- `NSGlassEffectView` is `API_AVAILABLE(macos(26.0))`.
- Styles: `.regular`, `.clear`.
- Properties: `contentView`, `cornerRadius`, `tintColor`, `style`;
  `effectIsInteractive` is macOS 27+.
- Header warning: only `contentView` is guaranteed inside the glass;
  arbitrary subviews have undefined z-order. Therefore the artwork must
  be reparented into `glass.contentView`, not layered underneath the
  glass view.

Project deployment target is 27.0 (`project.pbxproj`), so no
availability guard is required; still keep the code shaped like the
existing `#available(macOS 26.0, *)` precedent in
`Oto/UI/Theme/OtoControls.swift:132` if it reads better.

Fallback (verified in `NSVisualEffectView.h`):
`NSVisualEffectMaterial.hudWindow` (macOS 10.14+),
`blendingMode = .behindWindow`, `state = .active`, plus a dark scrim.

### 5.2 Hierarchy

Current: `PillContentView.layer` owns `bg`, `recordDot`, 10 bars, 9
chase dots; `label`, `shineLabel`, `spinner` are subviews.

Proposed:

```
PillContentView (clips, drag)
└── NSGlassEffectView (style .regular, capsule cornerRadius)
    └── contentView = ink NSView (layer-backed, masksToBounds)
        ├── bg fallback layer (hidden when glass is on)
        ├── recordDot
        ├── 10 bar layers
        ├── 9 chase layers
        ├── label
        ├── shineLabel + shineMask
        └── spinner
```

- Move the existing sublayers/subsviews one level down into `ink`; their
  local coordinates are unchanged because `ink` fills the glass bounds.
- `glass.frame = bounds`, `glass.cornerRadius = bounds.height / 2`,
  `ink.frame = glass.bounds` in a `layout()` override so the glass tracks
  the window during width animation.
- The glass is the only chrome; `bg` remains only as the Reduce
  Transparency / no-Liquid-Glass fallback.
- The window `hasShadow` stays. Verify the capsule shadow still reads;
  if Liquid Glass makes it too faint, the fallback is a custom shadow
  container (deferred decision, only if the probe demands it).

### 5.3 Look probe (first execution step)

Build a throwaway AppKit probe under `.context/glass-probe/` (not in the
app target) that shows a 92.4×26.4 capsule over a colorful desktop and
a white window, with three variants:

- A. `NSGlassEffectView` `.regular` + dark tint
  (start `NSColor(white: 0.02, alpha: 0.55)`).
- B. `.clear` + a `black @ 0.30` scrim above the glass.
- C. `NSVisualEffectView` `.hudWindow` `.behindWindow` + dark scrim.

Capture all three with `screencapture -l <window-id>` (or `-R`) and
compare white-bar contrast, frost, and edge treatment. Pick one; keep
the chrome behind a small `PillChrome` helper so the choice is
swappable. The plan's default recommendation is **A**, with **C** as the
fallback if Liquid Glass misbehaves in a transparent borderless panel.

## 6. Exact file changes (on execute)

1. `Oto/UI/FlowBar/VisualizerMath.swift`
   - `BarSample` becomes `{ level: Float, tick: UInt64 }`; all four
     call sites move to the scalar.
   - Move `barFullHeight: CGFloat = 16.5` here from `PillContentView`
     so `VisualizerMath` is the single geometry source; update
     `PillLayers` to use `VisualizerMath.barFullHeight`.
   - Delete `attack`, `release`, `floor`, `noiseGate`, `sway*`,
     `smoothStep`, `couple`, `displayValue`, `bandEdges`, `bandLevels`.
   - Add `levelFloorDB`, `levelCeilingDB`, `level(rms:)`,
     `smoothLevel(current:target:dt:)`, `audioGain`, `maxBarHeight`,
     `rippleStagger`, `ripplePeriod`, `envelope`, `centerOffset`,
     `ripple`, `barScale(index:level:time:)`.
   - Keep geometry, panel widths, work pill, shine, chase, breathe.

2. `Oto/Services/AudioSpectrumAnalyzer.swift` → rename to
   `Oto/Services/AudioLevelAnalyzer.swift`
   - `SpectrumFeedBox` → `LevelFeedBox` (same lock/convert/drop
     semantics).
   - `SpectrumEngine` → `LevelEngine`: remove `FFTSetup`, Hann window,
     bins, `bandEdges`; `level(_ buffer:) -> Float` using
     `vDSP_rmsqv` over the converted buffer.
   - `AudioSpectrumAnalyzer` → `AudioLevelAnalyzer`; `drain()` calls
     `model.ingestLevel(level, tick:)`.
   - Update the file header comments (no longer FFT).
   - Xcode uses synchronized groups; no pbxproj file entries to add.

3. `Oto/UI/FlowBar/FlowBarModel.swift`
   - Replace `smoothed: [Float]` with `targetLevel`, `smoothedLevel`,
     `lastAdvanceTime`.
   - Mark the per-frame clock state `@ObservationIgnored`: `advance`
     runs at 60/120 Hz and must not notify observers on every vsync.
   - `ingestLevel(_:tick:)` (called at buffer cadence) sets the target
     and the poll-path `sample`; `advance` only moves the private
     smoothed value and returns it.
   - `advance(to time: Double) -> Float` smooths per display frame and
     returns the level.
   - `publishSilence()` zeroes target/smoothed/sample.
   - Keep `motionFrozen` guard.

4. `Oto/UI/FlowBar/PillLayers.swift`
   - Add `glass`, `ink`; reparent artwork; `layout()` override plus
     `layout(width:)` updates.
   - `update(level:time:...)` replaces `update(values:...)`.
   - `setLiveLevels(level:time:)` replaces `setLiveLevels(_ values:)`.
   - Delete `startSway`/`stopSway`/`swayKey`/`swayOn`; the ripple is
     the idle motion now.
   - Add `reduceTransparency` handling (read from
     `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency`
     at update time; injectable in tests).
   - Keep labels/shine/spinner and all group fades unchanged.
   - Update the test helpers (`barScaleY`, `contentMaskedToBounds`,
     glass visibility, ink membership).

5. `Oto/UI/FlowBar/FlowBarPanel.swift`
   - `render(level:time:...)` instead of `values:`.
   - `pushLiveValues`: `let level = source.advance(to: link.timestamp)`;
     `content.setLiveLevels(level: level, time: link.timestamp)`.
   - Keep width/snap/drag untouched.

6. `Oto/UI/FlowBar/FlowBarController.swift`
   - Pass `model.sample.level` and a render time (use
     `CACurrentMediaTime()` for the poll path; the link owns live
     transforms).
   - Read/pass Reduce Transparency if it is not read in the view.
   - Rename analyzer/box types at construction.

7. `Oto/App/OtoApp.swift`
   - Rename `SpectrumFeedBox`/`AudioSpectrumAnalyzer` uses and the
     `spectrumBox`/`analyzer` properties to level names; same fork in
     the buffer handler (`relay.receive` + `levelBox.offer`).

8. Tests
   - `OtoTests/FlowBar/VisualizerMathTests.swift`: replace band and
     attack/release tests with level mapping, frame-rate-independent
     smoothing, envelope, ripple keyframes/periodicity, and bar-scale
     bounds.
   - `OtoTests/FlowBar/SpectrumEngineTests.swift` → `LevelEngineTests.swift`:
     440 Hz and 880 Hz at equal amplitude produce equal levels; level
     rises monotonically with amplitude; silence is 0; short buffers
     are safe; deterministic; box behavior unchanged.
   - `OtoTests/FlowBar/PillLayersTests.swift`: `update(level:time:)`;
     live levels change with time; Reduce Motion is static; glass
     hierarchy/fallback; no sway assertions.
   - `OtoTests/FlowBar/FlowBarControllerTests.swift`: keep
     `isLiveValues` assertions; add one check that the link path is
     active only while bars are live.
   - `OtoTests/FlowBar/FlowBarAudioHelpers.swift`: keep `sineBuffer`;
     it already supports amplitude/frequency.

## 7. Verification

1. `xcodebuild -scheme Oto -destination 'platform=macOS' build`
2. `xcodebuild test -scheme Oto -destination 'platform=macOS'`
3. Glass probe: capture variants A/B/C before touching the app; pick
   one; record the choice in the commit message.
4. Packaged, signed app only for live validation (TCC/shortcuts):
   - 5 s silence: resting dots + ripple, no flat line;
   - normal speech, loud speech, whisper: visible height growth within
     ~100 ms;
   - 60 Hz and 120 Hz displays: no stepping;
   - width change (recording → finalizing) and top/bottom snap: glass
     morphs with the capsule, no clipped edge;
   - Reduce Transparency on: solid dark fallback;
   - Reduce Motion on: static shaped bars, no display-link motion.
5. Screen-record a session at 60 fps; extract frames and compare the
   ripple travel/amplitude qualitatively against the reference clip.
6. Screenshots for the final report under `.context/`
   (reference vs Oto, glass variants, accessibility states), embedded
   with Markdown image syntax.

## 8. Assumptions questioned

- **"More bands / FFT = more real."** False for this reference. The
  real-pill look is one level + envelope + ripple. Per-band data is what
  makes Oto's row look like a tiny spectrum analyzer.
- **"Smoothing at the audio clock is fine."** No. Attack/release must
  run per display frame; the current per-buffer decay is ~1 s.
- **"Loudness already affects the bars."** No; `e / total` removes it.
- **"Frosted glass means SwiftUI `.glassEffect`."** The pill is AppKit
  CALayers; hosting a SwiftUI glass view would add a hosting layer for
  no benefit. `NSGlassEffectView` is the native counterpart.
- **"Silence should be static."** The reference ripples at silence; the
  current product already sways at silence. Replace the sway, don't
  stack a second idle animation.
- **"Glass is free."** A 92×26 Liquid Glass surface is cheap, but a
  transparent borderless panel is an unusual host. Probe first.
- **"The reference uses per-bar audio."** No; it uses a single
  `AudioLevel`, a fixed envelope, and a CSS ripple.

## 9. Risks / deferred decisions

- **Liquid Glass in the panel** may render without the expected desktop
  blur. Mitigation: probe; fallback C (`NSVisualEffectView .hudWindow`).
- **Microphone calibration** varies. The dB floor/ceiling are starting
  values; tune once on this Mac with real speech. Keep the two
  constants as the only knobs.
- **Dropping FFT** removes spectral information permanently for the
  pill. If Oto later wants a spectrum mode, it would need a new band
  path. This is the main product tradeoff; answer Q1 below.
- **Width animation** with glass could clip the capsule edge during the
  0.15 s morph; verify. If it does, drive the glass frame from `bounds`
  in `layout()` or animate the glass frame with the same curve.
- **White bars on glass** may lose contrast over bright wallpapers;
  the tint/scrim probe decides. Do not ship unreadable bars.
- **Window shadow** may weaken with translucency; only address it if
  the probe shows a real defect.
- **Docs:** `Docs/OTO_REBUILD_PLAN/06_BAR_VISUALIZER_RECREATION.md`
  describes a per-band visualizer and is now historically superseded
  for the pill. Do not rewrite it without an explicit instruction.

## 10. Open questions (recommended defaults)

1. **Drop the per-band FFT for the pill and use one broadband level?**
   Recommended: yes — that is the reference's actual model. Everything
   else in this plan follows from it.
2. **Keep Oto's current geometry (10 bars, 2.5 pt wide, 5.61 pt pitch,
   16.5 pt full height, red dot)?** Recommended: yes; the envelope and
   ripple reproduce the feel without resizing the pill.
3. **Glass choice:** A (dark-tinted Liquid Glass, recommended), B
   (clear glass + scrim), or C (classic HUD frost). Recommended: decide
   from the probe captures, default A.
4. **Retire the separate idle sway?** Recommended: yes; the resting
   ripple replaces it. Silence stays short and alive.
