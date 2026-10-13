#!/usr/bin/env bash
# Stable PreToolUse transport for the Jev damage-control gate.
#
# bin/fm-jev-gate-policy.mjs is the sole owner of shell classification, the
# R/M catalogs, the Jev consult, and the pilot log. This wrapper only acquires
# the command, re-verifies the gate's scope independently of the extension
# seat, invokes that policy, and renders the Pi deny response. It never
# executes, sources, evaluates, or expands the submitted command.
# See docs/jev-gate.md for the complete contract and validation record.
#
# Usage:
#   printf '%s' "$CMD" | bin/fm-jev-pretool-check.sh [--pi]
#   bin/fm-jev-pretool-check.sh record-override <open|close|expire> [reason...]
#
# The command is acquired on stdin (never argv), so no argv-size limit can
# silently allow an oversized command. --pi is the explicit Pi render flag;
# the default render is already the Pi render (plain text on stderr).
#
# Exit/output contract:
#   ALLOW  - exit 0 and no output. Every failure posture renders as an allow:
#            malformed or empty stdin, a scope that fails to confirm (a task
#            worktree, a secondmate home, a worker FM_TASK_ID, git missing),
#            an absent or unreadable activation flag, a missing Node runtime
#            or policy owner, an invalid or empty policy response, or a policy
#            evaluation that hits the transport's own wall-clock bound.
#   DENY   - exit 2, the plain-text deny reason (with its confidence line) on
#            stderr, and stdout left empty. The one stdout exception: when
#            FM_JEV_GATE_CACHE_OUT=1, the policy's trailing cache hint line
#            (consult verdicts only) is forwarded verbatim for the seat's
#            per-session decision cache.
#
# Environment:
#   FM_ROOT_OVERRIDE / FM_HOME / FM_STATE_OVERRIDE / FM_CONFIG_OVERRIDE are
#   honored throughout for tests. FM_TASK_ID (present in every spawned worker
#   pane, never in the helm) makes the transport inert. FM_JEV_GATE_OVERRIDE=1
#   carries the extension seat's in-memory operator window; the flag only ever
#   affects the invocation the seat itself spawns. FM_JEV_GATE_CACHE carries
#   the seat's cached verdict hint as "<choice>,<confidence>".
#   FM_JEV_GATE_CACHE_OUT=1 asks the transport to re-emit the policy's
#   trailing cache hint line on stdout so the seat can keep its decision
#   cache warm; without it the hint is discarded.
set -u

usage() {
  cat <<'EOF'
Usage: printf '%s' "$CMD" | fm-jev-pretool-check.sh [--pi]
       fm-jev-pretool-check.sh record-override <open|close|expire> [reason...]

Reads the command on stdin, classifies it through the Jev gate policy owner,
and exits 0 to allow or 2 to deny (plain-text reason on stderr). The
record-override action only appends audit events; it confers no authority.
EOF
}

PI_MODE=0
ACTION=""
REASON_TEXT=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pi) PI_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    record-override)
      [ "$#" -ge 2 ] || { echo "error: record-override needs open|close|expire" >&2; exit 2; }
      ACTION=$2
      shift 2
      REASON_TEXT="$*"
      shift "$#"
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$ROOT}
FM_HOME=${FM_HOME:-$FM_ROOT}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}

# ---- audit action: append an override lifecycle event, confer nothing ----------

record_override_event() {
  local kind=$1
  case "$kind" in
    open|close|expire) ;;
    *) echo "error: record-override needs open|close|expire" >&2; exit 2 ;;
  esac
  command -v node >/dev/null 2>&1 || exit 0
  local policy="$ROOT/bin/fm-jev-gate-policy.mjs"
  [ -f "$policy" ] || exit 0
  mkdir -p "$STATE" 2>/dev/null || exit 0
  local -a args=(--state "$STATE" --posture enforce --record "$kind")
  if [ -n "$REASON_TEXT" ]; then
    args+=(--reason "$REASON_TEXT")
  fi
  node "$policy" "${args[@]}" </dev/null >/dev/null 2>&1 || exit 0
  exit 0
}

if [ -n "$ACTION" ]; then
  record_override_event "$ACTION"
fi

# ---- judge action ---------------------------------------------------------------

CMD=""
CMD=$(cat 2>/dev/null || true)
[ -n "$CMD" ] || exit 0

# L4 - worker environment marker: every spawned ship/scout pane carries
# FM_TASK_ID and is never gated; the helm never has it.
[ -n "${FM_TASK_ID:-}" ] && exit 0

# L3 - transport scope guard: a plain, non-worktree firstmate checkout (the
# cd-guard mechanism), never a secondmate home. Any failure to confirm the
# scope is inert (exit 0), never a block.
[ -f "$FM_ROOT/AGENTS.md" ] || exit 0
[ -d "$FM_ROOT/bin" ] || exit 0
command -v git >/dev/null 2>&1 || exit 0
GIT_DIR=$(git -C "$FM_ROOT" rev-parse --git-dir 2>/dev/null) || exit 0
GIT_COMMON_DIR=$(git -C "$FM_ROOT" rev-parse --git-common-dir 2>/dev/null) || exit 0
[ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || exit 0
[ ! -e "$FM_HOME/.fm-secondmate-home" ] || exit 0

# L2 - activation flag: absent means off (fully inert); an unreadable or
# unknown value degrades to shadow, never silently to off or enforce.
[ -r "$CONFIG/jev-gate" ] || exit 0
ACTIVATION=$(tr -d '[:space:]' < "$CONFIG/jev-gate" 2>/dev/null) || ACTIVATION=""
case "$ACTIVATION" in
  enforce) POSTURE=enforce ;;
  shadow) POSTURE=shadow ;;
  *) POSTURE=shadow ;;
esac

command -v node >/dev/null 2>&1 || exit 0
POLICY="$ROOT/bin/fm-jev-gate-policy.mjs"
[ -f "$POLICY" ] || exit 0

TIMEOUT_S=${FM_JEV_GATE_TIMEOUT_S:-3}
case "$TIMEOUT_S" in
  ''|*[!0-9]*) TIMEOUT_S=3 ;;
esac
[ "$TIMEOUT_S" -gt 0 ] || TIMEOUT_S=3
WALL_S=$(( TIMEOUT_S + 8 ))

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

POLICY_ARGS=(--root "$FM_ROOT" --home "$FM_HOME" --state "$STATE" --config "$CONFIG" --posture "$POSTURE")
if [ "${FM_JEV_GATE_OVERRIDE:-}" = "1" ]; then
  POLICY_ARGS+=(--override-active 1)
fi
if [ -n "${FM_JEV_GATE_CACHE:-}" ]; then
  CACHE_CHOICE=${FM_JEV_GATE_CACHE%%,*}
  CACHE_CONF=${FM_JEV_GATE_CACHE#*,}
  if [ -n "$CACHE_CHOICE" ] && [ "$CACHE_CONF" != "$FM_JEV_GATE_CACHE" ]; then
    POLICY_ARGS+=(--cached-choice "$CACHE_CHOICE" --cached-confidence "$CACHE_CONF")
  fi
fi

POLICY_OUTPUT=$(printf '%s' "$CMD" | fm_run_timed "$WALL_S" node "$POLICY" "${POLICY_ARGS[@]}" 2>/dev/null) || POLICY_OUTPUT=""
[ -n "$POLICY_OUTPUT" ] || exit 0

TAB=$(printf '\t')
NL='
'

# A consult verdict appends one trailing cache hint line after the decision
# line. It is never part of the decision: strip it before parsing (so the
# deny reason stays clean), and forward it on stdout only when the seat
# asked for it through FM_JEV_GATE_CACHE_OUT.
DECISION_OUTPUT=$POLICY_OUTPUT
LAST_LINE=${POLICY_OUTPUT##*"$NL"}
case "$LAST_LINE" in
  cache"$TAB"*)
    DECISION_OUTPUT=${POLICY_OUTPUT%"$LAST_LINE"}
    DECISION_OUTPUT=${DECISION_OUTPUT%"$NL"}
    if [ "${FM_JEV_GATE_CACHE_OUT:-}" = "1" ]; then
      printf '%s\n' "$LAST_LINE"
    fi
    ;;
esac

DECISION=${DECISION_OUTPUT%%"$TAB"*}
[ "$DECISION" = "block" ] || exit 0
REST=${DECISION_OUTPUT#*"$TAB"}
[ "$REST" != "$DECISION_OUTPUT" ] || exit 0
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] || exit 0

# Pi render: plain text on stderr with the confidence line; stdout stays
# empty (the cache hint forwarding above is the one flagged exception).
printf '%s\n' "$REASON" >&2
exit 2
