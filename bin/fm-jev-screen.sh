#!/usr/bin/env bash
# fm-jev-screen.sh - typed Jev screen: one POST to /v1/systemone, validated TOON output.
#
# Usage:
#   fm-jev-screen.sh [--idle-secs <n>] [--window <s>] <input-file>
#
# The input file holds the text to classify - for the wedge pre-screen, the
# worker's terminal pane tail (last ~40 lines, plain text).  The tool wraps it
# into the standard Jev systemone request shape as `state.screen.input`, pins
# the C1 typed question and its five-option vocabulary in the question's
# criteria, sends the request, validates the response, and prints a `screen:`
# TOON block on stdout.
#
# Opt-in gate: TYPESAFE_API_KEY non-empty in the process environment, or
#   a TYPESAFE_API_KEY= line in $FM_HOME/.env read via fmx_env_get.
#   Absent in both → one "screen: off" line on stderr, nothing on stdout,
#   exit 0, no network call.
# The key lives in one shell variable and reaches curl as a header read
# from a file descriptor, never on argv; nothing logs or writes it.
#
# Output (stdout, TOON-style block):
#   screen:
#     status: clear | error
#     choice: <the selected option string>
#     confidence: <0.00-1.00>
#     latency_ms: <integer>
#     tokens: <input>/<output>
#   clear → the choice is the screen verdict; confidence is advisory.
#   error → API, network, response, or validation failure; exit 0.
#   Every outcome exits 0 so the caller never blocks on this tool.
#   Exit 2 only for a usage or configuration error (unreadable input
#   file, malformed --idle-secs, missing jq, missing curl).
#
# Environment:
#   TYPESAFE_API_KEY is the only screen-specific environment setting.
#
# Authority: this tool never replaces firstmate's judgment; it publishes
#   one inspectable verdict plus confidence, in code.
set -u

TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
export -n TYPESAFE_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"

TS_MODEL=jev-latest
TS_BASE=https://api.typesafe.ai
TS_TIMEOUT=5

die() { printf 'error: %s\n' "$1" >&2; exit 2; }

QUESTION_FILE='' JEVI_IDLE='' JEVI_WINDOW=''
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next}{exit}' "$0"
      exit 0
      ;;
    --idle-secs) [ $# -ge 2 ] || die "--idle-secs needs a value"; JEVI_IDLE=$2; shift 2 ;;
    --window) [ $# -ge 2 ] || die "--window needs a value"; JEVI_WINDOW=$2; shift 2 ;;
    -*) die "unknown flag $1" ;;
    *) [ -z "$QUESTION_FILE" ] || die "one input file only"; QUESTION_FILE=$1; shift ;;
  esac
done
case "$JEVI_IDLE" in ''|*[!0-9]*) [ -z "$JEVI_IDLE" ] || die "--idle-secs must be a whole number of seconds" ;; esac

# ---- opt-in gate ---------------------------------------------------------------
if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
  TYPESAFE_API_KEY_PRIVATE=$(fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env")
fi
if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
  echo "screen: off (TYPESAFE_API_KEY absent)" >&2
  exit 0
fi

# ---- inputs --------------------------------------------------------------------
[ -n "$QUESTION_FILE" ] || die "input file required (see --help)"
[ -r "$QUESTION_FILE" ] || die "input file not readable: $QUESTION_FILE"
[ -n "$QUESTION_FILE" ] || die "input file is empty: $QUESTION_FILE"

command -v jq >/dev/null 2>&1 || die "jq required"
command -v curl >/dev/null 2>&1 || die "curl required"

RESP_FILE=$(mktemp) || die "mktemp failed"
trap 'rm -f "$RESP_FILE"' EXIT

# ---- build and send the request ------------------------------------------------
REQUEST=$(jq -n --rawfile input "$QUESTION_FILE" --arg idle "$JEVI_IDLE" --arg window "$JEVI_WINDOW" --arg model "$TS_MODEL" '{
  model: $model,
  state: {screen: {input: $input, idle_secs: $idle, window: $window}},
  questions: {
    screen: {
      type: "choice",
      instructions: "What does this worker'"'"'s terminal pane tail (last ~40 lines, plain text) show? Choose the ONE option that best describes `screen.input`; `state.screen.idle_secs` and `state.screen.window` give the idle age and window identity when known.",
      criteria: {
        "actively-working": "streaming output, spinner, tool/step banner in flight",
        "waiting-at-prompt": "idle prompt or finished turn",
        "awaiting-user-input": "permission or question dialog",
        "stalled": "error loop, repeated traceback, unchanged error banner",
        "uncertain": "cannot determine from the input"
      }
    }
  }
}')

T0=$(fm_timing_now_ms)
HTTP=$(printf '%s' "$REQUEST" | curl -sS --max-time "$TS_TIMEOUT" -o "$RESP_FILE" -w '%{http_code}' \
  -X POST "$TS_BASE/v1/systemone" -H 'Content-Type: application/json' \
  -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$TYPESAFE_API_KEY_PRIVATE") \
  --data-binary @- 2>/dev/null) || HTTP=000
T1=$(fm_timing_now_ms)
LAT_MS=$(( T1 - T0 ))

# ---- validate response ---------------------------------------------------------
emit_error() {
  local reason=$1
  printf 'screen:\n  status: error\n  reason: %s\n' "$reason"
  exit 0
}

[ "$HTTP" = 200 ] || emit_error "http $HTTP after ${LAT_MS} ms"

jq -e '
  (.answers.screen.choice | type) == "string" and
  (.answers.screen.confidence | type) == "number" and
  .answers.screen.confidence >= 0 and .answers.screen.confidence <= 1 and
  (.answers.screen.probabilities | type) == "object" and
  all(.answers.screen.probabilities[]; type == "number" and . >= 0 and . <= 1) and
  ((.answers.screen.probabilities | [.[]] | add) as $total | $total >= 0.99 and $total <= 1.01) and
  ((has("usage") | not) or
    ((.usage | type) == "object" and
     (.usage.input_tokens | type) == "number" and
     (.usage.output_tokens | type) == "number"))
' "$RESP_FILE" >/dev/null 2>&1 || emit_error "response is not a screen Choice answer"

# ---- render TOON block ---------------------------------------------------------
CHOICE=$(jq -r '.answers.screen.choice' "$RESP_FILE")
CONFIDENCE=$(jq -r '.answers.screen.confidence' "$RESP_FILE")
INPUT_TOKENS=$(jq -r '.usage.input_tokens // 0' "$RESP_FILE")
OUTPUT_TOKENS=$(jq -r '.usage.output_tokens // 0' "$RESP_FILE")

printf 'screen:\n'
printf '  status: clear\n'
printf '  choice: %s\n' "$CHOICE"
printf '  confidence: %s\n' "$CONFIDENCE"
printf '  latency_ms: %s\n' "$LAT_MS"
printf '  tokens: %s/%s\n' "$INPUT_TOKENS" "$OUTPUT_TOKENS"
exit 0
