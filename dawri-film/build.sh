#!/bin/sh
# Dawri — One Visit (Living Screencast). Rebuilds the film from this folder in one command:
#   sh build.sh          picture + sound + mux + subtitles + poster
#   sh build.sh --vo     also re-synthesises the voice (edge-tts, needs a connection) and re-checks it with Whisper
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
LIB=${LIB:-$HOME/lemo-opuscar}
export LIB
[ -f "$LIB/core/render/video.mjs" ] || { echo "build.sh: set LIB to the lemo-opuscar folder"; exit 1; }
PY="$LIB/.venv/Scripts/python.exe"; [ -f "$PY" ] || PY="$LIB/.venv/bin/python"
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8
cd "$LIB"
if [ "$1" = "--vo" ]; then
  "$PY" core/tts/tts_zh.py "$HERE/lines.json" "$HERE/out/voice" --rate +9%          # en-US-AndrewNeural; per-line rate/say in lines.json
  WHISPER_MODEL=small.en "$PY" core/tts/asr_check.py "$HERE/lines.json" "$HERE/out/voice" --lang en
fi
node core/render/events.mjs "$HERE"                                                    # every key, click, jump and cue → events.json
"$PY" "$HERE/mix.py"                                                                   # score + foley + voice → out/mix.wav
node core/render/video.mjs "$HERE" --fps 30 --workers 6 --out "$HERE/out/video.mp4"
sh core/render/mux.sh "$HERE/out/video.mp4" "$HERE/out/mix.wav" "$HERE/dawri-film.mp4" 30 0
node "$HERE/tools/subs.mjs" "$HERE" && "$PY" core/render/srt.py "$HERE/out/subs.json" "$HERE/dawri-film.srt"
node core/render/still.mjs "$HERE" 58.2 --q nosubs=1 --prefix po_ --out "$HERE/out/stills" && cp "$HERE/out/stills/po_58.2.jpg" "$HERE/poster.jpg"
echo "built $HERE/dawri-film.mp4"
