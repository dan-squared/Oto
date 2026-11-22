# Pill v7 — errors off the pill (concise, menubar-owned), waves alive from frame one — PLAN

Status: WRITTEN + EXECUTED same turn (2026-09-22) — user ordered it explicitly.
Catcher still deferred.

## 0. Decisions

- **Errors leave the pill entirely.** "No audio heard" / "Microphone is
  off…" 200-wide pills die. Terminal failures project `.hidden` (pill
  melts out via the v6 vanish path); the concise home is the existing menu
  status line (`lastSessionSummary`: "failed: microphone denied" etc. —
  already concise, zero coordinator changes). Settings is one row below in
  the same menu, so mic-denied keeps its fix path. Menu label icon change
  explicitly deferred (needs observable plumbing through the scene).
- **Dead tunnels removed with the copy** (Reinsert precedent): `message` +
  `showsSettingsLink` fields leave `FlowBarProjection` (nothing reads them
  after this; controller renders notice text only), `.failure` state
  deleted, notice width becomes `VisualizerMath.noticeWidth` (200).
- **"Start from active waves": raise the floor.** At floor 0.10 × 20px the
  bars are 2px stubs — literal dots that "move up". Floor 0.10 → 0.30:
  silence reads as waves (6px + sway), voice continues from there. No
  seeding hack, no pop. Sway loop recomputed from the floor
  [f, f+.07, f+.14, f+.07, f]; gate 0.18 → 0.40 (silence 0.30 stays under,
  live voice clears it in 1–2 polls via attack 0.55).
- **"Stiff" → glide.** Analyzer publishes at 30Hz but the pill renders per
  150ms poll with instant sets — 6.7Hz stepping reads as stiff. Bar
  transforms now interpolate 0.12s easeOut per poll (retarget-from-
  presentation, the standard butter trick); targets still shaped by
  attack/release, so voice character is unchanged, only the stepping is
  gone. Label/message sets stay instant.

## 1. Exact changes

1. `FlowBarState.swift` — delete `.failure` (+ `==` arm); all `.failed`
   arms → `.hidden` (sessionID + recoveryAvailable pass through); delete
   `message` / `showsSettingsLink` (Equatable + every `project()` init).
2. `PillLayers.swift` — delete `forState` `.failure` arm; `update()` bars
   branch glides (own 0.12s easeOut transaction; label branch stays
   disabled-actions).
3. `VisualizerMath.swift` — `floor` 0.10 → 0.30; `swayThreshold` 0.40;
   `swayValues` computed from floor; add `noticeWidth = 200`.
4. `FlowBarController.swift` — notice width via `noticeWidth`; render
   `text: model.notice` (centered); header comment touch.
5. `FlowBarModel.swift` — init matches the slimmer projection.
6. Tests — state: failures → hidden / nil-tunnel deletions;
   controller `failureHolds…` → vanish + menu-summary pin
   (`lastSessionSummary` contains "microphone denied"); math: floor +
   sway-shape; pill: silent values use `VisualizerMath.floor`.

## 2. Untouched

Analyzer 30Hz, attack/release, chase/breathe/sway clocks, poll 150ms,
vanish path, notice/auto-copy/modal, coordinator (incl. summary strings),
handsFreeCaption (unconsumed metadata — out of scope).

## 3. Verification

Xcode ACP build + RunAllTests green (~218); grep gates: `showsSettingsLink`,
`No audio heard`, `Microphone is off`, `panelWidth(for: .failure`,
`setDisableActions` in bars branch → zero. Device: denied-mic dictate →
no pill, menu reads "failed: microphone denied"; cold start → waves, never
dots; voice → glide, no steps.
