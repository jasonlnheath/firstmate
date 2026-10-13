#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-command-screen.sh (SCREEN-1..15, plan v2 §12.1).
#
# Drives the typed Jev command-classification call with a fake curl on PATH
# that records argv, the request body it read from stdin, and the header it
# read from file descriptor 3, and answers with a canned systemone response.
# No case touches the network, and the absent-key case proves the tool makes
# no call at all. The closed four-option command vocabulary and the
# FM_JEV_GATE_TIMEOUT_S default (3 s) are pinned here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-jev-command-screen.sh"
TMP_ROOT=$(fm_test_tmproot fm-jev-command-screen)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/log"
QUESTION="$TMP_ROOT/command.txt"
BASE_PATH=$PATH
mkdir -p "$HOME_DIR/config" "$LOG"

# ---- canned responses ---------------------------------------------------------

VALID_DESTRUCTIVE=$(cat <<'JSON'
{
  "model": "jev-latest",
  "answers": {
    "command": {
      "type": "choice",
      "choice": "destructive",
      "confidence": 0.93,
      "probabilities": {
        "benign": 0.02,
        "grey-reversible": 0.03,
        "destructive": 0.93,
        "uncertain": 0.02
      }
    }
  },
  "usage": { "input_tokens": 470, "output_tokens": 30 }
}
JSON
)

VALID_BENIGN=$(cat <<'JSON'
{
  "model": "jev-latest",
  "answers": {
    "command": {
      "type": "choice",
      "choice": "benign",
      "confidence": 0.9,
      "probabilities": {
        "benign": 0.9,
        "grey-reversible": 0.04,
        "destructive": 0.02,
        "uncertain": 0.04
      }
    }
  },
  "usage": { "input_tokens": 455, "output_tokens": 25 }
}
JSON
)

VALID_GREY=$(cat <<'JSON'
{
  "model": "jev-latest",
  "answers": {
    "command": {
      "type": "choice",
      "choice": "grey-reversible",
      "confidence": 0.85,
      "probabilities": {
        "benign": 0.05,
        "grey-reversible": 0.85,
        "destructive": 0.04,
        "uncertain": 0.06
      }
    }
  },
  "usage": { "input_tokens": 460, "output_tokens": 27 }
}
JSON
)

VALID_UNCERTAIN_NO_USAGE=$(cat <<'JSON'
{
  "model": "jev-latest",
  "answers": {
    "command": {
      "type": "choice",
      "choice": "uncertain",
      "confidence": 0.6,
      "probabilities": {
        "benign": 0.1,
        "grey-reversible": 0.1,
        "destructive": 0.1,
        "uncertain": 0.7
      }
    }
  }
}
JSON
)

MALFORMED_NO_ANSWERS=$(cat <<'JSON'
{
  "model": "jev-latest",
  "answers": {
    "screen": {
      "choice": "benign",
      "confidence": 0.9
    }
  }
}
JSON
)

MALFORMED_CONFIDENCE_HIGH=$(cat <<'JSON'
{
  "model": "jev-latest",
  "answers": {
    "command": {
      "type": "choice",
      "choice": "benign",
      "confidence": 1.5,
      "probabilities": {
        "benign": 1.5
      }
    }
  },
  "usage": { "input_tokens": 100, "output_tokens": 10 }
}
JSON
)

MALFORMED_PROB_SUM=$(cat <<'JSON'
{
  "model": "jev-latest",
  "answers": {
    "command": {
      "type": "choice",
      "choice": "benign",
      "confidence": 0.9,
      "probabilities": {
        "benign": 0.9,
        "grey-reversible": 0.01,
        "destructive": 0.01,
        "uncertain": 0.02
      }
    }
  },
  "usage": { "input_tokens": 100, "output_tokens": 10 }
}
JSON
)

# ---- fake curl ---------------------------------------------------------------

RESPONSE_FILE="$TMP_ROOT/fake_curl_resp"
export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE_FILE" FAKE_CURL_HTTP="200"

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) printf '%s\n' "$1" >> "${FAKE_CURL_LOG:?}/argv"; shift ;;
  esac
done
cat > "${FAKE_CURL_LOG:?}/body"
cat /dev/fd/3 > "${FAKE_CURL_LOG:?}/header" 2>/dev/null || printf 'fd3 unreadable\n' > "${FAKE_CURL_LOG:?}/header"
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
chmod +x "$FAKEBIN/curl"

# ---- helpers -------------------------------------------------------------------

reset_response() {
  printf '%s' "$VALID_DESTRUCTIVE" > "$RESPONSE_FILE"
  : > "$LOG/argv" 2>/dev/null || true
  : > "$LOG/header" 2>/dev/null || true
  : > "$LOG/body" 2>/dev/null || true
}

reset_log() {
  rm -rf "$LOG"
  mkdir -p "$LOG"
  reset_response
}

# run <exit-var> <out-var> <err-var> [args...]: the tool with fakebin first on
# PATH and an isolated FM_HOME. TYPESAFE_API_KEY comes from the caller's env.
run() {
  local __exit=$1 __out=$2 __err=$3
  local _result='' _code
  shift 3
  set +e
  _result=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY="fake-key-123" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  set -e
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_result"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}

# run_off <exit-var> <out-var> <err-var> [args...]: the tool WITHOUT a key.
run_off() {
  local __exit=$1 __out=$2 __err=$3
  local _result='' _code
  shift 3
  set +e
  _result=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  set -e
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_result"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}

write_command() {
  printf '%s\n' "$1" > "$QUESTION"
}

_exit='' _out='' _err=''

echo "1..15"

# SCREEN-1: canned destructive 0.93 -> clear with the exact verdict fields.
{
  reset_log
  write_command 'rm -rf ~/scratch-build-dir'
  run _exit _out _err "$QUESTION"
  expect_code 0 "$_exit" "SCREEN-1 exit"
  assert_contains "$_out" "command:" "SCREEN-1 command block"
  assert_contains "$_out" "status: clear" "SCREEN-1 status clear"
  assert_contains "$_out" "choice: destructive" "SCREEN-1 choice"
  assert_contains "$_out" "confidence: 0.93" "SCREEN-1 confidence"
  assert_contains "$_out" "latency_ms:" "SCREEN-1 latency"
  assert_contains "$_out" "tokens:" "SCREEN-1 tokens"
}

# SCREEN-2: benign 0.9 -> clear.
{
  reset_log
  printf '%s' "$VALID_BENIGN" > "$RESPONSE_FILE"
  write_command 'mv big-dir /tmp/'
  run _exit _out _err "$QUESTION"
  expect_code 0 "$_exit" "SCREEN-2 exit"
  assert_contains "$_out" "status: clear" "SCREEN-2 status clear"
  assert_contains "$_out" "choice: benign" "SCREEN-2 choice"
}

# SCREEN-3: grey-reversible 0.85 -> clear.
{
  reset_log
  printf '%s' "$VALID_GREY" > "$RESPONSE_FILE"
  write_command 'git push --force-with-lease origin main'
  run _exit _out _err "$QUESTION"
  expect_code 0 "$_exit" "SCREEN-3 exit"
  assert_contains "$_out" "status: clear" "SCREEN-3 status clear"
  assert_contains "$_out" "choice: grey-reversible" "SCREEN-3 choice"
}

# SCREEN-4: uncertain with no usage field -> clear, tokens default 0/0.
{
  reset_log
  printf '%s' "$VALID_UNCERTAIN_NO_USAGE" > "$RESPONSE_FILE"
  write_command 'sudo apt-get upgrade'
  run _exit _out _err "$QUESTION"
  expect_code 0 "$_exit" "SCREEN-4 exit"
  assert_contains "$_out" "status: clear" "SCREEN-4 status clear"
  assert_contains "$_out" "choice: uncertain" "SCREEN-4 choice"
  assert_contains "$_out" "tokens: 0/0" "SCREEN-4 tokens default"
}

# SCREEN-5: HTTP 000 (network failure) -> error, exit 0.
{
  reset_log
  FAKE_CURL_HTTP="000" run _exit _out _err "$QUESTION"
  expect_code 0 "$_exit" "SCREEN-5 exit"
  assert_contains "$_out" "status: error" "SCREEN-5 error"
}

# SCREEN-6: HTTP 500 -> error, exit 0.
{
  reset_log
  FAKE_CURL_HTTP="500" run _exit _out _err "$QUESTION"
  expect_code 0 "$_exit" "SCREEN-6 exit"
  assert_contains "$_out" "status: error" "SCREEN-6 error"
}

# SCREEN-7: response missing answers.command -> error (validation).
{
  reset_log
  printf '%s' "$MALFORMED_NO_ANSWERS" > "$RESPONSE_FILE"
  run _exit _out _err "$QUESTION"
  expect_code 0 "$_exit" "SCREEN-7 exit"
  assert_contains "$_out" "status: error" "SCREEN-7 error"
}

# SCREEN-8: confidence 1.5 -> error.
{
  reset_log
  printf '%s' "$MALFORMED_CONFIDENCE_HIGH" > "$RESPONSE_FILE"
  run _exit _out _err "$QUESTION"
  expect_code 0 "$_exit" "SCREEN-8 exit"
  assert_contains "$_out" "status: error" "SCREEN-8 error"
}

# SCREEN-9: probabilities sum 0.94 -> error.
{
  reset_log
  printf '%s' "$MALFORMED_PROB_SUM" > "$RESPONSE_FILE"
  run _exit _out _err "$QUESTION"
  expect_code 0 "$_exit" "SCREEN-9 exit"
  assert_contains "$_out" "status: error" "SCREEN-9 error"
}

# SCREEN-10: no key anywhere -> "command: off" on stderr, exit 0, no call.
{
  reset_log
  run_off _exit _out _err "$QUESTION"
  expect_code 0 "$_exit" "SCREEN-10 exit"
  assert_contains "$_err" "command: off" "SCREEN-10 off stderr"
  assert_not_contains "$_out" "command:" "SCREEN-10 stdout has no block"
  [ ! -s "$LOG/argv" ] || fail "SCREEN-10: curl was called"
  pass "SCREEN-10: absent key makes no network call"
}

# SCREEN-11: key in env -> fd-3 header carries Bearer; key never on argv.
{
  reset_log
  write_command 'rm -rf ~/scratch-build-dir'
  run _exit _out _err "$QUESTION"
  expect_code 0 "$_exit" "SCREEN-11 exit"
  assert_contains "$(cat "$LOG/header")" "Bearer fake-key-123" "SCREEN-11 bearer header"
  assert_not_contains "$(cat "$LOG/argv")" "fake-key-123" "SCREEN-11 key not on argv"
}

# SCREEN-12: request body pins the command input, window, and closed
# four-option criteria with helm-session instructions.
{
  reset_log
  printf 'rm -rf ~/scratch-build-dir with trailing detail' > "$QUESTION"
  run _exit _out _err "$QUESTION"
  expect_code 0 "$_exit" "SCREEN-12 exit"
  jq -e --rawfile q "$QUESTION" '
    .state.command.input == $q and
    .state.command.window == "jev-gate" and
    (.questions.command.type == "choice") and
    (.questions.command.instructions | test("helm")) and
    (["benign", "grey-reversible", "destructive", "uncertain"]
      - (.questions.command.criteria | keys)) == []
  ' "$LOG/body" >/dev/null \
    || fail "SCREEN-12: request did not pin the command contract"
  pass "SCREEN-12: request pins input, window, and the four-option criteria"
}

# SCREEN-13: missing input file -> exit 2 usage error.
{
  reset_log
  run _exit _out _err "/nonexistent/command.txt"
  expect_code 2 "$_exit" "SCREEN-13 exit"
  [ -z "$_out" ] || fail "SCREEN-13 stdout not empty: $_out"
  assert_contains "$_err" "input file not readable" "SCREEN-13 stderr"
}

# SCREEN-14: FM_JEV_GATE_TIMEOUT_S=3 -> recorded curl argv contains --max-time 3
# (the v2 default is 3 s, not the wedge screen's 5 s).
{
  reset_log
  write_command 'ls -la'
  FM_JEV_GATE_TIMEOUT_S=3 run _exit _out _err "$QUESTION"
  expect_code 0 "$_exit" "SCREEN-14 exit"
  assert_contains "$(cat "$LOG/argv")" "--max-time" "SCREEN-14 max-time present"
  grep -A1 -F -- '--max-time' "$LOG/argv" | grep -F '3' >/dev/null \
    || fail "SCREEN-14: --max-time not set to 3"
  pass "SCREEN-14: FM_JEV_GATE_TIMEOUT_S reaches curl --max-time"
}

# SCREEN-15: key in env AND in $FM_HOME/.env -> env value wins.
{
  reset_log
  printf 'TYPESAFE_API_KEY=env-file-key-456\n' > "$HOME_DIR/.env"
  write_command 'ls -la'
  run _exit _out _err "$QUESTION"
  expect_code 0 "$_exit" "SCREEN-15 exit"
  assert_contains "$(cat "$LOG/header")" "Bearer fake-key-123" "SCREEN-15 env key wins"
  assert_not_contains "$(cat "$LOG/header")" "env-file-key-456" "SCREEN-15 .env key not used"
  rm -f "$HOME_DIR/.env"
}

echo "All tests complete."
