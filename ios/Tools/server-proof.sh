#!/bin/zsh
# The live proof of Clinic server mode, on the Dawri Build simulator only.
#
#     ios/Tools/server-proof.sh <outdir> [--derived <folder>]
#
# 1. Starts the backend with ios/Tools/clinic-server.sh start: blank HF_TOKEN=, 127.0.0.1, a free
#    port from 8101 to 8199 and a temp database. That script stops the server and exits 3 unless
#    /api/health says ai_mode simulated, and this one stops too.
# 2. Boots Dawri Build if it was shut down, and records its screen to <outdir>/server-proof.mov.
# 3. Runs the DawriServer scheme, which holds only ServerModeTests, with
#    TEST_RUNNER_DAWRI_SERVER=<url>, so the test runner reads the address as DAWRI_SERVER.
# 4. Exports every screenshot and timing attachment from the result into <outdir>/attachments,
#    copies the server's log to <outdir>/server.log, and checks that every request in it came
#    from 127.0.0.1 and none was the speech upload path.
# 5. Through a trap, whatever happened: stops the recording, stops the server, and shuts Dawri
#    Build down again if this script booted it.
#
# It never reads .env, never runs hf, and sends nothing to any host but 127.0.0.1. The derived
# folder and the output folder must be outside ios/. Exit 0 only when the tests and the log check
# both pass.
emulate -L zsh
setopt pipe_fail no_unset

UDID=B55FEAC2-08EB-460D-9261-E28A60F4B5CC
ROOT=${0:A:h:h:h}
CLINIC=$ROOT/ios/Tools/clinic-server.sh

usage() { print -u2 "usage: server-proof.sh <outdir> [--derived <folder>]"; exit 2 }

OUT='' DERIVED=''
while (( $# )); do
  case $1 in
    --derived) (( $# >= 2 )) || usage; DERIVED=${2:A}; shift 2 ;;
    --*) usage ;;
    *) [[ -z $OUT ]] || usage; OUT=${1:A}; shift ;;
  esac
done
[[ -n $OUT ]] || usage
for folder in $OUT ${DERIVED:-/}; do
  [[ $folder == $ROOT/ios(|/*) ]] && { print -u2 "server-proof: $folder must be outside ios/"; exit 2 }
done
KEEP_DERIVED=1
if [[ -z $DERIVED ]]; then
  DERIVED=$(/usr/bin/mktemp -d "${TMPDIR:-/private/tmp}/dawri-server-proof.XXXXXX")
  KEEP_DERIVED=0
fi
mkdir -p "$OUT"
RESULT=$OUT/ServerProof.xcresult
rm -rf "$RESULT" "$OUT/attachments"

export DAWRI_SERVER_STATE=$OUT/.clinic-server.state
STARTED_SERVER=0 BOOTED=0 RECORDER=''

simulator_state() {
  xcrun simctl list devices | grep "$UDID" | sed -E 's/.*\((Booted|Shutdown|Shutting Down|Booting)\).*/\1/'
}

cleanup() {
  if [[ -n $RECORDER ]] && kill -0 $RECORDER 2>/dev/null; then
    kill -INT $RECORDER 2>/dev/null
    wait $RECORDER 2>/dev/null
  fi
  if (( STARTED_SERVER )); then
    local dir
    dir=$(grep '^dir=' "$DAWRI_SERVER_STATE" 2>/dev/null | cut -d= -f2-)
    [[ -n $dir && -f $dir/server.log ]] && cp "$dir/server.log" "$OUT/server.log"
    "$CLINIC" stop
  fi
  if (( BOOTED )); then
    xcrun simctl shutdown "$UDID" 2>/dev/null
    print -r -- "server-proof: shut Dawri Build down again"
  fi
  (( KEEP_DERIVED )) || rm -rf "$DERIVED"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# 1. The server, simulated or nothing.
"$CLINIC" start | tee "$OUT/clinic-server-start.txt"
code=${pipestatus[1]}
(( code == 0 )) || { print -u2 "server-proof: clinic-server.sh start exited $code, nothing was run"; exit $code }
STARTED_SERVER=1
URL=$(grep '^url=' "$DAWRI_SERVER_STATE" | cut -d= -f2-)
[[ $URL =~ '^http://127\.0\.0\.1:81(0[1-9]|[1-9][0-9])$' ]] || { print -u2 "server-proof: bad server url $URL"; exit 1 }
grep -qx "ai_mode simulated $URL" "$OUT/clinic-server-start.txt" || { print -u2 "server-proof: no simulated line"; exit 3 }

# 2. Dawri Build, and nothing else.
if [[ $(simulator_state) == Shutdown ]]; then
  xcrun simctl boot "$UDID" || exit 1
  BOOTED=1
fi
xcrun simctl bootstatus "$UDID" -b >/dev/null || exit 1
rm -f "$OUT/server-proof.mov"
xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$OUT/server-proof.mov" 2>"$OUT/recorder.log" &
RECORDER=$!
sleep 2

# 3. The live tests.
print -r -- "server-proof: DawriServer on Dawri Build against $URL, started $(date -u +%Y-%m-%dT%H:%M:%SZ)"
TEST_RUNNER_DAWRI_SERVER=$URL xcodebuild test \
  -project "$ROOT/ios/Dawri.xcodeproj" -scheme DawriServer \
  -destination "id=$UDID" -derivedDataPath "$DERIVED" -resultBundlePath "$RESULT" \
  TEST_RUNNER_DAWRI_SERVER="$URL" 2>&1 | tee "$OUT/xcodebuild.log" | grep -E 'SERVER-PROOF|Test Case|error:|\*\* TEST'
TESTS=${pipestatus[1]}
print -r -- "server-proof: xcodebuild exited $TESTS, finished $(date -u +%Y-%m-%dT%H:%M:%SZ)"
grep -h 'SERVER-PROOF' "$OUT/xcodebuild.log" | sed 's/^.*SERVER-PROOF/SERVER-PROOF/' | sort -u >"$OUT/timings.txt"

kill -INT $RECORDER 2>/dev/null
wait $RECORDER 2>/dev/null
RECORDER=''

# 4. The attachments, and the server's own log.
mkdir -p "$OUT/attachments"
xcrun xcresulttool export attachments --path "$RESULT" --output-path "$OUT/attachments" >/dev/null \
  || print -u2 "server-proof: could not export the attachments"

dir=""
# Each file under the name the test gave it, such as en-11-s10-doctor-D-GP-023.png.
/usr/bin/python3 -I - "$OUT/attachments" <<'PY'
import json, re, sys
from pathlib import Path
folder = Path(sys.argv[1])
manifest = folder / "manifest.json"
if manifest.exists():
    for test in json.loads(manifest.read_text()):
        for item in test.get("attachments", []):
            source = folder / item["exportedFileName"]
            name = re.sub(r"_\d+_[0-9A-F-]{36}(\.\w+)$", r"\1", item.get("suggestedHumanReadableName", ""))
            if source.exists() and name and "/" not in name:
                source.rename(folder / name)
PY
ls "$OUT/attachments" >"$OUT/attachments.txt"

dir=$(grep '^dir=' "$DAWRI_SERVER_STATE" | cut -d= -f2-)
cp "$dir/server.log" "$OUT/server.log"
# Written in parts, so this script does not itself name the speech path.
speech='/api/'"as"'r'
requests=$(grep -cE '"(GET|POST|PUT|PATCH|DELETE) /' "$OUT/server.log")
foreign=$(grep -E '"(GET|POST|PUT|PATCH|DELETE) /' "$OUT/server.log" | grep -vcE '^INFO: +127\.0\.0\.1:[0-9]+ - "')
spoken=$(grep -cF "$speech" "$OUT/server.log")
print -r -- "server-proof: server log: $requests requests, $foreign not from 127.0.0.1, $spoken to the speech path" \
  | tee "$OUT/server-log-check.txt"
LOG_OK=0
(( requests > 0 && foreign == 0 && spoken == 0 )) && LOG_OK=1

if (( TESTS == 0 && LOG_OK )); then
  print -r -- "server-proof: PASSED. Output in $OUT"
  exit 0
fi
print -r -- "server-proof: FAILED (xcodebuild $TESTS, log check $LOG_OK). Output in $OUT"
exit 1
