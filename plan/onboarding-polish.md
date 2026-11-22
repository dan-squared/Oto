# Onboarding polish: recorder, permissions, catcher page, theme

Status: PLANNED. Awaiting "execute".

## Goal

Fix what the first-run flow gets wrong once it is used for real, and make the
flow look like a native Mac app window rather than a fixed dark stage:

1. The hold-key recorder in onboarding cannot be used twice, and Continue
   stops responding after it is armed.
2. Granting a permission in onboarding dead-ends: a denied grant has no
   action, and the row never updates when the person comes back from System
   Settings.
3. The catcher deserves its own chapter instead of being the third row of
   "What Oto does".
4. The shortcut card is cluttered (a `Hold key: … ⌄` dropdown under a field
   that already records any key) and does not use the Settings recorder
   (glass popover, red refusal, green accept).
5. The try-it field is a 150 pt editor in a card; it should be a small,
   quiet well.
6. The onboarding must follow the system appearance — window, chapters, and
   the intro itself (user chose chapters + intro).

## What the user reported, mapped to causes (verified in code)

| Report | Cause in the current code |
|---|---|
| "continue and the green flash don't work after flashing one … if I wanted to change it again" | `OnboardingShortcutPlate` does not use the Settings recorder at all: it is `KeycapField` + an inline `ShortcutRecorderModifier` (`OnboardingPlates.swift:136–160`). There is no green flash in onboarding — the flash lives only in `ShortcutCapturePopover` (Settings). `flow.arm()` (`OnboardingFlow.swift:129`) suspends global dispatch and installs a local key monitor; nothing dismisses it when the person moves on, so the monitor keeps eating key-downs (including Return) while `isRecording` stays true. |
| "giving permission fails on the onboarding" | `OnboardingPermissionsPlate` only offers a button while the status is `.notDetermined` (`OnboardingPlates.swift:235, 249`). Once denied, the row is inert text; there is no route to System Settings and no refresh when the person returns (`refreshPermissions()` runs once on load and once 2 s after the AX prompt). |
| "remove the dropdown and make it clean" | The `Menu` at `OnboardingPlates.swift:164–176` duplicates what the recorder above already does. |
| "the try it input should be clean and not that big" | `OnboardingTryPlate` is a `TextEditor` at `frame(height: 150)` inside an `OnboardingCard`. |
| "give the catcher its own page" | `.how` carries three rows (`OnboardingStage.Step.rows`), the third being "Never lose words", and the right plate swaps to a small catcher preview per row. |
| "native macOS theme aware" | `OnboardingView` forces `.preferredColorScheme(.dark)` and the window sets `appearance = .darkAqua`; every chapter color is a literal `.white.opacity(…)`. |

## Facts verified before planning

- `OtoPalette` is already a dynamic light/dark pair table
  (`Oto/UI/Theme/OtoPalette.swift`): `ink` = 0.09 light / 0.93 dark, `muted`
  = 0.55 / 0.58, `faint` = 0.83 / 0.32, `hairline` = 0.91 / 0.20, `wash`
  = 0.937 / 0.175, `ground` = 1.0 / 0.11. `OtoKey`, `OtoShortcutField` and
  `OtoStatus` already render through it or through `Color.primary`, so they
  are appearance-aware today.
- `CatcherPalette` (`Oto/UI/Scratchpad/CatcherPalette.swift`) is a pinned
  light/dark pair for the real catcher card — the new chapter reuses it
  rather than inventing colors.
- `ShortcutCapturePopover` (`Oto/Settings/DictationPane.swift:185–362`) is
  the Settings recorder: glass (`.presentationBackground(.ultraThinMaterial)`,
  corner 20), `OtoRecorderGlow` red on refusal / green on accept, 450 ms hold
  before close, `dispatch.setSuspended(true)` on appear and `false` on
  disappear, and `updateHoldTrigger`/`updateHandsFreeTrigger` on capture. It
  is `private` and takes `(dispatch, slot, onClose)`.
- `MicSettingsLink` (`Oto/UI/FlowBar/PermissionModal.swift:34–46`) already
  builds the System Settings deep links for the microphone, most specific
  first. There is no speech equivalent yet.
- `OtoSurface` (`MetalOnboardingShaderView.swift:196–219`) already resolves
  `windowBackgroundColor` per appearance (light 0.93, dark 0.11) and is
  passed to the composite as `surface`. `ShaderState.darkAppearance` already
  exists and is forwarded as `transition.z` — but `transition.z` is **never
  read** by `Waves.metal`, and nothing ever sets `darkAppearance` to false.
- `Waves.metal` composites light additively: `emitted = color * opacity`,
  then `color = emitted + surface.rgb * light.a * (1 - opacity)`, and the
  pigment step replaces the light with `ink.rgb * assetMask`. The mark mask
  is `smoothstep(0.012, 0.07, peak) * ink.a`, i.e. keyed on **luminance** —
  a black mark would mask to zero, so the light-mode mark needs the alpha
  path.
- `OtoMarkSource.prepared` keeps premultiplied RGBA with the plate removed
  (alpha ramped 0.30–0.55); `OtoLogoAsset` uploads those pixels and
  generates mips.
- No new SDK API is needed for any of this; everything used already compiles
  against `MacOSX27.0.sdk` (Xcode 27.1). Nothing here is deprecated.

## Changes

### A. One recorder, the Settings one

- `Oto/Settings/DictationPane.swift`: move `ShortcutCapturePopover` (lines
  185–362) verbatim to `Oto/Settings/ShortcutRecorderField.swift`, drop
  `private`. Signature and behaviour unchanged; `DictationPane` keeps its
  call site.
- `Oto/Onboarding/OnboardingPlates.swift` — `OnboardingShortcutPlate`:
  - `OtoShortcutField(chips: KeyNames.chips(for: flow.holdKind),
    recordLabel: "Record push-to-talk key", canClear: false,
    onRecord: { recorderShown = true })` — the same face Settings uses.
  - `.popover(isPresented: $recorderShown) { ShortcutCapturePopover(dispatch:
    flow.dispatch, slot: .hold) { recorderShown = false; flow.reloadHold() } }`
    — the same glass, red/green glow, 450 ms accept, and Escape/Close path.
  - Delete the `Menu` ("Hold key: … ⌄"), the inline `ShortcutRecorderModifier`
    and the `KeycapField` usage.
  - Keep the derived, non-editable "Double tap <key>" row and its note; keep
    the Fn caption.
- `Oto/Onboarding/OnboardingFlow.swift`: delete the paths that only existed
  for the inline recorder — `isRecording`, `arm()`, `captureCombo`,
  `captureModifier`, `refuse`, `applyHold`, `swapHoldAndHandsFree`,
  `showSwap`, `holdMessage`. Keep `disarm()` (resume dispatch) because
  `OnboardingView.onDisappear` calls it. Add
  `func reloadHold() { holdKind = dispatch.configuration.hold.kind }`.
- `KeyNames.holdOptions` / `holdMenuLabel` stay: they are still covered by
  `KeyNamesTests` and are the only sided-key table.

Why this fixes both reports: the popover is the component Settings already
proves — it re-arms every time it opens, resumes dispatch on disappear (so
Continue's Return works again), and its accept/refuse glow is the "green
flash" the onboarding never had.

### B. Permissions that can always be granted

- `Oto/UI/FlowBar/PermissionModal.swift`: add `SpeechSettingsLink` beside
  `MicSettingsLink` (`…?Privacy_SpeechRecognition`, then `?Privacy`, then the
  bare pane) and one `openFirst(_ candidates: [URL])` helper using
  `NSWorkspace.shared.open` (first candidate only — no fallback chain on
  success).
- `Oto/Onboarding/OnboardingPlates.swift` — `OnboardingPermissionsPlate`
  rows become status + one action:
  | Row | notDetermined | denied / not allowed | granted |
  |---|---|---|---|
  | Microphone | "Allow" → `ensureMicrophoneGrant()` | "Open Settings" → `MicSettingsLink` | check |
  | Accessibility | "Open Settings" → `requestAccessibilityPrompt()` | same | check |
  | Speech | "Allow" → `ensureSpeechGrant()` | "Open Settings" → `SpeechSettingsLink` | check |
  Each row keeps its guidance line (`micDeniedGuidance`,
  `speechDeniedGuidance`) under the status.
- `Oto/Onboarding/OnboardingView.swift`: `.onReceive(NotificationCenter
  .default.publisher(for: NSApplication.didBecomeActiveNotification))` →
  `flow.uiState.refreshPermissions()`. Coming back from System Settings now
  updates the rows without a timer.

### C. The catcher gets its own chapter

- `Oto/Onboarding/OnboardingStage.swift`: insert `case catcher` after `how`;
  `chapters = [.how, .catcher, .shortcut, .permissions, .speech, .tryIt]`
  (six dashes); `rows` for `.how` becomes 2.
- `Oto/Onboarding/OnboardingFlow.swift`: `next()` — `.how` last row →
  `.catcher`; `.catcher` → `.shortcut`. `back()` mirrors it.
- `Oto/Onboarding/OnboardingChapters.swift`:
  - `.how` keeps Push to talk and Hands-free (two rows).
  - `.catcher`: tag "Never lose words", symbol `tray.full`, title
    "Nothing gets lost", subtitle "No text field? The catcher keeps your
    words — one click to copy."
  - `thing(for: .catcher)` → `OnboardingCatcherPlate`.
- `Oto/Onboarding/OnboardingPlates.swift`: `OnboardingFlowBarPreview` drops
  its `catcher` case (row 2 no longer exists). New `OnboardingCatcherPlate`:
  a catcher card built from `CatcherPalette.current(colorScheme)` — tray
  glyph, "No text field", a two-line sample transcript, and a Copy button —
  sized ~390×220 inside `OnboardingPreviewPlate`.
- `OtoTests/OnboardingStageTests.swift`: chapter list and `.how` row count
  updated; add `.catcher` to the step-order assertions.

### D. Try-it field: small and quiet

`OnboardingTryPlate` keeps `flow.trialText` but renders a 92 pt well:
`TextEditor` with `scrollContentBackground(.hidden)`, `font(size: 13)`,
`OtoPalette.wash` fill, `OtoPalette.hairline` border, 12 pt inset, and a
placeholder overlay ("Your words land here.") when the text is empty. No
other behaviour changes.

### E. Native appearance for the window and the chapters

- Remove `.preferredColorScheme(.dark)` from `OnboardingView` and
  `native.appearance = NSAppearance(named: .darkAqua)` from
  `OnboardingWindowController`. The window keeps
  `backgroundColor = .windowBackgroundColor`, so it follows the system.
- New `Oto/Onboarding/OnboardingTheme.swift` — one small table documenting
  the mapping, so no chapter invents a literal:
  `ink = OtoPalette.ink`, `muted = OtoPalette.muted`,
  `faint = OtoPalette.faint`, `hairline = OtoPalette.hairline`,
  `wash = OtoPalette.wash`, `card = OtoPalette.ink.opacity(0.055)`,
  `cardEdge = OtoPalette.ink.opacity(0.10)`, `dashTrack = ink.opacity(0.18)`,
  `dashFill = ink.opacity(0.92)`.
- Replace every literal `.white.opacity(…)` / `.black` / `.white` in
  `OnboardingChapters.swift`, `OnboardingPlates.swift`,
  `OnboardingContinueButton.swift`, `OnboardingView.swift` with those tokens
  (text → `ink`, secondary → `muted`, tertiary → `faint`, hairlines → `hairline`,
  fills → `card`/`wash`).
- The pill inverts by construction: fill `OtoPalette.ink`, label
  `OtoPalette.ground`, border `ground.opacity(0.95/0.45)`. Dark Mode keeps
  today's white-on-dark pill; Light Mode gets ink-on-paper.
- `.tint(.white)` on the permission/prepare buttons becomes
  `.tint(OtoPalette.ink)` so the prominent fill inverts with the scheme.
- The mark: add `OtoMarkSource.tinted(_ color: NSColor) -> NSImage?` (draw
  the prepared image with `.destinationIn` over the color). `WelcomePair`
  renders the mark as a template tinted `OtoPalette.ink`; `finish()` passes
  the same tinted image to `OnboardingHandoff.fly`.
- Dimmers follow the scheme: black veil on dark, white veil on light
  (`updateDesktop`).

### F. The intro in Light Mode: ink instead of light

- `Waves.metal`:
  - Read the flag that is already plumbed: `bool dark = transition.z > 0.5;`
    (currently `transition.z` is written by `MetalOnboardingShaderView` from
    `state.darkAppearance` and never used).
  - Add one file-scope helper:
    `float3 emitLight(float3 tone, float a, float3 base, bool dark)` →
    `dark ? tone * a : base * (1 - tone) * a`.
  - Use it for the light term and for the pigment mix
    (`mix(emitLight(color, rayOpacity, …), ink.rgb * assetMask, pigment)`),
    and skip the `surface.rgb * light.a * (1 - opacity)` wash in light mode
    (it exists to fill a dark stage; on a light one it would double-count).
  - Mark mask: `dark ? smoothstep(0.012, 0.07, peak) * ink.a : ink.a`
    — the ink texture carries the alpha ramp already.
- `Oto/Onboarding/OtoMark.swift`:
  - `Prepared` gains `inkPixels` (same alpha, rgb zeroed).
  - `OtoLogoAsset` uploads both textures (`color`, `ink`) with mips, and
    exposes `texture(dark:)`.
- `Oto/Onboarding/MetalOnboardingShaderView.swift`:
  - `updateNSView` sets `renderer.state.darkAppearance =
    context.environment.colorScheme != .light`.
  - `encode` binds `logoAsset.texture(dark: state.darkAppearance)`.
  - `OtoOnboardingPalette` gains `ink` (dark radiance values:
    low ≈ 0.02, middle ≈ 0.06, high ≈ 0.12, core ≈ 0.02) used when
    `darkAppearance == false`; `silver` unchanged for Dark Mode.
- `OtoSurface` already resolves light/dark, so the native crop and the
  composite background follow the window automatically.

The result in Light Mode: a white-veiled desktop, ink rays that gather into
the black waveform bars, and a light window — the same choreography, opposite
polarity.

## Verification

1. `xcodebuild -scheme Oto -destination 'platform=macOS' build`.
2. `xcodebuild test -scheme Oto -destination 'platform=macOS'
   -only-testing:OtoTests` (582 tests today; the pre-existing flaky
   `RealTextInsertionTests.retryPostsWithoutFocusGates` is expected to need a
   solo rerun).
3. Runtime, Dark and Light (temporary `OTO_APPEARANCE` hook that sets
   `NSApp.appearance`, removed before commit), launched with
   `-app.Oto.onboardingVersion 0`:
   - Click the recorder three times in a row, choosing a different key each
     time: each click must open the glass popover, each capture must flash
     green and close, and the card's chip must change every time.
   - Press Return on the chapter after recording: Continue must advance.
   - Refuse a capture (e.g. a bare modifier chord): red glow, popover stays,
     Close restores.
   - Permissions with microphone denied: "Open Settings" lands on Privacy &
     Security → Microphone; returning updates the row to Allowed without
     reopening the chapter.
   - Six dashes; the catcher chapter shows its own card.
   - Capture every chapter in both appearances with the in-process
     `cacheDisplay` hook (Metal draws blank there, as before) and inspect.
4. Metal cannot be screen-captured on this machine (no Screen Recording, and
   `CGWindowListCreateImage` is gone on macOS 27). The light intro is
   verified by a temporary offscreen render (`OTO_SHADER_SHOT`) that encodes
   the same pass into an `rgba8Unorm` texture at t = 0.6, 1.4, 2.1, 3.2 in
   both palettes and writes PNGs for inspection. Hook removed before commit.
5. UI test: `OtoUITests/SettingsUITests.finishOnboardingIfPresent` already
   loops Continue/Next up to 12 times, which still covers six chapters.

## Risks and deferred decisions

- **The light intro is the risky part.** The composite assumes additive light
  over a dark surface; the light-mode branch is new shader code and can only
  be checked by offscreen frames, not by eye on the running window. If the
  ink pass reads wrong after the render check, the fallback is to keep the
  intro dark in Light Mode and hand over to a light window (the option the
  user declined) — flagged here rather than silently taken.
- The two-veil desktop dim (white in Light Mode) is a guess at the equivalent
  of a dark veil; it may need the peak lowered (`IntroTiming.dimmingPeak`).
- Removing `OnboardingFlow.applyHold`/`swapHoldAndHandsFree` means onboarding
  no longer offers "Swap" when the hold key equals the hands-free key; the
  popover's refusal ("That shortcut is already in use by the other mode")
  is the whole answer, exactly as in Settings.
- `KeyNames.holdOptions` / `holdMenuLabel` become UI-unused but stay tested.

## Open questions

None — the theme scope was answered (chapters + intro).
