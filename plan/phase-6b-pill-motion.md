# Flow Bar pill + motion — image-driven plan — PLAN ONLY

Status: PLANNING COMPLETE (2026-09-22, §7 answered — all recommended).
Nothing implemented. Awaiting `execute`.
Supersedes §5E's renderer/panel numbers ONLY where this file says so (bar
count, widths, per-state visuals); projection model, controller ownership,
analyzer feed, and all SDK citations stand
(`plan/phase-6b-flowbar-sdk27-recheck.md` stays the engineering base).

## 1. Image analysis (the four references, deeply)

All four show the same design language: a **small near-black pill**,
white rounded content, one accent per state. No text in any frame — state
is carried by shape + motion, not words.

- **img1 processing** (`tPa0Es`): small pill; left = row of ~9 tiny
  square dots; right = 8-spoke macOS-style spinner. Read: *working* state
  = determinate-ish dots + indeterminate spinner. Nothing voice-like —
  honest "I'm thinking", no fake waveform.
- **img2 recording-loud** (`7WltHS`): 10 white capsule bars, tall center
  tapering to edges. Read: ONE loud frame of live bars, not a static
  logo — real voice is never this symmetric. Our live bars must be
  asymmetric/band-driven; symmetry appears only instant-by-instant.
- **img3 recording** (`dmmcV2`): solid red dot left + 7 white capsule bars
  of varying heights. Read: the recording signature = **red dot + live
  bars**. This is the primary reference for the recording state.
- **img4 mini pill** (`XkZwUA`): tiny pill (~half the recording width),
  small dots inside; two frames suggest it reads on light AND dark
  backgrounds. Original read was "gradient border success" — gradient
  DROPPED 2026-09-22 (insertion is the confirmation). img4 now informs
  only the success-mini SIZE (128pt), solid fill.

Common craft details: generous corner radius (fully round), bars with
round caps and airy spacing (gap ≈ bar width), content vertically
centered with even padding, pill wider than tall (~3.5–4:1).

## 2. Motion spec per state (super-smooth, realistic, state-aware)

### Recording (img3: red dot + live bars)

- 8 thin capsule bars (Q1 revised 2026-09-22: 10→8 for mini proportions), white, driven ONLY by analyzer band energies.
  Realism rules: **fast attack (~0.55) / slow release (~0.12)** per bar
  (consonants snap, vowels decay — this asymmetry is what reads as
  "real"); floor 10% so bars never vanish; clamp 0…1; pad 0.12.
- Silence is honest: bars decay to the floor and sit still — never a
  fake idle bounce (a bouncing-when-quiet pill is the fastest way to look
  cheap). No-audio failure path unchanged (loud fail, not empty complete).
- Red dot: solid, subtle 2s breathe (opacity 1→0.55→1, `.smooth`) —
  alive without shouting. Frozen under Reduce Motion.
- Hands-free marker: hollow ring around the red dot (built 2026-09-22 —
  §5E's text caption retired; the pill carries no words outside
  failure/notice copy).

### Processing / working (img1: dots + spinner)

- 9 dots, opacity chase (wave travels left→right, 0.9s loop); spinner
  rotates linear 0.9s/rev. Bounded: both die instantly on state exit
  (no orphaned rotation — controller invariant already covers tasks;
  rotation is a value-driven angle, not a runaway timer).
- Deliberately NOT bars: processing must never look like listening.

### Success (no gradient — insertion IS the confirmation)

- Dropped: the gradient-border mini pill. Success with a valid target
  needs no new UI — the text appearing in the field is the confirmation.
- Pill behavior: brief neutral mini flash (solid fill, static low dots
  fading out), ~1.0s, then dismiss. No text, no accent color, no
  gradient. Cancelled: same mini shell, ~0.8s.
- No-target success is NOT a pill state at all — it routes to the
  catcher modal (`phase-6c-modal-and-media-duck.md` 6C1) or auto-copy
  when the modal is disabled in Settings.

### Failure

- Pill widens to fit message + Copy/Retry/Dismiss buttons; bars/dots
  replaced by static amber dot + text. Holds until user acts (unchanged).
  Motion: width spring only; content crossfades.

### Transitions (the "super smooth" requirement)

- Content: crossfade `.smooth(duration: 0.25)` on state change.
- Width: `.snappy(duration: 0.35)` between per-state widths — one
  continuous spring, never a jump-cut resize.
- Bars: `animation(_:value:)` on the sample array (docs-verified current);
  appear = scale 0.92→1 + fade `.snappy(0.3)`.
- Dismiss: fade + scale 0.95, `.smooth(0.2)`, THEN `orderOut` (existing
  cancel-before-orderOut invariant).

### Reduce Motion / Transparency (images stay intact)

- Motion: bars freeze at uniform low height, dot static, no rotation,
  no width spring (instant), fades become instant. Labels intact.
- Transparency: solid near-black fill (images read solid); opaque fill
  variant — no translucency dependency anywhere.

## 3. Engineering (best implementation, tech-wise)

- **No Metal.** Agreed with your instinct, with the engineering reason
  recorded: ~10 capsules + 9 dots + 1 spinner at ≤30 Hz on `Canvas` is
  trivial GPU work (single-digit % of one frame budget); Metal would add
  a second renderer, shader lifecycle, and battery cost for zero visible
  gain. Gate: profile on device (frame-time log in debug builds); Metal
  ONLY if profiling breaches budget — not before.
- `Canvas` (SwiftUICore, SDK-verified) + `GraphicsContext`, redraws only
  on new `BarSample` (≤30 Hz). No `TimelineView` (policy ban stands).
- `VisualizerMath`: pure, `nonisolated`, headless-tested — attack/release,
  floor, clamp, dot-chase phase, spinner angle, width table. All motion
  numbers live here, not in views.
- State→visual mapping: pure function on `FlowBarState` (which visual +
  which width + which content), tested without a window.
- Pill widths REVISED per "little, not big" (Q5): height 60pt;
  recording 232 / processing 208 / success-mini 128 / failure 280 (fits
  buttons). Old 480/220 retired. Success-mini keeps the 128 width for
  the neutral flash (no gradient ring — dropped 2026-09-22).
- Bar default 10 (Q1), was 18. Bands: analyzer maps FFT → 10 bands
  (log-spaced, voice-weighted) instead of 18.
- Files (same six as slice 6B, motion content added):
  `FlowBarState.swift` (unchanged shape), `FlowBarModel.swift` (+ sample
  @ ≤30 Hz), `FlowBarPanel.swift` (compact widths, gradient-border
  success style), `BarVisualizer.swift` (bars/dots/spinner/success visuals
  + transitions), `AudioSpectrumAnalyzer.swift` (10 voice-weighted bands),
  `FlowBarController.swift` (unchanged ownership).

## 4. Product design (why this is the right call)

- Matches your references pixel-for-pixel in language (pill, capsules,
  red dot, spinner, gradient success) while Oto's states map 1:1 onto
  them — no invented fourth visual.
- Honesty gradient: voice-aware when listening, clearly mechanical when
  thinking, silent-mini when done. The pill never performs liveness it
  doesn't have.
- Small by construction: the widest pill (failure, 280) is still smaller
  than v2's minimum (220 was min, 480 max — both retired).

## 5. Verification

- Headless: `VisualizerMath` tests (attack snaps faster than release;
  silence decays to floor; chase phase monotonic; widths match table;
  reduce-motion mapping static); state→visual mapping tests; full suite
  green; zero warnings.
- Profile gate: debug frame-time log, 20× stress, no dropped-frame
  regression vs static pill.
- Eyes-on matrix (you, the smoothness judge): record→speak→stop→done on
  built-in + Jabra; confirm no fake bounce in silence, chase reads
  mechanical-not-vocal, width spring never jumps, gradient matches img4,
  single-screen fallbacks.

## 6. Risks

- Key-equivalent firing in never-key panel (D1 from recheck) stands —
  clicks guaranteed; shortcuts best-effort.
- Gradient border at 128pt wide: dropped with the gradient (2026-09-22).
  Success flash is solid-fill only — nothing to verify visually beyond
  "brief and gone".
- 10 bands from FFT: fewer bands = each band wider; voice-weighting
  keeps speech responsive (low-mid emphasis), highs damped so "s" sounds
  don't peg every bar.

## 7. Questions — ANSWERED (2026-09-22, all recommended)

- Q1. Bar count: **10** (matches img2/img3).
- Q2. Recording marker: **red dot + bars** (img3).
- Q3. Processing visual: **dots-chase + spinner** (img1).
- Q4. Success: **neutral mini flash, no gradient, no text (decided
  2026-09-22 — gradient dropped; insertion is the confirmation)** /
  "Done" text pill.
- Q5. Widths: **mini per-state animated 152/140/84/260×44 (revised 2026-09-22 to match references)**.
- Q6. Silence: **flat floor bars** (honest).
