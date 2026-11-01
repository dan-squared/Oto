# Pill wave: more voice, same shape — plan

Status: implemented 2026-11-01. Both levers shipped exactly as §4 specified —
the dB window (`-55/-10` → `-52/-22`) and the asymmetric attack/release
keepers (`0.68` rising / `0.82` falling) — so §8's two open questions are
answered by the code, not outstanding. §7's retune note stands: the two
constants are the knobs, and the dB window is the one to move first.

Follow-up to `plan/flowbar-waveform-and-glass.md` (EXECUTING). User report
(2026-11-01, after the real-dictation pass): *"the waveforms are not that
reactive to voice — their vertical distance is limited, they don't react a
lot. Make them more sensitive, a little bit."*

## 1. The question

The wave is already driven by real loudness, is already reference-shaped,
and the geometry is already right. So why does it read flat, and what is
the smallest honest change that makes it answer the voice?

## 2. What is actually happening (verified in code, this tree)

`VisualizerMath.swift`:

- `levelFloorDB = -55`, `levelCeilingDB = -10` (lines 146-147).
- `level(rms:)` maps dB **linearly** across that 45 dB window (152-157).
- `barScaleBase = maxBarHeight / (barFullHeight × audioGain × ripplePeak)`
  = 15 / (16.5 × 5 × 1.5) ≈ **0.1212** (185-187).
- `barScale = clamp(barScaleBase × max(1, 5 × level) × envelope × ripple)`
  (240-248); `envelope` is `1 - h²/48` (191-195); `ripple` is 1.0…1.5 (223-236).
- Smoothing is symmetric: `alpha = 1 - 0.85^(dt·60)` ≈ 100 ms (162-166).

So the rendered bar height (pt, centre bar, envelope ≈ 0.995) is:

| level | dBFS | audio = max(1, 5·level) | height, ripple 1.0 | ripple 1.5 |
|------:|-----:|------------------------:|-------------------:|-----------:|
| 0.00 | ≤ -55 | 1.00 | 2.0 | 3.0 |
| 0.33 | -40 | 1.67 | 3.4 | 5.0 |
| 0.44 | -35 | 2.22 | 4.5 | 6.7 |
| 0.55 | **-30 (normal speech)** | 2.75 | **5.5** | **8.3** |
| 0.78 | -20 | 3.89 | 7.8 | 11.7 |
| 1.00 | ≥ -10 | 5.00 | 10.0 | 15.0 |

Normal speech therefore lives at **5.5–8.3 pt of a possible 15** — a bit
over one third of the pill's height, and the *movement* across a sentence
is ~4 pt. That is exactly the reported symptom.

Two facts that are **not** the cause, so they stay untouched:

1. **Envelope.** Fitting `1 - h²/k` to the per-bar maxima of the 21
   reference frames (`.context/reference/whisperflow/frame-0*.png`,
   measured 2026-11-01) gives k ≈ 48 at the two extreme pairs
   (h=4.5 → k=49.8, h=3.5 → k=47.3), vs Oto's k=48. The arch is right.
2. **Ceiling.** Oto's peak is 15/26.4 = 57% of the pill; the reference's
   measured peak is 81/180 ≈ 45% of the pill. Oto is already *taller*
   relative to its capsule; raising `maxBarHeight` would overshoot the
   reference, not approach it.

## 3. What the reference does (from the extracted asar)

- `gain: isMeeting ? 2 : 5` — Oto's `audioGain = 5` matches.
- Level smoothing: EMA keeper `0.85` per 60 fps frame, **plus** a slew
  limit `|Δ| ≤ 1.6 · dt` per second. Oto has the EMA, not the slew limit.
- Ripple 1.0 → 1.5 over 1 s, per-bar stagger 0.1 s — Oto matches.

The slew limit makes the reference **slower** than Oto, not faster. So the
reference's reactivity is bought with *amplitude at ordinary speech*, not
with speed. That is the lever to pull.

The reference's dB mapping itself is inside the main process (the renderer
only receives a 0…1 number), so it cannot be copied — it is Oto's own
calibration, which the code already documents as the device-dependent knob.

## 4. Decision

### 4.1 Re-centre the dB window (the real fix)

`levelFloorDB` **-55 → -52**, `levelCeilingDB` **-10 → -22** (45 dB → 30 dB).

| level | dBFS | height, ripple 1.0 | ripple 1.5 | vs today |
|------:|-----:|-------------------:|-----------:|---------:|
| 0.00 | ≤ -52 | 2.0 | 3.0 | unchanged |
| 0.23 | -45 (room noise) | 2.3 | 3.5 | +0.3 (barely lifts) |
| 0.73 | **-30 (normal speech)** | **7.3** | **11.0** | **+33 % / +32 %** |
| 1.00 | ≥ -22 (loud) | 10.0 | 15.0 | saturates sooner |

Why -52/-22 rather than the more aggressive -55/-25: the low end is what
protects the resting pill. At -45 dBFS RMS the bars move 2.3→3.5 pt
(today 2.0→3.0), i.e. a noisy room still reads as "at rest", while normal
speech gains a third of the range and now *fills* the row instead of
under-filling it. The floor also stays below the noise gate, so silence
still floors at 2–3 pt.

If the device pass shows speech still landing under ~65 % of the row,
step to -55/-25 (level 0.833 at -30 dBFS → 8.3–12.5 pt). One-line change,
no geometry moves.

### 4.2 Asymmetric attack / release (the "reactive" texture)

Symmetric 100 ms makes every syllable rise and fall at the same rate, so
the row breathes rather than punches. Split the keeper:

- attack `0.68` per 60 fps frame → 90 % in ≈ 98 ms
- release `0.82` per 60 fps frame → 90 % in ≈ 200 ms

`FlowBarModel.advance` calls one function, so the split lives in
`VisualizerMath.smoothLevel` (pick the keeper from the sign of the error).
This is a deliberate departure from the reference (which is symmetric plus
a slew clamp); recorded here as such. It is separable from 4.1 — if it
reads jittery on device, revert this alone.

### 4.3 Explicitly rejected

- **Raising `audioGain`** above 5: breaks verified reference parity
  (gain 5 is the reference's non-meeting value) and clips at level 0.71.
- **Raising `maxBarHeight`** past 15: the reference is proportionally
  shorter than Oto already (§2.2).
- **Adding the reference's slew clamp**: it is a smoothing clamp; it makes
  the wave *less* reactive.
- **Changing the envelope k**: measured to match (§2.1).
- **Reducing ripple depth at high level**: would look calmer but breaks
  the reference's permanent-ripple model; revisit only if 4.1+4.2 still
  reads flat.

## 5. Exact file changes

1. `Oto/UI/FlowBar/VisualizerMath.swift`
   - `levelFloorDB: -55 → -52`, `levelCeilingDB: -10 → -22` (with a comment
     naming this plan as the calibration record).
   - Add `attackKeeper: Float = 0.68`, `releaseKeeper: Float = 0.82`.
   - `smoothLevel`: choose the keeper by whether the clamped target is
     above or below `current`; keep the frame-rate compensation and the
     existing signature (callers unchanged).
   - Header note: the wave now reaches reference-proportional height at
     ordinary speech.
2. `Oto/UI/FlowBar/FlowBarModel.swift` — no signature change; the comment
   on `advance` should stop saying "0.85 (~100 ms)" and say
   "attack 98 ms / release 200 ms (VisualizerMath keeps the constants)".
3. Tests — **deferred by user instruction** (2026-11-01: no test runs until
   everything is finished). When they resume, `VisualizerMathTests` needs:
   `level(rms:)` at -30/-22/-52 dBFS, monotonicity, clipping, and that
   `smoothLevel` rises faster than it falls for equal `|Δ|`.

## 6. Verification (no test run, per user)

1. `xcodebuild -scheme Oto -destination 'platform=macOS' build`.
2. Run the packaged app, dictate 3 sentences at normal volume: the row
   should reach roughly two-thirds to three-quarters of the pill during
   voiced syllables, and settle to dashes between them.
3. If it is still under-filling: switch to -55/-25 (one edit) and repeat.
   If a noisy room lifts the resting bars above ~4 pt: raise the floor to
   -50.
4. Optional, only if tuning is needed: a temporary `os_log` of the RMS dB
   in `LevelEngine.level(_:)`, 20 s of speech, take the 90th percentile →
   set the ceiling to p90 + 2 dB. Removed before hand-off.

## 7. Risks / deferred

- Saturation: loud speech (>-22 dBFS) pins at level 1.0 and the top of
  the range is compressed. Accepted — the pill is 26.4 pt tall.
- Noise floor: a fan or a noisy room shows 2.3–3.5 pt of movement versus
  2.0–3.0 today. Accepted (small).
- The analyzer's RMS window is whatever buffer the tap delivers (currently
  documented as ~85 ms at 16 kHz). If syllable attacks still feel late
  after 4.2, that window is the next suspect — measure before shortening.

## 8. Open questions

1. Is "a little bit" ≈ +33 % mid-level height (4.1 as written), or should
   it land at the more aggressive -55/-25 now and be dialled back later?
2. Keep the asymmetric attack/release (4.2) or stay reference-symmetric?
