#!/usr/bin/env bash
# fm-durable-watch.sh - host, steer, and inspect one durable standing watcher.
#
# The durable-watcher path hosts a standing-watcher conversation (the
# board-keeper shape) on a pinned durable-pi backend, so context compaction
# manages the context wall and a process restart resumes the same session
# instead of rebuilding it. The path is INERT unless the home opts in with a
# definition file: nothing else in firstmate references this script, and with
# no config every subcommand refuses. docs/durable-watchers.md owns the
# operator contract and rollback procedure,
# docs/durable-watchers-feasibility.md owns the research evidence behind the
# pin, and docs/configuration.md "Durable watchers" owns the definition
# schema.
#
# Requires: bash, curl, python3, and either an attached backend_url or a
# durable-pi checkout installed by bin/fm-install-durable-pi.sh.
#
# Usage:
#   fm-durable-watch.sh arm <name> [--once]
#   fm-durable-watch.sh send <name> <message>
#   fm-durable-watch.sh status <name>
#   fm-durable-watch.sh stop <name>
#
# arm     Run the host loop in the foreground. Ensures the backend (owned
#         instance unless the definition attaches to backend_url), ensures or
#         resumes the session, applies the prompt file as agent instructions,
#         logs the recovery inspection, then polls the watcher's steering
#         inbox: each message is submitted with requestId pf-<msgid> and
#         whenBusy=steer, its submission outcome is appended to the
#         submissions log, and the message is acknowledged by moving it to
#         handled/. --once drains one inbox pass and exits. On exit the owned
#         backend is left standing so the next arm resumes in place; `stop`
#         ends it.
# send    Append the message to state/durable-watchers/<name>.inbox/ as the
#         next numbered .msg. File-first: it works while the host is down and
#         the host submits it on its next poll.
# status  Print the session's recovery inspection and cumulative usage from
#         the backend, or a diagnostic when unreachable.
# stop    Stop the watcher's owned backend by the recorded pid, never a
#         name-based kill. Durable state stays on disk for the next arm.
#
# Exit codes: 3 gate or definition refusal, 4 backend unreachable, 2 usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="$FM_HOME/state/durable-watchers"
CONFIG="$FM_HOME/config/durable-watchers"
JSONL="${PYTHON3:-python3}"

usage() {
  sed -n '/^# Usage:/,/^# Exit codes:/p' "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" | sed 's/^# \{0,1\}//'
  exit 2
}

die() {  # <code> <message...>
  local code=$1
  shift
  printf 'fm-durable-watch.sh: %s\n' "$*" >&2
  exit "$code"
}

# --- definition -------------------------------------------------------------

C_cwd=''
C_prompt=''
C_provider=''
C_model=''
C_poll=''
C_backend_url=''
C_port=''
C_api_token=''

load_definition() {  # <name>
  local name=$1
  local file=$CONFIG/$name.conf
  local key value
  [ -f "$file" ] || die 3 "no definition at config/durable-watchers/$name.conf; create one to opt in, and install the pinned checkout with fm-install-durable-pi.sh (docs/durable-watchers.md)"
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
      ''|'#'*) continue ;;
      *=*)
        key=${line%%=*}
        value=${line#*=}
        case $key in
          cwd) C_cwd=$value ;;
          prompt) C_prompt=$value ;;
          provider) C_provider=$value ;;
          model) C_model=$value ;;
          poll_seconds) C_poll=$value ;;
          backend_url) C_backend_url=$value ;;
          api_token) C_api_token=$value ;;
          port) C_port=$value ;;
          *) die 3 "config/durable-watchers/$name.conf: unknown key: $key" ;;
        esac
        ;;
      *) die 3 "config/durable-watchers/$name.conf: line is not key=value: $line" ;;
    esac
  done < "$file"
  [ -n "$C_cwd" ] || die 3 "config/durable-watchers/$name.conf: missing required key: cwd"
  [ -n "$C_prompt" ] || die 3 "config/durable-watchers/$name.conf: missing required key: prompt"
  [ -f "$C_prompt" ] || die 3 "config/durable-watchers/$name.conf: prompt file not found: $C_prompt"
  C_provider=${C_provider:-faux}
  C_model=${C_model:-echo}
  C_poll=${C_poll:-5}
  case $C_poll in
    ''|*[!0-9]*) die 3 "config/durable-watchers/$name.conf: poll_seconds must be a positive integer" ;;
  esac
}

# --- backend ----------------------------------------------------------------

find_checkout() {
  local candidate
  for candidate in "$FM_HOME/config/durable-pi-dir" "${FM_DURABLE_PI_DIR:-}" "$FM_HOME/state/durable-pi"; do
    if [ -f "$candidate" ]; then
      read -r candidate < "$candidate"
    fi
    [ -n "$candidate" ] || continue
    if [ -d "${candidate%/}/apps/dpi-backend/src" ]; then
      printf '%s\n' "${candidate%/}"
      return 0
    fi
  done
  return 1
}

# http <method> <path> [body-json]: first stdout line is the HTTP status,
# remaining lines are the response body. (A subshell cannot export HTTP_CODE
# back to the caller, so the status travels with the body.)
http() {
  local method=$1 path=$2 tmp out bodyfile
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-durable-watch-http.XXXXXX") || return 1
  if [ "$#" -ge 3 ]; then
    # Large bodies exceed the argv limit, so they travel by file.
    bodyfile=$(mktemp "${TMPDIR:-/tmp}/fm-durable-watch-body.XXXXXX") || { rm -f "$tmp"; return 1; }
    printf '%s' "$3" > "$bodyfile"
    out=$(curl -s -o "$tmp" -w '%{http_code}' \
      -X "$method" -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' \
      --data-binary @"$bodyfile" "$API_URL$path") || { rm -f "$tmp" "$bodyfile"; return 1; }
    rm -f "$bodyfile"
  else
    out=$(curl -s -o "$tmp" -w '%{http_code}' \
      -X "$method" -H "Authorization: Bearer $TOKEN" "$API_URL$path") || { rm -f "$tmp"; return 1; }
  fi
  printf '%s\n' "$out"
  cat "$tmp"
  rm -f "$tmp"
}

# split_http <http-output>: set HTTP_CODE and HTTP_BODY from one http() call.
split_http() {
  case $1 in
    *$'\n'*)
      HTTP_CODE=${1%%$'\n'*}
      HTTP_BODY=${1#*$'\n'}
      ;;
    *)
      HTTP_CODE=$1
      HTTP_BODY=''
      ;;
  esac
}

healthy() {  # <base-url> <token>
  curl -s -m 2 -H "Authorization: Bearer $2" "$1/healthz" 2>/dev/null | grep -q '"ok":true'
}

gen_token() {
  head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

free_port() {
  local port
  for port in $(shuf -i 20000-45000 -n 12 2>/dev/null) 24480; do
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
      printf '%s\n' "$port"
      return 0
    fi
  done
  return 1
}

start_owned_backend() {  # <name> <backend-dir> <port> <token>
  local name=$1 backend=$2 port=$3 token=$4
  : > "$STATE/$name.backend.log"
  (
    cd "$backend/apps/dpi-backend" || exit 1
    exec env DPI_PROVIDER="$C_provider" DPI_PORT="$port" DPI_HOST=127.0.0.1 \
      DPI_DATA_DIR="$STATE/$name.dpi" DPI_HOME="$STATE/$name.dpi" \
      DPI_START_DIRS="$C_cwd" DPI_TOKEN="$token" \
      npx tsx src/main.ts
  ) >> "$STATE/$name.backend.log" 2>&1 &
  OWNED_PID=$!
}

ensure_backend() {  # <name>
  local name=$1
  local port token pid backend
  local envfile="$STATE/$name.backend.env"
  if [ -n "$C_backend_url" ]; then
    API_URL=${C_backend_url%/}
    TOKEN=$C_api_token
    healthy "$API_URL" "$TOKEN" || die 4 "attached backend $API_URL is not healthy"
    return 0
  fi
  backend=$(find_checkout) ||
    die 3 "no durable-pi checkout found; run fm-install-durable-pi.sh $FM_HOME/state/durable-pi (or point config/durable-pi-dir at one)"
  # An owned backend already running from a previous arm is reused, never
  # duplicated: health decides reuse (the recorded pid is the launcher wrapper,
  # which can die before the backend it started), and a recorded instance that
  # is still alive is waited out before any new start, so two instances never
  # share one data dir.
  if [ -f "$envfile" ]; then
    # shellcheck disable=SC1090
    . "$envfile"
    if healthy "$API_URL" "$TOKEN"; then
      printf 'backend: reusing owned instance url=%s\n' "$API_URL"
      return 0
    fi
    pid=${OWNED_PID:-}
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      for _ in $(seq 1 30); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
      done
      kill -0 "$pid" 2>/dev/null &&
        die 4 "recorded backend pid $pid is alive but not healthy on $API_URL; log: $STATE/$name.backend.log"
    fi
  fi
  mkdir -p "$STATE/$name.dpi"
  chmod 700 "$STATE/$name.dpi" 2>/dev/null || true
  token=$(gen_token)
  port=${C_port:-} || true
  [ -n "$port" ] || port=$(free_port) || die 4 "no free port found for the owned backend"
  start_owned_backend "$name" "$backend" "$port" "$token"
  API_URL="http://127.0.0.1:$port"
  TOKEN=$token
  umask 077
  cat > "$envfile" <<EOF
TOKEN=$TOKEN
API_URL=$API_URL
OWNED_PID=$OWNED_PID
EOF
  umask 022
  for _ in $(seq 1 30); do
    healthy "$API_URL" "$TOKEN" && break
    kill -0 "$OWNED_PID" 2>/dev/null || die 4 "owned backend exited during startup; log: $STATE/$name.backend.log"
    sleep 1
  done
  healthy "$API_URL" "$TOKEN" || die 4 "owned backend did not become healthy on port $port; log: $STATE/$name.backend.log"
  printf 'backend: started owned instance pid=%s url=%s\n' "$OWNED_PID" "$API_URL"
}

ensure_session() {  # <name>
  local name=$1 sid body
  local sessionfile="$STATE/$name.session"
  sid=
  if [ -f "$sessionfile" ]; then
    read -r sid < "$sessionfile"
    out=$(http GET "/v1/sessions/$sid") || die 4 "backend unreachable at $API_URL"
    split_http "$out"
    [ "$HTTP_CODE" = 200 ] || sid=
  fi
  if [ -z "$sid" ]; then
    mkdir -p "$C_cwd"
    out=$(http POST /v1/sessions "{\"name\":\"$name\",\"cwd\":\"$C_cwd\",\"model\":{\"provider\":\"$C_provider\",\"modelId\":\"$C_model\"}}") ||
      die 4 "backend unreachable at $API_URL"
    split_http "$out"
    [ "$HTTP_CODE" = 201 ] || die 4 "session create failed (HTTP $HTTP_CODE): $HTTP_BODY"
    sid=$(printf '%s' "$HTTP_BODY" | "$JSONL" -c 'import json,sys; print(json.load(sys.stdin)["id"])')
    printf '%s\n' "$sid" > "$sessionfile"
    printf 'session: created %s\n' "$sid"
  else
    printf 'session: resumed %s\n' "$sid"
  fi
  SESSION_ID=$sid
}

apply_instructions() {
  local body out
  body=$("$JSONL" -c 'import json,sys
print(json.dumps({"instructions": sys.stdin.read()}))' < "$C_prompt") ||
    die 3 "cannot encode prompt file as JSON: $C_prompt"
  out=$(http PATCH "/v1/sessions/$SESSION_ID/agents/main/config" "$body") ||
    die 4 "backend unreachable at $API_URL"
  split_http "$out"
  [ "$HTTP_CODE" = 200 ] || die 4 "instructions apply failed (HTTP $HTTP_CODE): $HTTP_BODY"
  printf 'instructions: applied %s\n' "$C_prompt"
}

# --- inbox ------------------------------------------------------------------

inbox_next() {  # <inbox-dir> -> oldest message path; return 1 when none
  local oldest
  oldest=$(find "$1" -maxdepth 1 -name '*.msg' 2>/dev/null | sort | head -n 1)
  [ -n "$oldest" ] || return 1
  printf '%s\n' "$oldest"
}

submit_message() {  # <name> <msg-path>
  local name=$1 msg=$2 base body out status sid
  base=$(basename "$msg" .msg)
  body=$("$JSONL" -c 'import json,sys
print(json.dumps({"content": sys.stdin.read(), "requestId": sys.argv[1], "whenBusy": "steer", "waitMs": 30000}))' "pf-$base" < "$msg") ||
    { printf 'steer: encode failed for %s\n' "$msg"; return 1; }
  out=$(http POST "/v1/sessions/$SESSION_ID/agents/main/messages" "$body") ||
    { printf 'steer: backend unreachable for %s\n' "$base"; return 1; }
  split_http "$out"
  case $HTTP_CODE in
    200|202) ;;
    *) printf 'steer: submission failed for %s (HTTP %s)\n' "$base" "$HTTP_CODE"; return 1 ;;
  esac
  status=$(printf '%s' "$HTTP_BODY" | "$JSONL" -c 'import json,sys
try:
    print(json.load(sys.stdin).get("status", ""))
except Exception:
    print("")')
  sid=$(printf '%s' "$HTTP_BODY" | "$JSONL" -c 'import json,sys
try:
    print(json.load(sys.stdin).get("submissionId", ""))
except Exception:
    print("")')
  printf '%s msg=%s submission=%s status=%s\n' "$(date +%s)" "$base" "$sid" "$status" >> "$STATE/$name.submissions.log"
  printf 'steer: msg=%s submission=%s status=%s\n' "$base" "$sid" "$status"
}

drain_once() {  # <name>
  local name=$1 msg out
  while msg=$(inbox_next "$STATE/$name.inbox"); do
    out=$(submit_message "$name" "$msg") ||
      { printf 'steer: %s kept for retry; outcome: %s\n' "$msg" "$out"; break; }
    mkdir -p "$STATE/$name.inbox/handled"
    mv "$msg" "$STATE/$name.inbox/handled/" ||
      { printf 'steer: acknowledge failed for %s; submission outcome: %s\n' "$msg" "$out"; break; }
  done
}

# --- subcommands ------------------------------------------------------------

host_exit_log() {
  [ -n "${ARM_NAME:-}" ] || return 0
  printf 'host exited [at=%s]\n' "$(date +%s)" >> "$STATE/$ARM_NAME.log"
}

cmd_arm() {  # <name> [--once]
  local name=${1:-} once=${2:-} body
  [ -n "$name" ] || usage
  load_definition "$name"
  mkdir -p "$STATE/$name.inbox" "$STATE"
  chmod 700 "$STATE/$name.inbox" 2>/dev/null || true
  ensure_backend "$name"
  ensure_session "$name"
  apply_instructions "$name"
  out=$(http GET "/v1/sessions/$SESSION_ID/inspect") || die 4 "backend unreachable at $API_URL"
  split_http "$out"
  printf 'resume: %s\n' "$(printf '%s' "$HTTP_BODY" | tr -d '\n' | head -c 300)"
  printf 'armed [at=%s] url=%s\n' "$(date +%s)" "$API_URL" >> "$STATE/$name.log"
  ARM_NAME=$name
  trap 'host_exit_log' EXIT
  while :; do
    drain_once "$name"
    [ "$once" = "--once" ] && return 0
    sleep "$C_poll"
  done
}

cmd_send() {  # <name> <message...>
  local name=${1:-}
  [ "$#" -ge 2 ] || usage
  shift
  local message=$*
  load_definition "$name"
  local inbox="$STATE/$name.inbox" n next
  mkdir -p "$inbox"
  chmod 700 "$inbox" 2>/dev/null || true
  # Number past every message already handed to the backend (handled/): a
  # requestId is admitted once, so a reused number would replay an old answer.
  n=$(find "$inbox" -name '[0-9]*.msg' 2>/dev/null | sed 's#.*/##; s#\.msg$##' | sort -n | tail -n 1)
  next=$((10#${n:-0} + 1))
  printf '%s\n' "$message" > "$inbox/$(printf '%04d' "$next").msg"
  printf 'queued: %s\n' "$inbox/$(printf '%04d' "$next").msg"
}

recorded_backend_env() {  # <name>: set API_URL/TOKEN from the recorded env, or die 4
  local name=$1 envfile="$STATE/$1.backend.env"
  if [ -n "$C_backend_url" ]; then
    API_URL=${C_backend_url%/}
    TOKEN=$C_api_token
    return 0
  fi
  [ -f "$envfile" ] || die 4 "no owned backend recorded for $name; run arm first"
  # shellcheck disable=SC1090
  . "$envfile"
  return 0
}

cmd_status() {  # <name>
  local name=${1:-} sid body
  [ -n "$name" ] || usage
  load_definition "$name"
  [ -f "$STATE/$name.session" ] || die 4 "no session recorded for $name; run arm first"
  read -r sid < "$STATE/$name.session"
  recorded_backend_env "$name"
  healthy "$API_URL" "$TOKEN" || die 4 "backend at $API_URL is not healthy; run arm to restore it"
  out=$(http GET "/v1/sessions/$sid/inspect") || die 4 "backend unreachable at $API_URL"
  split_http "$out"
  printf 'session: %s\n' "$sid"
  printf 'inspect: %s\n' "$(printf '%s' "$HTTP_BODY" | tr -d '\n' | head -c 300)"
  body=$(curl -sN --max-time 3 -H "Authorization: Bearer $TOKEN" "$API_URL/v1/sessions/$sid/events" 2>/dev/null | head -c 4000)
  case $body in
    *'"usage"'*)
      printf 'usage: %s\n' "$(printf '%s' "$body" | "$JSONL" -c 'import json,sys
for line in sys.stdin:
    if line.startswith("data: ") and "\"usage\"" in line:
        print(json.dumps(json.loads(line[6:]).get("usage", {})))
        break' | head -c 300)"
      ;;
  esac
}

cmd_stop() {  # <name>
  local name=${1:-} envfile="$STATE/$1.backend.env"
  [ -n "$name" ] || usage
  load_definition "$name"
  if [ -f "$envfile" ]; then
    # shellcheck disable=SC1090
    . "$envfile"
    if [ -n "${OWNED_PID:-}" ] && kill -0 "$OWNED_PID" 2>/dev/null; then
      kill "$OWNED_PID" || die 4 "cannot stop owned backend pid $OWNED_PID"
      printf 'stopped: owned backend pid=%s\n' "$OWNED_PID"
      printf 'stopped [at=%s] pid=%s\n' "$(date +%s)" "$OWNED_PID" >> "$STATE/$name.log"
      return 0
    fi
  fi
  die 4 "no running owned backend recorded for $name"
}

case "${1:-}" in
  arm) shift; cmd_arm "$@" ;;
  send) shift; cmd_send "$@" ;;
  status) shift; cmd_status "$@" ;;
  stop) shift; cmd_stop "$@" ;;
  -h|--help) usage ;;
  '') usage ;;
  *) die 2 "unknown subcommand: $1" ;;
esac
