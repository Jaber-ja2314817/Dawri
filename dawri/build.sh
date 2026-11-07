#!/bin/sh
# build.sh — render Dawri دوري explainer video
# Usage: sh build.sh
# Requires: Node 20+, ffmpeg on PATH (or set FFMPEG), LIB env var (auto-detected)
set -e

HERE=$(cd "$(dirname "$0")" && pwd)

# Auto-detect library root (skill mode: LIB set by setup.sh; fallback to sibling clone)
LIB="${LIB:-$HOME/lemo-opuscar}"
[ -f "$LIB/core/render/video.mjs" ] || { echo "build.sh: LIB not found at '$LIB'. Set the LIB env var to the lemo-opuscar directory."; exit 1; }
export LIB

# ffmpeg: prefer the env var, then PATH, then the WinGet install location
FFMPEG_BIN=""
if command -v ffmpeg >/dev/null 2>&1; then
  FFMPEG_BIN=$(dirname "$(command -v ffmpeg)")
else
  WIN_FF_BASE="$USERPROFILE/AppData/Local/Microsoft/WinGet/Packages/Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe"
  WIN_FF=$(ls -d "$WIN_FF_BASE"/ffmpeg-*/bin 2>/dev/null | head -1)
  if [ -d "$WIN_FF" ]; then
    FFMPEG_BIN="$WIN_FF"
    PATH="$WIN_FF:$PATH"
    export PATH
  else
    echo "build.sh: ffmpeg not found — install it and add it to PATH"; exit 1
  fi
fi

VENV_PY="$LIB/.venv/Scripts/python.exe"
[ -f "$VENV_PY" ] || VENV_PY="$LIB/.venv/bin/python"
[ -f "$VENV_PY" ] || { echo "build.sh: Python venv not found in LIB; run: sh $LIB/../plugin/skills/lemo-opuscar/scripts/setup.sh deps"; exit 1; }

mkdir -p "$HERE/out"

echo "==> Step 1/4: export events"
cd "$LIB"
node core/render/events.mjs "$HERE"

echo "==> Step 2/4: render video (24 fps, 3 workers)"
node core/render/video.mjs "$HERE" --fps 24 --workers 3 --out "$HERE/out/video.mp4"

echo "==> Step 3/4: generate audio (voice + score + foley)"
LIB="$LIB" "$VENV_PY" "$HERE/mix.py"

echo "==> Step 4/4: mux"
sh "$LIB/core/render/mux.sh" \
  "$HERE/out/video.mp4" \
  "$HERE/out/mix.wav" \
  "$HERE/dawri.mp4" \
  24 0

echo ""
echo "Done: $HERE/dawri.mp4"
