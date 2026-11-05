#!/usr/bin/env bash
# Durable-watcher path contract tests.
#
# Portable coverage: with the gate off nothing in the repo references the
# durable-watcher scripts (byte-identity), every subcommand refuses cleanly
# without config, send stays file-first while the host is down, the host's
# message-id to requestId mapping is stable across repeated delivery, and the
# benchmark's table renders from recorded evidence without a backend.
# Live-path coverage against a real pinned durable-pi checkout lives in
# tests/fm-durable-watch-live.test.sh.
#
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_python3() {
  command -v python3 >/dev/null 2>&1 || {
    printf 'skip: python3 absent\n'
    exit 0
  }
}

HOST_BIN=$ROOT/bin/fm-durable-watch.sh
BENCH_BIN=$ROOT/bin/fm-durable-watch-bench.sh

fixture_home() {  # <name> -> prints FM_HOME path
  local dir=$FM_TEST_TMPDIR/fm-durable-watch-$1-$$
  mkdir -p "$dir/config" "$dir/state"
  printf '%s\n' "$dir"
}

write_config() {  # <fm-home> <name>
  mkdir -p "$1/config/durable-watchers"
  cat > "$1/config/durable-watchers/$2.conf" <<EOF
cwd=/tmp/fm-durable-watch-fixture-work
prompt=$FM_TEST_TMPDIR/keeper-prompt.md
backend_url=http://127.0.0.1:1
poll_seconds=1
EOF
  printf 'Keeper policy: keep the board current.\n' > "$FM_TEST_TMPDIR/keeper-prompt.md"
}

# --- fixture backend ---------------------------------------------------------
# Minimal stand-in for the dpi-backend v1 surface the host uses. Records every
# admitted messages body and replayed answers for repeated request ids, so the
# idempotency contract is observable. Binds port 0 and writes the real port to
# <state>/port.
fixture_backend() {  # <state-dir>
  require_python3
  mkdir -p "$1"
  cat > "$1/fixture.py" <<'PYEOF'
import json, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

state_dir, = sys.argv[1:2]
admissions = []
answers = {}
counter = [100]

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _json(self, code, obj):
        body = json.dumps(obj, separators=(',', ':')).encode()
        self.send_response(code)
        self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == '/healthz':
            self._json(200, {'ok': True})
        elif self.path == '/v1/sessions/s1/inspect':
            self._json(200, {'scheduling': 'idle', 'tasks': [], 'submissions': []})
        elif self.path.startswith('/v1/sessions/s1/events'):
            self.send_response(200)
            self.send_header('content-type', 'text/event-stream')
            self.end_headers()
            frame = json.dumps({'type': 'session', 'agents': [], 'tasks': [],
                                'usage': {'models': {'faux/echo': {'input': 10, 'output': 2, 'cacheRead': 0, 'cacheWrite': 0, 'totalTokens': 12}}}}) + '\n\n'
            self.wfile.write(b'id: 1\nevent: session\ndata: ' + frame.encode())
            threading.Event().wait(0.3)
        else:
            self._json(404, {'error': {'code': 'not_found', 'message': 'no route'}})

    def do_PATCH(self):
        n = int(self.headers.get('content-length', 0))
        raw = self.rfile.read(n)
        if self.path == '/v1/sessions/s1/agents/main/config':
            with open(state_dir + '/config.jsonl', 'a') as f:
                f.write(raw.decode() + '\n')
            self._json(200, {'ok': True})
        else:
            self._json(404, {'error': {'code': 'not_found', 'message': 'no route'}})

    def do_POST(self):
        n = int(self.headers.get('content-length', 0))
        raw = self.rfile.read(n)
        if self.path == '/v1/sessions':
            self._json(201, {'id': 's1', 'name': 'fixture', 'cwd': '/tmp',
                             'model': 'echo', 'agents': [{'id': 1, 'name': 'Main'}]})
            return
        if self.path == '/v1/sessions/s1/agents/main/messages':
            body = json.loads(raw or b'{}')
            rid = body.get('requestId', '')
            with open(state_dir + '/submissions.jsonl', 'a') as f:
                f.write(json.dumps({'requestId': rid, 'content': body.get('content', ''),
                                    'whenBusy': body.get('whenBusy', '')}) + '\n')
            if rid in answers:
                self._json(200, {'submissionId': answers[rid], 'status': 'done',
                                 'answer': {'entryId': 1, 'text': 'replayed'}})
                return
            counter[0] += 1
            answers[rid] = counter[0]
            self._json(200, {'submissionId': counter[0], 'status': 'done',
                             'answer': {'entryId': 2, 'text': 'done'}})
            return
        self._json(404, {'error': {'code': 'not_found', 'message': 'no route'}})

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
with open(state_dir + '/port', 'w') as f:
    f.write(str(server.server_port))
server.serve_forever()
PYEOF
  python3 "$1/fixture.py" "$1" &
  FIXTURE_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$1/port" ] && break
    sleep 0.3
  done
}

# --- 1. byte-identity: default-off surface ----------------------------------
# No pre-existing tracked script may reference the durable-watcher path; the
# only references may come from the new files themselves and their docs.
refs=$(git -C "$ROOT" grep -l -E 'fm-durable-watch|durable-watchers|fm-install-durable-pi' -- 'bin/*.sh' 'bin/*.mjs' 'bin/backends/*.sh' 'tests/*.sh' 2>/dev/null | grep -v -E 'fm-durable-watch|fm-install-durable-pi' || true)
[ -z "$refs" ] || fail "pre-existing scripts reference the durable-watcher path: $refs"
pass "byte-identity: no pre-existing script references the durable path"

# --- 2. gate refusals without config ----------------------------------------
home=$(fixture_home 'gate')
out=$(FM_HOME="$home" bash "$HOST_BIN" arm keeper 2>&1)
code=$?
expect_code 3 "$code" "arm without config exits 3"
assert_contains "$out" "config/durable-watchers" "arm refusal names the config path"
assert_contains "$out" "fm-install-durable-pi.sh" "arm refusal names the installer"
assert_absent "$home/state/durable-watchers" "arm without config creates no state"

for sub in status stop; do
  out=$(FM_HOME="$home" bash "$HOST_BIN" "$sub" keeper 2>&1 </dev/null)
  code=$?
  expect_code 3 "$code" "$sub without config exits 3"
  assert_contains "$out" "config/durable-watchers" "$sub refusal names the config path"
done
out=$(FM_HOME="$home" bash "$HOST_BIN" send keeper "test message" 2>&1 </dev/null)
code=$?
expect_code 3 "$code" "send without config exits 3"
assert_contains "$out" "config/durable-watchers" "send refusal names the config path"
pass "gate: every subcommand refuses cleanly without config"

# --- 3. malformed definition refusal ----------------------------------------
home=$(fixture_home 'malformed')
mkdir -p "$home/config/durable-watchers"
printf 'cwd=/tmp/work\nunknown_key=1\n' > "$home/config/durable-watchers/keeper.conf"
out=$(FM_HOME="$home" bash "$HOST_BIN" arm keeper 2>&1)
expect_code 3 "$?" "unknown config key exits 3"
assert_contains "$out" "unknown_key" "refusal names the unknown key"

home=$(fixture_home 'missing-key')
mkdir -p "$home/config/durable-watchers"
printf 'cwd=/tmp/work\n' > "$home/config/durable-watchers/keeper.conf"
out=$(FM_HOME="$home" bash "$HOST_BIN" arm keeper 2>&1)
expect_code 3 "$?" "missing required key exits 3"
assert_contains "$out" "prompt" "refusal names the missing key"
pass "config: malformed definitions refuse naming the key"

# --- 4. send is file-first and works while the host is down ------------------
home=$(fixture_home 'send')
write_config "$home" keeper
out=$(FM_HOME="$home" bash "$HOST_BIN" send keeper "refresh the board" 2>&1)
expect_code 0 "$?" "send with config exits 0"
assert_contains "$out" "queued" "send reports queued"
assert_present "$home/state/durable-watchers/keeper.inbox/0001.msg" "send appends 0001.msg"
out=$(FM_HOME="$home" bash "$HOST_BIN" send keeper "second steer" 2>&1)
expect_code 0 "$?" "second send exits 0"
assert_present "$home/state/durable-watchers/keeper.inbox/0002.msg" "send numbers messages"
assert_contains "$(cat "$home/state/durable-watchers/keeper.inbox/0001.msg")" "refresh the board" "message body is preserved"
pass "send: file-first durable steering while the host is down"

# --- 5. host drain: requestId mapping is stable, instructions applied --------
home=$(fixture_home 'drain')
fixstate=$FM_TEST_TMPDIR/fm-durable-watch-fixture-drain-$$
mkdir -p "$fixstate"
fixture_backend "$fixstate"
trap 'kill $FIXTURE_PID 2>/dev/null' EXIT
port=$(cat "$fixstate/port")
mkdir -p "$home/config/durable-watchers"
cat > "$home/config/durable-watchers/keeper.conf" <<EOF
cwd=/tmp/fm-durable-watch-fixture-work
prompt=$FM_TEST_TMPDIR/keeper-prompt.md
backend_url=http://127.0.0.1:$port
poll_seconds=1
EOF
FM_HOME="$home" bash "$HOST_BIN" send keeper "cycle one steer" >/dev/null
out=$(FM_HOME="$home" bash "$HOST_BIN" arm keeper --once 2>&1)
expect_code 0 "$?" "arm --once drains and exits 0"
assert_present "$home/state/durable-watchers/keeper.inbox/handled/0001.msg" "drained message is acknowledged by move"
assert_contains "$(cat "$fixstate/submissions.jsonl")" '"requestId": "pf-0001"' "message id maps to pf-<msgid> requestId"
assert_contains "$(cat "$fixstate/submissions.jsonl")" '"whenBusy": "steer"' "steer submission uses whenBusy steer"
assert_grep 'cycle one steer' "$fixstate/submissions.jsonl" "message body reaches the backend"
assert_grep 'Keeper policy: keep the board current.' "$fixstate/config.jsonl" "instructions carry the prompt file body"
# Redeliver the same message id: the identical requestId must be replayed, not
# re-admitted as a new run.
cp "$home/state/durable-watchers/keeper.inbox/handled/0001.msg" "$home/state/durable-watchers/keeper.inbox/0001.msg"
FM_HOME="$home" bash "$HOST_BIN" arm keeper --once >/dev/null 2>&1
count=$(grep -c -F '"requestId": "pf-0001"' "$fixstate/submissions.jsonl")
assert_equals 2 "$count" "repeated delivery reuses the identical requestId (admitted once by the backend)"
pass "host: stable requestId mapping across repeated delivery"

# --- 6. bench: argument refusals and table rendering -------------------------
out=$(FM_HOME="$home" bash "$BENCH_BIN" --cycles zero 2>&1)
expect_code 2 "$?" "bench bad --cycles exits 2"
assert_contains "$out" "--cycles" "bench refusal names the flag"

evA=$FM_TEST_TMPDIR/ev-baseline.json
evB=$FM_TEST_TMPDIR/ev-durable.json
cat > "$evA" <<'EOF'
{"mode":"faux","cycles":4,"totals":{"input":400,"cacheRead":1200,"totalTokens":1700,"wallMs":900},"perCycle":[{"cycle":1,"wallMs":200,"tokens":{"input":100,"cacheRead":100,"totalTokens":220}},{"cycle":2,"wallMs":220,"tokens":{"input":150,"cacheRead":200,"totalTokens":380}},{"cycle":3,"wallMs":230,"tokens":{"input":200,"cacheRead":300,"totalTokens":520}},{"cycle":4,"wallMs":250,"tokens":{"input":250,"cacheRead":400,"totalTokens":670}}],"restarts":[{"cycle":2,"recoveryMs":900,"steersAnswered":0,"steersMissed":1}],"finalActiveEntries":9,"steers":{"submitted":4,"answered":3,"missed":1}}
EOF
cat > "$evB" <<'EOF'
{"mode":"faux","cycles":4,"totals":{"input":260,"cacheRead":1800,"totalTokens":1400,"wallMs":860},"perCycle":[{"cycle":1,"wallMs":210,"tokens":{"input":100,"cacheRead":100,"totalTokens":220}},{"cycle":2,"wallMs":210,"tokens":{"input":80,"cacheRead":500,"totalTokens":600}},{"cycle":3,"wallMs":220,"tokens":{"input":80,"cacheRead":600,"totalTokens":580}},{"cycle":4,"wallMs":220,"tokens":{"input":80,"cacheRead":700,"totalTokens":600}}],"restarts":[{"cycle":2,"recoveryMs":300,"steersAnswered":1,"steersMissed":0}],"finalActiveEntries":4,"steers":{"submitted":4,"answered":4,"missed":0}}
EOF
out=$(bash "$BENCH_BIN" render "$evA" "$evB" 2>&1)
expect_code 0 "$?" "render exits 0"
assert_contains "$out" "baseline" "table has a baseline column"
assert_contains "$out" "durable" "table has a durable column"
for row in "tokens/cycle" "wall time/cycle" "context growth" "restart recovery" "steer delivery"; do
  assert_contains "$out" "$row" "table has the $row row"
done
pass "bench: plain comparison table renders from recorded evidence"

# --- 7. bench: occupied port refusal -----------------------------------------
out=$(FM_HOME="$home" bash "$BENCH_BIN" --cycles 2 --port "$port" 2>&1)
expect_code 2 "$?" "bench refuses an occupied port"
assert_contains "$out" "port" "port refusal names the port"
pass "bench: refuses an occupied port without touching it"

printf 'All durable-watcher contract tests passed.\n'
