# V6e wrap-up: voice-reactive waves, 0.4 dwell, double-tap verdict

Status: PLAN ONLY. Nothing implemented. Awaiting `execute`.

## 0. Evidence (ACP + SDK + code, 2026-10-01)

- ACP: workspace open (`workspace-7Wcy8gsDOc`), scheme Oto (Xcode
  tooling for verification, not code — all changes are app code).
- SDK harvest: NO public voice-activity API exists (only a passing
  mention in `AVAudioIONode.h`; `Speech` has none). Voice-reactivity
  must be built from our own energy analysis — Accelerate vDSP
  (already in use) is the sanctioned path, no new dependency.
- Mechanism (the actual answer): `bandLevels`
  (`AudioSpectrumAnalyzer.swift:164`) normalizes by TOTAL energy
  (`normalized = e / total`). In room noise the total is tiny, so
  normalization spreads it across bands as if it were voice — noise
  dances, voice doesn't dominate. No absolute gate exists anywhere
  in the chain. Smoothing (`attack`/`release`) and coupling only
  shape whatever arrives; they can't know silence from speech.
- Calibration anchor: test sine is amplitude 0.5 (huge energy);
  room noise sits ~1e-6–1e-4 total power; quiet voice ~0.1. Starting
  gate `1e-3` has an order of margin on both sides; matrix tunes it
  (established pattern — never guessed final).
- Double-tap + fn: structurally impossible, pinned by
  `fnDoubleTapNeverConverts` (`ShortcutDispatchDualTests.swift:493`)
  — fn bypasses the shared machine (`receiveFnHold`,
  `ShortcutDispatch.swift:440-479`), never feeds `holdTap`.
  Converting would double-fire against macOS emoji/dictation. This
  is working-as-designed, not a bug — the fix is messaging.

## 1. Voice-reactive waves (the fix)

- `VisualizerMath.noiseGate: Float = 1e-3` (total-power floor).
- `bandLevels(magnitudes:edges:binHz:noiseFloor: = noiseGate)`:
  total below floor → zeros BEFORE normalization (the exact line
  that amplifies noise today). Signature defaulted — engine and
  existing tests compile untouched.
- Downstream unchanged and correct: zeros → `displayValue` floor
  0.16 → bars sit short when silent (the approved idle look);
  voice clears the gate and dances full-range. Log band edges
  already voice-weight the split — no second mechanism added
  (restraint: one gate, matrix-tuned).
- Tests: sub-gate sine (amplitude 1e-4 → total ~1e-6) yields zeros;
  normal sine unaffected; existing silence/zero tests hold
  verbatim.

## 2. Dwell 0.6 → 0.4

- One constant (`loaderMinDwell`). Tail test retimed: visible at
  +0.30 (past the 0.14 melt, inside dwell), hidden at +0.75.
  `liveValuesLink` 800 ms sleep still clears. Flakiness watch
  recorded: margins are honest but not fat; widen on first flake.

## 3. Double-tap verdict + fn message placement (answers)

- Verdict: keep the exclusion (engineering forbids the alternative);
  fix the confusion. When the hold key IS bare fn, the derived
  double-tap caption must say taps can't convert AND what to do:
  proposed copy (matrix judges wording): "Double-tap needs a key
  macOS doesn't own — any hold key but fn works."
- Placement (asked where the fn-usage message goes): the derived
  double-tap row caption in the modal AND the onboarding caption —
  both already derive from the shared seam helper, so Phase C
  per-option strings ("your fn opens emoji — hold, don't tap" vs
  "fn is free here") land in exactly one function each. Still
  blocked on the matrix value table — unchanged.
- "fn not working is good" read as acceptance of current fn policy:
  no behavior change proposed anywhere in this plan.

## 4. Verification

Build green; suite green twice (flake protocol stands). Matrix:
quiet-room idle (bars short/still) → hum/talk (bars follow voice,
not the fan) → threshold tune note; dwell feel check; fn-hold
caption reads correctly; full catcher/dictation rounds (shared
renderer touched).

## 5. Risks

- A 1e-3 gate may clip very quiet whisperers on noisy hardware —
  failure mode is UNDER-animation (bars short), never lost
  dictation (gate is pixels-only; speech path untouched). Matrix
  either confirms or moves one constant.
- No state-machine, dispatch, HID, coordinator, or entitlement
  changes in this plan.
