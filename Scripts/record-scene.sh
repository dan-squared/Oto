#!/usr/bin/env bash
# Clean 60 fps, 16:9, silent screen capture. Fast by default (VideoToolbox).
# No captions, no click indicators, no overlays — only what Oto draws.
set -euo pipefail

TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
FFMPEG="$(command -v ffmpeg || true)"
FFPROBE="$(command -v ffprobe || true)"
if [[ -z "$FFMPEG" || -z "$FFPROBE" ]]; then
  echo "ERROR: ffmpeg/ffprobe not found (brew install ffmpeg)." >&2
  exit 1
fi

find_screen_device() {
  # Device lines look like: [AVFoundation indev @ 0x..] [2] Capture screen 0
  # The index is the bracketed numeric field, not $1.
  "$FFMPEG" -hide_banner -f avfoundation -list_devices true -i '' 2>&1 \
    | awk '/Capture screen/ {
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^\[[0-9]+\]$/) { gsub(/[\[\]]/, "", $i); print $i; exit }
        }
      }' || true
}

# Screen Recording permission helper: records 2 s, then deletes the file.
if [[ "${1:-}" == "--check" ]]; then
  CHECK_DIR="$(mktemp -d -t oto-permission-check)"
  PROBE="$CHECK_DIR/check.mp4"
  CHECK_DEVICE="${OTO_CAPTURE_DEVICE:-$(find_screen_device)}"
  echo "Requesting a 2-second screen capture to check permission (device=${CHECK_DEVICE})…"
  if "$FFMPEG" -hide_banner -loglevel error \
      -f avfoundation -framerate 60 -pixel_format nv12 \
      -i "${CHECK_DEVICE}:none" \
      -t 2 -an -fps_mode cfr -r 60 \
      -c:v h264_videotoolbox -b:v 8M -pix_fmt yuv420p -y "$PROBE"; then
    rm -rf "$CHECK_DIR"
    echo "PASS: Screen Recording permission is working."
    exit 0
  fi
  rm -rf "$CHECK_DIR"
  echo "FAIL: macOS blocked the capture." >&2
  cat >&2 <<'PERM'
Grant permission once:
  System Settings → Privacy & Security → Screen Recording
  Enable the app that launched this script (Terminal, OpenCode, or ffmpeg),
  then QUIT AND REOPEN that app and run this check again.
PERM
  exit 1
fi

OUT="${1:-}"
DURATION="${2:-6}"
PRESET="${3:-${OTO_CAPTURE_PRESET:-fast}}"
[[ -n "$OUT" && "$DURATION" =~ ^[0-9]+$ ]] || {
  echo "Usage: $0 <output.mp4> <seconds> [fast|quality]   or: $0 --check" >&2
  exit 1
}

DEVICE="${OTO_CAPTURE_DEVICE:-$(find_screen_device)}"
[[ -n "$DEVICE" ]] || { echo "ERROR: no Capture screen device found." >&2; exit 1; }

WIDTH="${OTO_CAPTURE_WIDTH:-1920}"
HEIGHT=$((WIDTH * 9 / 16))
CAPTURE_DIR="$(mktemp -d -t oto-capture)"
TMP="$CAPTURE_DIR/capture.mp4"
mkdir -p "$(dirname "$OUT")"
trap 'rm -rf "$CAPTURE_DIR"' EXIT

# Move the cursor to the corner so it is not in the shot.
swift -e 'import AppKit; if let s = NSScreen.main { CGWarpMouseCursorPosition(CGPoint(x: s.frame.maxX - 3, y: s.frame.minY + 3)) }' >/dev/null 2>&1 || true

if [[ "$PRESET" == "quality" ]]; then
  ENCODER=(-c:v libx264 -crf 16 -preset medium -profile:v high -level 4.2)
else
  ENCODER=(-c:v h264_videotoolbox -b:v 16M)
fi

echo "Recording ${DURATION}s at 60 fps, ${WIDTH}x${HEIGHT} 16:9, preset=${PRESET}, device=${DEVICE}"
echo "Get the app into position:"
for i in 3 2 1; do echo "  ${i}..."; sleep 1; done
echo "  recording now"

set +e
"${TIMEOUT_BIN:-env}" $([[ -n "$TIMEOUT_BIN" ]] && echo "$((DURATION + 20))") \
  "$FFMPEG" -hide_banner -loglevel error \
  -f avfoundation -framerate 60 -pixel_format nv12 -i "${DEVICE}:none" \
  -t "$DURATION" -an \
  -vf "scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=decrease:flags=lanczos,pad=${WIDTH}:${HEIGHT}:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1" \
  -fps_mode cfr -r 60 \
  "${ENCODER[@]}" \
  -pix_fmt yuv420p -movflags +faststart -y "$TMP" 2>&1
STATUS=$?
set -e

if [[ $STATUS -ne 0 ]]; then
  echo "ERROR: capture failed (status $STATUS)." >&2
  echo "Run '$0 --check' and grant Screen Recording permission to the launching app." >&2
  exit 1
fi
mv "$TMP" "$OUT"
trap - EXIT
rm -rf "$CAPTURE_DIR"

FPS="$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of csv=p=0 "$OUT")"
FRAMES="$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=nb_frames -of csv=p=0 "$OUT")"
AUDIO="$("$FFPROBE" -v error -select_streams a -show_entries stream=index -of csv=p=0 "$OUT" | wc -l | tr -d ' ')"
EXPECTED=$((DURATION * 60))
if [[ "$FPS" == "60/1" && "$AUDIO" == "0" && "$FRAMES" -ge $((EXPECTED - 10)) && "$FRAMES" -le $((EXPECTED + 10)) ]]; then
  echo "PASS: $OUT — ${FPS}, ${FRAMES} frames (~${EXPECTED}), no audio, 16:9 ${WIDTH}x${HEIGHT}."
else
  echo "WARN: $OUT — fps=${FPS} frames=${FRAMES} audio_streams=${AUDIO}; re-record if it looks rough." >&2
fi
