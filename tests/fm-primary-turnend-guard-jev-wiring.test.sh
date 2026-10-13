#!/usr/bin/env bash
# Wiring tests for the Jev gate seat in .pi/extensions/fm-primary-turnend-guard.ts.
#
# Owns WIRE-1..12 and the wiring half of the O suite (GATE-O1..O5, GATE-O8,
# GATE-O9) per plan v2 §12.10/§12.9. Node-import harness in the
# fm-calm-pi-extension pattern: a fixture project holds a copy of the modified
# extension with a fake `pi` object capturing handlers, recording fakes for
# cd/arm/gate reachable through the existing fixture-bin mechanism and the
# FM_JEV_GATE_CHECK seam, and - for the real-stack O rows - real copies of the
# gate transport and policy against a recording fake screener. No case touches
# the network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-jev-wiring)
W_PROJ="$TMP_ROOT/project"
W_BIN="$W_PROJ/bin"
W_STATE="$TMP_ROOT/state"
W_CONFIG="$TMP_ROOT/config"
W_LOG="$TMP_ROOT/log"
W_SCREENER="$TMP_ROOT/fake-screener.sh"
BASE_PATH=$PATH
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
TRANSPORT_SRC="$ROOT/bin/fm-jev-pretool-check.sh"
POLICY_SRC="$ROOT/bin/fm-jev-gate-policy.mjs"

if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  echo "skip: node or npm not found for the Jev wiring suite"
  exit 0
fi
if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
  echo "skip: installed @earendil-works/pi-coding-agent package not found"
  exit 0
fi

mkdir -p \
  "$W_PROJ/.pi/extensions/lib" \
  "$W_PROJ/node_modules/@earendil-works" \
  "$W_BIN" "$W_STATE" "$W_CONFIG" "$W_LOG"

cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" \
  "$W_PROJ/.pi/extensions/fm-primary-turnend-guard.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" \
  "$W_PROJ/.pi/extensions/lib/fm-operational-input.ts"
ln -s "$PI_PACKAGE_DIR" "$W_PROJ/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" \
  "$W_PROJ/node_modules/@earendil-works/pi-tui" 2>/dev/null || true
ln -s "$PI_PACKAGE_DIR/node_modules/typebox" \
  "$W_PROJ/node_modules/typebox" 2>/dev/null || true
printf '%s\n' '{"type":"module"}' > "$W_PROJ/package.json"

# The fixture is a miniature plain firstmate checkout so the real transport
# stack passes its scope guard in the O rows.
fm_git_init_commit "$W_PROJ"
printf '# fixture\n' > "$W_PROJ/AGENTS.md"

# ---- recording fakes -----------------------------------------------------------

cat > "$W_BIN/fm-cd-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
mkdir -p "${WIRE_LOG:?}"
printf '%s\n' "$*" >> "${WIRE_LOG:?}/cd.calls"
if [ "${FAKE_CD_EXIT:-0}" = "2" ]; then
  printf 'denied by the cd-guard PreToolUse seatbelt\n' >&2
  exit 2
fi
exit 0
SH

cat > "$W_BIN/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
mkdir -p "${WIRE_LOG:?}"
printf '%s\n' "$*" >> "${WIRE_LOG:?}/arm.calls"
if [ "${FAKE_ARM_EXIT:-0}" = "2" ]; then
  printf 'denied by the watcher-arm PreToolUse seatbelt\n' >&2
  exit 2
fi
exit 0
SH

cat > "$W_BIN/gate-stub.sh" <<'SH'
#!/usr/bin/env bash
# Stub gate transport: records stdin, argv, and the seat-set override/cache
# env, then answers per FAKE_GATE_* controls.
set -u
log="${WIRE_LOG:?}"
mkdir -p "$log"
cat > "$log/gate.stdin.last"
{
  printf 'args:'
  printf ' %s' "$@"
  printf '\noverride: %s\n' "${FM_JEV_GATE_OVERRIDE:-}"
  printf 'cache: %s\n' "${FM_JEV_GATE_CACHE:-}"
} >> "$log/gate.calls"
printf '%s\n' "$$" > "$log/gate.pid"
[ -n "${FAKE_GATE_SLEEP:-}" ] && sleep "${FAKE_GATE_SLEEP}"
if [ "${FM_JEV_GATE_OVERRIDE:-}" = "1" ]; then
  exit 0
fi
if [ "${FAKE_GATE_EXIT:-0}" = "2" ]; then
  printf '[JG-R1] stub deny (stage: regex, confidence: 1.00)\n' >&2
  exit 2
fi
exit 0
SH
chmod +x "$W_BIN/fm-cd-pretool-check.sh" "$W_BIN/fm-arm-pretool-check.sh" \
  "$W_BIN/gate-stub.sh"

cat > "$W_SCREENER" <<'SH'
#!/usr/bin/env bash
set -u
log="${WIRE_LOG:?}"
mkdir -p "$log"
: >> "${WIRE_LOG:?}/screen.calls"
[ -n "${1:-}" ] && cp "$1" "$log/screen.input"
if [ "${FAKE_SCREEN_MODE:-}" = "sleep" ]; then
  sleep "${FAKE_SCREEN_SLEEP_SECS:-30}"
fi
printf 'command:\n  status: clear\n  choice: %s\n  confidence: %s\n  latency_ms: 12\n  tokens: 100/20\n' \
  "${FAKE_SCREEN_CHOICE:-benign}" "${FAKE_SCREEN_CONF:-0.95}"
SH
chmod +x "$W_SCREENER"

reset_wire_log() {
  rm -rf "$W_LOG"
  mkdir -p "$W_LOG"
}

arm_activation() {   # arm_activation [value]
  printf '%s\n' "${1:-enforce}" > "$W_CONFIG/jev-gate"
}

disarm_activation() {
  rm -f "$W_CONFIG/jev-gate"
}

# wire_run <js-file>: run a scenario file inside the fixture project.
wire_run() {
  (cd "$W_PROJ" && WIRE_EXT="$W_PROJ/.pi/extensions/fm-primary-turnend-guard.ts" \
    WIRE_LOG="$W_LOG" node "$1" 2> "$TMP_ROOT/node-err")
}

# scenario <name> <js-body-file>: copy the body over scenario.mjs and run it.
scenario() {
  cp "$2" "$W_PROJ/scenario.mjs"
  wire_run "$W_PROJ/scenario.mjs"
}

cat > "$TMP_ROOT/preamble.js" <<'JS'
import { pathToFileURL } from "node:url";

export async function load() {
  const ext = await import(
    `${pathToFileURL(process.env.WIRE_EXT).href}?v=${Date.now()}-${Math.random()}`
  );
  const handlers = new Map();
  const commands = new Map();
  const pi = {
    events: { emit() {}, on() {} },
    on(event, handler) {
      if (event === "tool_call" || event === "session_shutdown") {
        handlers.set(event, handler);
      }
    },
    registerCommand(name, cmd) {
      commands.set(name, cmd);
    },
    sendMessage() {},
    sendUserMessage() {},
  };
  ext.default(pi);
  return { handlers, commands };
}

export async function callTool(handlers, toolName, command) {
  const h = handlers.get("tool_call");
  if (!h) return { missing: "tool_call handler" };
  try {
    return await h({ type: "tool_call", toolName, input: { command } }, {});
  } catch (error) {
    return { threw: String((error && error.message) || error) };
  }
}

export async function fireShutdown(handlers) {
  const h = handlers.get("session_shutdown");
  if (!h) return { missing: "session_shutdown handler" };
  try {
    return await h({}, {});
  } catch (error) {
    return { threw: String((error && error.message) || error) };
  }
}
JS

cat "$TMP_ROOT/preamble.js" > "$W_PROJ/preamble.mjs"

# common env for every run: state/config isolation plus the checker fakes.
wire_env() {
  printf '%s\n' \
    "FM_STATE_OVERRIDE=$W_STATE" \
    "FM_CONFIG_OVERRIDE=$W_CONFIG" \
    "WIRE_LOG=$W_LOG"
}

echo "1..19"

# ---- WIRE rows (stub gate) -----------------------------------------------------

# WIRE-1: activation present; bash rm -rf / with a denying gate fake ->
# {block:true, reason}, and the fake recorded the exact command on stdin.
{
  reset_wire_log
  arm_activation
  cat > "$TMP_ROOT/w1.js" <<'JS'
import { load, callTool } from "./preamble.mjs";
const { handlers } = await load();
const result = await callTool(handlers, "bash", "rm -rf /");
console.log(JSON.stringify(result));
JS
  FAKE_GATE_EXIT=2 FM_JEV_GATE_CHECK="$W_BIN/gate-stub.sh" \
    scenario w1 "$TMP_ROOT/w1.js" > "$TMP_ROOT/w1-out"
  jq -e '.block == true' "$TMP_ROOT/w1-out" >/dev/null \
    || fail "WIRE-1: handler did not block"
  reason=$(jq -r '.reason // ""' "$TMP_ROOT/w1-out")
  assert_contains "$reason" "stub deny" "WIRE-1 reason from the gate fake"
  assert_contains "$(cat "$W_LOG/gate.stdin.last")" "rm -rf /" "WIRE-1 command on stdin"
  pass "WIRE-1: denying gate transport blocks with its reason"
}

# WIRE-2: activation absent -> {} and the gate fake is never spawned.
{
  reset_wire_log
  disarm_activation
  cat > "$TMP_ROOT/w2.js" <<'JS'
import { load, callTool } from "./preamble.mjs";
const { handlers } = await load();
const result = await callTool(handlers, "bash", "rm -rf /");
console.log(JSON.stringify(result));
JS
  FM_JEV_GATE_CHECK="$W_BIN/gate-stub.sh" scenario w2 "$TMP_ROOT/w2.js" > "$TMP_ROOT/w2-out"
  jq -e 'length == 0' "$TMP_ROOT/w2-out" >/dev/null || fail "WIRE-2: handler not silent"
  [ ! -s "$W_LOG/gate.calls" ] || fail "WIRE-2: gate fake was spawned"
  pass "WIRE-2: disarmed pilot never spawns the gate"
}

# WIRE-3: a read tool call never spawns the gate.
{
  reset_wire_log
  arm_activation
  cat > "$TMP_ROOT/w3.js" <<'JS'
import { load, callTool } from "./preamble.mjs";
const { handlers } = await load();
const result = await callTool(handlers, "read", "some/file");
console.log(JSON.stringify(result));
JS
  FAKE_GATE_EXIT=2 FM_JEV_GATE_CHECK="$W_BIN/gate-stub.sh" \
    scenario w3 "$TMP_ROOT/w3.js" > "$TMP_ROOT/w3-out"
  jq -e 'length == 0' "$TMP_ROOT/w3-out" >/dev/null || fail "WIRE-3: handler not silent"
  [ ! -s "$W_LOG/gate.calls" ] || fail "WIRE-3: gate fake was spawned"
  pass "WIRE-3: non-bash tools skip the gate"
}

# WIRE-4: a bash call with an empty command spawns nothing.
{
  reset_wire_log
  arm_activation
  cat > "$TMP_ROOT/w4.js" <<'JS'
import { load, callTool } from "./preamble.mjs";
const { handlers } = await load();
const result = await callTool(handlers, "bash", "");
console.log(JSON.stringify(result));
JS
  FAKE_GATE_EXIT=2 FM_JEV_GATE_CHECK="$W_BIN/gate-stub.sh" \
    scenario w4 "$TMP_ROOT/w4.js" > "$TMP_ROOT/w4-out"
  jq -e 'length == 0' "$TMP_ROOT/w4-out" >/dev/null || fail "WIRE-4: handler not silent"
  [ ! -s "$W_LOG/gate.calls" ] || fail "WIRE-4: gate fake was spawned"
  pass "WIRE-4: empty command spawns nothing"
}

# WIRE-5: gate fake exits 0 -> {} (no block, no error).
{
  reset_wire_log
  arm_activation
  cat > "$TMP_ROOT/w5.js" <<'JS'
import { load, callTool } from "./preamble.mjs";
const { handlers } = await load();
const result = await callTool(handlers, "bash", "ls -la");
console.log(JSON.stringify(result));
JS
  FAKE_GATE_EXIT=0 FM_JEV_GATE_CHECK="$W_BIN/gate-stub.sh" \
    scenario w5 "$TMP_ROOT/w5.js" > "$TMP_ROOT/w5-out"
  jq -e 'length == 0' "$TMP_ROOT/w5-out" >/dev/null || fail "WIRE-5: handler not silent"
  pass "WIRE-5: allowing gate transport keeps the call silent"
}

# WIRE-6: a nonexistent gate transport fails open to {}.
{
  reset_wire_log
  arm_activation
  cat > "$TMP_ROOT/w6.js" <<'JS'
import { load, callTool } from "./preamble.mjs";
const { handlers } = await load();
const result = await callTool(handlers, "bash", "rm -rf /");
console.log(JSON.stringify(result));
JS
  FM_JEV_GATE_CHECK=/nonexistent/gate.sh scenario w6 "$TMP_ROOT/w6.js" > "$TMP_ROOT/w6-out"
  jq -e 'length == 0' "$TMP_ROOT/w6-out" >/dev/null \
    || fail "WIRE-6: broken gate path did not fail open"
  pass "WIRE-6: broken gate transport fails open"
}

# WIRE-7: a blocking cd fake short-circuits before the gate fake spawns.
{
  reset_wire_log
  arm_activation
  cat > "$TMP_ROOT/w7.js" <<'JS'
import { load, callTool } from "./preamble.mjs";
const { handlers } = await load();
const result = await callTool(handlers, "bash", "cd /somewhere");
console.log(JSON.stringify(result));
JS
  FAKE_CD_EXIT=2 FAKE_GATE_EXIT=2 FM_JEV_GATE_CHECK="$W_BIN/gate-stub.sh" \
    scenario w7 "$TMP_ROOT/w7.js" > "$TMP_ROOT/w7-out"
  jq -e '.block == true' "$TMP_ROOT/w7-out" >/dev/null || fail "WIRE-7: not blocked"
  reason=$(jq -r '.reason // ""' "$TMP_ROOT/w7-out")
  assert_contains "$reason" "cd-guard" "WIRE-7 reason from the cd fake"
  [ ! -s "$W_LOG/gate.calls" ] || fail "WIRE-7: gate fake spawned after a cd block"
  pass "WIRE-7: seat ordering short-circuits at the cd guard"
}

# WIRE-8: the override window dies with the session; no authority file remains.
{
  reset_wire_log
  arm_activation
  cat > "$TMP_ROOT/w8.js" <<'JS'
import { load, callTool, fireShutdown } from "./preamble.mjs";
const { handlers, commands } = await load();
const cmd = commands.get("jev-override");
if (!cmd) throw new Error("jev-override not registered");
await cmd.handler("--reason wiring check", {});
await fireShutdown(handlers);
const result = await callTool(handlers, "bash", "rm -rf /");
console.log(JSON.stringify(result));
JS
  FAKE_GATE_EXIT=2 FM_JEV_GATE_CHECK="$W_BIN/gate-stub.sh" \
    scenario w8 "$TMP_ROOT/w8.js" > "$TMP_ROOT/w8-out"
  jq -e '.block == true' "$TMP_ROOT/w8-out" >/dev/null \
    || fail "WIRE-8: a fresh session must block again"
  tail -n 3 "$W_LOG/gate.calls" > "$TMP_ROOT/w8-tail" || true
  assert_not_contains "$(cat "$TMP_ROOT/w8-tail" 2>/dev/null)" "override: 1" \
    "WIRE-8 override flag after shutdown"
  if ls "$W_STATE/jev-gate/" 2>/dev/null | grep -qi 'override'; then
    fail "WIRE-8: an override file survived shutdown"
  fi
  pass "WIRE-8: in-memory window dies with the session"
}

# WIRE-9: a multi-line command reaches the gate fake byte-exact on stdin.
{
  reset_wire_log
  arm_activation
  cat > "$TMP_ROOT/w9.js" <<'JS'
import { load, callTool } from "./preamble.mjs";
const { handlers } = await load();
const result = await callTool(handlers, "bash", "ls\nrm -rf /etc");
console.log(JSON.stringify(result));
JS
  FAKE_GATE_EXIT=2 FM_JEV_GATE_CHECK="$W_BIN/gate-stub.sh" \
    scenario w9 "$TMP_ROOT/w9.js" > "$TMP_ROOT/w9-out"
  jq -e '.block == true' "$TMP_ROOT/w9-out" >/dev/null || fail "WIRE-9: not blocked"
  assert_contains "$(cat "$W_LOG/gate.stdin.last")" "$(printf 'ls\nrm -rf /etc')" \
    "WIRE-9 exact multi-line stdin"
  pass "WIRE-9: multi-line command delivered byte-exact"
}

# WIRE-10: a foreign live lock holder suppresses the gate seat.
{
  reset_wire_log
  arm_activation
  sleep 30 &
  foreign_pid=$!
  printf '%s\n' "$foreign_pid" > "$W_STATE/.lock"
  cat > "$TMP_ROOT/w10.js" <<'JS'
import { load, callTool } from "./preamble.mjs";
const { handlers } = await load();
const result = await callTool(handlers, "bash", "rm -rf /");
console.log(JSON.stringify(result));
JS
  FAKE_GATE_EXIT=2 FM_JEV_GATE_CHECK="$W_BIN/gate-stub.sh" \
    scenario w10 "$TMP_ROOT/w10.js" > "$TMP_ROOT/w10-out"
  [ ! -s "$W_LOG/gate.calls" ] || fail "WIRE-10: gate spawned despite a foreign lock"
  kill "$foreign_pid" 2>/dev/null || true
  wait "$foreign_pid" 2>/dev/null || true
  pass "WIRE-10: foreign lock holder keeps the seat out"
}

# WIRE-11: a gate fake that ignores stdin and sleeps forever cannot wedge the
# tool path - the seat's wall clock kills it and the handler returns {}.
{
  reset_wire_log
  arm_activation
  cat > "$TMP_ROOT/w11.js" <<'JS'
import { load, callTool } from "./preamble.mjs";
const { handlers } = await load();
const t0 = Date.now();
const result = await callTool(handlers, "bash", "rm -rf /");
console.log(JSON.stringify({ result, elapsed: Date.now() - t0 }));
JS
  FAKE_GATE_EXIT=2 FAKE_GATE_SLEEP=60 FM_JEV_GATE_WALL_MS=1500 \
    FM_JEV_GATE_CHECK="$W_BIN/gate-stub.sh" \
    scenario w11 "$TMP_ROOT/w11.js" > "$TMP_ROOT/w11-out"
  jq -e '(.result | length) == 0 and .elapsed < 10000' "$TMP_ROOT/w11-out" >/dev/null \
    || fail "WIRE-11: hung gate wedged the tool path"
  gate_pid=$(cat "$W_LOG/gate.pid" 2>/dev/null || true)
  if [ -n "$gate_pid" ]; then
    for i in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$gate_pid" 2>/dev/null || break
      sleep 0.2
    done
    if kill -0 "$gate_pid" 2>/dev/null; then
      kill -9 "$gate_pid" 2>/dev/null || true
      fail "WIRE-11: hung gate child survived the wall clock"
    fi
  fi
  pass "WIRE-11: wall-clock kill keeps the tool path alive"
}

# WIRE-12: /jev-override registers exactly once, requires a reason, and opens
# the in-memory window.
{
  reset_wire_log
  arm_activation
  cat > "$TMP_ROOT/w12.js" <<'JS'
import { load, callTool } from "./preamble.mjs";
const { handlers, commands } = await load();
if (commands.size !== 1 || !commands.has("jev-override")) {
  throw new Error(`expected only jev-override, got: ${[...commands.keys()].join(",")}`);
}
const cmd = commands.get("jev-override");
await cmd.handler("", {});
await callTool(handlers, "bash", "rm -rf /");
await cmd.handler("--reason real reason", {});
await callTool(handlers, "bash", "rm -rf /");
console.log(JSON.stringify({ ok: true }));
JS
  FAKE_GATE_EXIT=2 FM_JEV_GATE_CHECK="$W_BIN/gate-stub.sh" \
    scenario w12 "$TMP_ROOT/w12.js" > "$TMP_ROOT/w12-out" \
    || fail "WIRE-12: scenario threw"
  override_lines=$(grep -c '^override: 1$' "$W_LOG/gate.calls" 2>/dev/null || true)
  [ "$override_lines" -eq 1 ] \
    || fail "WIRE-12: expected exactly one gated call with the override flag"
  pass "WIRE-12: operator-only command requires a reason and opens the window"
}

# ---- GATE O rows (real transport + policy + fake screener) ----------------------

REAL_STACK_ENV=(FM_JEV_GATE_CHECK="$W_BIN/fm-jev-pretool-check.sh"
  FM_JEV_COMMAND_SCREENER="$W_SCREENER")

# GATE-O1: block, then the operator opens the window, then the same command
# allows - with override_pass, overridden_block, and both audit events.
{
  reset_wire_log
  arm_activation
  cp "$TRANSPORT_SRC" "$W_BIN/fm-jev-pretool-check.sh"
  cp "$POLICY_SRC" "$W_BIN/fm-jev-gate-policy.mjs"
  cat > "$TMP_ROOT/o1.js" <<'JS'
import { load, callTool } from "./preamble.mjs";
const { handlers, commands } = await load();
const first = await callTool(handlers, "bash", "rm -rf /");
await commands.get("jev-override").handler("--reason o1 check", {});
const second = await callTool(handlers, "bash", "rm -rf /");
console.log(JSON.stringify({ first, second }));
JS
  env "${REAL_STACK_ENV[@]}" scenario o1 "$TMP_ROOT/o1.js" > "$TMP_ROOT/o1-out"
  jq -e '.first.block == true and (".second.block" | length) >= 0' "$TMP_ROOT/o1-out" >/dev/null \
    || fail "GATE-O1: first call did not block"
  jq -e '(.second.block | not) and (.second.threw | not)' "$TMP_ROOT/o1-out" >/dev/null \
    || fail "GATE-O1: second call did not allow"
  assert_equals "1" "$(awk '$1=="override_pass"{print $2}' "$W_STATE/jev-gate/counters")" \
    "GATE-O1 override_pass"
  assert_equals "1" "$(awk '$1=="overridden_block"{print $2}' "$W_STATE/jev-gate/counters")" \
    "GATE-O1 overridden_block"
  grep -q 'override_open' "$W_STATE/jev-gate/events.jsonl" \
    || fail "GATE-O1: override_open event missing"
  grep -q 'override_pass' "$W_STATE/jev-gate/events.jsonl" \
    || fail "GATE-O1: override_pass event missing"
  pass "GATE-O1: operator window turns a block into a logged pass"
}

# GATE-O2: `off` closes the window; the same command blocks again.
{
  reset_wire_log
  arm_activation
  cat > "$TMP_ROOT/o2.js" <<'JS'
import { load, callTool } from "./preamble.mjs";
const { handlers, commands } = await load();
await commands.get("jev-override").handler("--reason o2 check", {});
const open = await callTool(handlers, "bash", "rm -rf /");
await commands.get("jev-override").handler("off", {});
const closed = await callTool(handlers, "bash", "rm -rf /");
console.log(JSON.stringify({ open, closed }));
JS
  env "${REAL_STACK_ENV[@]}" scenario o2 "$TMP_ROOT/o2.js" > "$TMP_ROOT/o2-out"
  jq -e '(.open.block | not) and .closed.block == true' "$TMP_ROOT/o2-out" >/dev/null \
    || fail "GATE-O2: window did not close"
  grep -q 'override_close' "$W_STATE/jev-gate/events.jsonl" \
    || fail "GATE-O2: override_close event missing"
  pass "GATE-O2: off closes the window and blocks resume"
}

# GATE-O3: shutdown kills the window; a fresh session blocks again and no
# override authority file exists.
{
  reset_wire_log
  arm_activation
  cat > "$TMP_ROOT/o3.js" <<'JS'
import { load, callTool, fireShutdown } from "./preamble.mjs";
const { handlers, commands } = await load();
await commands.get("jev-override").handler("--reason o3 check", {});
await fireShutdown(handlers);
const after = await callTool(handlers, "bash", "rm -rf /");
console.log(JSON.stringify({ after }));
JS
  env "${REAL_STACK_ENV[@]}" scenario o3 "$TMP_ROOT/o3.js" > "$TMP_ROOT/o3-out"
  jq -e '.after.block == true' "$TMP_ROOT/o3-out" >/dev/null \
    || fail "GATE-O3: fresh session did not block"
  if ls "$W_STATE/jev-gate/" 2>/dev/null | grep -qi 'override'; then
    fail "GATE-O3: override authority file present after shutdown"
  fi
  pass "GATE-O3: no window file survives the session"
}

# GATE-O4: an override flag from a bare shell affects only that invocation.
{
  reset_wire_log
  arm_activation
  set +e
  direct_out=$(printf 'rm -rf /' | FM_JEV_GATE_OVERRIDE=1 "$W_BIN/gate-stub.sh" 2>/dev/null)
  direct_code=$?
  set -e
  expect_code 0 "$direct_code" "GATE-O4 direct invocation"
  cat > "$TMP_ROOT/o4.js" <<'JS'
import { load, callTool } from "./preamble.mjs";
const { handlers } = await load();
const result = await callTool(handlers, "bash", "rm -rf /");
console.log(JSON.stringify(result));
JS
  FAKE_GATE_EXIT=2 FM_JEV_GATE_CHECK="$W_BIN/gate-stub.sh" \
    scenario o4 "$TMP_ROOT/o4.js" > "$TMP_ROOT/o4-out"
  jq -e '.block == true' "$TMP_ROOT/o4-out" >/dev/null \
    || fail "GATE-O4: shell flag opened the seat window"
  assert_not_contains "$(tail -n 3 "$W_LOG/gate.calls")" "override: 1" \
    "GATE-O4 seat did not pass the flag"
  pass "GATE-O4: authority stays in the seat's memory"
}

# GATE-O5: a block reason surfaced to the model carries no override recipe.
{
  reset_wire_log
  arm_activation
  cat > "$TMP_ROOT/o5.js" <<'JS'
import { load, callTool } from "./preamble.mjs";
const { handlers } = await load();
const result = await callTool(handlers, "bash", "rm -rf /");
console.log(JSON.stringify(result));
JS
  env "${REAL_STACK_ENV[@]}" scenario o5 "$TMP_ROOT/o5.js" > "$TMP_ROOT/o5-out"
  reason=$(jq -r '.reason // ""' "$TMP_ROOT/o5-out")
  [ -n "$reason" ] || fail "GATE-O5: no block reason"
  assert_not_contains "$reason" "override" "GATE-O5 no override word"
  assert_not_contains "$reason" "jev-override" "GATE-O5 no command recipe"
  pass "GATE-O5: deny text teaches nothing about bypassing"
}

# GATE-O8: a 30-minute window publishes reason and remaining TTL to status.
{
  reset_wire_log
  arm_activation
  cat > "$TMP_ROOT/o8.js" <<'JS'
import { load } from "./preamble.mjs";
const { commands } = await load();
await commands.get("jev-override").handler("--ttl 30 --reason expensive cleanup approved", {});
console.log(JSON.stringify({ ok: true }));
JS
  env "${REAL_STACK_ENV[@]}" scenario o8 "$TMP_ROOT/o8.js" > "$TMP_ROOT/o8-out" \
    || fail "GATE-O8: opening the window failed"
  status_out=$(FM_HOME="$W_PROJ" FM_STATE_OVERRIDE="$W_STATE" \
    "$ROOT/bin/fm-jev-gate-override.sh" status 2>&1)
  assert_contains "$status_out" "expensive cleanup approved" "GATE-O8 reason"
  assert_contains "$status_out" "30" "GATE-O8 remaining TTL"
  pass "GATE-O8: seat-published view shows reason and TTL"
}

# GATE-O9: during the window a marker command allows without consulting Jev;
# the event records the skipped consult.
{
  reset_wire_log
  arm_activation
  cat > "$TMP_ROOT/o9.js" <<'JS'
import { load, callTool } from "./preamble.mjs";
const { handlers, commands } = await load();
await commands.get("jev-override").handler("--reason o9 check", {});
const result = await callTool(handlers, "bash", "sudo apt-get upgrade");
console.log(JSON.stringify(result));
JS
  FAKE_SCREEN_CHOICE=destructive FAKE_SCREEN_CONF=0.95 \
    env "${REAL_STACK_ENV[@]}" scenario o9 "$TMP_ROOT/o9.js" > "$TMP_ROOT/o9-out"
  jq -e '(.block | not)' "$TMP_ROOT/o9-out" >/dev/null \
    || fail "GATE-O9: marker command blocked during the window"
  [ ! -s "$W_LOG/screen.calls" ] || fail "GATE-O9: screener consulted during the window"
  override_event=$(grep 'override_pass' "$W_STATE/jev-gate/events.jsonl" | tail -n 1)
  [ -n "$override_event" ] || fail "GATE-O9: override_pass event missing"
  printf '%s\n' "$override_event" > "$TMP_ROOT/o9-event"
  jq -e '.stage == "override" and (.choice == null)' "$TMP_ROOT/o9-event" >/dev/null \
    || fail "GATE-O9: event stage/choice mismatch"
  pass "GATE-O9: window pass skips the consult and logs the unknown"
}

echo "All tests complete."
