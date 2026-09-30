# V6 catcher + settings round (15%, titlebar, 10-bar pill, rail, radii)

Status: PLAN ONLY. Nothing implemented. Awaiting `execute`.

Covers the user's 6 asks + the V6 catcher handoff + verdicts on each
order (§8 — two orders are bad as proposed, with replacements).

## 0. Evidence base (all verified 2026-09-29, nothing from memory)

- ACP: `XcodeListWorkspaces` → none open (logged; the project was NOT
  opened in Xcode GUI — opening it remotely would hijack the user's
  IDE, so SDK headers + `.swiftinterface` stand as local truth per
  `AGENTS.md`).
- `MacOSX27.0.sdk`, Xcode 27.0: `titleVisibility` +
  `titlebarAppearsTransparent` present (`NSWindow.h:306,309`, 10.10+);
  `titlebarSeparatorStyle` present (`NSWindow.h:644`, macOS 11+);
  SwiftUI `Settings` scene has NO title API (`SwiftUI.swiftinterface`
  — `Settings` at :533/:551, zero `windowTitle` on macOS) → the
  "Oto Settings" text is system-generated and can only be hidden via
  NSWindow dressing, never configured.
- `VisualizerMath.swift` (live): barCount 8 (:40), attack 0.55 (:44),
  release 0.10 (:47), floor 0.30 (:50), pillHeight 26.4 (:54),
  barWidth 2.8875 (:56), barPitch 7.0125 (:57), recordDot 6.6 (:59),
  swayThreshold 0.40 (:91), swayValues derived from floor (:94-97),
  `couple()` count-agnostic (:119-124).
- Count flows downhill from `barCount`: analyzer `bandEdges(count:
  barCount)` (`AudioSpectrumAnalyzer.swift:114`), model smoothing
  arrays (`FlowBarModel.swift:27,43,56`), pill loops
  (`PillLayers.swift:120,188-189`) — NO hardcoded 8 in layout. A
  count change is constant-only.
- Test pins that must move: `barCount == 8` + `barWidth == 2.8875`
  (`VisualizerMathTests.swift:143-144`); `couple`/`bandEdges` tests
  use explicit `count: 8` (parameterized — unaffected); sway pins
  read `floor` dynamically (`:153-156`, auto-hold); `PillLayersTests`
  uses `centerText`/index hooks valid for any count (grep-gate at
  execute time).
- Catcher live anchors (post-reskin; handoff's :377/:57/:64 still
  valid): chrome `64`, width `94`, height `95`, hide `195`,
  cardHeight `255`, mask `284`, morph `312`, copy `342`, XStyle `360`,
  X usage `405`, view struct `377`. `CatcherXStyle` has no test refs.
- Settings live sizes: 910×702 scene (`SettingsRoot.swift:56-57`,
  `OtoApp.swift:152`), rail 218 (`:58`), PageRow 30pt/13pt/12px icon
  (`SettingsRoot.swift:101-111`).

## 1. Settings +15% over ORIGINAL (revert the +30% landing)

The +30% (910×702) ships reverted. Target is +15% over the original
700×540: **805×621** (700×1.15, 540×1.15); rail 218 → **193**
(168×1.15); page section spacing 22 → **20** (18×1.15);
`defaultSize` matched. Panes flow — no other geometry changes.
Modal (560) + onboarding (620×480) untouched.

## 2. Title bar (recommendation: dress, DON'T re-register)

Verdict on the order: the *look* is approved, the *mechanism*
("register as an app frame") is rejected — a `WindowGroup` settings
window loses system ⌘-comma, `SettingsLink`, and Settings-scene
behaviors; re-wiring those (custom ⌘ command + menu button swap) is
all cost for zero visual gain.

Instead, new `SettingsWindowDresser` (owned by `OtoApp`, ~30 lines):
observes `NSWindow.didBecomeKeyNotification`; for any titled window
whose title is NOT "Welcome to Oto" (the only other titled window
Oto owns — no localization dependence, no class sniffing), sets
`titleVisibility = .hidden`, `titlebarAppearsTransparent = true`,
`backgroundColor = OtoPalette.NS.ground`. Idempotent, re-applied per
becomeKey (survives SwiftUI window recreation); if the window is
never found it no-ops and the native look remains — never a broken
state. Hiding the text costs ~zero accessibility: `window.title`
stays "Oto Settings" for VoiceOver/Exposé. Color consistency comes
free: transparent bar over the ground pair blends in both schemes.

## 3. Corner radii down a step

`OtoBig`/`OtoPill` 10 → **8**, `OtoQuick` 8 → **6**
(`OtoControls.swift`). ContentShape + stroke follow. Switch,
Segmented, Door, Keycap untouched. No test pins shapes.

## 4. Ten-bar pill, same width, hotter response (exact math)

Geometry (zero-overflow proof): today's record block =
6.6 + 4.95 + 8×7.0125 = **67.65**, margins 12.375/side. Ten bars:
pitch = (92.4 − 2×12.375 − 11.55)/10 = **5.61**, barWidth 2.5 (gap
3.11 vs today's 4.125). Block stays 67.65 — identical silhouette,
no layout-code change (all derived), `panelWidth` table untouched.

Response: attack 0.55 → **0.70**, release 0.10 → **0.08**, floor
0.30 → **0.16** (silence reads short, per ask), swayThreshold
0.40 → **0.35** (`swayValues` auto-derive to [0.16,0.25,0.34,…]).
Caution recorded: 0.70 attack tracks hard but stays < 1.0 (no
overshoot by construction); if the matrix hears jitter, attack is
the single knob (0.70 → 0.62), never a redesign. Update the two
pins (§0); everything else (couple, chase, breathe, heights) holds.

## 5. Rail rows 30→36, type 13→14

`PageRow`: frame height **36**, title **14pt** (weight logic
unchanged), icon 12px/16×16 box unchanged (glyph stays optical;
row breathes around it). Rail 193 still fits "Privacy & History"
truncation as today — no ellipsis logic added.

## 6. V6 catcher (handoff adopted with 3 corrections)

- Anchors per §0. Chrome 154 → **102** (20 top + 18 gap + 44
  actions + 20 bottom): delete the 44 (X row) + 8 (X→text) terms.
- View: delete X row + `xHovering` + `CatcherXStyle` struct; footer
  = `OtoPill("Cancel", filled: false)` + `OtoPill("Copy", filled:
  true)`, gap 8, trailing, top pad 18, `minHeight 44`,
  `Spacer(minLength: 0)` above (load-bearing — pins footer on
  short/empty cards). Cancel → `hide()` only.
- CORRECTION 1 (growth): handoff's "grows downward only" is
  top-slot-only. Bottom slot keeps upward growth from the pill's
  bottom edge via `morphEndFrameAtSlot` — downward growth there
  would detach from the pill and risk screen overflow.
  Pill-position analysis: top slot = `visibleFrame` top (below
  notch/menu bar, which `visibleFrame` excludes); bottom slot =
  `visibleFrame` bottom; card always grows AWAY from its pill edge.
- CORRECTION 2 (empty copy): handoff leaves the hint unspecified —
  use "Nothing to paste into." in dim transcript color, top-anchored.
- CORRECTION 3: nonactivating panels accept button clicks keyless
  (Copy proves it) — Cancel needs no focus change.
- Controller/palette/mask/copy logic untouched. Tests: chrome pin
  (`NoTargetModalTests.swift:163`) → `20+18+44+20`; height test
  passes automatically (reads `chromeHeight`).

## 7. Verification

Build green; suite green twice (XCTWaiter-flake protocol stands).
Matrix: Settings 805×621 light+dark (rail 36pt rows, hidden title,
seamless bar), modal screenshot (r8 buttons), dictation 10-bar
voice/silence behavior + no-overflow at 92.4, catcher empty/short/
50-word cards with bottom-pinned Cancel+Copy in both slots,
over-limit `Copied` pill re-run (renderer touched via barCount).

## 8. Verdicts on your orders (reasoned)

1. 15% size — good, exact numbers in §1.
2. App-frame settings — BAD as proposed (kills ⌘,/SettingsLink for
   nothing); do §2 dressing instead, same pixels, zero integration
   loss. Title text hidden but kept for AX — the one thing dressing
   does better than your proposal.
3. Radius 8 — good, harmless (§3).
4. 10 bars, same width, hotter — good with §4's computed pitch and
   jitter caution; "short when silent" via floor 0.16 (explicitly
   overrides the old "silence reads as waves" rule — your call,
   recorded).
5. Rail 36/14 — good (§5).
6. Catcher handoff — good with 3 corrections (§6); the slot-growth
   correction is the one that would have broken bottom-slot cards.
