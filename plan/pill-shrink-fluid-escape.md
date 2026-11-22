# Pill rework: no-flash mic gate, 25% smaller, fluid waves, Escape cancel — plan

## Goal

Four items, one release, in this order:
1. **No pill before the permission card** — mic-denied goes straight to the card, zero pill flash.
2. **Pill 25% smaller** — every geometry constant ×0.75, drag/ghosts/snap following automatically.
3. **Waves super sensitive + butter fluid** — separate the values clock from the 150ms state poll, run values at display vsync, retune smoothing for the faster clock.
4. **Escape cancels dictation** — the wiring already exists; close the reliability gaps and prove it in the packaged app.

## Spec sources

- User notes (this session): pill flashes before the modal; 25% smaller incl. drag/drop; waves "super sensitive, super fluid, responsive, smooth, a bit fast, not cluttered"; Escape cancels dictation.
- `Docs/START_HERE_PRODUCT.md` canonical on conflict.
- Current code: `FlowBarController.pollOnce` (`FlowBarController.swift:109`), `PillVisual.forState` (`PillLayers.swift:34`), `VisualizerMath` constants (`VisualizerMath.swift:36-61`), analyzer drain 33ms (`AudioSpectrumAnalyzer.swift:198`), model smoothing (`FlowBarModel.swift:44`), Escape path (`HIDEventMonitor.swift:38-40` → `ShortcutDispatch.swift:249` → `DictationCoordinator.cancel`).

## Facts verified against the local SDK (never from memory)

- **Flash root cause (traced, not guessed):** `begin` → `.starting` → projection `.preparing` → pill shows bars (`PillVisual.forState`, `FlowBarState.swift:74`). `runPreparation` then does `audio.start()` (engine spin-up) + `speech.prepare()` → `ensureMicrophone()` returns false instantly when denied (`AppleSpeechService.swift:141`, `PermissionsManager.swift:50-58`) → `.failed(microphoneDenied)` → up to 150ms later the next poll hides the pill and shows the card (`FlowBarController.swift:288-309`). Net: pill visible ~200–400ms before the card. Mic-denied is knowable synchronously up front (`AVAudioApplication.shared.recordPermission`, `PermissionsManager.swift:24-35`) — the pill has no business showing.
- **`NSView.displayLink(target:selector:)` exists** in this SDK (`NSView.h:662`, `NSScreen.h:141`, `NSWindow.h:825`, MacOSX27.0.sdk; `CADisplayLink` macos(14.0)+, deployment target 27.0 → no `#available` needed). `+displayLinkWithTarget:selector:` is `API_UNAVAILABLE(macos)` — the NSView factory is the correct macOS spelling.
- **`vDSP_create_fftsetup` is NOT deprecated** (no deprecation attribute in `vDSP.h`; engine stays as-is).
- **Render bottleneck is the poll, not the FFT:** analyzer publishes ≤30Hz into `model.sample`, but `panel.render` reads it on the 150ms (6.7Hz) poll (`FlowBarController.swift:221-230`) — 3 of 4 analyzer updates are dropped, and each rendered step glides 0.12s (`PillLayers.swift:404`). That stepping + long glide IS the "cluttered" feel. Worse on BT: tap `bufferSize 4096` @16kHz = 256ms per buffer, so spectrum input itself arrives at ~4Hz there (device-proven value, `plan/buffer-size.md` — untouched).
- **Smoothing coefficients are rate-dependent:** `smoothStep` attack 0.55 / release 0.12 assume ~33ms steps (`VisualizerMath.swift:101-105`). Doubling the drain rate without rescaling silently doubles responsiveness AND halves decay grace — rescale by `α' = 1−(1−α)^r`, `r = dt'/dt`.
- **Escape wiring already exists end-to-end:** tap observes Escape, never consumes (passes through to the focused app by design) → `onEscape` → `receiveEscape` → `coordinator.cancel(activeSessionID)`; `canCancel` covers starting/recording/finalizing/inserting (`DictationState.swift:176-183`); `activeSessionID` is set on both hold-begin and hands-free-toggle paths (`ShortcutDispatch.swift:267-282`) and never cleared eagerly (stranded-cancel defense). So item 4 is gap-closing + proof, not new plumbing.
- **Escape gap (real):** combo triggers work without Accessibility, but Escape rides the HID tap which needs AX trust (`ShortcutDispatch.swift:85-94`, `HIDEventMonitor.swift:99-118`). Combo-without-AX = Escape silently dead. `refreshAvailability()` heals the tap on menu open — exists, unwired to any Escape status.

## Assumptions questioned

- "Just hide the pill faster on failure" — rejected: the flash happens during `.starting`, before failure exists. Gate on mic status instead (knowable upfront), both in the controller (view-layer, primary) and fast-fail in the coordinator (skips useless engine spin-up; needs an injectable seam so fakes stay hermetic).
- "Shrink the pill view only" — rejected: widths, dots, ghosts, snap indicator all derive from `VisualizerMath`; scaling the constants scales everything including drag (ghosts use `currentWidth`/`pillHeight`, `FlowBarPanel.swift:205-234`; snap radius `h/2`, `PillLayers.swift:164-167`). Slot margins (`topMargin 12`/`bottomMargin 28`) are screen offsets, not pill size — kept.
- "Faster = turn off smoothing/glide" — rejected: raw 60Hz band levels jitter; responsiveness comes from faster attack + vsync delivery, grace from a (rescaled) release + short glide. Exact feel values are set by the device matrix, tests pin whatever ships.
- "Escape should consume the key" — rejected (existing design stands): Escape passes through AND cancels; consuming it would break the focused app's own Escape handling.
- No third-party packages involved (Accelerate/AVFoundation/AppKit only) → no `context7` needed; latest-API check was done directly in MacOSX27.0.sdk per AGENTS.md.

## Exact file changes

**A. Mic gate (no flash).**
1. `FlowBarController.swift`: inject `micDenied: () -> Bool = { PermissionsManager().microphoneStatus() == .denied }`; in `syncPanel`, when denied and projection is `.preparing`/`.recording`-from-starting (simplest: whenever denied, never show the pill — card owns the surface), skip `panel?.show` entirely. `syncPermissionModal` unchanged (still shows/hides the card). Tests inject `micDenied: { true/false }` — no real TCC reads in tests.
2. `DictationCoordinator.swift` (fast-fail, small): inject `isMicDenied: () -> Bool = { PermissionsManager().microphoneStatus() == .denied }` (default real, fakes pass false); `begin()` returns nil + emits `.failed(context, .microphoneDenied)`… more precisely: check at the top of `runPreparation` before `audio.start()` → fail fast without spinning the engine. Keeps all session-ID/cancel invariants (check-then-set inside the actor).
3. Tests: `FlowBarControllerTests` — denied → dictate shows card, pill never visible (`panel == nil || !isVisible` after starting-polls); granted → unchanged behavior. Coordinator test — denied fake fails fast with `.microphoneDenied`, audio fake never started.

**B. 25% smaller (×0.75, `VisualizerMath` + `PillLayers`).**
4. `VisualizerMath.swift`: `pillHeight` 32→24; `barWidth` 3.5→2.625; `barPitch` 8.5→6.375; `recordDot` 8→6; `chaseDot` 3→2.25; `chasePitch` 8→6; `spinnerSize` 16→12; `panelWidth` preparing/recording 112→84, finalizing/inserting 116→87; `noticeWidth` 200→150. `dotCount`/`barCount` unchanged (count stays, elements shrink — v3 precedent).
5. `PillLayers.swift`: `barFullHeight` 20→15; `padding` 10→7.5. Radius/ghost/drag code untouched (derives from constants).
6. Tests: `VisualizerMathTests` new pins; `PillLayersTests` frames rebuilt at 84×24/87×24; `FlowBarPositionTests` width examples updated. Permission modal (60pt card) untouched — different surface.

**C. Fluid + sensitive waves.**
7. `FlowBarPanel.swift`: own a `CADisplayLink` via `content.displayLink(target:selector:)` (SDK-verified spelling above), created when bars show, invalidated on hide/group-switch/Reduce-Motion-freeze. Each vsync: read latest `model.sample` and push bar transforms with actions **disabled** (1:1 at 60/120Hz — no 0.12 smear). The 150ms poll keeps group switching + geometry + panel show/hide; it stops setting per-frame transforms while the link owns them (flag on the panel).
8. `AudioSpectrumAnalyzer.swift`: drain 33ms→16ms (~60Hz). FFT cost is trivial at 512pt; converter/relay unchanged.
9. `VisualizerMath.swift` + `FlowBarModel.swift`: rescale to the 16ms clock (`α' = 1−(1−α)^0.5`: attack 0.55→0.33, release 0.12→0.062), then sensitivity bump for feel — starting point attack **0.45** (≈28ms snap) / release **0.08** (≈190ms graceful decay); `floor` 0.30 and `swayThreshold` 0.40 kept unless the feel matrix says otherwise. Tests pin the shipped pair; `smoothStep` stays pure.
10. Tap size stays 4096 (device-proven; the 85ms@48k quantization floor is acknowledged, sway covers silence aliveness). No analyzer-thread changes (still off-MainActor, still drop-on-full box).

**D. Escape cancel reliability.**
11. `OtoMenuBarView.swift` (or `ShortcutDispatch.calibration` surfacing): when trigger is combo AND HID tap is dead (no AX), show "Escape cancel unavailable — grant Accessibility in Settings" instead of failing silent. Reuse `refreshAvailability()` (already heals on menu open).
12. No coordinator/dispatch logic change expected (wiring verified above); if the packaged-app matrix finds a dead path, the fix lands here minimally and this plan gets a one-line amendment — no new feature plumbing pre-built on a guess.
13. Tests: HID `decide` Escape-emits-while-passing-through (exists? extend), dispatch `receiveEscape` cancels active session for both hold and hands-free modes, combo-without-AX surfaces the warning.

## Verification steps

- `xcodebuild -scheme Oto -destination 'platform=macOS' build` clean + full suite green (new/updated pins incl.).
- Grep gates: no new force unwraps; no NSEvent monitors (ban stands — menu-tracking wedge); no coordinator edits beyond the mic fast-fail seam.
- Packaged signed `.app` only (TCC/AX invalid from raw executables): deny mic → dictate → card appears with **zero pill frame** (Top + Bottom); grant → waves live.
- Feel matrix (user's side, built-in mic + BT if handy): quiet room (sway alive, no jitter), normal voice (bars jump within ~1–2 frames, decay gracefully), loud (no pegging/clipping look); drag pill top↔bottom (ghost size matches new pill, thunk + settle tick intact); Reduce Motion on (static bars, no link).
- Escape matrix (packaged app): hold-record → Esc (cancelled, nothing inserted, Esc still reaches app); hands-free-record → Esc; starting → Esc; finalizing/inserting → Esc (cancel wins); combo trigger without AX → warning shown, Esc dead AND explained.

## Risks / deferred

- 60Hz drain doubles analyzer wake-ups; FFT 512pt is negligible, but if Instruments shows otherwise, fall back to 30Hz drain + vsync-interpolated render (link still smooths via shorter 0.05 glide) — documented fallback, not a redesign.
- Per-frame MainActor reads at vsync are one sample struct — no allocation, no await; if ProMotion 120Hz shows tearing in bar transforms, halve link rate via `preferredFramesPerSecond = 60`.
- Coordinator fast-fail changes `begin` timing for denied users only; granted path untouched. Fakes must pass `isMicDenied: { false }` — test-only seam, zero production branching.
- Catcher modal work stays deferred (prior call); permission-card appearance already signed off.

## Open questions

1. Pill margins: keep Top-12/Bottom-28 with the smaller pill (recommended — slots are screen-json, not pill-json), or tighten proportionally (9/21)? Default keep; one-line change if you disagree.
2. Escape warning copy: menu row only, or also a one-time notification? Default menu row (no new surfaces).
3. After your feel test, attack/release get one retune pass max before pinning — beyond that it's taste, not correctness.
