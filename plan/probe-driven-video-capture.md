# Probe-driven video capture — 60 fps clean shots, no captions

Status: planning finished — waiting for "execute".

## 1. Goal

Produce six **clean, smooth, silent, 60 fps** clips with:

- **No captions, no text, no overlays, no graphics** — only what Oto actually draws.
- **No speaking** — a DEBUG-only probe injects a scripted final transcript through the app's fake speech seam while real insertion, catcher, dictionary and cleanup still run.
- **No manual record/stop** — one command records a fixed-length clip.
- Predictable quality: explicit frame rate, hardware or high-quality software encode, validated with `ffprobe`.

## 2. Verified facts (this session)

- `Oto/Services/AudioCaptureService.swift`: `AudioCaptureServing` + `FakeAudioCapture` ship in the **app target**.
- `Oto/Services/SpeechService.swift`: `SpeechServing` + `FakeSpeechService(finalText:)` ship in the app target.
- `Oto/App/OtoApp.swift:144-150`: one seam builds `AppleAudioCapture` + `AppleSpeechService`; the coordinator takes the protocols.
- `/opt/homebrew/bin/ffmpeg` exists. `ffmpeg -devices` lists `avfoundation`.
- `ffmpeg -f avfoundation -list_devices true -i ''` reports:
  - `[2] Capture screen 0` (video), `[0] MacBook Air Microphone` (audio).
  - Input supports `uyvy422`, `yuyv422`, `nv12` — **not** `yuv420p`; the input pixel format must be specified as `nv12`.
- Encoders available: `h264_videotoolbox`, `hevc_videotoolbox`, `prores_videotoolbox`, `libx264`.
- `screencapture -v -V<seconds>` exists as a fallback but exposes no frame-rate control.
- Both `ffmpeg` AVFoundation capture and `screencapture -v` currently **fail/hang without Screen Recording TCC permission** (tested: 2 s capture produced no file). This must be granted once by the user; it cannot be granted from code.
- Swift can move the cursor: `CGWarpMouseCursorPosition` compiled and ran successfully. Python Quartz is not installed — use a `swift -e` one-liner in the script.
- The Screendrop MCP is an **editor only** (no recording tool) and is not loaded in this session. It is not needed to produce these clean MP4s.

## 3. Assumptions questioned

- "Clean shots" = **absolutely no added text or graphics**. No captions, no zoom labels, no keystroke callouts. (Earlier I proposed a keyboard-press indicator on scene 6; it is now dropped unless you say otherwise.)
- Fake speech means no real audio buffers reach the visualizer, so the waveform may sit flat. The pill still shows real state. This is honest UI, not a fabricated waveform. Acceptable for clean shots.
- Auto-driving the coordinator bypasses the global shortcut, so it proves insertion but not the key press. Scene 6 keeps a **real shortcut press** (with injected transcript) so the pill appears truthfully.
- Screen Recording permission will be granted to whichever process actually launches the recorder (Terminal/OpenCode/ffmpeg). The script will print exact instructions on first failure.

## 4. Exact file changes

### A. DEBUG demo probe

- `Oto/Support/DemoDriver.swift` (new, whole file inside `#if DEBUG`):
  - Reads env: `OTO_DEMO_TEXT` (scripted final text), `OTO_DEMO_AUTO` (`1` = drive session on a timer), `OTO_DEMO_MODE` (`hold`/`handsFree`/`catcher`).
  - Pure `static func script(for mode: DemoMode) -> String` with four fixed lines:
    - Notes: `Send this to Daniel tomorrow.`
    - Catcher: `Remember to buy oat milk tomorrow.`
    - Cleanup: `Um, like, you know, send this to Daniel tomorrow, um, okay?`
    - Dictionary: `oh my god that was fast`
  - Builds `FakeAudioCapture(stubPeak: 1.0)` + `FakeSpeechService(finalText: script)`.
  - `static func makeServices() -> (any AudioCaptureServing, any SpeechServing)`.
- `Oto/App/OtoApp.swift`:
  - Under `#if DEBUG`, if any demo env is present, use `DemoDriver.makeServices()` instead of real audio/speech.
  - After coordinator creation, if `OTO_DEMO_AUTO=1`, launch one bounded `Task`: sleep 1 s → `beginHold()` → sleep 2 s → `finish(id)`. No loops, no repeats, all awaits checked.

### B. Recorder script — quality first

- `Scripts/record-scene.sh` (new):
  - Usage: `./Scripts/record-scene.sh <output.mp4> <seconds> [preset]`
  - Presets:
    - `quality` (default): `libx264 -crf 16 -preset medium -pix_fmt yuv420p -profile:v high -level 4.2 -movflags +faststart`
    - `fast`: `h264_videotoolbox -b:v 16M -pix_fmt yuv420p -movflags +faststart`
  - Auto-detect the screen device index from `ffmpeg -f avfoundation -list_devices true -i ''` (look for `Capture screen`), override with `OTO_CAPTURE_DEVICE`.
  - Input: `-f avfoundation -framerate 60 -pixel_format nv12 -i "<index>:none" -t <seconds>`.
  - Frame pacing: `-fps_mode cfr -r 60` so output is constant 60 fps.
  - Scale: `-vf "scale=2560:-2:flags=lanczos"` (or `1920` if `OTO_CAPTURE_WIDTH` set); keeps Retina text crisp and gives a normal-size deliverable.
  - **No** `-k` (no click display), **no** `-g/-A` (no audio), **no** `drawtext`/`overlay` filters — clean shots only.
  - Before capture: move cursor off-frame with `swift -e 'import CoreGraphics; CGWarpMouseCursorPosition(... )'`, restore it after.
  - Countdown: 3 seconds on stderr ("position the app now").
  - Write to a local temp file, then encode to the output path; delete temp on success or failure.
  - If ffmpeg fails/hangs, print the Screen Recording permission path:
    `System Settings → Privacy & Security → Screen Recording → enable the app that launched this script (Terminal / OpenCode / ffmpeg)`, then quit and reopen it.
  - Validate after encoding with `ffprobe`: `avg_frame_rate` must be `60/1`, `nb_frames` within ±10 of `seconds × 60`, `codec_name=h264`, `pix_fmt=yuv420p`, zero audio streams. Print a clear PASS/FAIL.

### C. Output hygiene and docs

- `.gitignore`: add `Videos/` and `*.mov` temp patterns so raw captures never pollute the repo.
- `Docs/VIDEO_SHOOT.md`: exact commands for all six scenes:
  - scene 1: onboarding Welcome — `OTO_DEMO` off, `./Scripts/record-scene.sh Videos/01-welcome.mp4 5`.
  - scene 2: Notes frontmost, `OTO_DEMO_AUTO=1 OTO_DEMO_TEXT='Send this to Daniel tomorrow.'` open Oto → record 7.
  - scene 3: Desktop frontmost, catcher mode → record 6.
  - scene 4: Notes frontmost, cleanup mode → record 8.
  - scene 5: Notes frontmost, dictionary mode → record 5.
  - scene 6: hands-free shortcut enabled, real press, `OTO_DEMO_TEXT` set → record 9.
- `OtoTests/DemoDriverTests.swift` (new): pin the pure script table and env parsing; no screen recording in tests.

## 5. Why this will actually be smooth

1. **Explicit 60 fps input** with `nv12` — no frame-rate guesswork from `screencapture`.
2. **Constant-frame-rate output** (`-fps_mode cfr -r 60`) — no variable-frame-rate judder on playback.
3. **Qualified encoder**: software x264 CRF 16 for maximum text crispness (clips are only 5–9 s, so encode time is acceptable), or VideoToolbox 16 Mb/s for near-zero CPU if you prefer `fast`.
4. **Lanczos scaling** from the Retina source — avoids the blur of naive downscaling.
5. **Local temp file** on APFS — no network disk in the capture path.
6. **No competing work** during capture: no `xcodebuild`, no Simulator, no other recorders; the demo driver uses bounded async timers, never blocking the main actor.
7. **Cursor removed** and no overlays — nothing moves that shouldn't.
8. **ffprobe gate** — every clip must prove 60 fps and correct frame count before we accept it; a dropped-frame take gets re-recorded, not "fixed" in post.

## 6. Verification

1. Debug build green; Release build proves no demo code ships.
2. After Screen Recording permission is granted, a 2 s smoke capture passes the ffprobe gate.
3. `OTO_DEMO_AUTO=1 OTO_DEMO_TEXT='…'` with Notes frontmost lands the text using the real insertion path; with Desktop frontmost the catcher appears.
4. Record one real scene; confirm no captions/overlays/cursor in a frame.
5. Full test suite green.
6. Optional Screendrop edit pass only if you later ask for zooms/speed — default is no edits.

## 7. Risks / deferred

- Screen Recording TCC is mandatory; first run may require approving Terminal/OpenCode and restarting it.
- Fake audio yields a static waveform; if that reads as "dead" on video, a later tweak can feed synthetic buffers into `LevelFeedBox` from the demo driver.
- Auto mode does not prove the global shortcut; scene 6 uses a real press.
- Retina source + Lanczos scale uses CPU; if frames drop, switch to the `fast` preset (VideoToolbox) before changing anything else.
- No captions means readability depends on large in-app text (Notes ≥36 pt).

## 8. Open questions

1. Confirm zero overlays (my assumption) — including dropping the keyboard-press indicator from scene 6.
2. Prefer `quality` (x264 CRF 16, slower encode) or `fast` (VideoToolbox 16 Mb/s) as the default? Plan picks `quality`.
