# Onboarding: remove the Metal shader arrival completely

Status: implementing (user asked directly: "i don't need the onboarding shader
animation remove it completely").

## Goal

The onboarding window opens as one plain native window. No Metal light, no
transparent carrier window, no desktop dimmers, no soundtrack, no
shader-clock choreography. Welcome is the same brand hero (mark + "Oto" +
one line + the one pill) drawn statically; the chapters and the finish
flight to the menu bar are untouched.

## What goes

| Piece | Why it exists today | Fate |
|---|---|---|
| `MetalOnboardingShaderView.swift` | MTKView + two-pass renderer, bloom, shader uniforms | delete |
| `Oto/Resources/OnboardingShaders/Waves.metal` | the ray shader source | delete |
| `IntroTiming.swift` | shader pacing map, WelcomeTiming choreography, IntroPlayback clock | delete |
| `OnboardingSound.swift` + `arrival-02.m4a` | the arrival's soundtrack, started by IntroPlayback | delete |
| `WelcomeLayout.swift` | shader-clock layout for mark/name reveal | delete (hero becomes plain SwiftUI) |
| `OtoLogoUniforms`, `OtoLogoTiming` shader keys, `OtoLogoAsset` | GPU mark asset | delete from `OtoMark.swift`; keep `OtoMarkSource` (cropped/tinted) |
| carrier window, dimmers, `updateDesktop`, `retireCarrier`, `observeInterruptions` | light crossing the desktop | delete from `OnboardingWindowController` |
| `OtoHaptics.intro*` | taps that carry the ray swell | delete; keep `handoffLanded` |
| shader probe (`OTO_SHADER_SHOT`, `OtoSurface`) | offscreen render verification | delete from `OtoProbe` |

## What stays

- `OnboardingStage` step machine, resume, chapter frame, page indicator.
- The per-chapter pill label (symbol + short text) above the title — the
  user asked for it back; the theme just never got its two colours
  (`tagIdle`, `tagIdleText`). Add them.
- The finish flight (`OnboardingHandoff`) from the page mark to the real
  menu-bar item.
- One native `NSWindow` (titled, hidden traffic lights, no full screen),
  centred at min(1020×760, visible frame − 24).

## Facts verified

- Xcode project uses `PBXFileSystemSynchronizedRootGroup`: deleting source
  and resource files needs no `project.pbxproj` edit.
- `OtoSurface.uniforms` is used only by `OtoProbe.capture` for the probe's
  background; replaced with a local light/dark value.
- `OtoLogoTiming.side` was only used by `WelcomeLayout` and its tests; the
  hero now carries its own 72 pt constant.
- `IntroPlayback`, `WelcomeTiming`, `IntroTiming`, `WelcomeLayout` are
  referenced only by the files being deleted plus `OnboardingStageTests`
  (two test structs removed) and `OtoProbe`.
- `OtoProbe.captureIfRequested` called `finishAnimation()`; with no intro it
  just waits for the window and captures the chapters.

## Verification

- `xcodebuild -scheme Oto -destination 'platform=macOS' build`
- `xcodebuild test -scheme Oto -destination 'platform=macOS'`
- `OTO_SHOT=<dir> OTO_APPEARANCE=light|dark` capture of the welcome and each
  chapter, reviewed for layout and contrast.

## Risks / deferred

- No intro animation at all is intentional. The window simply appears; the
  chapter turns and the finish flight remain the only motion.
- Removing the soundtrack removes the `app.Oto.onboarding.sound` preference
  read; the stored value is left alone (harmless).
