#!/bin/zsh
# The one way an iOS agent starts the Dawri backend: simulated mode, on 127.0.0.1, with a temp
# database, and never a credit spent.
#
#   ios/Tools/clinic-server.sh start              start one, print "ai_mode simulated <url>"
#   ios/Tools/clinic-server.sh status             print the state file and the health line
#   ios/Tools/clinic-server.sh stop               stop the one this script started
#   ios/Tools/clinic-server.sh contract <scratch> start, run the ClinicContract suite against
#                                                 it with swift test --scratch-path <scratch>,
#                                                 then stop it, whatever happened
#
# What start runs, from the repo root, and nothing else:
#   HF_TOKEN= HF_HUB_OFFLINE=1 DEMO_PASSCODE= SIMULATE_LOAD=1 DAWRI_DB=<temp>/dawri.db \
#     .venv/bin/python -m uvicorn backend.main:app --host 127.0.0.1 --port <free port 8101-8199>
#
# - The blank HF_TOKEN= wins over any token in .env, because load_dotenv never overrides a
#   variable that is already set, so the backend starts in simulated mode. The blank
#   DEMO_PASSCODE= leaves the demo reset open in the same way.
# - Before anything uses the server, /api/health must say ai_mode simulated. Otherwise the
#   server is stopped at once and the script exits 3.
# - Only http://127.0.0.1:<port>/api/health is ever requested here, with redirects off.
# - This script never reads, prints or sources .env, never runs hf, and sends nothing anywhere
#   else.
#
# State lives in $DAWRI_SERVER_STATE, by default $TMPDIR/dawri-clinic-server.state, as
# url=, pid=, db= and dir= lines. stop kills only that pid, and only if it is this uvicorn.
#
# Exit codes: 0 ok, 1 usage or failure, 3 refused because the server was not simulated.

emulate -L zsh
setopt no_unset pipe_fail

ROOT=${0:A:h:h:h}
cd "$ROOT" || exit 1

TMPBASE=${TMPDIR:-/tmp}
STATE=${DAWRI_SERVER_STATE:-${TMPBASE%/}/dawri-clinic-server.state}

die() { print -r -- "clinic-server: $*" >&2; exit 1; }

# The only URL this script will talk to.
require_local() {
  [[ $1 =~ '^http://127\.0\.0\.1:81(0[1-9]|[1-9][0-9])$' ]] || die "refusing a URL that is not http://127.0.0.1:8101-8199: $1"
}

health() {
  require_local "$1"
  /usr/bin/curl --silent --show-error --noproxy '*' --proto '=http' --max-redirs 0 \
    --max-time 3 "$1/api/health"
}

# ai_mode from a health reply, or nothing.
ai_mode_of() {
  print -r -- "$1" | /usr/bin/python3 -I -c '
import json, sys
try:
    print(json.load(sys.stdin).get("ai_mode", ""))
except Exception:
    print("")
'
}

state_value() {
  [[ -f $STATE ]] || return 1
  local line
  for line in "${(@f)$(<$STATE)}"; do
    [[ $line == $1=* ]] && { print -r -- "${line#*=}"; return 0; }
  done
  return 1
}

is_our_server() {
  local pid=$1 command
  command=$(/bin/ps -o command= -p "$pid" 2>/dev/null) || return 1
  [[ $command == *"uvicorn backend.main:app --host 127.0.0.1 --port 81"* ]]
}

stop_pid() {
  local pid=$1 tries=0
  is_our_server "$pid" || return 0
  kill -TERM "$pid" 2>/dev/null
  while is_our_server "$pid" && (( tries < 50 )); do
    sleep 0.2
    tries=$((tries + 1))
  done
  is_our_server "$pid" && kill -KILL "$pid" 2>/dev/null
  return 0
}

cmd_start() {
  if [[ -f $STATE ]]; then
    local old
    old=$(state_value pid) && is_our_server "$old" && die "already running (pid $old); stop it first"
    rm -f "$STATE"
  fi
  [[ -x .venv/bin/python ]] || die ".venv/bin/python not found"

  local port='' candidate
  for candidate in {8101..8199}; do
    if ! /usr/sbin/lsof -nP -iTCP:$candidate -sTCP:LISTEN >/dev/null 2>&1; then
      port=$candidate
      break
    fi
  done
  [[ -n $port ]] || die "no free port in 8101-8199"

  local dir db log url pid
  dir=$(/usr/bin/mktemp -d "${TMPBASE%/}/dawri-clinic-server.XXXXXX") || die "mktemp failed"
  db=$dir/dawri.db
  log=$dir/server.log
  url=http://127.0.0.1:$port
  require_local "$url"

  HF_TOKEN= HF_HUB_OFFLINE=1 DEMO_PASSCODE= SIMULATE_LOAD=1 DAWRI_DB=$db .venv/bin/python -m uvicorn backend.main:app --host 127.0.0.1 --port $port >"$log" 2>&1 </dev/null &!
  pid=$!
  print -r -- "url=$url"$'\n'"pid=$pid"$'\n'"db=$db"$'\n'"dir=$dir" >"$STATE"

  local reply='' tries=0
  while (( tries < 150 )); do
    reply=$(health "$url" 2>/dev/null) && [[ -n $reply ]] && break
    kill -0 "$pid" 2>/dev/null || { print -r -- "$(<$log)" >&2; rm -f "$STATE"; die "the server exited before it answered"; }
    sleep 0.2
    tries=$((tries + 1))
  done
  [[ -n $reply ]] || { stop_pid "$pid"; rm -f "$STATE"; die "no answer from $url/api/health"; }

  local mode
  mode=$(ai_mode_of "$reply")
  print -r -- "health $url/api/health: $reply"
  if [[ $mode != simulated ]]; then
    stop_pid "$pid"
    rm -f "$STATE"
    print -r -- "clinic-server: REFUSED, ai_mode is '${mode}', not simulated. The server was stopped." >&2
    exit 3
  fi
  print -r -- "ai_mode simulated $url"
}

cmd_stop() {
  local pid
  pid=$(state_value pid) || { print -r -- "clinic-server: nothing to stop"; return 0; }
  stop_pid "$pid"
  rm -f "$STATE"
  print -r -- "clinic-server: stopped pid $pid"
}

cmd_status() {
  local url pid
  url=$(state_value url) || { print -r -- "clinic-server: not running"; return 1; }
  pid=$(state_value pid)
  print -r -- "$(<$STATE)"
  if is_our_server "$pid"; then
    print -r -- "health $url/api/health: $(health "$url" 2>&1)"
  else
    print -r -- "clinic-server: pid $pid is not running"
    return 1
  fi
}

cmd_contract() {
  local scratch=${1:-}
  [[ -n $scratch ]] || die "usage: clinic-server.sh contract <scratch path>"
  [[ ${scratch:A} == ${ROOT}/ios(|/*) ]] && die "the scratch path must be outside ios/"

  cmd_start || return $?
  trap 'cmd_stop' EXIT INT TERM

  local url db
  url=$(state_value url)
  db=$(state_value db)
  require_local "$url"
  # Health once more, just before the suite: it must still say simulated.
  [[ $(ai_mode_of "$(health "$url")") == simulated ]] || { print -r -- "clinic-server: REFUSED before the suite" >&2; return 3; }

  DAWRI_CONTRACT_SERVER=$url DAWRI_CONTRACT_DB=$db \
    swift test --package-path ios/DawriCore --scratch-path "$scratch" --no-parallel --filter ClinicContract
}

case ${1:-} in
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  contract) shift; cmd_contract "$@" ;;
  *) print -r -- "usage: clinic-server.sh start|stop|status|contract <scratch>" >&2; exit 1 ;;
esac
