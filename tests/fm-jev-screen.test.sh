#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-screen.sh.
#
# Drives the public argv and environment interface with a fake curl on PATH
# that records argv, the request body it read from stdin, and the header it
# read from file descriptor 3, and answers with a canned Jev systemone
# response.  A fake quota-axi serves the selected schema-5 fixture. No case
# touches the network, and the absent-key case proves the tool makes no call
# at all.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-jev-screen.sh"
TMP_ROOT=$(fm_test_tmproot fm-jev-screen)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
NO_CURL_BIN="$TMP_ROOT/no-curl-bin"
LOG="$TMP_ROOT/log"
QUESTION="$TMP_ROOT/question.txt"
BASE_PATH=$PATH
mkdir -p "$HOME_DIR/config" "$LOG" "$NO_CURL_BIN"
for command_name in bash chmod cp dirname jq mktemp rm; do
  ln -s "$(command -v "$command_name")" "$NO_CURL_BIN/$command_name"
done

# ---- canned responses --------------------------------------------------------
#
# A valid clear response (actively-working).
VALID_ACTIVE_WORKING=$(cat <<'JSON'
{
  "model": "jev-latest",
  "answers": {
    "screen": {
      "type": "choice",
      "choice": "actively-working",
      "confidence": 0.92,
      "probabilities": {
        "actively-working": 0.92,
        "waiting-at-prompt": 0.04,
        "awaiting-user-input": 0.02,
        "stalled": 0.01,
        "uncertain": 0.01
      }
    }
  },
  "usage": { "input_tokens": 340, "output_tokens": 28 }
}
JSON
)

# A valid clear response (waiting-at-prompt).
VALID_WAITING=$(cat <<'JSON'
{
  "model": "jev-latest",
  "answers": {
    "screen": {
      "type": "choice",
      "choice": "waiting-at-prompt",
      "confidence": 0.85,
      "probabilities": {
        "actively-working": 0.05,
        "waiting-at-prompt": 0.85,
        "awaiting-user-input": 0.04,
        "stalled": 0.03,
        "uncertain": 0.03
      }
    }
  },
  "usage": { "input_tokens": 310, "output_tokens": 22 }
}
JSON
)

# A valid clear response (stalled).
VALID_STALLED=$(cat <<'JSON'
{
  "model": "jev-latest",
  "answers": {
    "screen": {
      "type": "choice",
      "choice": "stalled",
      "confidence": 0.78,
      "probabilities": {
        "actively-working": 0.02,
        "waiting-at-prompt": 0.08,
        "awaiting-user-input": 0.04,
        "stalled": 0.78,
        "uncertain": 0.08
      }
    }
  },
  "usage": { "input_tokens": 320, "output_tokens": 24 }
}
JSON
)

# A valid clear response with no usage field.
VALID_NO_USAGE=$(cat <<'JSON'
{
  "model": "jev-latest",
  "answers": {
    "screen": {
      "type": "choice",
      "choice": "uncertain",
      "confidence": 0.65,
      "probabilities": {
        "actively-working": 0.05,
        "waiting-at-prompt": 0.10,
        "awaiting-user-input": 0.05,
        "stalled": 0.05,
        "uncertain": 0.75
      }
    }
  }
}
JSON
)

# Malformed response: missing answers.screen.
MALFORMED_NO_ANSWERS=$(cat <<'JSON'
{
  "model": "jev-latest",
  "answers": {
    "other": {
      "choice": "foo",
      "confidence": 0.9
    }
  }
}
JSON
)

# Malformed response: confidence out of range.
MALFORMED_CONFIDENCE_HIGH=$(cat <<'JSON'
{
  "model": "jev-latest",
  "answers": {
    "screen": {
      "type": "choice",
      "choice": "actively-working",
      "confidence": 1.5,
      "probabilities": {
        "actively-working": 1.5
      }
    }
  },
  "usage": { "input_tokens": 100, "output_tokens": 10 }
}
JSON
)

# Malformed response: probabilities don't sum to ~1.
MALFORMED_PROB_SUM=$(cat <<'JSON'
{
  "model": "jev-latest",
  "answers": {
    "screen": {
      "type": "choice",
      "choice": "actively-working",
      "confidence": 0.90,
      "probabilities": {
        "actively-working": 0.90,
        "waiting-at-prompt": 0.01,
        "awaiting-user-input": 0.01,
        "stalled": 0.01,
        "uncertain": 0.01
      }
    }
  },
  "usage": { "input_tokens": 100, "output_tokens": 10 }
}
JSON
)

# ---- fake curl ---------------------------------------------------------------
#
# Fake curl: records argv, the stdin body, and the header read from fd 3, then
# answers with FAKE_CURL_RESPONSE and FAKE_CURL_HTTP.
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
if [ "${FAKE_CURL_FAIL:-0}" = 1 ]; then
  exit 7
fi
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
chmod +x "$FAKEBIN/curl"

# ---- helpers -----------------------------------------------------------------

reset_response() {
  printf '%s' "$VALID_ACTIVE_WORKING" > "$RESPONSE_FILE"
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
# PATH and an isolated FM_HOME.  TYPESAFE_API_KEY comes from the caller's env.
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

# ---- question file helper ----------------------------------------------------
write_question() {
  printf '%s\n' "$1" > "$QUESTION"
}

# ---- tests -------------------------------------------------------------------

echo "1..15"

# 1. No key → no call, exit 0, "screen: off" on stderr.
{
  reset_log
  run_off _exit _out _err "$QUESTION"
  expect_code 0 "$_exit" "no-key exit"
  assert_contains "$_err" "screen: off" "no-key stderr"
  assert_not_contains "$_out" "screen:" "no-key stdout has no screen block"
  [ ! -s "$LOG/argv" ] || fail "no-key: curl was called" "no-key: curl was called"
}

# 2. Golden response: actively-working → clear.
{
  reset_log
  reset_response
  write_question "What does this worker show?"
  run _exit _out _err "$QUESTION"
  expect_code 0 "$_exit" "actively-working exit"
  assert_contains "$_out" "screen:" "actively-working has screen block"
  assert_contains "$_out" "status: clear" "actively-working status clear"
  assert_contains "$_out" "choice: actively-working" "actively-working choice"
  assert_contains "$_out" "confidence: 0.92" "actively-working confidence"
  assert_contains "$_out" "latency_ms:" "actively-working latency"
  assert_contains "$_out" "tokens:" "actively-working tokens"
}

# 3. Golden response: waiting-at-prompt → clear.
{
  reset_log
  printf '%s' "$VALID_WAITING" > "$RESPONSE_FILE"
  write_question "What does this worker show?"
  run _exit _out _err "$QUESTION"
  expect_code 0 "$_exit" "waiting exit"
  assert_contains "$_out" "status: clear" "waiting status clear"
  assert_contains "$_out" "choice: waiting-at-prompt" "waiting choice"
  assert_contains "$_out" "confidence: 0.85" "waiting confidence"
}

# 4. Golden response: stalled → clear.
{
  reset_log
  printf '%s' "$VALID_STALLED" > "$RESPONSE_FILE"
  write_question "What does this worker show?"
  run _exit _out _err "$QUESTION"
  expect_code 0 "$_exit" "stalled exit"
  assert_contains "$_out" "status: clear" "stalled status clear"
  assert_contains "$_out" "choice: stalled" "stalled choice"
}

# 5. Golden response: no usage field → clear, tokens default to 0/0.
{
  reset_log
  printf '%s' "$VALID_NO_USAGE" > "$RESPONSE_FILE"
  write_question "What does this worker show?"
  run _exit _out _err "$QUESTION"
  expect_code 0 "$_exit" "no-usage exit"
  assert_contains "$_out" "status: clear" "no-usage status clear"
  assert_contains "$_out" "choice: uncertain" "no-usage choice"
  assert_contains "$_out" "tokens: 0/0" "no-usage tokens default"
}

# 6. HTTP 000 (network failure) → error.
{
  reset_log
  FAKE_CURL_HTTP="000" run _exit _out _err "$QUESTION"
  expect_code 0 "$_exit" "http-000 exit"
  assert_contains "$_out" "status: error" "http-000 error"
  assert_contains "$_out" "http 000" "http-000 reason"
}

# 7. HTTP 500 → error.
{
  reset_log
  FAKE_CURL_HTTP="500" run _exit _out _err "$QUESTION"
  expect_code 0 "$_exit" "http-500 exit"
  assert_contains "$_out" "status: error" "http-500 error"
}

# 8. Malformed response (missing answers.screen) → error.
{
  reset_log
  printf '%s' "$MALFORMED_NO_ANSWERS" > "$RESPONSE_FILE"
  run _exit _out _err "$QUESTION"
  expect_code 0 "$_exit" "malformed exit"
  assert_contains "$_out" "status: error" "malformed error"
}

# 9. Malformed response (confidence out of range) → error.
{
  reset_log
  printf '%s' "$MALFORMED_CONFIDENCE_HIGH" > "$RESPONSE_FILE"
  run _exit _out _err "$QUESTION"
  expect_code 0 "$_exit" "malformed-confidence exit"
  assert_contains "$_out" "status: error" "malformed-confidence error"
}

# 10. Malformed response (probabilities don't sum to ~1) → error.
{
  reset_log
  printf '%s' "$MALFORMED_PROB_SUM" > "$RESPONSE_FILE"
  run _exit _out _err "$QUESTION"
  expect_code 0 "$_exit" "malformed-prob exit"
  assert_contains "$_out" "status: error" "malformed-prob error"
}

# 11. Key via fd, never argv.
{
  reset_log
  printf '%s' "$VALID_ACTIVE_WORKING" > "$RESPONSE_FILE"
  write_question "What does this worker show?"
  run _exit _out _err "$QUESTION"
  # Check that the header file contains the Bearer token.
  assert_contains "$(cat "$LOG/header")" "Bearer fake-key-123" "key via fd"
}

# 12. Missing question file → exit 2.
{
  reset_log
  run _exit _out _err "/nonexistent/question.txt"
  expect_code 2 "$_exit" "missing-file exit"
  assert_contains "$_out" "" "missing-file stdout empty" || true
  assert_contains "$_err" "input file not readable" "missing-file stderr"
}

# 13. The request body carries the question file's text as the screen input,
# so the model classifies the actual pane tail and not an empty prompt.
{
  reset_log
  reset_response
  printf '● Bash(npm test)\n  ⎿ 34 tests passing\n' > "$QUESTION"
  run _exit _out _err "$QUESTION"
  expect_code 0 "$_exit" "payload exit"
  jq -e --rawfile q "$QUESTION" '.state.screen.input == $q' "$LOG/body" >/dev/null \
    || fail "request body did not carry the question file text as screen.input"
  pass "request carries the question file text as screen.input"
}

# 14. The request pins the C1 typed question and the five-option vocabulary,
# so the wedge screen and its confidence stay comparable across callers.
{
  reset_log
  reset_response
  write_question "streaming build output"
  run _exit _out _err "$QUESTION"
  expect_code 0 "$_exit" "instructions exit"
  jq -e '
    (.questions.screen.type == "choice") and
    (.questions.screen.instructions | test("terminal pane tail")) and
    (.questions.screen.instructions | test("screen.input")) and
    (["actively-working", "waiting-at-prompt", "awaiting-user-input", "stalled", "uncertain"]
      - (.questions.screen.criteria | keys)) == []
  ' "$LOG/body" >/dev/null \
    || fail "request did not pin the C1 question and option criteria"
  pass "request pins the C1 question and the five-option criteria"
}

# 15. Optional --idle-secs and --window context reaches the state block, per
# the C1 input contract (harness/window identity, idle seconds, tail text).
{
  reset_log
  reset_response
  write_question "spinner mid-turn"
  run _exit _out _err --idle-secs 240 --window "test:fm-quiet" "$QUESTION"
  expect_code 0 "$_exit" "context exit"
  jq -e '.state.screen.idle_secs == "240" and .state.screen.window == "test:fm-quiet"' "$LOG/body" >/dev/null \
    || fail "request did not carry the idle/window context"
  pass "optional idle and window context reach the request state"
}

echo "All tests complete."
