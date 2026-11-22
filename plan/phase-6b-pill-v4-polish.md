# Pill v4 — overflow clip, buttery finish, instant catcher — PLAN ONLY

Status: PLANNING ONLY (2026-09-22). Nothing implemented. Awaiting `go`.

## 1. Diagnosis (three defects, three root causes)

- **F1. Dots overflow the constricted pill.** Transition
  finalizing(116)→successFlash(64): the 9 chase dots (67px block) fade
  out over 0.22s WHILE the frame is already 64 wide — and
  `PillContentView` never clips, so the dying dots paint over the
  desktop outside the pill. Two-part cure: (a) `clipsToBounds = true` on
  the content view (overflow becomes structurally impossible, every
  mode, forever); (b) shrink transitions hide the old group INSTANTLY
  (opacity 0, no fade-out) while the incoming group fades in — fades
  only ever play on groups that fit.
- **F2. Finishing feels abrupt, not smooth.** Flash end today = bare
  `orderOut` (pixels vanish in one frame). Cure: 0.18s content fade-out
  (layer opacity → 0 on the render server) THEN orderOut, cancellable:
  a generation counter invalidates a pending hide the moment the state
  moves (new session never inherits a stale fade).
- **F3. Catcher entry lags.** Three stacked delays: (a) ≤150ms poll
  quantization (state truth — kept); (b) first-show AppKit+SwiftUI
  construction on the transition path (the long tail — removed by
  PREWARM: build modal panel + hosting once at controller start, show()
  becomes setFrame + orderFront + 0.18s animator fade/scale);
  (c) `syncAnalyzer` (awaited stop, ~35ms) runs BEFORE recovery routing
  in `pollOnce` (reorder: route first, stop after — no constraint the
  other way). Appear motion: alpha 0→1 + scale 0.97→1 via the panel
  animator, 0.18s `.easeOut` — quick (under ~200ms perceived) yet
  buttery, never a pop.

## 2. Exact changes (on `go`)

1. `PillLayers.swift`
   - `wantsLayer` view gets `clipsToBounds = true` (F1a, one line).
   - `show(visual:animated:)`: `animated=false` path sets group
     opacities with actions disabled AND skips the fade transaction
     (F1b). Callers: shrink transitions (flash/message/notice from a
     wider group) pass false; growth/same-size pass true.
   - Test hooks unchanged (model values already immediate).
2. `FlowBarPanel.swift`
   - `fadeHide(duration:0.18, then:)` helper: fades `content.layer`
     opacity → 0, then orderOut + restore opacity (so next show starts
     visible). Pill only; modal has its own appear path.
   - Width-shrink detection lives in the controller (it knows both
     widths); panel stays dumb.
3. `FlowBarController.swift`
   - `pollOnce` reorder: `syncRecovery` BEFORE `syncAnalyzer` (F3c).
   - Flash deadline → `fadeHide` with generation counter
     (`hideGeneration += 1` on every state change; stale completion
     no-ops) instead of bare `hide()` (F2).
   - `start()` calls `modal.prewarm()` + creates the pill panel hidden
     at flash width (F3b — first-show cost moves to launch).
   - Shrink map: any transition TO flash/message/notice FROM a wider
     group renders with `animated=false` on the outgoing side (F1b).
4. `NoTargetModal.swift`
   - `prewarm()`: build panel + hosting once (no text, never ordered).
   - `show()`: reuse prewarmed panel; appear via
     `panel.animator()` alpha 0→1 + scale 0.97→1, 0.18s easeOut (F3).
5. Tests (headless where possible)
   - clipsToBounds true on content view.
   - shrink-switch: outgoing group opacity 0 immediately (no fade).
   - generation guard: stale fade completion doesn't orderOut (drive
     via two rapid `pollOnce` state changes with fakes).
   - prewarm: `show()` after `prewarm()` doesn't rebuild (panel
     identity stable — expose internal `panelExists`).
   - Full suite green, zero warnings.

## 3. Verification (device, user)

- Overflow: record→stop on built-in mic, watch the 116→64 transition
  frame-by-frame (QuickTime screen recording if unsure) — zero dot
  pixels outside the pill silhouette.
- Finish: success/cancel flashes melt out (no pop); rapid
  dictate-stop-dictate shows no ghost hide.
- Catcher: desktop dictate → modal feels instant with a soft land
  (target: perceived <200ms, no pop, no slide-from-anywhere).
- Focus: frontmost app unchanged through modal appear (existing probe).

## 4. Risks / non-goals

- Prewarm pays one SwiftUI render at launch (~ms, off the launch path —
  controller starts after app init). Negligible by construction.
- Fade-hide adds one 0.18s Task per flash; generation-guarded, no leak
  (structured in the poll owner, cancelled with it).
- Non-goal: tightening the 150ms poll (state truth stays quantized;
  prewarm + reorder buy the perceived speed without touching it).
- Open: none blocking. One confirm on build: failure message stays
  1-line truncated at 200 wide (kept from v3).
