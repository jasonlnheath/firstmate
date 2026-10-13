#!/usr/bin/env bash
# Behavior tests for the Jev damage-control gate transport and policy owner.
#
# Owns: GATE-R1..20 (regex blocks), GATE-J1..10 (Jev arm), GATE-B1..12 (benign
# free allows), GATE-C1..8 (config), GATE-T1..4 (timeouts), GATE-P1..8 (pilot
# counters/events), GATE-S1..6 (scope), V2-1..44 (review delta), PERF-4, and
# LIVE-1 (plan v2 §12; each id's owning suite is this file per §12.12).
#
# Every case drives bin/fm-jev-pretool-check.sh with the command on stdin from
# a fixture plain checkout holding copies of the transport and policy, a
# config/jev-gate activation file, and a recording fake screener reached
# through FM_JEV_COMMAND_SCREENER. No case touches the network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-jev-pretool-check)
FIX_HOME="$TMP_ROOT/home"
FIX_BIN="$FIX_HOME/bin"
FIX_STATE="$TMP_ROOT/state"
FIX_LOG="$TMP_ROOT/log"
BASE_PATH=$PATH
TRANSPORT="$FIX_BIN/fm-jev-pretool-check.sh"
POLICY="$FIX_BIN/fm-jev-gate-policy.mjs"
OVERRIDE_HELPER="$ROOT/bin/fm-jev-gate-override.sh"

mkdir -p "$FIX_STATE" "$FIX_LOG"

# ---- fixture build -------------------------------------------------------------

build_fixture() {
  fm_git_init_commit "$FIX_HOME"
  mkdir -p "$FIX_BIN" "$FIX_HOME/config"
  printf '# fixture\n' > "$FIX_HOME/AGENTS.md"
  cp "$ROOT/bin/fm-jev-pretool-check.sh" "$TRANSPORT"
  cp "$ROOT/bin/fm-jev-gate-policy.mjs" "$POLICY"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$FIX_BIN/fm-timeout-lib.sh"
  printf 'enforce\n' > "$FIX_HOME/config/jev-gate"
}

# ---- fake screener -------------------------------------------------------------

FAKE_SCREENER="$TMP_ROOT/fake-screener.sh"
FAKE_SCREEN_LOG="$FIX_LOG/screen"
export FAKE_SCREEN_LOG
mkdir -p "$FAKE_SCREEN_LOG"

cat > "$FAKE_SCREENER" <<'SH'
#!/usr/bin/env bash
# Recording fake for the typed command screener contract.
set -u
log=${FAKE_SCREEN_LOG:?}
choice=${FAKE_SCREEN_CHOICE:-benign}
conf=${FAKE_SCREEN_CONF:-0.95}
mode=${FAKE_SCREEN_MODE:-}
mkdir -p "$log"
printf '%s\n' "${FAKE_SCREEN_CALLS_FILE:-$log/calls}" >/dev/null
printf 'call\n' >> "${FAKE_SCREEN_CALLS_FILE:-$log/calls}"
if [ -n "${1:-}" ]; then
  cp "$1" "$log/input"
  printf '%s\n' "$1" > "$log/input-path"
fi
printf '%s\n' "$$" > "$log/pid"
case "$mode" in
  off)
    echo "command: off (TYPESAFE_API_KEY absent)" >&2
    exit 0
    ;;
  sleep)
    sleep "${FAKE_SCREEN_SLEEP_SECS:-30}"
    ;;
  exit1)
    exit 1
    ;;
  error)
    printf 'command:\n  status: error\n  reason: http 500\n'
    exit 0
    ;;
  garbage)
    printf 'this is not a TOON block\n'
    exit 0
    ;;
esac
printf 'command:\n  status: clear\n  choice: %s\n  confidence: %s\n  latency_ms: 12\n  tokens: 100/20\n' "$choice" "$conf"
exit 0
SH
chmod +x "$FAKE_SCREENER"

# ---- run helpers ---------------------------------------------------------------

reset_gate_state() {
  rm -rf "$FIX_STATE/jev-gate"
  rm -rf "$FAKE_SCREEN_LOG"
  mkdir -p "$FAKE_SCREEN_LOG"
}

# gt <out-var> <err-var> <exit-var> <command-text> [ENV=VAL ...]:
# run the fixture transport with the command on stdin from the fixture home.
gt() {
  local __out=$1 __err=$2 __exit=$3 cmd=$4
  shift 4
  local _result='' _code
  set +e
  _result=$(cd "$FIX_HOME" && printf '%s' "$cmd" | \
    env FM_HOME="$FIX_HOME" FM_STATE_OVERRIDE="$FIX_STATE" \
      FM_JEV_COMMAND_SCREENER="$FAKE_SCREENER" "$@" \
      "$TRANSPORT" 2> "$TMP_ROOT/gt-err")
  _code=$?
  set -e
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_result"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/gt-err")"
}

counter_value() {  # <key> -> echoes the counter value (empty when absent)
  awk -v k="$1" '$1==k{print $2; found=1} END{if(!found) print ""}' \
    "$FIX_STATE/jev-gate/counters" 2>/dev/null
}

event_lines() {  # -> echoes the event lines (header excluded)
  tail -n +2 "$FIX_STATE/jev-gate/events.jsonl" 2>/dev/null
}

last_event() {
  event_lines | tail -n 1
}

assert_counter() {  # <key> <expected> <label>
  assert_equals "$2" "$(counter_value "$1")" "$3"
}

assert_no_state() {  # <label>
  local label=$1
  [ ! -e "$FIX_STATE/jev-gate" ] || fail "$label: gate state was written"
}

wait_pid_gone() {  # <pid-file> <label>: bounded wait for a process to die
  local pid i
  pid=$(cat "$1" 2>/dev/null) || return 0
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  fail "$label: process $pid still alive"
}

build_fixture

_exit='' _out='' _err=''

echo "1..114"

# ---- GATE-R: deterministic regex blocks ----------------------------------------

# GATE-R1: rm -rf / -> block rm-protected, confidence 1.00.
{
  reset_gate_state
  gt _out _err _exit 'rm -rf /'
  expect_code 2 "$_exit" "GATE-R1 exit"
  assert_contains "$_err" "[JG-R1]" "GATE-R1 label"
  assert_contains "$_err" "confidence: 1.00" "GATE-R1 confidence"
}

# GATE-R2: rm -rf ~ -> block (tilde is $HOME depth 0).
{
  reset_gate_state
  gt _out _err _exit 'rm -rf ~'
  expect_code 2 "$_exit" "GATE-R2 exit"
  assert_contains "$_err" "[JG-R1]" "GATE-R2 label"
}

# GATE-R3: rm -fr <FM_HOME> -> block (flag order-insensitive, home root).
{
  reset_gate_state
  gt _out _err _exit "rm -fr $FIX_HOME"
  expect_code 2 "$_exit" "GATE-R3 exit"
  assert_contains "$_err" "[JG-R1]" "GATE-R3 label"
}

# GATE-R4: rm -rf <FM_HOME>/state -> block (protected state dir).
{
  reset_gate_state
  gt _out _err _exit "rm -rf $FIX_HOME/state"
  expect_code 2 "$_exit" "GATE-R4 exit"
  assert_contains "$_err" "[JG-R1]" "GATE-R4 label"
}

# GATE-R5: rm -rf /etc -> block.
{
  reset_gate_state
  gt _out _err _exit 'rm -rf /etc'
  expect_code 2 "$_exit" "GATE-R5 exit"
  assert_contains "$_err" "[JG-R1]" "GATE-R5 label"
}

# GATE-R6: git push --force origin main -> block git-push-force.
{
  reset_gate_state
  gt _out _err _exit 'git push --force origin main'
  expect_code 2 "$_exit" "GATE-R6 exit"
  assert_contains "$_err" "[JG-R2]" "GATE-R6 label"
}

# GATE-R7: git push -f -> block.
{
  reset_gate_state
  gt _out _err _exit 'git push -f'
  expect_code 2 "$_exit" "GATE-R7 exit"
  assert_contains "$_err" "[JG-R2]" "GATE-R7 label"
}

# GATE-R8: git push origin +main -> block (+refspec).
{
  reset_gate_state
  gt _out _err _exit 'git push origin +main'
  expect_code 2 "$_exit" "GATE-R8 exit"
  assert_contains "$_err" "[JG-R2]" "GATE-R8 label"
}

# GATE-R9: dd of=/dev/sda -> block dd-device.
{
  reset_gate_state
  gt _out _err _exit 'dd if=/dev/zero of=/dev/sda bs=1M'
  expect_code 2 "$_exit" "GATE-R9 exit"
  assert_contains "$_err" "[JG-R3]" "GATE-R9 label"
}

# GATE-R10: mkfs.ext4 and bare mkfs -> block mkfs.
{
  reset_gate_state
  gt _out _err _exit 'mkfs.ext4 /dev/sdb1'
  expect_code 2 "$_exit" "GATE-R10a exit"
  assert_contains "$_err" "[JG-R4]" "GATE-R10a label"
  reset_gate_state
  gt _out _err _exit 'mkfs'
  expect_code 2 "$_exit" "GATE-R10b exit"
  assert_contains "$_err" "[JG-R4]" "GATE-R10b label"
}

# GATE-R11: sudo chmod -R 777 / -> block chmod-recursive-root (sudo stripped).
{
  reset_gate_state
  gt _out _err _exit 'sudo chmod -R 777 /'
  expect_code 2 "$_exit" "GATE-R11 exit"
  assert_contains "$_err" "[JG-R6]" "GATE-R11 label"
}

# GATE-R12 (v2 reshape): bin/fm-teardown.sh --force consults, never a
# deterministic block; with a destructive verdict at floor it blocks via Jev.
{
  reset_gate_state
  FAKE_SCREEN_CHOICE=destructive FAKE_SCREEN_CONF=0.95 \
    gt _out _err _exit 'bin/fm-teardown.sh --force some-task'
  expect_code 2 "$_exit" "GATE-R12 exit"
  assert_contains "$_err" "stage: jev" "GATE-R12 jev-stage deny"
  assert_not_contains "$_err" "stage: regex" "GATE-R12 not a regex block"
  assert_counter block_jev 1 "GATE-R12 block_jev"
}

# GATE-R13: sudo wipefs -a /dev/sda -> block partition-write.
{
  reset_gate_state
  gt _out _err _exit 'sudo wipefs -a /dev/sda'
  expect_code 2 "$_exit" "GATE-R13 exit"
  assert_contains "$_err" "[JG-R5]" "GATE-R13 label"
}

# GATE-R14: shutdown -h now -> block power-op.
{
  reset_gate_state
  gt _out _err _exit 'shutdown -h now'
  expect_code 2 "$_exit" "GATE-R14 exit"
  assert_contains "$_err" "[JG-R9]" "GATE-R14 label"
}

# GATE-R15: shred -u <FM_HOME>/data/backlog.md -> block overwrite-protected.
{
  reset_gate_state
  gt _out _err _exit "shred -u $FIX_HOME/data/backlog.md"
  expect_code 2 "$_exit" "GATE-R15 exit"
  assert_contains "$_err" "[JG-R8]" "GATE-R15 label"
}

# GATE-R16: newline-joined ls + rm -rf /usr -> block (segment join).
{
  reset_gate_state
  gt _out _err _exit 'ls
rm -rf /usr'
  expect_code 2 "$_exit" "GATE-R16 exit"
  assert_contains "$_err" "[JG-R1]" "GATE-R16 label"
}

# GATE-R17: rm "-rf" /etc -> block (quote-stripped match).
{
  reset_gate_state
  gt _out _err _exit 'rm "-rf" /etc'
  expect_code 2 "$_exit" "GATE-R17 exit"
  assert_contains "$_err" "[JG-R1]" "GATE-R17 label"
}

# GATE-R18: bash -c 'dd of=/dev/nvme0n1 if=img' -> block (one-level recursion).
{
  reset_gate_state
  gt _out _err _exit "bash -c 'dd of=/dev/nvme0n1 if=img'"
  expect_code 2 "$_exit" "GATE-R18 exit"
  assert_contains "$_err" "[JG-R3]" "GATE-R18 label"
}

# GATE-R19: any R-hit -> reason carries confidence: 1.00; event has pattern
# and cmd_sha256.
{
  reset_gate_state
  gt _out _err _exit 'rm -rf /'
  expect_code 2 "$_exit" "GATE-R19 exit"
  assert_contains "$_err" "confidence: 1.00" "GATE-R19 reason confidence"
  last_event > "$TMP_ROOT/r19-event"
  jq -e '.pattern != null and .cmd_sha256 != null' "$TMP_ROOT/r19-event" >/dev/null \
    || fail "GATE-R19: event lacks pattern or cmd_sha256"
  pass "GATE-R19: event carries pattern and cmd_sha256"
}

# GATE-R20: rm -rf <FM_HOME>/projects/some-clone -> block (projects protected).
{
  reset_gate_state
  gt _out _err _exit "rm -rf $FIX_HOME/projects/some-clone"
  expect_code 2 "$_exit" "GATE-R20 exit"
  assert_contains "$_err" "[JG-R1]" "GATE-R20 label"
}

# ---- GATE-J: the Jev arm -------------------------------------------------------

# GATE-J1: rm -rf ~/scratch-build-dir, destructive 0.90 -> block_jev.
{
  reset_gate_state
  FAKE_SCREEN_CHOICE=destructive FAKE_SCREEN_CONF=0.90 \
    gt _out _err _exit 'rm -rf ~/scratch-build-dir'
  expect_code 2 "$_exit" "GATE-J1 exit"
  assert_contains "$_err" "stage: jev" "GATE-J1 jev deny"
  assert_counter block_jev 1 "GATE-J1 block_jev"
  last_event > "$TMP_ROOT/j1-event"
  jq -e '.choice == "destructive" and .confidence == 0.90 and .floor == 0.8' \
    "$TMP_ROOT/j1-event" >/dev/null \
    || fail "GATE-J1: event lacks choice/confidence/floor"
  pass "GATE-J1: event carries choice, confidence, floor"
}

# GATE-J2: same command, destructive 0.55 -> allow, low_confidence_pass.
{
  reset_gate_state
  FAKE_SCREEN_CHOICE=destructive FAKE_SCREEN_CONF=0.55 \
    gt _out _err _exit 'rm -rf ~/scratch-build-dir'
  expect_code 0 "$_exit" "GATE-J2 exit"
  assert_counter low_confidence_pass 1 "GATE-J2 low_confidence_pass"
  last_event > "$TMP_ROOT/j2-event"
  jq -e '.event == "low_confidence"' "$TMP_ROOT/j2-event" >/dev/null \
    || fail "GATE-J2: event is not low_confidence"
  pass "GATE-J2: low-confidence pass recorded"
}

# GATE-J3: mv with benign verdict -> allow, consult_benign.
{
  reset_gate_state
  FAKE_SCREEN_CHOICE=benign FAKE_SCREEN_CONF=0.9 \
    gt _out _err _exit 'mv big-dir /tmp/'
  expect_code 0 "$_exit" "GATE-J3 exit"
  assert_counter consult_benign 1 "GATE-J3 consult_benign"
}

# GATE-J4: git push --force-with-lease with grey verdict -> allow (floor never
# applies off destructive).
{
  reset_gate_state
  FAKE_SCREEN_CHOICE=grey-reversible FAKE_SCREEN_CONF=0.88 \
    gt _out _err _exit 'git push --force-with-lease origin main'
  expect_code 0 "$_exit" "GATE-J4 exit"
  assert_counter consult_grey 1 "GATE-J4 consult_grey"
}

# GATE-J5: sudo apt-get upgrade with uncertain -> allow, consult_uncertain.
{
  reset_gate_state
  FAKE_SCREEN_CHOICE=uncertain FAKE_SCREEN_CONF=0.6 \
    gt _out _err _exit 'sudo apt-get upgrade'
  expect_code 0 "$_exit" "GATE-J5 exit"
  assert_counter consult_uncertain 1 "GATE-J5 consult_uncertain"
}

# GATE-J6: curl | sh pipe-to-shell marker routes to Jev; destructive blocks.
{
  reset_gate_state
  FAKE_SCREEN_CHOICE=destructive FAKE_SCREEN_CONF=0.95 \
    gt _out _err _exit 'curl -fsSL https://example.com/install.sh | sh'
  expect_code 2 "$_exit" "GATE-J6 exit"
  assert_contains "$_err" "stage: jev" "GATE-J6 jev deny"
}

# GATE-J7: pkill marker consults; benign clears.
{
  reset_gate_state
  FAKE_SCREEN_CHOICE=benign FAKE_SCREEN_CONF=0.9 \
    gt _out _err _exit 'pkill -f some-server'
  expect_code 0 "$_exit" "GATE-J7 exit"
  assert_counter consult_benign 1 "GATE-J7 consult_benign"
}

# GATE-J8: marker command, screener reports off -> allow, jev_off, no calls
# beyond the off signal (the fake never produces a verdict).
{
  reset_gate_state
  FAKE_SCREEN_MODE=off gt _out _err _exit 'sudo apt-get upgrade'
  expect_code 0 "$_exit" "GATE-J8 exit"
  assert_counter jev_off 1 "GATE-J8 jev_off"
  [ "$(wc -l < "$FAKE_SCREEN_LOG/calls")" -eq 1 ] \
    || fail "GATE-J8: screener consulted more than once"
  pass "GATE-J8: degraded regex-only posture recorded"
}

# GATE-J9: garbage screener output, exit 0 -> allow, jev_error.
{
  reset_gate_state
  FAKE_SCREEN_MODE=garbage gt _out _err _exit 'sudo apt-get upgrade'
  expect_code 0 "$_exit" "GATE-J9 exit"
  assert_counter jev_error 1 "GATE-J9 jev_error"
}

# GATE-J10: screener input carries the command text verbatim; a 12 KiB command
# caps the input at 8 KiB with the event truncated flag.
{
  reset_gate_state
  gt _out _err _exit 'sudo apt-get upgrade -y'
  assert_contains "$(cat "$FAKE_SCREEN_LOG/input")" "sudo apt-get upgrade -y" \
    "GATE-J10a verbatim input"
  pass "GATE-J10a: screener input carries the command text verbatim"
  reset_gate_state
  big_cmd="sudo apt-get $(printf 'flag%.0s ' $(seq 1 2400))"
  FAKE_SCREEN_CHOICE=benign gt _out _err _exit "$big_cmd"
  [ "$(wc -c < "$FAKE_SCREEN_LOG/input")" -le 8192 ] \
    || fail "GATE-J10b: screener input exceeded the 8 KiB cap"
  last_event > "$TMP_ROOT/j10-event"
  jq -e '.truncated == true' "$TMP_ROOT/j10-event" >/dev/null \
    || fail "GATE-J10b: event lacks the truncated flag"
  pass "GATE-J10b: oversized command capped with the truncated flag"
}

# ---- GATE-B: benign commands pass free -----------------------------------------

# GATE-B1: ls -la -> allow free, screener never called, allow_free++.
{
  reset_gate_state
  gt _out _err _exit 'ls -la'
  expect_code 0 "$_exit" "GATE-B1 exit"
  [ -z "$(cat "$FAKE_SCREEN_LOG/calls" 2>/dev/null)" ] \
    || fail "GATE-B1: screener was called"
  assert_counter allow_free 1 "GATE-B1 allow_free"
  pass "GATE-B1: free allow without a consult"
}

# GATE-B2: marker text inside a quoted arg of a safe reader -> allow free.
{
  reset_gate_state
  gt _out _err _exit "rg -n 'rm -rf /' docs/"
  expect_code 0 "$_exit" "GATE-B2 exit"
  [ -z "$(cat "$FAKE_SCREEN_LOG/calls" 2>/dev/null)" ] \
    || fail "GATE-B2: screener was called"
  pass "GATE-B2: quoted marker text stays a free allow"
}

# GATE-B3: echo of a watcher-kill string -> allow free.
{
  reset_gate_state
  gt _out _err _exit "echo 'pkill -f fm-watch'"
  expect_code 0 "$_exit" "GATE-B3 exit"
  [ -z "$(cat "$FAKE_SCREEN_LOG/calls" 2>/dev/null)" ] \
    || fail "GATE-B3: screener was called"
  pass "GATE-B3: echo payload stays a free allow"
}

# GATE-B4: git status && git diff --stat -> allow free.
{
  reset_gate_state
  gt _out _err _exit 'git status && git diff --stat'
  expect_code 0 "$_exit" "GATE-B4 exit"
  assert_counter allow_free 1 "GATE-B4 allow_free"
}

# GATE-B5: cat state/foo.status -> allow free.
{
  reset_gate_state
  gt _out _err _exit 'cat state/foo.status'
  expect_code 0 "$_exit" "GATE-B5 exit"
  assert_counter allow_free 1 "GATE-B5 allow_free"
}

# GATE-B6: interpreter payload with destructive text -> allow free (no
# interpreter-payload recursion, the plan's accepted OQ2 gap).
{
  reset_gate_state
  gt _out _err _exit 'python3 -c '"'"'print("dd of=/dev/sda")'"'"''
  expect_code 0 "$_exit" "GATE-B6 exit"
  [ -z "$(cat "$FAKE_SCREEN_LOG/calls" 2>/dev/null)" ] \
    || fail "GATE-B6: screener was called"
  pass "GATE-B6: interpreter payload stays a free allow"
}

# GATE-B7: empty command -> allow, no effects at all.
{
  reset_gate_state
  gt _out _err _exit ''
  expect_code 0 "$_exit" "GATE-B7 exit"
  assert_no_state "GATE-B7"
  pass "GATE-B7: empty command has no effects"
}

# GATE-B8: the override readout helper is never gated.
{
  reset_gate_state
  gt _out _err _exit 'bin/fm-jev-gate-override.sh status'
  expect_code 0 "$_exit" "GATE-B8 exit"
  [ -z "$(cat "$FAKE_SCREEN_LOG/calls" 2>/dev/null)" ] \
    || fail "GATE-B8: screener was called"
  assert_counter allow_free 1 "GATE-B8 allow_free"
  pass "GATE-B8: override tooling passes free"
}

# GATE-B9: printf of a mkfs string -> allow free.
{
  reset_gate_state
  gt _out _err _exit "printf '%s\n' 'mkfs /dev/sda'"
  expect_code 0 "$_exit" "GATE-B9 exit"
  [ -z "$(cat "$FAKE_SCREEN_LOG/calls" 2>/dev/null)" ] \
    || fail "GATE-B9: screener was called"
  pass "GATE-B9: printf payload stays a free allow"
}

# GATE-B10: watcher-policy domain commands stay free (no arm-check overlap).
{
  reset_gate_state
  gt _out _err _exit 'bin/fm-watch-arm.sh'
  expect_code 0 "$_exit" "GATE-B10a exit"
  [ -z "$(cat "$FAKE_SCREEN_LOG/calls" 2>/dev/null)" ] \
    || fail "GATE-B10a: screener was called"
  gt _out _err _exit 'bin/fm-watch-checkpoint.sh --seconds 180'
  expect_code 0 "$_exit" "GATE-B10b exit"
  [ -z "$(cat "$FAKE_SCREEN_LOG/calls" 2>/dev/null)" ] \
    || fail "GATE-B10b: screener was called"
  pass "GATE-B10: watcher lifecycle commands pass free"
}

# GATE-B11: tmux send-keys payload is text to another pane -> allow free.
{
  reset_gate_state
  gt _out _err _exit "tmux send-keys -t lab 'rm -rf /' Enter"
  expect_code 0 "$_exit" "GATE-B11 exit"
  [ -z "$(cat "$FAKE_SCREEN_LOG/calls" 2>/dev/null)" ] \
    || fail "GATE-B11: screener was called"
  pass "GATE-B11: send-keys payload stays a free allow"
}

# GATE-B12: a 100 KiB command of repeated harmless segments -> allow free,
# no event written.
{
  reset_gate_state
  big_cmd=$(printf 'ls -la; %.0s' $(seq 1 2000))
  gt _out _err _exit "$big_cmd"
  expect_code 0 "$_exit" "GATE-B12 exit"
  assert_counter allow_free 1 "GATE-B12 allow_free"
  [ "$(event_lines | wc -l)" -eq 0 ] || fail "GATE-B12: event written for a free allow"
  pass "GATE-B12: large command judged with no event"
}

# ---- GATE-C: config threshold and activation -----------------------------------

# GATE-C1: floor absent (default 0.8, inclusive): 0.79 allows, 0.80 blocks.
{
  reset_gate_state
  FAKE_SCREEN_CHOICE=destructive FAKE_SCREEN_CONF=0.79 \
    gt _out _err _exit 'rm -rf ~/scratch-build-dir'
  expect_code 0 "$_exit" "GATE-C1a exit"
  assert_counter low_confidence_pass 1 "GATE-C1a low_confidence_pass"
  FAKE_SCREEN_CHOICE=destructive FAKE_SCREEN_CONF=0.80 \
    gt _out _err _exit 'rm -rf ~/scratch-build-dir'
  expect_code 2 "$_exit" "GATE-C1b exit"
  assert_counter block_jev 1 "GATE-C1b block_jev"
}

# GATE-C2: floor file 0.9: 0.89 allows, 0.91 blocks.
{
  reset_gate_state
  printf '0.9\n' > "$FIX_HOME/config/jev-gate-floor"
  FAKE_SCREEN_CHOICE=destructive FAKE_SCREEN_CONF=0.89 \
    gt _out _err _exit 'rm -rf ~/scratch-build-dir'
  expect_code 0 "$_exit" "GATE-C2a exit"
  FAKE_SCREEN_CHOICE=destructive FAKE_SCREEN_CONF=0.91 \
    gt _out _err _exit 'rm -rf ~/scratch-build-dir'
  expect_code 2 "$_exit" "GATE-C2b exit"
  rm -f "$FIX_HOME/config/jev-gate-floor"
}

# GATE-C3: floor file with surrounding whitespace is honored.
{
  reset_gate_state
  printf ' 0.75 \n' > "$FIX_HOME/config/jev-gate-floor"
  FAKE_SCREEN_CHOICE=destructive FAKE_SCREEN_CONF=0.74 \
    gt _out _err _exit 'rm -rf ~/scratch-build-dir'
  expect_code 0 "$_exit" "GATE-C3a exit"
  FAKE_SCREEN_CHOICE=destructive FAKE_SCREEN_CONF=0.76 \
    gt _out _err _exit 'rm -rf ~/scratch-build-dir'
  expect_code 2 "$_exit" "GATE-C3b exit"
  rm -f "$FIX_HOME/config/jev-gate-floor"
}

# GATE-C4: malformed floor abc -> default 0.8.
{
  reset_gate_state
  printf 'abc\n' > "$FIX_HOME/config/jev-gate-floor"
  FAKE_SCREEN_CHOICE=destructive FAKE_SCREEN_CONF=0.79 \
    gt _out _err _exit 'rm -rf ~/scratch-build-dir'
  expect_code 0 "$_exit" "GATE-C4a exit"
  FAKE_SCREEN_CHOICE=destructive FAKE_SCREEN_CONF=0.80 \
    gt _out _err _exit 'rm -rf ~/scratch-build-dir'
  expect_code 2 "$_exit" "GATE-C4b exit"
  rm -f "$FIX_HOME/config/jev-gate-floor"
}

# GATE-C5: out-of-range floors 1.5, 0.9.9, -0.2 each fall back to 0.8.
{
  for bad in 1.5 0.9.9 -0.2; do
    reset_gate_state
    printf '%s\n' "$bad" > "$FIX_HOME/config/jev-gate-floor"
    FAKE_SCREEN_CHOICE=destructive FAKE_SCREEN_CONF=0.79 \
      gt _out _err _exit 'rm -rf ~/scratch-build-dir'
    expect_code 0 "$_exit" "GATE-C5 ($bad) allow exit"
    FAKE_SCREEN_CHOICE=destructive FAKE_SCREEN_CONF=0.80 \
      gt _out _err _exit 'rm -rf ~/scratch-build-dir'
    expect_code 2 "$_exit" "GATE-C5 ($bad) block exit"
    rm -f "$FIX_HOME/config/jev-gate-floor"
  done
  pass "GATE-C5: malformed floors fall back to 0.8"
}

# GATE-C6: floor 1 with destructive 1.00 -> block (inclusive floor).
{
  reset_gate_state
  printf '1\n' > "$FIX_HOME/config/jev-gate-floor"
  FAKE_SCREEN_CHOICE=destructive FAKE_SCREEN_CONF=1.0 \
    gt _out _err _exit 'rm -rf ~/scratch-build-dir'
  expect_code 2 "$_exit" "GATE-C6 exit"
  rm -f "$FIX_HOME/config/jev-gate-floor"
}

# GATE-C7: activation absent -> inert: allow, no screener call, no state.
{
  reset_gate_state
  mv "$FIX_HOME/config/jev-gate" "$TMP_ROOT/jev-gate.saved"
  gt _out _err _exit 'rm -rf /'
  expect_code 0 "$_exit" "GATE-C7 exit"
  [ -z "$(cat "$FAKE_SCREEN_LOG/calls" 2>/dev/null)" ] \
    || fail "GATE-C7: screener was called"
  assert_no_state "GATE-C7"
  mv "$TMP_ROOT/jev-gate.saved" "$FIX_HOME/config/jev-gate"
  pass "GATE-C7: absent activation is fully inert"
}

# GATE-C8: counters and events land under FM_STATE_OVERRIDE.
{
  reset_gate_state
  gt _out _err _exit 'rm -rf /'
  expect_code 2 "$_exit" "GATE-C8 exit"
  assert_present "$FIX_STATE/jev-gate/counters" "GATE-C8 counters"
  assert_present "$FIX_STATE/jev-gate/events.jsonl" "GATE-C8 events"
}

# ---- GATE-T: timeout behavior --------------------------------------------------

# GATE-T1: sleeping screener with a 1 s budget -> allow, jev_timeout, event.
{
  reset_gate_state
  FAKE_SCREEN_MODE=sleep FAKE_SCREEN_SLEEP_SECS=10 FM_JEV_GATE_TIMEOUT_S=1 \
    gt _out _err _exit 'sudo apt-get upgrade'
  expect_code 0 "$_exit" "GATE-T1 exit"
  assert_counter jev_timeout 1 "GATE-T1 jev_timeout"
  last_event > "$TMP_ROOT/t1-event"
  jq -e '.event == "timeout"' "$TMP_ROOT/t1-event" >/dev/null \
    || fail "GATE-T1: event is not timeout"
  pass "GATE-T1: screener timeout fails open with a timeout event"
}

# GATE-T2: screener exits 3 -> allow, jev_error.
{
  reset_gate_state
  FAKE_SCREEN_MODE=exit1 gt _out _err _exit 'sudo apt-get upgrade'
  expect_code 0 "$_exit" "GATE-T2 exit"
  assert_counter jev_error 1 "GATE-T2 jev_error"
}

# GATE-T3: screener prints the API-error TOON shape -> allow, jev_error.
{
  reset_gate_state
  FAKE_SCREEN_MODE=error gt _out _err _exit 'sudo apt-get upgrade'
  expect_code 0 "$_exit" "GATE-T3 exit"
  assert_counter jev_error 1 "GATE-T3 jev_error"
}

# GATE-T4: override window active + sleeping screener -> allow fast,
# override_pass, screener not consulted.
{
  reset_gate_state
  FAKE_SCREEN_MODE=sleep FAKE_SCREEN_SLEEP_SECS=30 FM_JEV_GATE_OVERRIDE=1 \
    gt _out _err _exit 'sudo apt-get upgrade'
  expect_code 0 "$_exit" "GATE-T4 exit"
  assert_counter override_pass 1 "GATE-T4 override_pass"
  [ -z "$(cat "$FAKE_SCREEN_LOG/calls" 2>/dev/null)" ] \
    || fail "GATE-T4: screener was consulted during the window"
  pass "GATE-T4: override window skips the consult"
}

# ---- GATE-P: pilot counters and events -----------------------------------------

# GATE-P1: first decision creates counters with the full closed key set and
# exactly one event line after the chain header.
{
  reset_gate_state
  gt _out _err _exit 'rm -rf /'
  expect_code 2 "$_exit" "GATE-P1 exit"
  for key in allow_free consult_benign consult_grey consult_uncertain \
    low_confidence_pass block_regex block_jev block_repeat near_miss \
    jev_off jev_timeout jev_error jev_degraded override_opened override_pass \
    overridden_block override_expired; do
    grep -q "^$key " "$FIX_STATE/jev-gate/counters" \
      || fail "GATE-P1: counter key missing: $key"
  done
  [ "$(wc -l < "$FIX_STATE/jev-gate/events.jsonl")" -eq 2 ] \
    || fail "GATE-P1: expected chain header + exactly one event line"
  tail -n 1 "$FIX_STATE/jev-gate/events.jsonl" > "$TMP_ROOT/p1-event"
  jq -e '.event' "$TMP_ROOT/p1-event" >/dev/null \
    || fail "GATE-P1: event line is not valid JSON"
  pass "GATE-P1: counters and a single event recorded"
}

# GATE-P2: a Jev block event carries exactly the pinned field set.
{
  reset_gate_state
  FAKE_SCREEN_CHOICE=destructive FAKE_SCREEN_CONF=0.93 \
    gt _out _err _exit 'sudo apt-get upgrade'
  expect_code 2 "$_exit" "GATE-P2 exit"
  last_event > "$TMP_ROOT/p2-event"
  jq -e '
    (keys | sort) == (["ts","seq","prev_sha256","sha256","stage","event",
      "posture","choice","confidence","floor","cmd_sha256","cmd"] | sort) and
    .stage == "jev" and .event == "block"
  ' "$TMP_ROOT/p2-event" >/dev/null \
    || fail "GATE-P2: event field set or stage mismatch"
  pass "GATE-P2: Jev block event matches the pinned field set"
}

# GATE-P3: a 5 KiB blocking command caps the event cmd at 4096 bytes with
# truncated true.
{
  reset_gate_state
  big_blocker="sudo $(printf 'x%.0s' $(seq 1 5100))"
  FAKE_SCREEN_CHOICE=destructive FAKE_SCREEN_CONF=0.95 \
    gt _out _err _exit "$big_blocker"
  expect_code 2 "$_exit" "GATE-P3 exit"
  last_event > "$TMP_ROOT/p3-event"
  jq -e '.truncated == true and (.cmd | length) == 4096' "$TMP_ROOT/p3-event" >/dev/null \
    || fail "GATE-P3: event cmd not capped at 4096 with truncated flag"
  pass "GATE-P3: event cmd capped with truncated flag"
}

# GATE-P4: crossing 1 MiB rotates to events-<epoch>.jsonl, the fresh file
# starts with a chain header plus the event, and only 3 rotations are kept.
{
  reset_gate_state
  for i in 1 2 3 4; do
    mkdir -p "$FIX_STATE/jev-gate"
    head -c 1153434 /dev/zero | tr '\0' 'x' >> "$FIX_STATE/jev-gate/events.jsonl" 2>/dev/null \
      || true
    [ -f "$FIX_STATE/jev-gate/events.jsonl" ] \
      || printf '%s\n' '{"type":"chain-header"}' > "$FIX_STATE/jev-gate/events.jsonl"
    gt _out _err _exit 'rm -rf /'
  done
  rotations=$(find "$FIX_STATE/jev-gate" -name 'events-*.jsonl' | wc -l)
  [ "$rotations" -le 3 ] || fail "GATE-P4: $rotations rotations kept (cap is 3)"
  [ "$rotations" -ge 1 ] || fail "GATE-P4: no rotation happened"
  [ "$(wc -l < "$FIX_STATE/jev-gate/events.jsonl")" -eq 2 ] \
    || fail "GATE-P4: fresh file is not header + 1 event"
  head -n 1 "$FIX_STATE/jev-gate/events.jsonl" | grep -q 'chain-header' \
    || fail "GATE-P4: fresh file does not start with a chain header"
  pass "GATE-P4: rotation, fresh chain, and the 3-rotation cap"
}

# GATE-P5: 2 blocks + 1 free allow -> counters 2/2/1 exactly.
{
  reset_gate_state
  gt _out _err _exit 'rm -rf /'
  gt _out _err _exit 'rm -rf /etc'
  gt _out _err _exit 'ls -la'
  assert_counter block_regex 2 "GATE-P5 block_regex"
  assert_counter allow_free 1 "GATE-P5 allow_free"
}

# GATE-P6: 20 rapid sequential allows -> allow_free 20, counters uncorrupted.
{
  reset_gate_state
  i=0
  while [ "$i" -lt 20 ]; do
    gt _out _err _exit 'ls -la'
    i=$((i + 1))
  done
  assert_counter allow_free 20 "GATE-P6 allow_free"
  awk 'NF != 2 || $2 + 0 != $2 { exit 1 }' "$FIX_STATE/jev-gate/counters" \
    || fail "GATE-P6: counters file corrupted"
  pass "GATE-P6: 20 sequential evaluations recorded cleanly"
}

# GATE-P7: state/jev-gate/ is 0700 and its files 0600.
{
  reset_gate_state
  gt _out _err _exit 'rm -rf /'
  dir_mode=$(stat -c %a "$FIX_STATE/jev-gate")
  counters_mode=$(stat -c %a "$FIX_STATE/jev-gate/counters")
  events_mode=$(stat -c %a "$FIX_STATE/jev-gate/events.jsonl")
  assert_equals "700" "$dir_mode" "GATE-P7 dir mode"
  assert_equals "600" "$counters_mode" "GATE-P7 counters mode"
  assert_equals "600" "$events_mode" "GATE-P7 events mode"
}

# GATE-P8: the override helper status readout prints window, counters, and the
# false-block proxy line after known traffic.
{
  reset_gate_state
  gt _out _err _exit 'rm -rf /'
  gt _out _err _exit 'rm -rf /etc'
  status_out=$(FM_STATE_OVERRIDE="$FIX_STATE" FM_HOME="$FIX_HOME" "$OVERRIDE_HELPER" status 2>&1)
  status_code=$?
  expect_code 0 "$status_code" "GATE-P8 status exit"
  assert_contains "$status_out" "window" "GATE-P8 window line"
  assert_contains "$status_out" "block_regex" "GATE-P8 counters"
  assert_contains "$status_out" "false-block proxy" "GATE-P8 proxy line"
  assert_contains "$status_out" "overridden" "GATE-P8 overridden term"
}

# ---- GATE-S: scope (helm only) -------------------------------------------------

# GATE-S1: FM_ROOT_OVERRIDE at a linked worktree -> inert, no state writes.
{
  reset_gate_state
  wt_repo="$TMP_ROOT/s1-repo"
  wt_dir="$TMP_ROOT/s1-worktree"
  fm_git_worktree "$wt_repo" "$wt_dir" fm-s1-branch
  mkdir -p "$wt_dir/bin"
  cp "$ROOT/bin/fm-jev-pretool-check.sh" "$wt_dir/bin/" 2>/dev/null || true
  cp "$ROOT/bin/fm-jev-gate-policy.mjs" "$wt_dir/bin/" 2>/dev/null || true
  cp "$ROOT/bin/fm-timeout-lib.sh" "$wt_dir/bin/" 2>/dev/null || true
  (cd "$FIX_HOME" && printf 'rm -rf /' | \
    env FM_ROOT_OVERRIDE="$wt_dir" FM_HOME="$FIX_HOME" FM_STATE_OVERRIDE="$FIX_STATE" \
      FM_JEV_COMMAND_SCREENER="$FAKE_SCREENER" \
      "$wt_dir/bin/fm-jev-pretool-check.sh" > /dev/null 2> "$TMP_ROOT/s1-err")
  gt_code=$?
  expect_code 0 "$gt_code" "GATE-S1 exit"
  assert_no_state "GATE-S1"
  pass "GATE-S1: linked worktree scope is inert"
}

# GATE-S2: a home carrying the secondmate marker is inert.
{
  reset_gate_state
  touch "$FIX_HOME/.fm-secondmate-home"
  gt _out _err _exit 'rm -rf /'
  expect_code 0 "$_exit" "GATE-S2 exit"
  assert_no_state "GATE-S2"
  rm -f "$FIX_HOME/.fm-secondmate-home"
}

# GATE-S3: plain checkout, activation absent -> inert.
{
  reset_gate_state
  mv "$FIX_HOME/config/jev-gate" "$TMP_ROOT/jev-gate.saved"
  gt _out _err _exit 'rm -rf /'
  expect_code 0 "$_exit" "GATE-S3 exit"
  assert_no_state "GATE-S3"
  mv "$TMP_ROOT/jev-gate.saved" "$FIX_HOME/config/jev-gate"
}

# GATE-S4: plain checkout, activation present -> active (positive control).
{
  reset_gate_state
  gt _out _err _exit 'rm -rf /'
  expect_code 2 "$_exit" "GATE-S4 exit"
  assert_contains "$_err" "[JG-R1]" "GATE-S4 label"
}

# GATE-S5: git missing from PATH -> inert (scope failure never denies).
{
  reset_gate_state
  sans_path=$(fm_test_base_path_sans "$BASE_PATH" git)
  (cd "$FIX_HOME" && printf 'rm -rf /' | \
    env PATH="$sans_path" FM_HOME="$FIX_HOME" FM_STATE_OVERRIDE="$FIX_STATE" \
      FM_JEV_COMMAND_SCREENER="$FAKE_SCREENER" \
      "$TRANSPORT" >/dev/null 2> "$TMP_ROOT/s5-err")
  gt_code=$?
  expect_code 0 "$gt_code" "GATE-S5 exit"
  assert_no_state "GATE-S5"
  pass "GATE-S5: missing git is inert"
}

# GATE-S6: a failing fake git -> inert.
{
  reset_gate_state
  failing_bin="$TMP_ROOT/failing-git-bin"
  mkdir -p "$failing_bin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$failing_bin/git"
  chmod +x "$failing_bin/git"
  (cd "$FIX_HOME" && printf 'rm -rf /' | \
    env PATH="$failing_bin:$BASE_PATH" FM_HOME="$FIX_HOME" FM_STATE_OVERRIDE="$FIX_STATE" \
      FM_JEV_COMMAND_SCREENER="$FAKE_SCREENER" \
      "$TRANSPORT" >/dev/null 2> "$TMP_ROOT/s6-err")
  gt_code=$?
  expect_code 0 "$gt_code" "GATE-S6 exit"
  assert_no_state "GATE-S6"
  pass "GATE-S6: failing git is inert"
}

# ---- V2 delta (review §7 fold) -------------------------------------------------

# V2-1: command rm -rf / -> block rm-protected.
{
  reset_gate_state
  gt _out _err _exit 'command rm -rf /'
  expect_code 2 "$_exit" "V2-1 exit"
  assert_contains "$_err" "[JG-R1]" "V2-1 label"
}

# V2-2: env rm -rf / -> block.
{
  reset_gate_state
  gt _out _err _exit 'env rm -rf /'
  expect_code 2 "$_exit" "V2-2 exit"
  assert_contains "$_err" "[JG-R1]" "V2-2 label"
}

# V2-3: /usr/bin/rm -rf / -> block (basename resolution).
{
  reset_gate_state
  gt _out _err _exit '/usr/bin/rm -rf /'
  expect_code 2 "$_exit" "V2-3 exit"
  assert_contains "$_err" "[JG-R1]" "V2-3 label"
}

# V2-4: nohup rm -rf / -> block.
{
  reset_gate_state
  gt _out _err _exit 'nohup rm -rf /'
  expect_code 2 "$_exit" "V2-4 exit"
  assert_contains "$_err" "[JG-R1]" "V2-4 label"
}

# V2-5: timeout 5 rm -rf / -> block.
{
  reset_gate_state
  gt _out _err _exit 'timeout 5 rm -rf /'
  expect_code 2 "$_exit" "V2-5 exit"
  assert_contains "$_err" "[JG-R1]" "V2-5 label"
}

# V2-6: nice -n 5 rm -rf / -> block.
{
  reset_gate_state
  gt _out _err _exit 'nice -n 5 rm -rf /'
  expect_code 2 "$_exit" "V2-6 exit"
  assert_contains "$_err" "[JG-R1]" "V2-6 label"
}

# V2-7: \rm -rf / -> block (backslash strip).
{
  reset_gate_state
  gt _out _err _exit '\rm -rf /'
  expect_code 2 "$_exit" "V2-7 exit"
  assert_contains "$_err" "[JG-R1]" "V2-7 label"
}

# V2-8: echo dir | xargs rm -rf -> the xargs wrapper never escapes; the wrapped
# rm carries the marker, and a destructive verdict blocks.
{
  reset_gate_state
  FAKE_SCREEN_CHOICE=destructive FAKE_SCREEN_CONF=0.95 \
    gt _out _err _exit 'echo dir | xargs rm -rf'
  expect_code 2 "$_exit" "V2-8 exit"
  [ -s "$FAKE_SCREEN_LOG/calls" ] || fail "V2-8: wrapped rm never reached the screener"
  assert_contains "$_err" "stage: jev" "V2-8 jev deny"
}

# V2-9: : > <FM_HOME>/state/.lock -> block redirect-protected.
{
  reset_gate_state
  gt _out _err _exit ": > $FIX_HOME/state/.lock"
  expect_code 2 "$_exit" "V2-9 exit"
  assert_contains "$_err" "[JG-R7]" "V2-9 label"
}

# V2-10: > ~/.ssh/authorized_keys -> block redirect-protected.
{
  reset_gate_state
  gt _out _err _exit '> ~/.ssh/authorized_keys'
  expect_code 2 "$_exit" "V2-10 exit"
  assert_contains "$_err" "[JG-R7]" "V2-10 label"
}

# V2-11: tee into a protected file -> consult-routed; destructive blocks.
{
  reset_gate_state
  FAKE_SCREEN_CHOICE=destructive FAKE_SCREEN_CONF=0.95 \
    gt _out _err _exit "tee $FIX_HOME/data/backlog.md </dev/null"
  expect_code 2 "$_exit" "V2-11 exit"
  assert_contains "$_err" "stage: jev" "V2-11 jev deny"
}

# V2-12: sed -i on a protected file -> consult-routed; destructive blocks.
{
  reset_gate_state
  FAKE_SCREEN_CHOICE=destructive FAKE_SCREEN_CONF=0.95 \
    gt _out _err _exit "sed -i 's/x/y/' $FIX_HOME/data/backlog.md"
  expect_code 2 "$_exit" "V2-12 exit"
  assert_contains "$_err" "stage: jev" "V2-12 jev deny"
}

# V2-13: rm -rf state from the home cwd -> block (resolves into the protected
# state dir).
{
  reset_gate_state
  gt _out _err _exit 'rm -rf state'
  expect_code 2 "$_exit" "V2-13 exit"
  assert_contains "$_err" "[JG-R1]" "V2-13 label"
}

# V2-14: rm -rf . from the home cwd -> block (cwd is the protected root).
{
  reset_gate_state
  gt _out _err _exit 'rm -rf .'
  expect_code 2 "$_exit" "V2-14 exit"
  assert_contains "$_err" "[JG-R1]" "V2-14 label"
}

# V2-15: rm -rf ../sibling -> consult-routed outside the P-set; the screener
# input carries the resolved operand.
{
  reset_gate_state
  mkdir -p "$TMP_ROOT/sibling"
  FAKE_SCREEN_CHOICE=benign gt _out _err _exit 'rm -rf ../sibling'
  expect_code 0 "$_exit" "V2-15 exit"
  assert_contains "$(cat "$FAKE_SCREEN_LOG/input")" "$TMP_ROOT/sibling" \
    "V2-15 resolved operand in screener input"
}

# V2-16: a 200 KiB command carrying rm -rf / is judged (no argv cliff).
{
  reset_gate_state
  big_cmd="$(printf 'ls -la; %.0s' $(seq 1 25000)) rm -rf /"
  [ "${#big_cmd}" -gt 150000 ] || fail "V2-16 fixture too small"
  gt _out _err _exit "$big_cmd"
  expect_code 2 "$_exit" "V2-16 exit"
  assert_contains "$_err" "[JG-R1]" "V2-16 label"
}

# V2-17: a hung policy evaluation hits the self-alarm: the transport renders
# allow and the screener child is reaped.
{
  reset_gate_state
  FAKE_SCREEN_MODE=sleep FAKE_SCREEN_SLEEP_SECS=60 \
    FM_JEV_GATE_TIMEOUT_S=30 FM_JEV_GATE_WALL_S=2 \
    gt _out _err _exit 'sudo apt-get upgrade'
  expect_code 0 "$_exit" "V2-17 exit"
  wait_pid_gone "$FAKE_SCREEN_LOG/pid" "V2-17"
  pass "V2-17: self-alarm bounded the evaluation and reaped the child"
}

# V2-18: shadow posture would-block: allow, would_block event, no deny text.
{
  reset_gate_state
  printf 'shadow\n' > "$FIX_HOME/config/jev-gate"
  gt _out _err _exit 'rm -rf /'
  expect_code 0 "$_exit" "V2-18 exit"
  [ -z "$_err" ] || fail "V2-18: deny text on stderr in shadow"
  last_event > "$TMP_ROOT/v18-event"
  jq -e '.event == "would_block" and .stage == "regex" and .pattern != null' \
    "$TMP_ROOT/v18-event" >/dev/null \
    || fail "V2-18: event is not a regex would_block"
  pass "V2-18: shadow records the would-block without denying"
  printf 'enforce\n' > "$FIX_HOME/config/jev-gate"
}

# V2-19: shadow still counts block_regex and block_repeat on a second
# identical would-block; the status readout shows both.
{
  reset_gate_state
  printf 'shadow\n' > "$FIX_HOME/config/jev-gate"
  gt _out _err _exit 'rm -rf /'
  gt _out _err _exit 'rm -rf /'
  status_out=$(FM_STATE_OVERRIDE="$FIX_STATE" FM_HOME="$FIX_HOME" "$OVERRIDE_HELPER" status 2>&1)
  assert_contains "$status_out" "block_regex=2" "V2-19 block_regex count"
  assert_contains "$status_out" "block_repeat=1" "V2-19 block_repeat count"
  printf 'enforce\n' > "$FIX_HOME/config/jev-gate"
}

# V2-20: flipping the same fixture to enforce blocks the same command.
{
  reset_gate_state
  printf 'enforce\n' > "$FIX_HOME/config/jev-gate"
  gt _out _err _exit 'rm -rf /'
  expect_code 2 "$_exit" "V2-20 exit"
  assert_contains "$_err" "[JG-R1]" "V2-20 label"
}

# V2-21: three consecutive failing consults open the breaker; the next marker
# command allows degraded without consulting.
{
  reset_gate_state
  FAKE_SCREEN_MODE=exit1 gt _out _err _exit 'sudo apt-get upgrade'
  expect_code 0 "$_exit" "V2-21 run1 exit"
  FAKE_SCREEN_MODE=error gt _out _err _exit 'sudo apt-get upgrade'
  expect_code 0 "$_exit" "V2-21 run2 exit"
  FAKE_SCREEN_MODE=garbage gt _out _err _exit 'sudo apt-get upgrade'
  expect_code 0 "$_exit" "V2-21 run3 exit"
  calls_after_three=$(wc -l < "$FAKE_SCREEN_LOG/calls")
  last_event > "$TMP_ROOT/v21-open"
  jq -e '.event == "breaker_open"' "$TMP_ROOT/v21-open" >/dev/null \
    || fail "V2-21: breaker_open event missing at the transition"
  FAKE_SCREEN_CHOICE=benign gt _out _err _exit 'sudo apt-get upgrade'
  expect_code 0 "$_exit" "V2-21 run4 exit"
  [ "$(wc -l < "$FAKE_SCREEN_LOG/calls")" -eq "$calls_after_three" ] \
    || fail "V2-21: the breaker still consulted"
  assert_counter jev_degraded 2 "V2-21 jev_degraded"
  last_event > "$TMP_ROOT/v21-degraded"
  jq -e '.event == "degraded"' "$TMP_ROOT/v21-degraded" >/dev/null \
    || fail "V2-21: degraded event missing"
  pass "V2-21: breaker opens after 3 failures and suspends consults"
}

# V2-22: an expired cooldown probes Jev again; success closes the breaker.
{
  reset_gate_state
  printf '{"consecutive_failures":3,"open_since":1,"cooldown_until":1}\n' \
    > "$FIX_STATE/jev-gate-breaker-craft"
  mkdir -p "$FIX_STATE/jev-gate"
  mv "$FIX_STATE/jev-gate-breaker-craft" "$FIX_STATE/jev-gate/breaker"
  FAKE_SCREEN_CHOICE=benign gt _out _err _exit 'sudo apt-get upgrade'
  expect_code 0 "$_exit" "V2-22 exit"
  [ -s "$FAKE_SCREEN_LOG/calls" ] || fail "V2-22: expired breaker did not probe"
  event_lines | grep -q 'breaker_close' || fail "V2-22: breaker_close event missing"
  pass "V2-22: expired cooldown probes and closes on success"
}

# V2-23: an out-of-vocabulary choice counts as jev_error and allows.
{
  reset_gate_state
  FAKE_SCREEN_CHOICE=very-bad FAKE_SCREEN_CONF=0.99 \
    gt _out _err _exit 'sudo apt-get upgrade'
  expect_code 0 "$_exit" "V2-23 exit"
  assert_counter jev_error 1 "V2-23 jev_error"
  [ "$(counter_value consult_benign)" = "0" ] \
    || [ -z "$(counter_value consult_benign)" ] \
    || fail "V2-23: consult_benign was incremented"
}

# V2-24: echo 'rm -rf /' -> allow free plus a near_miss event and counter.
{
  reset_gate_state
  gt _out _err _exit "echo 'rm -rf /'"
  expect_code 0 "$_exit" "V2-24 exit"
  assert_counter near_miss 1 "V2-24 near_miss"
  last_event > "$TMP_ROOT/v24-event"
  jq -e '.event == "near_miss"' "$TMP_ROOT/v24-event" >/dev/null \
    || fail "V2-24: event is not near_miss"
  pass "V2-24: destructive token outside argv recorded as near_miss"
}

# V2-25: production shape - the worktree's own transport with no override is
# inert even with activation present in the main fixture home.
{
  reset_gate_state
  wt_repo="$TMP_ROOT/v25-repo"
  wt_dir="$TMP_ROOT/v25-worktree"
  fm_git_worktree "$wt_repo" "$wt_dir" fm-v25-branch
  mkdir -p "$wt_dir/bin"
  cp "$ROOT/bin/fm-jev-pretool-check.sh" "$wt_dir/bin/"
  cp "$ROOT/bin/fm-jev-gate-policy.mjs" "$wt_dir/bin/"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$wt_dir/bin/"
  (cd "$FIX_HOME" && printf 'rm -rf /' | \
    env FM_HOME="$FIX_HOME" FM_STATE_OVERRIDE="$FIX_STATE" \
      FM_JEV_COMMAND_SCREENER="$FAKE_SCREENER" \
      "$wt_dir/bin/fm-jev-pretool-check.sh" >/dev/null 2> "$TMP_ROOT/v25-err")
  v25_code=$?
  expect_code 0 "$v25_code" "V2-25 exit"
  assert_no_state "V2-25"
  pass "V2-25: worktree-derived scope is inert without overrides"
}

# V2-26: FM_TASK_ID present makes the gate inert.
{
  reset_gate_state
  gt _out _err _exit 'rm -rf /' FM_TASK_ID=jev-gate-ship
  expect_code 0 "$_exit" "V2-26 exit"
  assert_no_state "V2-26"
}

# V2-27: the supervision-branch gap is documented as known-inert, not
# accidental; the seat's lock belt keeps non-lock-owning sessions ungated
# (WIRE-10 owns the wiring half).
{
  assert_present "$ROOT/docs/jev-gate.md" "V2-27 doc exists"
  docs_text=$(cat "$ROOT/docs/jev-gate.md")
  assert_contains "$docs_text" "supervision branch" "V2-27 branch gap documented"
}

# V2-28: git reset --hard in the primary checkout blocks deterministically.
{
  reset_gate_state
  gt _out _err _exit 'git reset --hard'
  expect_code 2 "$_exit" "V2-28 exit"
  assert_contains "$_err" "[JG-R10]" "V2-28 label"
  assert_contains "$_err" "confidence: 1.00" "V2-28 confidence"
}

# V2-29: git clean -fdx in the primary checkout blocks; fm-teardown --force
# consults (companion to GATE-R12).
{
  reset_gate_state
  gt _out _err _exit 'git clean -fdx'
  expect_code 2 "$_exit" "V2-29a exit"
  assert_contains "$_err" "[JG-R10]" "V2-29a label"
  reset_gate_state
  FAKE_SCREEN_CHOICE=benign gt _out _err _exit 'bin/fm-teardown.sh --force t'
  expect_code 0 "$_exit" "V2-29b exit"
  [ -s "$FAKE_SCREEN_LOG/calls" ] || fail "V2-29b: teardown force did not consult"
  pass "V2-29: discard-shaped git blocks; teardown force consults"
}

# V2-30: find -delete on a protected tree -> consult-routed; destructive blocks.
{
  reset_gate_state
  FAKE_SCREEN_CHOICE=destructive FAKE_SCREEN_CONF=0.95 \
    gt _out _err _exit "find $FIX_HOME/state -name '*.tmp' -delete"
  expect_code 2 "$_exit" "V2-30 exit"
  assert_contains "$_err" "stage: jev" "V2-30 jev deny"
}

# V2-31: rsync --delete into a protected dir -> consult-routed; blocks.
{
  reset_gate_state
  FAKE_SCREEN_CHOICE=destructive FAKE_SCREEN_CONF=0.95 \
    gt _out _err _exit "rsync -a --delete src/ $FIX_HOME/state/"
  expect_code 2 "$_exit" "V2-31 exit"
  assert_contains "$_err" "stage: jev" "V2-31 jev deny"
}

# V2-32: brace-expanded operands land depth-1 under home and consult; the
# screener input shows both resolved operands.
{
  reset_gate_state
  FAKE_SCREEN_CHOICE=benign gt _out _err _exit 'rm -rf ./{a,b}'
  expect_code 0 "$_exit" "V2-32 exit"
  screener_input=$(cat "$FAKE_SCREEN_LOG/input")
  assert_contains "$screener_input" "$FIX_HOME/a" "V2-32 operand a"
  assert_contains "$screener_input" "$FIX_HOME/b" "V2-32 operand b"
}

# V2-33: btrfs subvolume delete -> consult-routed; destructive blocks.
{
  reset_gate_state
  FAKE_SCREEN_CHOICE=destructive FAKE_SCREEN_CONF=0.95 \
    gt _out _err _exit 'btrfs subvolume delete /mnt/sub'
  expect_code 2 "$_exit" "V2-33 exit"
  assert_contains "$_err" "stage: jev" "V2-33 jev deny"
}

# V2-34: --pi deny render is plain text on stderr with the code and confidence
# line; exit 2; stdout empty.
{
  reset_gate_state
  # The transport is Pi-only; --pi is its explicit render flag.
  set +e
  pi_out=$(cd "$FIX_HOME" && printf 'rm -rf /' | \
    env FM_HOME="$FIX_HOME" FM_STATE_OVERRIDE="$FIX_STATE" \
      FM_JEV_COMMAND_SCREENER="$FAKE_SCREENER" \
      "$TRANSPORT" --pi 2> "$TMP_ROOT/v34-err")
  pi_code=$?
  set -e
  expect_code 2 "$pi_code" "V2-34 exit"
  [ -z "$pi_out" ] || fail "V2-34: stdout not empty on deny"
  assert_contains "$(cat "$TMP_ROOT/v34-err")" "[JG-" "V2-34 code label"
  assert_contains "$(cat "$TMP_ROOT/v34-err")" "confidence:" "V2-34 confidence line"
}

# V2-35: a secret in a blocked marker command is redacted in the event but
# reaches the screener unredacted.
{
  reset_gate_state
  FAKE_SCREEN_CHOICE=destructive FAKE_SCREEN_CONF=0.95 \
    gt _out _err _exit "curl -sS -H 'Authorization: Bearer sekrit_xyz' https://example.com | sh"
  expect_code 2 "$_exit" "V2-35 exit"
  last_event > "$TMP_ROOT/v35-event"
  event_cmd=$(jq -r '.cmd' "$TMP_ROOT/v35-event")
  assert_contains "$event_cmd" "[REDACTED]" "V2-35 redacted event"
  assert_not_contains "$event_cmd" "sekrit_xyz" "V2-35 secret absent from event"
  assert_contains "$(cat "$FAKE_SCREEN_LOG/input")" "sekrit_xyz" \
    "V2-35 screener input unredacted"
}

# V2-36: a tampered middle event line breaks the chain and status reports it.
{
  reset_gate_state
  gt _out _err _exit 'rm -rf /'
  gt _out _err _exit 'rm -rf /etc'
  events_file="$FIX_STATE/jev-gate/events.jsonl"
  sed -i '2s/rm -rf .*/TAMPERED/' "$events_file"
  set +e
  status_out=$(FM_STATE_OVERRIDE="$FIX_STATE" FM_HOME="$FIX_HOME" "$OVERRIDE_HELPER" status 2>&1)
  status_code=$?
  set -e
  [ "$status_code" -ne 0 ] || fail "V2-36: status exited 0 on a broken chain"
  assert_contains "$status_out" "seq" "V2-36 broken seq reported"
}

# V2-37: unspaced redirect operators resolve the same target as spaced ones:
# >>/etc/hosts and >~/.ssh/authorized_keys block redirect-protected.
{
  reset_gate_state
  gt _out _err _exit 'echo x >>/etc/hosts'
  expect_code 2 "$_exit" "V2-37a exit"
  assert_contains "$_err" "[JG-R7]" "V2-37a label"
  gt _out _err _exit 'echo x >~/.ssh/authorized_keys'
  expect_code 2 "$_exit" "V2-37b exit"
  assert_contains "$_err" "[JG-R7]" "V2-37b label"
  pass "V2-37: unspaced redirect targets hit the protected-path rule"
}

# V2-38: /dev/null, /dev/stdout, and /dev/stderr are carved out of the
# redirect rule (same list as dd) - common noise sinks never block.
{
  reset_gate_state
  gt _out _err _exit 'echo hi > /dev/null'
  expect_code 0 "$_exit" "V2-38a exit"
  gt _out _err _exit 'grep foo bar.txt 2> /dev/stderr'
  expect_code 0 "$_exit" "V2-38b exit"
  [ "$(event_lines | wc -l)" -eq 0 ] || fail "V2-38: event written for a carved-out sink"
  pass "V2-38: /dev carve-outs pass without an event"
}

# V2-39: the unspaced fd-redirect spelling 2>/dev/null also passes the
# carve-out (operator and target both parsed without a gap).
{
  reset_gate_state
  gt _out _err _exit 'grep foo bar.txt 2>/dev/null'
  expect_code 0 "$_exit" "V2-39 exit"
  [ -z "$_err" ] || fail "V2-39: deny text for an unspaced /dev/null sink"
  pass "V2-39: unspaced 2>/dev/null allows"
}

# V2-40: git checkout -- . in the primary checkout blocks deterministically.
{
  reset_gate_state
  gt _out _err _exit 'git checkout -- .'
  expect_code 2 "$_exit" "V2-40 exit"
  assert_contains "$_err" "[JG-R10]" "V2-40 label"
}

# V2-41: git restore in the primary checkout blocks deterministically.
{
  reset_gate_state
  gt _out _err _exit 'git restore .'
  expect_code 2 "$_exit" "V2-41 exit"
  assert_contains "$_err" "[JG-R10]" "V2-41 label"
}

# V2-42: a Jev deny renders only the reason on stderr; the policy's trailing
# cache hint line never reaches the model, and stdout stays empty without the
# seat's cache-out flag.
{
  reset_gate_state
  FAKE_SCREEN_CHOICE=destructive FAKE_SCREEN_CONF=0.95 \
    gt _out _err _exit 'sudo apt-get upgrade'
  expect_code 2 "$_exit" "V2-42 exit"
  assert_contains "$_err" "stage: jev" "V2-42 jev deny"
  assert_not_contains "$_err" "cache" "V2-42 cache line in deny text"
  [ -z "$_out" ] || fail "V2-42: stdout not empty without the cache-out flag"
  pass "V2-42: deny reason carries no cache hint"
}

# V2-43: with FM_JEV_GATE_CACHE_OUT=1 the trailing cache hint line is the one
# stdout line the transport re-emits, deny or not.
{
  reset_gate_state
  FAKE_SCREEN_CHOICE=destructive FAKE_SCREEN_CONF=0.95 \
    gt _out _err _exit 'sudo apt-get upgrade' FM_JEV_GATE_CACHE_OUT=1
  expect_code 2 "$_exit" "V2-43 exit"
  assert_contains "$_out" "cache$(printf '\t')destructive$(printf '\t')0.95" \
    "V2-43 cache line on stdout"
  assert_not_contains "$_err" "cache" "V2-43 stderr clean"
  pass "V2-43: cache-out flag forwards the cache line"
}

# V2-44: a lock dir orphaned by a killed holder is stolen, not honored
# forever; a live fresh holder is never stolen from.
{
  reset_gate_state
  gt _out _err _exit 'rm -rf /'
  sleep 0.2 & dead_holder=$!
  wait "$dead_holder"
  mkdir -p "$FIX_STATE/jev-gate/.lock"
  printf '%s\n' "$dead_holder" > "$FIX_STATE/jev-gate/.lock/pid"
  gt _out _err _exit 'rm -rf /etc'
  expect_code 2 "$_exit" "V2-44a exit"
  [ ! -e "$FIX_STATE/jev-gate/.lock" ] || fail "V2-44a: stolen lock left behind"
  pass "V2-44a: dead-holder lock stolen and cleaned"
  sleep 5 & live_holder=$!
  mkdir -p "$FIX_STATE/jev-gate/.lock"
  printf '%s\n' "$live_holder" > "$FIX_STATE/jev-gate/.lock/pid"
  gt _out _err _exit 'rm -rf /etc'
  expect_code 2 "$_exit" "V2-44b exit"
  [ -e "$FIX_STATE/jev-gate/.lock" ] || fail "V2-44b: live holder's lock was stolen"
  kill "$live_holder" 2>/dev/null || true
  wait "$live_holder" 2>/dev/null || true
  pass "V2-44b: live fresh holder keeps its lock"
}

# ---- PERF / LIVE ---------------------------------------------------------------

# PERF-4: the hard-kill bound - a sleeping screener is killed at the timeout,
# the decision returns allow with jev_timeout, and the child is reaped.
{
  reset_gate_state
  FAKE_SCREEN_MODE=sleep FAKE_SCREEN_SLEEP_SECS=30 FM_JEV_GATE_TIMEOUT_S=1 \
    gt _out _err _exit 'sudo apt-get upgrade'
  expect_code 0 "$_exit" "PERF-4 exit"
  assert_counter jev_timeout 1 "PERF-4 jev_timeout"
  wait_pid_gone "$FAKE_SCREEN_LOG/pid" "PERF-4"
  pass "PERF-4: wall-clock kill fired and reaped the child"
}

# LIVE-1: opt-in real-API smoke, never run in CI.
fm_live_gate opt-in FM_JEV_GATE_LIVE curl
{
  reset_gate_state
  set +e
  (cd "$FIX_HOME" && printf 'sudo apt-get upgrade' | \
    env FM_HOME="$FIX_HOME" FM_STATE_OVERRIDE="$FIX_STATE" \
      "$TRANSPORT" >/dev/null 2> "$TMP_ROOT/live-err")
  live_code=$?
  set -e
  expect_code 0 "$live_code" "LIVE-1 exit"
  pass "LIVE-1: real-API smoke completed without a hang"
}

echo "All tests complete."
