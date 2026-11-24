#!/usr/bin/env bash
# fm-tg.sh - the outbound Telegram lane.
#
# CONTRACT (this header is the one owner of the lane's mechanics).
#   One script owns every line that leaves firstmate for Telegram. Hooks push
#   with `send`, the wake drain retries with `retry`, and `failed` is the
#   human view of what is still queued. No other firstmate code calls hermes.
#   This script is a leaf: it never files a note, never appends a wake, and
#   never calls any other fm- surface, so no receipt can trigger fleet work.
#
# Usage:
#   fm-tg.sh send --key <event-key> [--source <hook-name>]   # one line, stdin
#   fm-tg.sh retry [--max <n>]                               # re-send unsent keys
#   fm-tg.sh failed                                          # human view of unsent keys
#
#   The line for `send` is the whole of stdin: newline and tab runs collapse
#   to single spaces and the result is capped at 300 characters, so one event
#   is one short line. An empty line is refused.
#
#   The engine is `hermes send --to <target> --quiet --file -` with the line
#   on stdin, never argv, and the engine's exit code passes through as this
#   script's own. The engine's own stderr is discarded: a delivery error can
#   echo the target or account details, and the exit code plus the journal
#   are the diagnostics this lane promises.
#
#   Target and engine resolution:
#     config/tg-target            the delivery target, the ONLY place it
#                                 lives. Absent means the lane is OFF: every
#                                 push fails closed with one journal line and
#                                 one stderr line, and nothing is sent.
#     config/tg-hermes-bin        optional explicit hermes binary, wins over
#                                 every discovery path.
#     PATH, then $HOME/.hermes/hermes-agent/.venv/bin/hermes (the canonical
#     install dir), then ~/.local/bin/hermes when it is a live link. A broken
#     symlink resolves to nothing. No usable binary is a loud one-line
#     failure (exit 5), journaled like any other refusal.
#
#   Journal: $STATE/tg/journal.jsonl, strictly append-only, one JSON object
#   per attempt: {"at":<epoch>,"key":<key>,"rc":<exit>,"source":<hook>,
#   "line":"<the normalized line>"} plus "reason" on refusals that never
#   reached the engine. `at` and `line` are the retry inputs, so a journaled
#   line is always re-sendable. A key is SENT when any of its rows has
#   rc=0: `send` for a sent key is a no-op that prints `already-sent` and
#   writes nothing, so one event is one line even across processes. A key is
#   UNSENT otherwise; its latest row's `at` is its age. Every read validates
#   the whole file and fails closed on a malformed row: the journal is the
#   dedupe oracle, and guessing around corruption could double-send. Retention
#   is unbounded (volumes are a few lines a day); truncation, if ever needed,
#   is a captain-approved manual act, and it may allow a truncated key to be
#   sent again.
#
#   Retry: `retry` re-sends unsent keys whose latest attempt is at least 60 s
#   old, oldest first, at most --max per invocation (default 5), using the
#   journaled line, key, and source. It is a delivery mechanic, not an alarm:
#   no wake is ever created. With the lane off or hermes missing it fails
#   closed without touching the journal.
#
#   Rate limit: every send serializes under the home's portable lock
#   ($STATE/tg/.send.lock, the fm-wake-lib lock, which reclaims a dead
#   holder's lock instead of depending on flock) with a minimum 1.1 s spacing
#   between send starts, held in $STATE/tg/.last-send. Delivery is
#   at-least-once: a success is journaled after the send, so a crash between
#   the engine accepting a line and the journal append can re-send that one
#   line on retry.
#
#   Environment:
#     FM_HOME / FM_STATE_OVERRIDE / FM_CONFIG_OVERRIDE   the usual home dirs.
#     FM_TG_LOCK_WAIT    seconds one send waits for the send lock before it
#                       journals a lock-busy failure and exits 1 (default 30).
#     FM_TG_TEST_CLOCK  (test seam, armed only with FM_TEST_SEAM=1) absolute
#                       path to a file holding the current epoch (digits with
#                       an optional fraction). The clock, the journal `at`
#                       stamps, and the retry ages all read it, and a
#                       rate-limit wait advances it instead of sleeping.
#
#   PRIVACY: the target lives only in gitignored config/tg-target and is
#   never printed; lines travel on stdin; the engine's stderr is discarded;
#   the journal holds the sent line itself, in gitignored state/.
#
# Exit codes:
#   0  sent, retried, or already-sent
#   1  the engine failed, or the attempt could not complete
#   2  usage error, or the journal is corrupt (nothing was sent)
#   4  the lane is off: no config/tg-target (nothing was sent, journaled)
#   5  no usable hermes binary (nothing was sent, journaled)
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
TG_DIR="$STATE/tg"
JOURNAL="$TG_DIR/journal.jsonl"
LOCK="$TG_DIR/.send.lock"
LAST_SEND="$TG_DIR/.last-send"

SPACING=1.1
RETRY_GRACE=60
RETRY_MAX_DEFAULT=5
LOCK_WAIT="${FM_TG_LOCK_WAIT:-30}"

TARGET=""
HERMES_BIN=""
TG_SEND_AT=""

die() { printf 'fm-tg: %s\n' "$*" >&2; exit 2; }

# First non-comment, non-blank line of a config file, or nothing.
read_setting() {  # <file-name>
  local path="$CONFIG/$1" line
  [ -r "$path" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    printf '%s' "$line"
    return 0
  done < "$path"
}

# The clock seam is the single owner of "now" for journal stamps, retry
# ages, and rate limiting. Outside the test seam it is the wall clock.
clock_now() {
  local value
  if [ -n "${FM_TG_TEST_CLOCK:-}" ] && [ "${FM_TEST_SEAM:-}" = 1 ]; then
    value=$(sed -n '1p' "$FM_TG_TEST_CLOCK" 2>/dev/null) \
      || die "FM_TG_TEST_CLOCK is set but unreadable: $FM_TG_TEST_CLOCK"
    case "$value" in
      ''|*[!0-9.]*) die "FM_TG_TEST_CLOCK must hold an epoch (digits, optional fraction)" ;;
    esac
    printf '%s\n' "$value"
    return 0
  fi
  value=$(date +%s.%N 2>/dev/null || true)
  case "$value" in
    ''|*[!0-9.]*) value=$(date +%s) ;;
  esac
  printf '%s\n' "$value"
}

valid_key() {
  case "$1" in
    ''|.*|*/*|*[[:space:]]*) return 1 ;;
  esac
  [ "${#1}" -le 128 ] || return 1
  case "$1" in
    *[!A-Za-z0-9._:-]*) return 1 ;;
  esac
  return 0
}

valid_source() {
  case "$1" in
    ''|*[[:space:]]*) return 1 ;;
  esac
  [ "${#1}" -le 32 ] || return 1
  case "$1" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# ---------------------------------------------------------------- journal

# journal <mode> [args...]: the JSONL oracle. Exit 0/1 answer `sent`; exit 3
# means corruption, and every wrapper turns that into this script's exit 2.
journal() {
  command -v python3 >/dev/null 2>&1 \
    || die "python3 is required for the Telegram journal"
  python3 - "$JOURNAL" "$@" <<'PY'
import json, sys

path, mode = sys.argv[1], sys.argv[2]

def refuse(lineno):
    sys.stderr.write(
        "fm-tg: journal %s line %d is malformed; refusing to send or retry "
        "until it is repaired or truncated manually\n" % (path, lineno))
    sys.exit(3)

def rows():
    try:
        handle = open(path, encoding="utf-8")
    except FileNotFoundError:
        return
    with handle:
        for lineno, raw in enumerate(handle, 1):
            raw = raw.strip()
            if not raw:
                continue
            try:
                row = json.loads(raw)
            except ValueError:
                refuse(lineno)
            if not isinstance(row, dict):
                refuse(lineno)
            if not (isinstance(row.get("key"), str)
                    and isinstance(row.get("rc"), int)
                    and isinstance(row.get("at"), (int, float))
                    and isinstance(row.get("line"), str)
                    and isinstance(row.get("source"), str)):
                refuse(lineno)
            yield row

if mode == "sent":
    key = sys.argv[3]
    for row in rows():
        if row["key"] == key and row["rc"] == 0:
            sys.exit(0)
    sys.exit(1)

if mode == "append":
    at, key, rc, source, line = sys.argv[3:8]
    reason = sys.argv[8] if len(sys.argv) > 8 else None
    row = {"at": float(at), "key": key, "rc": int(rc),
           "source": source, "line": line}
    if reason is not None:
        row["reason"] = reason
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(row, separators=(",", ":")) + "\n")
    sys.exit(0)

# state[key] = (latest row, any success) for both remaining modes.
state = {}
for row in rows():
    entry = state.setdefault(row["key"], [None, False])
    if row["rc"] == 0:
        entry[1] = True
    entry[0] = row

if mode == "unsent":
    now, min_age, cap = float(sys.argv[3]), float(sys.argv[4]), int(sys.argv[5])
    unsent = []
    for key, (row, sent) in state.items():
        if sent or now - row["at"] < min_age:
            continue
        unsent.append((row["at"], key, row))
    unsent.sort(key=lambda entry: (entry[0], entry[1]))
    for at, key, row in unsent[:cap]:
        print("%s\t%s\t%s\t%s\t%s"
              % (key, at, row["rc"], row["source"], row["line"]))
    sys.exit(0)

if mode == "failed":
    now = float(sys.argv[3])
    unsent = []
    for key, (row, sent) in state.items():
        if not sent:
            unsent.append((row["at"], key, row))
    unsent.sort(key=lambda entry: (entry[0], entry[1]))
    for at, key, row in unsent:
        print("%s rc=%s %ss ago: %s" % (key, row["rc"], int(now - at), row["line"]))
    sys.exit(0)

sys.stderr.write("fm-tg: unknown journal mode: %s\n" % mode)
sys.exit(3)
PY
}

journal_sent() {  # <key> -> 0 sent, 1 not sent; exit 2 on a corrupt journal
  local rc=0
  journal sent "$1" || rc=$?
  case "$rc" in
    0|1) return "$rc" ;;
    *) exit 2 ;;
  esac
}

journal_unsent() {  # <now> <min-age> <cap> -> TSV lines; exit 2 on corruption
  local rc=0
  journal unsent "$1" "$2" "$3" || rc=$?
  case "$rc" in
    0) return 0 ;;
    *) exit 2 ;;
  esac
}

journal_append_row() {  # <at> <key> <rc> <source> <line> [reason]
  if [ -n "${6:-}" ]; then
    journal append "$1" "$2" "$3" "$4" "$5" "$6" || return 1
  else
    journal append "$1" "$2" "$3" "$4" "$5" || return 1
  fi
  return 0
}

# ---------------------------------------------------------------- send lock

load_lock_lib() {
  [ "${FM_TG_WAKE_LIB:-}" = 1 ] && return 0
  [ -r "$FM_ROOT/bin/fm-wake-lib.sh" ] \
    || die "the send lock needs $FM_ROOT/bin/fm-wake-lib.sh"
  # shellcheck source=bin/fm-wake-lib.sh
  FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" STATE="$STATE" \
    . "$FM_ROOT/bin/fm-wake-lib.sh"
  FM_TG_WAKE_LIB=1
}

acquire_lock() {
  load_lock_lib
  fm_lock_acquire_wait_max "$LOCK" "$LOCK_WAIT"
}

release_lock() {
  fm_lock_release "$LOCK"
}

# ---------------------------------------------------------------- send

# Read the whole of stdin as the line, one line, capped. The newline-to-
# space collapse can leave trailing whitespace; trim the tail so the engine,
# the journal, and the retry all see the exact same line.
read_line() {
  local raw
  raw=$(cat; printf .)
  raw=${raw%.}
  raw=$(printf '%s' "$raw" | tr '\n\t' '  ')
  raw=${raw%"${raw##*[![:space:]]}"}
  printf '%s' "${raw:0:300}"
}

resolve_hermes() {
  local candidate
  candidate=$(read_setting tg-hermes-bin)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    HERMES_BIN=$candidate
    return 0
  fi
  if command -v hermes >/dev/null 2>&1; then
    HERMES_BIN=$(command -v hermes)
    return 0
  fi
  candidate="$HOME/.hermes/hermes-agent/.venv/bin/hermes"
  if [ -x "$candidate" ]; then
    HERMES_BIN=$candidate
    return 0
  fi
  candidate="$HOME/.local/bin/hermes"
  if [ -L "$candidate" ] && [ -x "$candidate" ]; then
    HERMES_BIN=$candidate
    return 0
  fi
  return 5
}

# Hold the send lock, then space the send at least SPACING after the previous
# send's start. A test-seam wait advances the clock file instead of sleeping;
# a real wait sleeps the shortfall. Sets TG_SEND_AT to the send's start time.
rate_limit_wait() {
  local last now gap target delta
  last=$(sed -n '1p' "$LAST_SEND" 2>/dev/null || true)
  case "$last" in
    ''|*[!0-9.]*) last=0 ;;
  esac
  now=$(clock_now)
  gap=$(awk -v n="$now" -v l="$last" 'BEGIN { printf "%.6f", n - l }')
  if awk -v g="$gap" -v s="$SPACING" 'BEGIN { exit (g >= s) ? 0 : 1 }'; then
    TG_SEND_AT=$now
    return 0
  fi
  target=$(awk -v l="$last" -v s="$SPACING" 'BEGIN { printf "%.6f", l + s }')
  if [ -n "${FM_TG_TEST_CLOCK:-}" ] && [ "${FM_TEST_SEAM:-}" = 1 ]; then
    printf '%s\n' "$target" > "$FM_TG_TEST_CLOCK" 2>/dev/null || true
  else
    delta=$(awk -v t="$target" -v n="$now" \
      'BEGIN { d = t - n; if (d < 0) d = 0; printf "%.3f", d }')
    [ "$delta" = "0.000" ] || sleep "$delta"
  fi
  TG_SEND_AT=$target
}

# The locked send body. Every failure is an explicit return; a die here would
# exit with the lock held. The EXIT trap in send_locked is the backstop.
send_locked_body() {  # <key> <source> <line> [verb]
  local key=$1 source=$2 line=$3 verb=${4:-sent}
  local rc=0
  if journal_sent "$key"; then
    printf 'already-sent %s\n' "$key"
    return 0
  fi
  rate_limit_wait
  printf '%s\n' "$line" \
    | "$HERMES_BIN" send --to "$TARGET" --quiet --file - >/dev/null 2>/dev/null || rc=$?
  printf '%s\n' "$TG_SEND_AT" > "$LAST_SEND" 2>/dev/null || true
  if ! journal_append_row "$TG_SEND_AT" "$key" "$rc" "$source" "$line"; then
    printf 'fm-tg: journal append failed; %s may be re-sent by a later retry\n' "$key" >&2
    rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    printf '%s %s\n' "$verb" "$key"
  else
    printf 'fm-tg: send failed for %s (engine exit %s); the line stays queued for retry\n' \
      "$key" "$rc" >&2
  fi
  return "$rc"
}

send_locked() {  # <key> <source> <line> [verb] -> the attempt's exit code
  local key=$1 source=$2 line=$3 verb=${4:-sent}
  local rc=0
  if journal_sent "$key"; then
    printf 'already-sent %s\n' "$key"
    return 0
  fi
  if ! acquire_lock; then
    local at
    at=$(clock_now)
    journal_append_row "$at" "$key" 1 "$source" "$line" \
      "send lock busy after ${LOCK_WAIT}s" || true
    printf 'fm-tg: send lock busy after %ss: %s\n' "$LOCK_WAIT" "$LOCK" >&2
    return 1
  fi
  # From here until release, an unexpected exit must not leak the lock.
  trap 'fm_lock_release "$LOCK" 2>/dev/null || true' EXIT
  send_locked_body "$key" "$source" "$line" "$verb" || rc=$?
  release_lock || true
  trap - EXIT
  return "$rc"
}

cmd_send() {
  local key="" source="direct" line at
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --key)
        [ "$#" -ge 2 ] \
          || die "usage: fm-tg.sh send --key <event-key> [--source <hook-name>]"
        key=$2
        shift 2
        ;;
      --source)
        [ "$#" -ge 2 ] \
          || die "usage: fm-tg.sh send --key <event-key> [--source <hook-name>]"
        source=$2
        shift 2
        ;;
      -h|--help) die "usage: fm-tg.sh send --key <event-key> [--source <hook-name>]" ;;
      *) die "unknown option for send: $1" ;;
    esac
  done
  valid_key "$key" || die "invalid event key (use 1-128 characters: A-Za-z0-9._:-)"
  valid_source "$source" || die "invalid source label (use 1-32 characters: A-Za-z0-9._-)"
  line=$(read_line)
  [ -n "$line" ] || die "refusing to send an empty line"
  mkdir -p "$TG_DIR" 2>/dev/null \
    || { printf 'fm-tg: cannot create state directory %s\n' "$TG_DIR" >&2; exit 1; }
  TARGET=$(read_setting tg-target)
  if [ -z "$TARGET" ]; then
    at=$(clock_now)
    journal_append_row "$at" "$key" 4 "$source" "$line" \
      "lane off: no $CONFIG/tg-target" || true
    printf 'fm-tg: telegram lane is off: no %s/tg-target; nothing was sent\n' "$CONFIG" >&2
    return 4
  fi
  if ! resolve_hermes; then
    at=$(clock_now)
    journal_append_row "$at" "$key" 5 "$source" "$line" "no usable hermes binary" || true
    printf 'fm-tg: no usable hermes binary (PATH, %s/.hermes/hermes-agent/.venv/bin/hermes, ~/.local/bin/hermes, or %s/tg-hermes-bin); nothing was sent\n' \
      "$HOME" "$CONFIG" >&2
    return 5
  fi
  send_locked "$key" "$source" "$line"
}

# ---------------------------------------------------------------- retry

cmd_retry() {
  local max=$RETRY_MAX_DEFAULT now rows key at rc source line any_fail=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --max)
        [ "$#" -ge 2 ] || die "usage: fm-tg.sh retry [--max <n>]"
        max=$2
        case "$max" in
          ''|*[!0-9]*|0*) die "retry --max wants a positive integer" ;;
        esac
        shift 2
        ;;
      -h|--help) die "usage: fm-tg.sh retry [--max <n>]" ;;
      *) die "unknown option for retry: $1" ;;
    esac
  done
  TARGET=$(read_setting tg-target)
  if [ -z "$TARGET" ]; then
    printf 'fm-tg: telegram lane is off: no %s/tg-target; nothing was retried\n' "$CONFIG" >&2
    return 4
  fi
  if ! resolve_hermes; then
    printf 'fm-tg: no usable hermes binary (PATH, %s/.hermes/hermes-agent/.venv/bin/hermes, ~/.local/bin/hermes, or %s/tg-hermes-bin); nothing was retried\n' \
      "$HOME" "$CONFIG" >&2
    return 5
  fi
  mkdir -p "$TG_DIR" 2>/dev/null \
    || { printf 'fm-tg: cannot create state directory %s\n' "$TG_DIR" >&2; exit 1; }
  now=$(clock_now)
  rows=$(journal_unsent "$now" "$RETRY_GRACE" "$max")
  [ -n "$rows" ] || return 0
  # A here-string, not a pipe: the loop must run in this shell so any_fail
  # survives, and the value is used literally, never re-expanded.
  while IFS=$'\t' read -r key at rc source line; do
    [ -n "$key" ] || continue
    send_locked "$key" "$source" "$line" retried || any_fail=1
  done <<< "$rows"
  return "$any_fail"
}

# ---------------------------------------------------------------- failed

cmd_failed() {
  [ "$#" -eq 0 ] || die "usage: fm-tg.sh failed"
  local now out
  now=$(clock_now)
  out=$(journal failed "$now") || exit 2
  [ -n "$out" ] || return 0
  printf '%s\n' "$out"
  return 0
}

# ---------------------------------------------------------------- dispatch

case "${1:-}" in
  send)    shift; cmd_send "$@" ;;
  retry)   shift; cmd_retry "$@" ;;
  failed)  shift; cmd_failed "$@" ;;
  ''|-h|--help|help)
    # The whole header block, found rather than counted, so this help cannot
    # silently truncate when the header grows.
    awk 'NR == 1 { next }
         /^#/ { sub(/^# ?/, ""); print; next }
         { exit }' "${BASH_SOURCE[0]}" ;;
  *) die "unknown subcommand: $1 (try --help)" ;;
esac
