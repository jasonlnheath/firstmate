#!/usr/bin/env bash
# Durable-watcher live-path test against a real pinned durable-pi checkout.
#
# This is a harness-dependent check: its verdict comes from real dpi-backend
# behavior, so it must run against the real checkout when one is installed.
# Without the checkout it skips with an explicit notice naming the installer,
# never a silent pass. With the checkout it proves the real path end to end:
# steer admitted once, steer while busy joins the run, a mid-run process kill
# resumes and completes the outstanding submission, and the benchmark produces
# a parseable comparison table over a real faux-model run.
#
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_DURABLE_WATCH_LIVE

require_python3() {
  command -v python3 >/dev/null 2>&1 || {
    printf 'skip: live: python3 absent\n'
    exit 0
  }
}
require_python3
command -v node >/dev/null 2>&1 || {
  printf 'skip: live: node absent\n'
  exit 0
}

checkout=${FM_DURABLE_PI_DIR:-}
if [ -z "$checkout" ]; then
  for candidate in "${FM_HOME:-$ROOT}/state/durable-pi" "$HOME/.dpi-firstmate/durable-pi"; do
    if [ -d "$candidate/apps/dpi-backend/src" ]; then
      checkout=$candidate
      break
    fi
  done
fi
if [ -z "$checkout" ] || [ ! -d "$checkout/apps/dpi-backend/src" ]; then
  printf 'skip: live: pinned durable-pi checkout not installed; run bin/fm-install-durable-pi.sh <destination>\n'
  exit 0
fi

BACKEND_DIR=$checkout/apps/dpi-backend
scratch=$FM_TEST_TMPDIR/durable-live
mkdir -p "$scratch/data" "$scratch/work"

free_port() {
  python3 - <<'PYEOF'
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
PYEOF
}

start_backend() {  # <log-file> -> sets BACKEND_PID
  local log=$1
  DPI_PROVIDER=faux \
    DPI_HOME="$scratch/dpihome" \
    DPI_PORT=$BENCH_PORT \
    DPI_DATA_DIR="$scratch/data" \
    DPI_START_DIRS="$scratch/work" \
    DPI_TOKEN=$TOKEN \
    nohup npx --prefix "$BACKEND_DIR" tsx "$BACKEND_DIR/src/main.ts" >"$log" 2>&1 &
  BACKEND_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    curl -s -m 1 "http://127.0.0.1:$BENCH_PORT/healthz" 2>/dev/null | grep -q '"ok":true' && return 0
    sleep 0.5
  done
  fail "fixture dpi-backend did not become healthy on port $BENCH_PORT (log: $log)"
}

stop_backend() {
  [ -n "${BACKEND_PID:-}" ] && kill "$BACKEND_PID" 2>/dev/null
  wait "${BACKEND_PID:-}" 2>/dev/null
  BACKEND_PID=
}

BENCH_PORT=$(free_port)
TOKEN=live-test-token-0123456789abcdef012345
API=http://127.0.0.1:$BENCH_PORT/v1
AUTH="Authorization: Bearer $TOKEN"
trap stop_backend EXIT

cd "$BACKEND_DIR" || fail "cannot enter $BACKEND_DIR"
start_backend "$scratch/backend.log"

# --- session create, steer admitted once -------------------------------------
code=$(curl -s -o "$scratch/session.json" -w '%{http_code}' -X POST "$API/sessions" \
  -H "$AUTH" -H 'content-type: application/json' \
  -d '{"name":"live","cwd":"'"$scratch/work"'","model":{"provider":"faux","modelId":"echo"}}')
assert_equals 201 "$code" "session created"
sid=$(python3 -c "import json;print(json.load(open('$scratch/session.json'))['id'])")
[ -n "$sid" ] || fail "session id missing"

out=$(curl -s -X POST "$API/sessions/$sid/agents/main/messages" -H "$AUTH" \
  -H 'content-type: application/json' \
  -d '{"content":"live cycle one","requestId":"live-1","waitMs":20000}')
assert_contains "$out" '"status":"done"' "first submission completes"
out=$(curl -s -X POST "$API/sessions/$sid/agents/main/messages" -H "$AUTH" \
  -H 'content-type: application/json' \
  -d '{"content":"live cycle one","requestId":"live-1","waitMs":20000}')
assert_contains "$out" '"status":"done"' "repeated requestId replays without a second run"

# --- steer while busy joins the run ------------------------------------------
curl -s -X POST "$API/sessions/$sid/agents/main/messages" -H "$AUTH" \
  -H 'content-type: application/json' \
  -d '{"content":"slow: busy for a moment","requestId":"live-2"}' >/dev/null
sleep 1
out=$(curl -s -X POST "$API/sessions/$sid/agents/main/messages" -H "$AUTH" \
  -H 'content-type: application/json' \
  -d '{"content":"live steer mid-run","requestId":"live-3","whenBusy":"steer"}')
assert_contains "$out" '"status"' "steer while busy is accepted"

# --- kill mid-run, restart, outstanding submission completes -----------------
kill "$BACKEND_PID" 2>/dev/null
wait "$BACKEND_PID" 2>/dev/null
BACKEND_PID=
( cd "$BACKEND_DIR" && start_backend "$scratch/backend2.log" ) || exit 1
out=$(curl -s "$API/sessions/$sid/submissions/$(python3 -c "import json;print(json.loads('''$out''')['submissionId'])")?waitMs=30000" -H "$AUTH")
case $out in
  *'"status":"done"'*) pass "steer submitted before the kill completes after resume" ;;
  *'"status"'*) printf 'not ok - steer before kill did not complete: %s\n' "$out" >&2; exit 1 ;;
  *) fail "submission long-poll after restart returned nothing" ;;
esac

# --- benchmark end to end on the real checkout --------------------------------
rm -f "$scratch/backend.log" "$scratch/backend2.log"
stop_backend
BENCH_PORT=$(free_port)
FM_DURABLE_PI_DIR=$checkout FM_HOME=$scratch/home bash "$ROOT/bin/fm-durable-watch-bench.sh" \
  --cycles 3 --bytes-per-cycle 400 --steers-per-cycle 1 --inject-restart-at 2 \
  --scratch "$scratch/bench" >"$scratch/bench.out" 2>"$scratch/bench.err"
expect_code 0 "$?" "benchmark completes against the real checkout"
assert_contains "$(cat "$scratch/bench.out")" "tokens/cycle" "real table reports tokens/cycle"
assert_contains "$(cat "$scratch/bench.out")" "durable" "real table reports the durable column"
assert_present "$scratch/bench/baseline.evidence.json" "baseline evidence recorded"
assert_present "$scratch/bench/durable.evidence.json" "durable evidence recorded"

printf 'Durable-watcher live-path tests passed.\n'
