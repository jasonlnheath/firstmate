#!/usr/bin/env bash
# fm-durable-watch-bench.sh - benchmark the durable-watcher path against the
# plain-session baseline it replaces.
#
# Runs one comparable watch-keeper scenario twice over one owned, scratch
# durable-pi backend and prints a plain comparison table, so a home can
# measure gains or degradation before and after adopting the gated path
# (docs/durable-watchers.md owns the operator contract;
# docs/durable-watchers-feasibility.md owns the research evidence and the
# modeling notes summarized here).
#
# Paths compared:
#   baseline  A plain persistent session with compaction off, restarted every
#             --baseline-restart-every cycles as a fresh session whose first
#             message rebuilds the full prior working context. In-flight work
#             at a restart is abandoned and counted missed, modeling a plain
#             agent session whose process died.
#   durable   One persistent session with automatic compaction scaled to the
#             synthetic wall; at the injected restart the same session
#             resumes and the in-flight submission is polled to completion,
#             modeling the durable path's crash resume.
#
# Mode is faux by default: the deterministic free model measures structure
# (cycle count, context size, restart recovery, delivery reliability), and
# the table labels token rows as synthetic. Pass --provider/--model plus the
# provider's API key in the environment for real cost numbers.
#
# The bench owns its own port, token, and data dir and kills only the
# backend pid it started, never by name.
#
# Requires: bash, curl, python3, node, and a durable-pi checkout installed by
# bin/fm-install-durable-pi.sh (or FM_DURABLE_PI_DIR).
#
# Usage:
#   fm-durable-watch-bench.sh [--cycles N] [--bytes-per-cycle B]
#       [--baseline-restart-every K] [--steers-per-cycle S]
#       [--inject-restart-at R] [--port P] [--provider NAME] [--model ID]
#       [--scratch DIR] [--keep]
#   fm-durable-watch-bench.sh render <baseline.evidence.json> <durable.evidence.json>
#
# render  Reprint the comparison table from two recorded evidence files
#         without any backend, so a run can be re-reported later.
#         --inject-restart-at 0 disables the injected restart.
#
# Evidence: <scratch>/baseline.evidence.json and <scratch>/durable.evidence.json.
# Exit codes: 2 usage or refusal, 4 backend failure.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
JSONL="${PYTHON3:-python3}"

die() {  # <code> <message...>
  local code=$1
  shift
  printf 'fm-durable-watch-bench.sh: %s\n' "$*" >&2
  exit "$code"
}

CYCLES=6
BYTES=800
BASELINE_RESTART_EVERY=3
STEERS=1
INJECT_AT=''
PORT=''
PROVIDER="faux"
MODEL="echo"
SCRATCH=''
KEEP=0

if [ "${1:-}" = render ]; then
  shift
  [ "$#" -eq 2 ] || die 2 "render needs exactly two evidence files"
  for f in "$@"; do
    [ -f "$f" ] || die 2 "evidence file not found: $f"
  done
  exec "$JSONL" "$SCRIPT_DIR/fm-durable-watch-bench-table.py" "$@"
fi

while [ "$#" -gt 0 ]; do
  case $1 in
    --cycles) CYCLES=${2:-}; [ -n "$CYCLES" ] || die 2 "--cycles needs a value"; shift 2 ;;
    --bytes-per-cycle) BYTES=${2:-}; [ -n "$BYTES" ] || die 2 "--bytes-per-cycle needs a value"; shift 2 ;;
    --baseline-restart-every) BASELINE_RESTART_EVERY=${2:-}; [ -n "$BASELINE_RESTART_EVERY" ] || die 2 "--baseline-restart-every needs a value"; shift 2 ;;
    --steers-per-cycle) STEERS=${2:-}; [ -n "$STEERS" ] || die 2 "--steers-per-cycle needs a value"; shift 2 ;;
    --inject-restart-at) INJECT_AT=${2:-}; [ -n "$INJECT_AT" ] || die 2 "--inject-restart-at needs a value"; shift 2 ;;
    --port) PORT=${2:-}; [ -n "$PORT" ] || die 2 "--port needs a value"; shift 2 ;;
    --provider) PROVIDER=${2:-}; [ -n "$PROVIDER" ] || die 2 "--provider needs a value"; shift 2 ;;
    --model) MODEL=${2:-}; [ -n "$MODEL" ] || die 2 "--model needs a value"; shift 2 ;;
    --scratch) SCRATCH=${2:-}; [ -n "$SCRATCH" ] || die 2 "--scratch needs a value"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '/^# Usage:/,/^# Evidence:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die 2 "unknown argument: $1" ;;
  esac
done

validate_int() {  # <flag> <value> [allow-zero]
  case $2 in
    ''|*[!0-9]*) die 2 "$1 must be an integer, got: $2" ;;
  esac
  if [ "${3:-}" = allow-zero ]; then
    [ "$2" -ge 0 ] || die 2 "$1 must be at least 0, got: $2"
  else
    [ "$2" -ge 1 ] || die 2 "$1 must be at least 1, got: $2"
  fi
}
validate_int --cycles "$CYCLES"
# The backend rejects request bodies over 256kb, and the baseline rebuild
# carries every prior payload, so the scenario must fit inside 200k chars.
if [ "$(( CYCLES * BYTES ))" -gt 200000 ]; then
  die 2 "cycles x bytes-per-cycle must stay at or under 200000 (backend body cap), got: $(( CYCLES * BYTES ))"
fi
validate_int --bytes-per-cycle "$BYTES"
validate_int --baseline-restart-every "$BASELINE_RESTART_EVERY"
validate_int --steers-per-cycle "$STEERS"
[ -z "$INJECT_AT" ] && INJECT_AT=$(( CYCLES / 2 ))
validate_int --inject-restart-at "$INJECT_AT" allow-zero

command -v node >/dev/null 2>&1 || die 2 "node is required to run the bench backend but is not installed"

if [ -z "$SCRATCH" ]; then
  SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-durable-bench.XXXXXX") || die 4 "cannot create scratch dir"
fi
mkdir -p "$SCRATCH/data" "$SCRATCH/work"
WORK_DIR=$(cd "$SCRATCH/work" && pwd)

# A port the bench does not own must be refused before anything starts.
port_open() {  # <port>
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}
if [ -n "$PORT" ]; then
  if port_open "$PORT"; then
    die 2 "port $PORT is already occupied; the bench refuses to share or disturb it"
  fi
else
  PORT=$(shuf -i 20000-45000 -n 1 2>/dev/null) || PORT=24490
  while port_open "$PORT"; do
    PORT=$((PORT + 1))
    [ "$PORT" -lt 46000 ] || die 2 "no free port found in 20000-46000"
  done
fi

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

CHECKOUT=$(find_checkout) ||
  die 2 "no durable-pi checkout found; run fm-install-durable-pi.sh $FM_HOME/state/durable-pi (or point config/durable-pi-dir at one)"
BACKEND_DIR=$CHECKOUT/apps/dpi-backend

TOKEN=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
API_URL=http://127.0.0.1:$PORT
BASE=http://127.0.0.1:$PORT/v1
AUTH="Authorization: Bearer $TOKEN"

OWNED_PID=
start_backend() {  # <log>
  local log=$1 i
  (
    cd "$BACKEND_DIR" || exit 1
    exec env DPI_PROVIDER="$PROVIDER" DPI_PORT="$PORT" DPI_HOST=127.0.0.1 \
      DPI_DATA_DIR="$SCRATCH/data" DPI_HOME="$SCRATCH/data" \
      DPI_START_DIRS="$WORK_DIR" DPI_TOKEN="$TOKEN" \
      npx tsx src/main.ts
  ) >> "$log" 2>&1 &
  OWNED_PID=$!
  for i in $(seq 1 60); do
    curl -s -m 2 -H "$AUTH" "$API_URL/healthz" 2>/dev/null | grep -q '"ok":true' && return 0
    kill -0 "$OWNED_PID" 2>/dev/null || die 4 "bench backend exited during startup; log: $log"
    sleep 1
  done
  die 4 "bench backend did not become healthy on port $PORT; log: $log"
}

cleanup() {
  if [ "$KEEP" = 1 ]; then
    printf 'kept: backend pid=%s scratch=%s\n' "${OWNED_PID:-}" "$SCRATCH"
    return 0
  fi
  [ -n "$OWNED_PID" ] && kill "$OWNED_PID" 2>/dev/null
  return 0
}
trap cleanup EXIT

http_json() {  # <method> <path> [body] -> first stdout line is the HTTP status,
  # the rest is the response body (a subshell cannot export BENCH_HTTP_CODE).
  local method=$1 path=$2 tmp out bodyfile
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-durable-bench-http.XXXXXX") || return 1
  if [ "$#" -ge 3 ]; then
    # Large payloads exceed the argv limit, so the body travels by file.
    bodyfile=$(mktemp "${TMPDIR:-/tmp}/fm-durable-bench-body.XXXXXX") || { rm -f "$tmp"; return 1; }
    printf '%s' "$3" > "$bodyfile"
    out=$(curl -s -m 150 -o "$tmp" -w '%{http_code}' -X "$method" -H "$AUTH" \
      -H 'content-type: application/json' --data-binary @"$bodyfile" "$BASE$path") ||
      { rm -f "$tmp" "$bodyfile"; return 1; }
    rm -f "$bodyfile"
  else
    out=$(curl -s -m 150 -o "$tmp" -w '%{http_code}' -X "$method" -H "$AUTH" "$BASE$path") ||
      { rm -f "$tmp"; return 1; }
  fi
  printf '%s\n' "$out"
  cat "$tmp"
  rm -f "$tmp"
}

# split_http <http-output>: set BENCH_HTTP_CODE and BENCH_BODY.
split_http() {
  case $1 in
    *$'\n'*)
      BENCH_HTTP_CODE=${1%%$'\n'*}
      BENCH_BODY=${1#*$'\n'}
      ;;
    *)
      BENCH_HTTP_CODE=$1
      BENCH_BODY=''
      ;;
  esac
}

session_usage() {  # <session-id> -> cumulative usage JSON for the session's model
  curl -sN --max-time 3 -H "$AUTH" "$API_URL/v1/sessions/$1/events" 2>/dev/null |
    head -c 4000 |
    "$JSONL" -c 'import json,sys
for line in sys.stdin:
    if line.startswith("data: ") and "\"usage\"" in line:
        u = json.loads(line[6:]).get("usage", {}).get("models", {})
        for m in u.values():
            print(json.dumps(m))
            break
        break'
}

active_context() {  # <session-id> -> "entries bytes"
  local out
  out=$(http_json GET "/sessions/$1/agents/main/entries?scope=active") || { printf '0 0'; return 0; }
  split_http "$out"
  printf '%s' "$BENCH_BODY" | "$JSONL" -c 'import json,sys
try:
    items = json.load(sys.stdin).get("items", [])
    print(len(items), sum(len(json.dumps(it)) for it in items))
except Exception:
    print("0 0")'
}

mk_payload() {  # <cycle> -> about-BYTE-byte deterministic context-growth payload
  "$JSONL" -c 'import sys
cycle, nbytes = int(sys.argv[1]), int(sys.argv[2])
chunk = "context growth row for the keeper scenario "
text = (f"cycle {cycle} " + chunk * (nbytes // len(chunk) + 1))[:nbytes]
print(f"cycle {cycle} context growth payload: {text}")' "$1" "$BYTES"
}

encode_submission() {  # <request-id> <wait-ms> -> submission JSON body on stdout
  "$JSONL" -c 'import json,sys
print(json.dumps({"content": sys.stdin.read(), "requestId": sys.argv[1], "whenBusy": "steer", "waitMs": int(sys.argv[2])}))' "$1" "$2"
}

submit_wait() {  # <session-id> <request-id> <content> -> outcome status on stdout
  local sid=$1 rid=$2 content=$3 out
  out=$(encode_submission "$rid" 60000 <<<"$content") || die 4 "cannot encode submission body"
  out=$(http_json POST "/sessions/$sid/agents/main/messages" "$out") ||
    die 4 "backend unreachable during submission"
  split_http "$out"
  case $BENCH_HTTP_CODE in 200|202) ;; *) die 4 "submission failed (HTTP $BENCH_HTTP_CODE): $BENCH_BODY" ;; esac
  printf '%s' "$BENCH_BODY" | "$JSONL" -c 'import json,sys
try:
    print(json.load(sys.stdin).get("status", ""))
except Exception:
    print("")'
}

usage_delta() {  # <before-json> <after-json> -> "input cacheRead totalTokens"
  "$JSONL" -c "import json,sys
def parse(s):
    s = s.strip()
    return json.loads(s) if s else {'input': 0, 'cacheRead': 0, 'totalTokens': 0}
a, b = parse(sys.argv[1]), parse(sys.argv[2])
print(b['input'] - a['input'], b['cacheRead'] - a['cacheRead'], b['totalTokens'] - a['totalTokens'])" "$1" "$2"
}

field3() {  # <"a b c"> <index>
  printf '%s' "$1" | cut -d' ' -f"$2"
}

run_path() {  # <path-name> -> writes <scratch>/<path-name>.evidence.json
  local path_name=$1 sid out before after delta t0 t1 t_kill wall_ms
  local evidence="$SCRATCH/$path_name.evidence.json"
  local -a per_cycle=() restarts=()
  local submitted=0 answered=0 missed=0 rebuild
  local cycle current_sid i rid status r_answered r_missed sub_id

  out=$(http_json POST /sessions "{\"name\":\"bench-$path_name\",\"cwd\":\"$WORK_DIR\",\"model\":{\"provider\":\"$PROVIDER\",\"modelId\":\"$MODEL\"}}") ||
    die 4 "backend unreachable at scenario start"
  split_http "$out"
  [ "$BENCH_HTTP_CODE" = 201 ] || die 4 "scenario session create failed (HTTP $BENCH_HTTP_CODE): $BENCH_BODY"
  sid=$(printf '%s' "$BENCH_BODY" | "$JSONL" -c 'import json,sys; print(json.load(sys.stdin)["id"])')
  current_sid=$sid
  : > "$SCRATCH/$path_name.payloads"

  if [ "$path_name" = durable ]; then
    out=$(http_json PATCH "/sessions/$sid/compaction" '{"enabled":true,"reserveTokens":2000,"backgroundTokens":1000,"keepRecentTokens":500}') ||
      die 4 "backend unreachable setting compaction"
    split_http "$out"
    [ "$BENCH_HTTP_CODE" = 200 ] || die 4 "compaction apply failed (HTTP $BENCH_HTTP_CODE): $BENCH_BODY"
  fi

  for cycle in $(seq 1 "$CYCLES"); do
    # Baseline restart: abandon the old session, open a fresh one, and rebuild
    # the full prior working context as its first message. The usage baseline
    # is captured off the fresh session before the rebuild submits, so the
    # rebuild's tokens count in this cycle's delta and the totals row.
    if [ "$path_name" = baseline ] && [ "$cycle" -gt 1 ] && [ $(( (cycle - 1) % BASELINE_RESTART_EVERY )) -eq 0 ]; then
      t0=$(date +%s%3N)
      out=$(http_json POST /sessions "{\"name\":\"bench-$path_name-c$cycle\",\"cwd\":\"$WORK_DIR\",\"model\":{\"provider\":\"$PROVIDER\",\"modelId\":\"$MODEL\"}}") ||
        die 4 "backend unreachable during baseline restart"
      split_http "$out"
      [ "$BENCH_HTTP_CODE" = 201 ] || die 4 "baseline restart session failed (HTTP $BENCH_HTTP_CODE)"
      current_sid=$(printf '%s' "$BENCH_BODY" | "$JSONL" -c 'import json,sys; print(json.load(sys.stdin)["id"])')
      before=$(session_usage "$current_sid")
      rebuild=$("$JSONL" -c 'import sys
texts = [l.rstrip("\n") for l in sys.stdin if l.strip()]
joined = "rebuild of prior working context: " + " | ".join(texts)
print(joined[-200000:])' < "$SCRATCH/$path_name.payloads")
      submit_wait "$current_sid" "bench-$path_name-r$cycle" "$rebuild" >/dev/null
      t1=$(date +%s%3N)
      restarts+=("{\"cycle\":$cycle,\"recoveryMs\":$((t1 - t0)),\"steersAnswered\":0,\"steersMissed\":0}")
    else
      before=$(session_usage "$current_sid")
    fi

    t0=$(date +%s%3N)
    payload=$(mk_payload "$cycle")
    printf '%s\n' "$payload" >> "$SCRATCH/$path_name.payloads"

    if [ "$INJECT_AT" -ne 0 ] && [ "$cycle" = "$INJECT_AT" ]; then
      # Put both the cycle payload and a steer in flight, then kill the owned
      # backend by the pid it was started with. The durable path resumes the
      # same session and the steer completes; the baseline abandons the
      # session and the steer counts missed.
      out=$(encode_submission "bench-$path_name-c$cycle" 1000 <<<"$payload") ||
        die 4 "cannot encode injected cycle payload"
      out=$(http_json POST "/sessions/$current_sid/agents/main/messages" "$out") ||
        die 4 "backend unreachable during injected cycle payload"
      split_http "$out"
      case $BENCH_HTTP_CODE in 200|202) ;; *) die 4 "injected cycle payload failed (HTTP $BENCH_HTTP_CODE)" ;; esac
      rid="bench-$path_name-s$cycle"
      out=$(encode_submission "$rid" 1000 <<<"bench steer during restart window cycle $cycle") ||
        die 4 "cannot encode injected steer"
      out=$(http_json POST "/sessions/$current_sid/agents/main/messages" "$out") ||
        die 4 "backend unreachable during injected steer"
      split_http "$out"
      case $BENCH_HTTP_CODE in 200|202) ;; *) die 4 "injected steer failed (HTTP $BENCH_HTTP_CODE)" ;; esac
      sub_id=$(printf '%s' "$BENCH_BODY" | "$JSONL" -c 'import json,sys; print(json.load(sys.stdin)["submissionId"])')
      submitted=$((submitted + 1))
      t_kill=$(date +%s%3N)
      kill "$OWNED_PID" 2>/dev/null
      wait "$OWNED_PID" 2>/dev/null
      OWNED_PID=
      start_backend "$SCRATCH/backend-restart.log"
      r_answered=0
      r_missed=1
      if [ "$path_name" = durable ]; then
        # A submission admitted by a previous backend process reports pending
        # without long-polling, so the resume poll loops until the resumed
        # run completes or the deadline passes.
        r_status=pending
        for _ in $(seq 1 45); do
          body=$(curl -s -m 10 -H "$AUTH" "$BASE/sessions/$current_sid/submissions/$sub_id?waitMs=2000") ||
            die 4 "backend unreachable polling resumed submission"
          if printf '%s' "$body" | grep -Fq '"status":"done"'; then
            r_status="done"
            break
          fi
          if printf '%s' "$body" | grep -Fq '"status":"unanswered"'; then
            r_status="unanswered"
            break
          fi
          sleep 2
        done
        if [ "$r_status" = "done" ]; then
          answered=$((answered + 1)); r_answered=1; r_missed=0
        else
          missed=$((missed + 1))
        fi
      else
        missed=$((missed + 1))
      fi
      restarts+=("{\"cycle\":$cycle,\"recoveryMs\":$(( $(date +%s%3N) - t_kill )),\"steersAnswered\":$r_answered,\"steersMissed\":$r_missed}")
      after=$(session_usage "$current_sid")
      delta=$(usage_delta "$before" "$after")
      wall_ms=$(( $(date +%s%3N) - t0 ))
    else
      submit_wait "$current_sid" "bench-$path_name-c$cycle" "$payload" >/dev/null
      for i in $(seq 1 "$STEERS"); do
        rid="bench-$path_name-s${cycle}-$i"
        status=$(submit_wait "$current_sid" "$rid" "bench steer $i for cycle $cycle: keep the board current")
        submitted=$((submitted + 1))
        if [ "$status" = "done" ]; then
          answered=$((answered + 1))
        else
          missed=$((missed + 1))
        fi
      done
      after=$(session_usage "$current_sid")
      delta=$(usage_delta "$before" "$after")
      wall_ms=$(( $(date +%s%3N) - t0 ))
    fi

    per_cycle+=("{\"cycle\":$cycle,\"wallMs\":$wall_ms,\"tokens\":{\"input\":$(field3 "$delta" 1),\"cacheRead\":$(field3 "$delta" 2),\"totalTokens\":$(field3 "$delta" 3)}}")
    printf 'bench: %s cycle %s/%s wallMs=%s\n' "$path_name" "$cycle" "$CYCLES" "$wall_ms" >&2
  done

  read -r final_entries final_bytes <<< "$(active_context "$current_sid")"
  {
    printf '{"mode":"%s","cycles":%s,"provider":"%s","model":"%s","finalActiveEntries":%s,"finalActiveBytes":%s,' \
      "$path_name" "$CYCLES" "$PROVIDER" "$MODEL" "${final_entries:-0}" "${final_bytes:-0}"
    printf '"steers":{"submitted":%s,"answered":%s,"missed":%s},' "$submitted" "$answered" "$missed"
    printf '"restarts":[%s],' "$(IFS=,; printf '%s' "${restarts[*]:-}")"
    printf '"perCycle":[%s]}\n' "$(IFS=,; printf '%s' "${per_cycle[*]:-}")"
  } > "$evidence"
  printf 'bench: %s evidence at %s\n' "$path_name" "$evidence" >&2
}

# --- run both paths ---------------------------------------------------------

start_backend "$SCRATCH/backend.log"
run_path baseline
run_path durable
"$JSONL" "$SCRIPT_DIR/fm-durable-watch-bench-table.py" "$SCRATCH/baseline.evidence.json" "$SCRATCH/durable.evidence.json"
