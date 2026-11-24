#!/usr/bin/env bash
# fm-telegram-note.sh - the safe Telegram note submit helper.
#
# CONTRACT (this header is the one owner of the helper's mechanics).
#   This is the one filing path for a captain note that arrives through the
#   Hermes /fm skill: the body comes from stdin or from the one optional
#   file argument, NEVER from the command line, so quoting hazards and the
#   gateway's keyword filter cannot touch it, and the captain's words never
#   appear in a process list.
#
#   The request id is tg:<YYYYMMDD>:<sha256(body)[:12]>: the same body filed
#   again on the same day replays the original note (fm-inbox.sh's
#   --request-id idempotency), and the same body on a later day files fresh.
#
#   It calls fm-inbox.sh note --request-id <id> --source tg --json -, prints
#   that JSON as its entire stdout, and exits with the filing status only:
#   0 saved and announced (or a replay of it), 3 saved but NOT announced,
#   1 nothing saved, 2 usage. No pipelines mask the exit code; no side
#   effect can change it.
#
#   After a filing that exits 0 it pushes the accepted receipt
#   `fm: got it - note <id>` through bin/fm-tg.sh (key note.<id>.accepted).
#   The push is best effort: a failure is journaled by fm-tg.sh and re-sent
#   by its retry, and the helper still exits with the filing status, because
#   the note is the cargo and the receipt is only the confirmation.
#
#   PRIVACY: no secret, chat id, or token is ever printed; the receipt line
#   is firstmate's own one-liner. The helper never reads or writes anything
#   under ~/.hermes: that side of the channel is the /fm skill's own text.
#
# Environment:
#   FM_HOME / FM_STATE_OVERRIDE / FM_DATA_OVERRIDE / FM_CONFIG_OVERRIDE
#                       the usual home dirs, passed through to fm-inbox.sh
#                       and fm-tg.sh by inheritance.
#   FM_TG_TEST_CLOCK   (test seam, armed only with FM_TEST_SEAM=1) path to a
#                       file holding the current epoch; the request id's
#                       date comes from it.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"

die() { printf 'fm-telegram-note: %s\n' "$*" >&2; exit 2; }

command -v python3 >/dev/null 2>&1 || die "python3 is required to file a Telegram note"

case "${1:-}" in
  -h|--help)
    awk 'NR == 1 { next }
         /^#/ { sub(/^# ?/, ""); print; next }
         { exit }' "${BASH_SOURCE[0]}"
    exit 0
    ;;
esac

if [ "$#" -gt 1 ]; then
  die "usage: fm-telegram-note.sh [<note-file>] (body from the file, or stdin)"
fi

body=""
if [ "$#" -eq 1 ] && [ "$1" != "-" ]; then
  [ -r "$1" ] || die "cannot read note file: $1"
  body=$(cat "$1"; printf .)
else
  body=$(cat; printf .)
fi
body=${body%.}
[ -n "${body//[[:space:]]/}" ] || die "refusing to file an empty note"

# The clock seam keeps the request id's date testable; outside it, the date
# is today. Reading stdin through python keeps the hash byte-exact.
clock_epoch() {
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
  date +%s
}

now=$(clock_epoch)
request_id=$(printf '%s' "$body" | python3 -c '
import hashlib, sys, time
epoch = float(sys.argv[1])
body = sys.stdin.buffer.read()
stamp = time.strftime("%Y%m%d", time.gmtime(epoch))
print("tg:%s:%s" % (stamp, hashlib.sha256(body).hexdigest()[:12]))
' "$now") || die "could not compute the request id"

rc=0
filing=$(printf '%s' "$body" \
  | "$FM_ROOT/bin/fm-inbox.sh" note --request-id "$request_id" --source tg --json -) || rc=$?

if [ -n "$filing" ]; then
  printf '%s\n' "$filing"
fi

if [ "$rc" -eq 0 ] && [ -x "$FM_ROOT/bin/fm-tg.sh" ]; then
  note_id=$(printf '%s\n' "$filing" | python3 -c '
import json, sys
try:
    value = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
note_id = value.get("id")
if isinstance(note_id, str) and note_id:
    print(note_id)
' 2>/dev/null) || note_id=""
  if [ -n "$note_id" ]; then
    printf 'fm: got it - note %s\n' "$note_id" \
      | "$FM_ROOT/bin/fm-tg.sh" send --key "note.$note_id.accepted" \
        --source telegram-note >&2 || true
  fi
fi

exit "$rc"
