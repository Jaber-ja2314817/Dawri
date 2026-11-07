#!/usr/bin/env bash
# Black-box checks of the Dawri image. Usage: frontend/scripts/docker-check.sh [image]
# Stops at the first failed check and removes its own containers on any exit.
# It only ever touches dawri-check and dawri-check-real, and binds 127.0.0.1:7860.
# Nothing here reaches Hugging Face: the switch-on check runs with --network none.
set -euo pipefail
set -E

IMAGE="${1:-dawri:local}"
NAME=dawri-check
REAL_NAME=dawri-check-real
BASE=http://127.0.0.1:7860
WORK="$(mktemp -d)"
STREAM_PID=""
CHECK="setup"

cleanup() {
  local status=$?
  trap - EXIT ERR
  if [ -n "$STREAM_PID" ]; then
    kill "$STREAM_PID" 2>/dev/null || true
  fi
  docker rm -f "$NAME" "$REAL_NAME" >/dev/null 2>&1 || true
  rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'echo "FAIL $CHECK: a command failed at line $LINENO"' ERR

pass() { echo "PASS $CHECK: $1"; }

fail() {
  echo "FAIL $CHECK: $1"
  trap - ERR
  exit 1
}

fail_with_logs() {
  echo "FAIL $CHECK: $2"
  echo "--- last log lines of $1"
  docker logs --tail 30 "$1" 2>&1 || true
  trap - ERR
  exit 1
}

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

# Prints "<status> <content type>", and keeps the body in $WORK/<name>.
fetch() { curl -sS --max-time 5 -o "$WORK/$2" -w '%{http_code} %{content_type}' "$BASE$1"; }

# Runs a Python expression over one JSON file, bound to the name j.
json_expr() {
  python3 -c '
import json, sys
j = json.load(open(sys.argv[1], encoding="utf-8"))
value = eval(sys.argv[2])
print(value if not isinstance(value, bool) else str(value).lower())
' "$1" "$2"
}

wait_for_health() {
  local deadline=$(( $(date +%s) + 30 )) code
  while :; do
    code="$(curl -s -o "$WORK/health" -w '%{http_code}' --max-time 2 "$BASE/api/health" || true)"
    if [ "$code" = "200" ]; then
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      fail_with_logs "$NAME" "/api/health was not 200 within 30 s (last status $code)"
    fi
    sleep 0.5
  done
}

check_tools() {
  local tool
  for tool in docker curl python3; do
    command -v "$tool" >/dev/null || fail "$tool is not installed"
  done
  docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "image $IMAGE does not exist"
  docker rm -f "$NAME" "$REAL_NAME" >/dev/null 2>&1 || true
}

check_1_user() {
  CHECK="1 user"
  docker run -d --name "$NAME" "$IMAGE" >/dev/null
  local result
  result="$(docker exec -i "$NAME" python - <<'PY' 2>&1 || true
import os

status = open("/proc/1/status").read()
pid1_uid = next(line.split()[1] for line in status.splitlines() if line.startswith("Uid:"))
writable = []
for root, _, files in os.walk("/app"):
    for path in [root, *(os.path.join(root, name) for name in files)]:
        if os.access(path, os.W_OK):
            writable.append(path)
try:
    with open("/app/.write-probe", "w"):
        pass
    created = True
except OSError:
    created = False
print(f"pid1_uid={pid1_uid} exec_uid={os.getuid()} writable={len(writable)} created={created}")
PY
)"
  case "$result" in
    "pid1_uid=1000 exec_uid=1000 writable=0 created=False") ;;
    *) fail_with_logs "$NAME" "expected uid 1000 and a read-only /app, got: $result" ;;
  esac
  docker rm -f "$NAME" >/dev/null
  pass "PID 1 is uid 1000, and nothing under /app is writable by it"
}

check_2_hardened() {
  CHECK="2 hardened run"
  docker run -d --name "$NAME" --read-only --tmpfs /tmp:rw,mode=1777 --user 1000:1000 \
    -p 127.0.0.1:7860:7860 "$IMAGE" >/dev/null
  wait_for_health
  local exact
  exact="$(json_expr "$WORK/health" 'j == {"status": "ok", "ai_mode": "simulated", "simulate_load": True}')"
  [ "$exact" = "true" ] || fail "health body was: $(cat "$WORK/health")"
  pass "read-only run answers /api/health with exactly $(cat "$WORK/health")"
}

check_3_routes() {
  CHECK="3 routes"
  local out asset
  out="$(fetch / index)"
  case "$out" in
    "200 text/html"*) ;;
    *) fail "GET / gave: $out" ;;
  esac
  out="$(fetch /staff/login spa)"
  case "$out" in
    "200 text/html"*) ;;
    *) fail "GET /staff/login gave: $out" ;;
  esac
  cmp -s "$WORK/index" "$WORK/spa" || fail "GET /staff/login is not the same file as index.html"
  asset="$(grep -o 'src="/assets/[^"]*\.js"' "$WORK/index" | head -1 | cut -d'"' -f2 || true)"
  [ -n "$asset" ] || fail "index.html names no script under /assets"
  out="$(fetch "$asset" asset)"
  case "$out" in
    "200 "*javascript*) ;;
    *) fail "GET $asset gave: $out" ;;
  esac
  out="$(fetch /manifest.webmanifest manifest)"
  case "$out" in
    "200 "*) ;;
    *) fail "GET /manifest.webmanifest gave: $out" ;;
  esac
  out="$(fetch /api/nope nope)"
  case "$out" in
    "404 application/json"*) ;;
    *) fail "GET /api/nope gave: $out" ;;
  esac
  [ "$(json_expr "$WORK/nope" 'j["error"]')" = "not_found" ] || fail "body: $(cat "$WORK/nope")"
  pass "HTML root, SPA fallback, asset $asset, manifest, and JSON 404 not_found"
}

check_4_sse() {
  CHECK="4 sse"
  curl -sS --max-time 5 -H 'Content-Type: application/json' -d '{"staff_id":"S-WAK-NURSE1"}' \
    -o "$WORK/login" "$BASE/api/staff/login"
  local token counter waited
  token="$(json_expr "$WORK/login" 'j["token"]')"
  counter="$(json_expr "$WORK/login" 'j["counters"][0]["id"]')"
  curl -sS -N --max-time 120 -D "$WORK/sse.head" -o "$WORK/sse.body" \
    "$BASE/api/counters/$counter/stream?token=$token" 2>"$WORK/sse.err" &
  STREAM_PID=$!
  waited=0
  while [ ! -s "$WORK/sse.body" ]; do
    [ "$waited" -lt 50 ] || fail "no bytes from the stream within 5 s"
    sleep 0.1
    waited=$(( waited + 1 ))
  done
  sleep 2
  kill -0 "$STREAM_PID" 2>/dev/null || fail "the stream closed: $(cat "$WORK/sse.err")"
  head -1 "$WORK/sse.head" | grep -q ' 200' || fail "stream status: $(head -1 "$WORK/sse.head")"
  grep -qi '^content-type: text/event-stream' "$WORK/sse.head" || fail "stream is not event-stream"
  if grep -qi '^content-length:' "$WORK/sse.head"; then
    fail "the stream has a Content-Length"
  fi
  # A real event has to cross the open stream too, not only the opening bytes.
  curl -sS --max-time 10 -o /dev/null -X POST -H "Authorization: Bearer $token" \
    "$BASE/api/demo/reset"
  waited=0
  until grep -q 'demo.reset' "$WORK/sse.body"; do
    [ "$waited" -lt 30 ] || fail "the open stream did not deliver the reset event within 3 s"
    sleep 0.1
    waited=$(( waited + 1 ))
  done
  kill -0 "$STREAM_PID" 2>/dev/null || fail "the stream closed after the event"
  pass "$counter stream stays open, first bytes and a live event arrived, no Content-Length"
}

check_5_stop() {
  CHECK="5 stop"
  kill -0 "$STREAM_PID" 2>/dev/null || fail "no stream open before the stop"
  local start end took exit_code oom
  # An explicit grace: Docker Desktop here kills after 3 s by default, which would race
  # uvicorn's own 3 s limit. A hung app still fails, because it is killed at 8 s.
  start="$(now_ms)"
  docker stop -t 8 "$NAME" >/dev/null
  end="$(now_ms)"
  took=$(( end - start ))
  wait "$STREAM_PID" 2>/dev/null || true
  STREAM_PID=""
  exit_code="$(docker inspect --format '{{.State.ExitCode}}' "$NAME")"
  oom="$(docker inspect --format '{{.State.OOMKilled}}' "$NAME")"
  [ "$took" -lt 8000 ] || fail_with_logs "$NAME" "docker stop took ${took} ms"
  [ "$oom" = "false" ] || fail "the container was OOM killed"
  # 0 or 143 are a handled SIGTERM. 137 means Docker had to kill it.
  case "$exit_code" in
    0|143) ;;
    *) fail_with_logs "$NAME" "exit code $exit_code" ;;
  esac
  docker logs "$NAME" >"$WORK/stop.log" 2>&1
  grep -q 'Application shutdown complete' "$WORK/stop.log" \
    || fail_with_logs "$NAME" "the app did not finish its shutdown"
  grep -q 'Finished server process' "$WORK/stop.log" \
    || fail_with_logs "$NAME" "uvicorn did not finish"
  pass "docker stop took ${took} ms with a stream open, exit code $exit_code, shutdown complete"
  # Checks 6 to 8 need it running. The same container keeps its logs across the restart.
  docker start "$NAME" >/dev/null
  wait_for_health
}

check_6_contents() {
  CHECK="6 contents"
  local result
  result="$(docker exec -i "$NAME" python - <<'PY' 2>&1 || true
import importlib.util
import os

found = []
for path in ("/app/backend/tests", "/app/Dawri-Vault", "/app/frontend", "/app/.env", "/fe"):
    if os.path.exists(path):
        found.append(path)
for root, dirs, files in os.walk("/app"):
    for name in dirs + files:
        if name == "node_modules" or name == ".env" or name.startswith(".env."):
            found.append(os.path.join(root, name))
        if name.endswith((".tsx", ".ts", ".db")):
            found.append(os.path.join(root, name))
if importlib.util.find_spec("pytest") is not None:
    found.append("pytest module")
if "HF_TOKEN" in os.environ:
    found.append("HF_TOKEN in the environment")
print("clean" if not found else "found: " + ", ".join(found[:10]))
PY
)"
  [ "$result" = "clean" ] || fail "$result"
  if docker inspect --format '{{json .Config.Env}}' "$NAME" | grep -q 'HF_TOKEN'; then
    fail "HF_TOKEN is set in the image"
  fi
  pass "no tests, vault, .env, node_modules or frontend source, pytest absent, no HF_TOKEN"
}

check_7_healthy() {
  CHECK="7 healthy"
  local deadline=$(( $(date +%s) + 45 )) state
  while :; do
    state="$(docker inspect --format '{{.State.Health.Status}}' "$NAME")"
    case "$state" in
      healthy) break ;;
      unhealthy) fail_with_logs "$NAME" "Docker reports unhealthy" ;;
    esac
    [ "$(date +%s)" -lt "$deadline" ] || fail "still $state after 45 s"
    sleep 1
  done
  pass "Docker reports the container healthy"
}

check_8_logs() {
  CHECK="8 logs"
  docker logs "$NAME" >"$WORK/run.log" 2>&1
  if grep -q 'token=' "$WORK/run.log"; then
    fail "a stream token reached the log"
  fi
  # uvicorn logs one traceback for each stream it cancels at its graceful limit, so the
  # stop in check 5 leaves exactly one. Any other traceback fails.
  local tracebacks cancelled
  tracebacks="$(grep -c 'Traceback' "$WORK/run.log" || true)"
  cancelled="$(grep -c 'CancelledError: Task cancelled, timeout graceful shutdown exceeded' \
    "$WORK/run.log" || true)"
  if [ "$tracebacks" -gt "$cancelled" ] || [ "$cancelled" -gt 1 ]; then
    fail_with_logs "$NAME" "$tracebacks tracebacks in the log, $cancelled from the stop"
  fi
  pass "no token=, and no Traceback apart from $cancelled from uvicorn cancelling the stream at the stop"
  docker rm -f "$NAME" >/dev/null
}

check_9_switch_on() {
  CHECK="9 switch-on"
  docker run -d --network none -e HF_TOKEN=local-check-not-a-token --name "$REAL_NAME" \
    "$IMAGE" >/dev/null
  [ "$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$REAL_NAME")" = "none" ] \
    || fail "the container has a network"
  local result
  result="$(docker exec -i "$REAL_NAME" python - <<'PY' 2>&1 || true
import io
import json
import os
import sqlite3
import time
import urllib.error
import urllib.request
import wave

BASE = "http://127.0.0.1:7860"
SENTENCE = "عندي حرارة وكحة من ثلاث أيام"
BOUNDARY = "dawri-check-boundary"


def call(path, body=None, token=None, raw=None, content_type="application/json"):
    data = raw if raw is not None else (None if body is None else json.dumps(body).encode())
    headers = {"Content-Type": content_type}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(BASE + path, data=data, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=40) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.load(error)


deadline = time.time() + 30
while True:
    try:
        status, health = call("/api/health")
        break
    except urllib.error.URLError:
        if time.time() > deadline:
            raise SystemExit("health did not answer within 30 s")
        time.sleep(0.5)
if health.get("ai_mode") != "real":
    raise SystemExit(f"health says {health}")

call("/api/auth/start", {"qid": "DEMO-10001"})
status, login = call("/api/auth/verify", {"qid": "DEMO-10001", "otp": "0000"})
if status != 200:
    raise SystemExit(f"patient login gave {status}")
token = login["token"]
status, visit = call("/api/visits", {"consent": True}, token)
if status != 200:
    raise SystemExit(f"new visit gave {status}: {visit}")
visit_id = visit["visit_id"]

limit = float(os.environ.get("LLM_TIMEOUT_SEC", "10")) + 5
started = time.time()
status, turn = call(f"/api/visits/{visit_id}/chat", {"text": SENTENCE}, token)
took = time.time() - started
if status != 200 or not turn.get("reply"):
    raise SystemExit(f"chat gave {status}: {turn}")
if took > limit:
    raise SystemExit(f"chat took {took:.1f} s, limit {limit:.0f} s")
if turn.get("ai_source") != "simulated":
    raise SystemExit(f"chat was served by {turn.get('ai_source')}")

db = sqlite3.connect("/tmp/dawri.db")
rows = db.execute(
    "SELECT COUNT(*) FROM event WHERE type = 'ai.fallback' AND visit_id = ?", (visit_id,)
).fetchone()[0]
db.close()
if rows < 1:
    raise SystemExit("no ai.fallback row")

buffer = io.BytesIO()
with wave.open(buffer, "wb") as clip:
    clip.setnchannels(1)
    clip.setsampwidth(2)
    clip.setframerate(16000)
    clip.writeframes(b"\0\0" * 1600)
head = (
    f'--{BOUNDARY}\r\nContent-Disposition: form-data; name="audio"; filename="a.wav"\r\n'
    "Content-Type: audio/wav\r\n\r\n"
).encode()
body = head + buffer.getvalue() + f"\r\n--{BOUNDARY}--\r\n".encode()
status, asr = call(
    "/api/asr", token=token, raw=body, content_type=f"multipart/form-data; boundary={BOUNDARY}"
)
if status != 502 or asr.get("error") != "asr_failed" or "text" in asr:
    raise SystemExit(f"asr gave {status}: {asr}")

print(f"ok ai_mode=real chat={took:.2f}s limit={limit:.0f}s ai.fallback_rows={rows} asr=502")
PY
)"
  case "$result" in
    "ok "*) ;;
    *) fail_with_logs "$REAL_NAME" "$result" ;;
  esac
  docker logs "$REAL_NAME" >"$WORK/real.log" 2>&1
  if grep -q 'local-check-not-a-token' "$WORK/real.log"; then
    fail "the token reached the log"
  fi
  if grep -q 'Traceback' "$WORK/real.log"; then
    fail_with_logs "$REAL_NAME" "a Traceback reached the log"
  fi
  pass "$result"
  docker rm -f "$REAL_NAME" >/dev/null
}

report_size() {
  echo "Image $IMAGE: $(docker image ls "$IMAGE" --format '{{.Size}}') on disk."
}

check_tools
check_1_user
check_2_hardened
check_3_routes
check_4_sse
check_5_stop
check_6_contents
check_7_healthy
check_8_logs
check_9_switch_on
echo "All checks passed."
report_size
