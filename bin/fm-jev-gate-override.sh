#!/usr/bin/env bash
# fm-jev-gate-override.sh - readout and scripted-close helper for the Jev
# damage-control gate pilot.
#
# The dangerous-mode window opens ONLY through the extension's operator-facing
# /jev-override command and lives in that seat's memory; this helper has no
# "on" verb and confers no authority. It owns:
#
#   status                    window state, counters, breaker state, event
#                             chain verification, and the pilot readout lines
#   off                       scripted close: clears the seat-published view
#                             and records an override_close audit event
#                             (advisory - the window itself ends only via
#                             /jev-override off, TTL expiry, or shutdown)
#
# State lives under ${FM_STATE_OVERRIDE:-${FM_HOME:-repo}/state}/jev-gate/.
# status exits non-zero when the event hash chain fails verification.
set -u

usage() {
  cat <<'EOF'
Usage: fm-jev-gate-override.sh status
       fm-jev-gate-override.sh off
EOF
}

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || exit 0
FM_HOME=${FM_HOME:-$ROOT}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
GATE_STATE="$STATE/jev-gate"
TRANSPORT="$ROOT/bin/fm-jev-pretool-check.sh"

ZEROS="0000000000000000000000000000000000000000000000000000000000000000"

counter_value() {  # <key>
  awk -v k="$1" '$1==k{print $2}' "$GATE_STATE/counters" 2>/dev/null
}

chain_status() {  # <events-file>: prints the verification line, rc 1 when broken
  local file=$1
  if [ ! -f "$file" ]; then
    printf 'chain: no events yet\n'
    return 0
  fi
  local line sha prev_field canonical digest broken_seq
  local expected_prev=$ZEROS
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    sha=$(printf '%s' "$line" | jq -r '.sha256 // ""' 2>/dev/null) || sha=""
    prev_field=$(printf '%s' "$line" | jq -r '.prev_sha256 // ""' 2>/dev/null) || prev_field=""
    if [ "$prev_field" != "$expected_prev" ]; then
      broken_seq=$(printf '%s' "$line" | jq -r '.seq // "?"' 2>/dev/null)
      printf 'chain: BROKEN at seq %s (prev hash mismatch)\n' "$broken_seq"
      return 1
    fi
    canonical=$(printf '%s' "$line" | jq -c '.sha256 = ""' 2>/dev/null) || canonical=""
    digest=$(printf '%s' "$canonical" | sha256sum 2>/dev/null | awk '{print $1}')
    if [ "$digest" != "$sha" ]; then
      broken_seq=$(printf '%s' "$line" | jq -r '.seq // "?"' 2>/dev/null)
      printf 'chain: BROKEN at seq %s (hash mismatch)\n' "$broken_seq"
      return 1
    fi
    expected_prev=$sha
  done < "$file"
  printf 'chain: verified\n'
  return 0
}

cmd_status() {
  local view="$GATE_STATE/override-status" now remaining
  now=$(date +%s) || now=0
  if [ -r "$view" ]; then
    remaining=$(( $(jq -r '.expires_at // 0' "$view" 2>/dev/null) / 1000 - now ))
    [ "$remaining" -lt 0 ] && remaining=0
    printf 'window: open (remaining ~%s min)\n' "$((( remaining + 59 ) / 60 ))"
    printf 'reason: %s\n' "$(jq -r '.reason // ""' "$view" 2>/dev/null)"
  else
    printf 'window: closed\n'
  fi

  if [ -r "$GATE_STATE/counters" ]; then
    printf 'counters:\n'
    awk '{printf "  %s=%s\n", $1, $2}' "$GATE_STATE/counters"
  fi

  local breaker_failures breaker_cooldown
  breaker_failures=$(jq -r '.consecutive_failures // 0' "$GATE_STATE/breaker" 2>/dev/null || printf '0')
  breaker_cooldown=$(jq -r '.cooldown_until // 0' "$GATE_STATE/breaker" 2>/dev/null || printf '0')
  if [ "$breaker_failures" -ge 3 ] 2>/dev/null && [ "$breaker_cooldown" -gt $(( now * 1000 )) ] 2>/dev/null; then
    printf 'breaker: open (cooldown %ss remaining)\n' "$(( (breaker_cooldown - now * 1000) / 1000 ))"
  else
    printf 'breaker: closed\n'
  fi

  local chain_line chain_rc=0
  chain_line=$(chain_status "$GATE_STATE/events.jsonl") || chain_rc=$?
  printf '%s\n' "$chain_line"
  if [ "$chain_rc" -ne 0 ]; then
    return 1
  fi

  local overridden blocked
  overridden=$(counter_value overridden_block)
  overridden=${overridden:-0}
  blocked=$(( $(counter_value block_regex) + $(counter_value block_jev) ))
  printf 'false-block proxy: overridden/(regex+jev blocks) = %s/%s\n' "$overridden" "$blocked"
  printf 'jev availability: timeouts=%s errors=%s degraded=%s off=%s consults=%s\n' \
    "$(counter_value jev_timeout)" "$(counter_value jev_error)" \
    "$(counter_value jev_degraded)" "$(counter_value jev_off)" \
    "$(( $(counter_value consult_benign) + $(counter_value consult_grey) + $(counter_value consult_uncertain) ))"
  printf 'near-misses: %s\n' "$(counter_value near_miss)"
  return 0
}

cmd_off() {
  # Idempotent: no published view means nothing to close here.
  [ -e "$GATE_STATE/override-status" ] || exit 0
  rm -f "$GATE_STATE/override-status"
  [ -x "$TRANSPORT" ] && "$TRANSPORT" record-override close "scripted off" >/dev/null 2>&1
  exit 0
}

case "${1:-}" in
  status) shift; cmd_status "$@" ;;
  off) cmd_off ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
