#!/usr/bin/env bash
# fm-jev-command-screen.sh - typed Jev command classification: one POST to
# /v1/systemone, validated TOON output.
#
# Usage:
#   fm-jev-command-screen.sh <input-file>
#
# The input file holds the command text to classify - for the Jev
# damage-control gate, the bash command a Pi session is about to run, with
# operands resolved and capped at 8 KiB by the policy owner. The tool wraps it
# into the standard Jev systemone request shape as `state.command.input`,
# pins the typed question and its closed four-option vocabulary in the
# question's criteria, sends the request, validates the response, and prints a
# `command:` TOON block on stdout.
#
# Opt-in gate: TYPESAFE_API_KEY non-empty in the process environment, or
#   a TYPESAFE_API_KEY= line in $FM_HOME/.env read via fmx_env_get.
#   Absent in both -> one "command: off" line on stderr, nothing on stdout,
#   exit 0, no network call.
# The key lives in one shell variable and reaches curl as a header read
# from a file descriptor, never on argv; nothing logs or writes it.
#
# Output (stdout, TOON-style block):
#   command:
#     status: clear | error
#     choice: <the selected option string>
#     confidence: <0.00-1.00>
#     latency_ms: <integer>
#     tokens: <input>/<output>
#   clear -> the choice is the classification verdict; confidence is advisory.
#   error -> API, network, response, or validation failure; exit 0.
#   Every outcome exits 0 so the caller never blocks on this tool.
#   Exit 2 only for a usage or configuration error (unreadable input
#   file, missing jq, missing curl).
#
# Environment:
#   TYPESAFE_API_KEY is the only classification-specific setting.
#   FM_JEV_GATE_TIMEOUT_S bounds the HTTP call; the gate sits in the tool hot
#   path, so the default is 3 s (the wedge screen uses 5 s).
#
# The closed choice vocabulary is validated here AND by the policy owner:
# an answer outside {benign, grey-reversible, destructive, uncertain} is an
# error, never a silently-mapped verdict.
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
TS_TIMEOUT=${FM_JEV_GATE_TIMEOUT_S:-3}
case "$TS_TIMEOUT" in
  ''|*[!0-9]*) TS_TIMEOUT=3 ;;
esac
[ "$TS_TIMEOUT" -gt 0 ] || TS_TIMEOUT=3

die() { printf 'error: %s\n' "$1" >&2; exit 2; }

COMMAND_FILE=''
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next}{exit}' "$0"
      exit 0
      ;;
    -*) die "unknown flag $1" ;;
    *) [ -z "$COMMAND_FILE" ] || die "one input file only"; COMMAND_FILE=$1; shift ;;
  esac
done

# ---- opt-in gate ---------------------------------------------------------------
if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
  TYPESAFE_API_KEY_PRIVATE=$(fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env")
fi
if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
  echo "command: off (TYPESAFE_API_KEY absent)" >&2
  exit 0
fi

# ---- inputs --------------------------------------------------------------------
[ -n "$COMMAND_FILE" ] || die "input file required (see --help)"
[ -r "$COMMAND_FILE" ] || die "input file not readable: $COMMAND_FILE"

command -v jq >/dev/null 2>&1 || die "jq required"
command -v curl >/dev/null 2>&1 || die "curl required"

RESP_FILE=$(mktemp) || die "mktemp failed"
trap 'rm -f "$RESP_FILE"' EXIT

# ---- build and send the request ------------------------------------------------
REQUEST=$(jq -n --rawfile input "$COMMAND_FILE" --arg model "$TS_MODEL" '{
  model: $model,
  state: {command: {input: $input, window: "jev-gate"}},
  questions: {
    command: {
      type: "choice",
      instructions: "The input is one shell command about to run in the captain'"'"'s firstmate helm session. Choose the ONE option that best describes `state.command.input`.",
      criteria: {
        "benign": "routine command, no plausible lasting damage",
        "grey-reversible": "touches or rewrites state but is plausibly recoverable",
        "destructive": "plausibly irreversible or catastrophic to system state, unlanded work, or fleet infrastructure",
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
  printf 'command:\n  status: error\n  reason: %s\n' "$reason"
  exit 0
}

[ "$HTTP" = 200 ] || emit_error "http $HTTP after ${LAT_MS} ms"

jq -e '
  (.answers.command.choice | type) == "string" and
  (.answers.command.choice | IN("benign", "grey-reversible", "destructive", "uncertain")) and
  (.answers.command.confidence | type) == "number" and
  .answers.command.confidence >= 0 and .answers.command.confidence <= 1 and
  (.answers.command.probabilities | type) == "object" and
  all(.answers.command.probabilities[]; type == "number" and . >= 0 and . <= 1) and
  ((.answers.command.probabilities | [.[]] | add) as $total | $total >= 0.99 and $total <= 1.01) and
  ((has("usage") | not) or
    ((.usage | type) == "object" and
     (.usage.input_tokens | type) == "number" and
     (.usage.output_tokens | type) == "number"))
' "$RESP_FILE" >/dev/null 2>&1 || emit_error "response is not a valid command Choice answer"

# ---- render TOON block ---------------------------------------------------------
CHOICE=$(jq -r '.answers.command.choice' "$RESP_FILE")
CONFIDENCE=$(jq -r '.answers.command.confidence' "$RESP_FILE")
INPUT_TOKENS=$(jq -r '.usage.input_tokens // 0' "$RESP_FILE")
OUTPUT_TOKENS=$(jq -r '.usage.output_tokens // 0' "$RESP_FILE")

printf 'command:\n'
printf '  status: clear\n'
printf '  choice: %s\n' "$CHOICE"
printf '  confidence: %s\n' "$CONFIDENCE"
printf '  latency_ms: %s\n' "$LAT_MS"
printf '  tokens: %s/%s\n' "$INPUT_TOKENS" "$OUTPUT_TOKENS"
exit 0
