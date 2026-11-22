# Hand-off: land on the real menu-bar item, and land with a tap

## Goal

The last chapter ends, the Oto mark leaves the window's header and flies to
the menu-bar item that is now the app's home. Today it lands at a constant
point near the screen's top-right corner, which is only right when Oto's item
is the rightmost one. Make it land on the item itself — the exact frame, at
the icon's own size — and make the landing felt on a Force Touch trackpad.

Nothing else about onboarding changes: same timing, same curve, same colours,
same window, same order of teardown.

## Spec sources

- Apple, `NSWindow.convertRectToScreen(_:)` — macOS 10.7+; the measured
  status-bar window's frame and its button's frame are already in screen
  coordinates once converted (`MacOSX27.0.sdk/.../NSWindow.h:473`).
- Apple, `NSStatusBarButton` — public `NSButton` subclass used inside a
  status item (`AppKit.framework/Headers/NSStatusBarButton.h:17`).
- Apple, `NSHapticFeedbackManager` — `.alignment` is the pattern for
  "alignment of any type"; the performer may suppress a request (e.g. no
  finger on the trackpad) (`NSHapticFeedback.h:15–31`).
- `Docs/START_HERE_PRODUCT.md:184` — the menu-bar item is
  `MenuBarExtra("Oto", systemImage: "waveform")`. Its glyph is the SF
  waveform (vertical bars), not a second rendering of the Oto mark; the
  product docs steer the icon, so it is not changed here.

## Facts verified against this Mac (2026-10-31, Debug build, probe)

Screen 1710 × 1112 @2x, visible frame 1710 × 1074, `safeAreaInsets.top` 37.5
(menu bar 38 pt tall).

`NSApp.windows` contains Oto's own status item (and only Oto's — the window
list is process-local):

```
NSStatusBarWindow Item-0 frame=(1366, 1074, 32, 38) level=25 visible=true
  NSStatusBarContentView (0, 0, 32, 38)
    NSView             (0, 8, 31.5, 22)
      NSStatusBarButton (0, -3, 32, 29)   → window coords (0, 5, 32, 29)
```

- The old constant target was x ≈ 1669; the item's centre is x = 1382, so
  the flight missed by ~287 pt. That is the user's "not accurate".
- A pixel capture of the status item (alpha bounding box) puts the SF
  waveform's ink at 12 × 13.5 pt, centred on the button's centre
  (16, 19.5). The item's window is 32 pt wide, so the icon is centred with
  ~10 pt of padding each side; the ink does **not** fill the button.
- The Oto mark's cropped ink is 583 × 491 px, aspect 1.187.

**Consequence:** the landing frame is the button's centre, and the flying
mark's ink should be ~13.5 pt tall (16 pt wide at its own aspect) — not the
22 pt square the old constant used.

`NSStatusBarWindow` and `NSStatusBarContentView` are private classes; the
implementation does not depend on their names. It selects windows that sit
at `.statusBar` level and contain a public `NSStatusBarButton`, which is
also what keeps Oto's dimmers and carrier (same level) out.

## Exact changes

### `Oto/Onboarding/OnboardingHandoff.swift`

- Keep `flightDuration = 0.55`, the quintic curve, the cover window and the
  CALayer flight.
- Add the landing geometry:
  - `landingHeight(forButtonHeight:)`: 47% of the status button's height,
    clamped to 13…16 pt (the measured ink height is 13.5 on a 38 pt bar;
    the clamp keeps the mark icon-sized on a shorter bar). Comment the
    measurement.
  - `landingRect(centredIn:aspect:)`: a rect of that height, width =
    height × the mark's aspect, centred on the button.
- Add `statusItemTarget(on:screen:windows:)`:
  - Filter to visible, positive-size windows at `.statusBar` level that
    contain an `NSStatusBarButton` (recursive).
  - Prefer the one whose `screen` is the onboarding window's screen; else
    the first. This is what makes it right on a 13", 14", 16" or external
    display, with or without a notch, and with any number of neighbours.
  - Read the button's frame via `convert(_:to: nil)` +
    `window.convertRectToScreen(_:)`; return `landingRect` with the image's
    aspect. `nil` when no status item is found or its frame is empty.
- `fly` uses `target` as before (position + bounds), but:
  - adds an opacity fade to 0 over the last 0.08 s so the mark dissolves
    into the real glyph instead of vanishing with a hard edge;
  - takes `image` aspect into account only through the caller's target
    (the target is already the mark's shape, so `.resizeAspect` fills it);
  - uses the target window's screen scale for `contentsScale`, not
    `NSScreen.main`;
  - on completion, calls `OtoHaptics.handoffLanded()` (only when a flight
    happened) before `arrival()`.
- Fallback path unchanged: no status item → constant target (still the
  screen's top-right, same as today), which is also the Reduce Motion path.

### `Oto/Onboarding/OnboardingWindowController.swift`

- In `finish()`, resolve the target as
  `OnboardingHandoff.statusItemTarget(on: screen) ?? OnboardingHandoff.menuBarTarget(on: screen)`
  and pass it to `fly`. No other change; the `markInFlight` flag, 0.25 s
  beat and `complete()` ordering stay.

### `Oto/Onboarding/OtoHaptics.swift`

- Add `handoffLanded()` → `.alignment`, matching `introClimax()`'s pattern.

### `OtoTests/OnboardingHandoffTests.swift` (new)

- `landingRect` centres on the button for the measured 32 × 29 button and
  produces a 13.6 pt-tall box with the mark's aspect.
- Clamps hold for a 22 pt and a 40 pt button.
- The fallback `menuBarTarget` stays fully inside the screen, top-right.

The window lookup is verified by the probe rather than in the unit test
host: creating and ordering a status-level `NSWindow` inside the test runner
crashes it, and the predicate itself is the simple "level + public
`NSStatusBarButton`" rule below.

## Verification

1. `xcodebuild -scheme Oto -destination 'platform=macOS' build` — success.
2. `xcodebuild test … -only-testing:OtoTests/OnboardingHandoffTests` —
   4 tests pass.
3. Probe (temporary, uncommitted) printed:
   `HANDOFF target=(1373.908, 1086.685, 16.184, 13.63)` against the measured
   button rect `(1366, 1079, 32, 29)` — the target's centre is exactly the
   button's centre (1382, 1093.5), and the size is 16.18 × 13.63 pt, which
   is the SF waveform's 13.5 pt ink height at the Oto mark's aspect.
4. Screen capture of the status item (`.context/handoff/landing-footprint.png`)
   with the mark composited at the target: same centre, same height; the
   mark's outer bars overhang the waveform's 12 pt ink by ~2 pt each side,
   inside the item's 10 pt side padding.
5. Haptic cannot be automated; it requires a Force Touch trackpad *and* a
   finger resting on it (the system suppresses otherwise).

## Assumptions questioned

- **"The status item is always there."** It is created with the
  `MenuBarExtra` at launch; if the lookup returns nil (auto-hidden bar,
  first frames), the old constant keeps the flight alive.
- **"One status window per screen."** Unverified here (one display). The
  lookup prefers the onboarding screen and otherwise takes any; if the item
  lives on another display the flight would cross displays, which AppKit
  cannot composite in one borderless window. Deferred: clamp the flight to
  the start screen's menu bar in that case (rare: onboarding opens on
  `NSScreen.main`).
- **"The glyph is 13.5 pt."** Measured from a 2x capture of the SF
  waveform; other symbols/weights could differ, but the product docs fix
  `waveform`. The 47% ratio + 13…16 clamp tolerates bar-height variation.
- **"A dissolve is better than a hard cut."** The flying mark and the icon
  are similar but not identical (Oto bars vs SF waveform); a 0.08 s fade
  hides the 1–2 pt difference. Easy to remove if it reads as a fade-out.

## Risks / deferred

- Private `NSStatusBarWindow`/`NSStatusBarContentView` are avoided as class
  names; the `.statusBar` level + `NSStatusBarButton` predicate is public.
- Haptic is silent on a mouse, and suppressed on a trackpad without contact.
  That is a platform limit; no workaround exists.
- Reduce Motion: no flight, no tap — the window simply closes, as today.
- Multi-display cross-screen flight: see above.

## Open questions

1. Does the dissolve read as landing or as fading? Review the captured
   frame / live run; removing the fade is a two-line change.
2. On a Mac with a 24 pt menu bar (no notch, some external setups), is the
   clamp's 13 pt floor right? Verify on hardware if one is available.
