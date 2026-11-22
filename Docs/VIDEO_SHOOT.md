# Clean 60 fps video shoot

Six clean, silent, 16:9 clips. **No captions, no text, no overlays, no click indicators** — only what Oto draws. Everything is recorded at 60 fps with the fast VideoToolbox preset; if a scene looks rough, re-record it rather than editing it.

## 0. One-time permission (the only thing you must do)

The first screen capture needs macOS Screen Recording permission. This will **not** silently succeed — run the preflight:

```bash
./Scripts/record-scene.sh --check
```

If macOS shows a permission prompt, allow it. If it prints `FAIL`, go to:

`System Settings → Privacy & Security → Screen Recording`

Enable the app that launched the command (**Terminal**, **OpenCode**, or **ffmpeg**), then **quit and reopen that app** and re-run the check. Screen Recording permission cannot be granted from code; the script cannot do this for you.

Once it prints `PASS`, you're done for the whole session.

## 1. Aspect ratio and framing

The recorder captures the full display, then fits it inside a **16:9** frame with `force_original_aspect_ratio=decrease` + padding. Nothing is cropped: the whole onboarding window and its elements stay visible, with thin black bars only if your display isn't 16:9. Default output is **1920×1080**. Override with `OTO_CAPTURE_WIDTH=2560` if you want 2560×1440.

Use large text in Notes (≥36 pt) so it reads at final size.

## 2. Scenes and exact commands

Set up once before scenes 2–5: grant Oto's Mic + Accessibility, add the dictionary rule `oh my god → omg` (Everywhere), enable Auto Cleanup, enable the hands-free double-tap shortcut.

### Scene 1 — Welcome (5 s)
Menu → Show onboarding… (or fresh first run). Stop on the Welcome frame with the flower mark. No clicks.
```bash
./Scripts/record-scene.sh Videos/01-welcome.mp4 5
```

### Scene 2 — Core promise (7 s)
Make **Notes** frontmost with an empty note. Launch a DEBUG build with the scripted transcript and auto session:
```bash
OTO_DEMO_AUTO=1 OTO_DEMO_TEXT='Send this to Daniel tomorrow.' open -a Oto
./Scripts/record-scene.sh Videos/02-core.mp4 7
```
The probe starts a session after ~1 s and finishes it after ~2 s; text lands in Notes.

### Scene 3 — Catcher (6 s)
Make the **Desktop** frontmost (no text field). Catcher must be enabled in Settings.
```bash
OTO_DEMO_AUTO=1 OTO_DEMO_MODE=catcher open -a Oto
./Scripts/record-scene.sh Videos/03-catcher.mp4 6
```

### Scene 4 — Clean up as you go (8 s)
Notes frontmost, Auto Cleanup enabled.
```bash
OTO_DEMO_AUTO=1 OTO_DEMO_MODE=cleanup open -a Oto
./Scripts/record-scene.sh Videos/04-cleanup.mp4 8
```
If Auto Cleanup is unavailable on this Mac, use `OTO_DEMO_TEXT` with the already-clean sentence and skip the claim in the clip.

### Scene 5 — Dictionary (5 s)
Notes frontmost.
```bash
OTO_DEMO_AUTO=1 OTO_DEMO_MODE=dictionary open -a Oto
./Scripts/record-scene.sh Videos/05-dictionary.mp4 5
```

### Scene 6 — Hands-free + handoff (9 s)
Real press required so the pill appears honestly. Enable the hands-free shortcut in Settings → Dictation first, then:
```bash
OTO_DEMO_TEXT='This is hands-free.' open -a Oto
./Scripts/record-scene.sh Videos/06-handsfree.mp4 9
```
During the countdown: position Notes, press the hands-free shortcut twice to start, again to finish.

## 3. After each clip

The script validates and prints `PASS` with fps/frame count/no audio. If it prints `WARN`, re-record that scene.

Output files are ignored by git and live in `Videos/`. Send me the paths and I'll wire them into `site/`.
