#!/usr/bin/env bash
# fm-helm-reset.sh - the gated bedtime reset for the PRIMARY pi helm: at a
# safe overnight boundary, /new the helm session and submit the continuation
# prompt so the fresh session resumes from the stowed handoff.
#
# SAFETY CONTRACT (captain-approved helm-freshness design): the reset is GATED
# and never fires on an arbitrary turn. Gates 1-5 must ALL pass; the first
# failing gate atomically replaces state/.helm-reset.refusal (so the file
# always names the LATEST refusal, for morning diagnosis), says so on stderr,
# and exits 3 without touching the pane:
#   1. away-posture  state/.afk-contract exists - the captain is away.
#   2. wake-queue    no unacknowledged rows in the durable wake queue (any
#                    kind), read under the queue lock through
#                    bin/fm-wake-lib.sh's fm_wake_queued_keys.
#   3. leases        no LIVE task lease (state/.lease-*) under
#                    bin/fm-lease-lib.sh's own fm_lease_live contract; a stale
#                    lease passes and is never cleaned here (read-only gate).
#   4. workers       every state/<id>.meta reads done or unknown through
#                    bin/fm-crew-state.sh: no working/parked/blocked/paused/
#                    failed worker, and an unreadable verdict refuses (an
#                    instrument failure must not read as a safe boundary).
#   5. window        local wall-clock time is inside the configured window
#                    (default 01:00-02:00; start > end wraps past midnight).
#   6. dry-run       config/helm-reset's dry-run flag (default true) decides
#                    whether anything is sent. A dry run performs every gate,
#                    the pane discovery, and the composer verification, sends
#                    nothing, and records what it would have done in
#                    state/.helm-reset.last.
#
# ACTION (all gates pass, dry-run off; herdr only):
#   - resolve the primary helm pane (discovery below) and verify it exists;
#   - refuse unless the composer verdict is exactly `empty` (the shared owner
#     bin/fm-composer-lib.sh, via fm_backend_composer_state);
#   - type `/new` ONCE and submit it through fm_backend_send_text_submit
#     (Enter-only retries, never retyped - a swallowed Enter leaves the text
#     in the composer and retyping would duplicate it), requiring the
#     confirmed `empty` verdict;
#   - wait for the FRESH session: herdr's native agent registration (`agent
#     get`, .result.agent.agent_session.value - the pi session file herdr
#     observed) must change from its pre-/new value, proving pi started a new
#     session, or - when herdr never reported a session value to compare -
#     the composer must read `empty` on two consecutive polls; then the
#     composer must read `empty`;
#   - type the continuation prompt ONCE and submit it, again requiring the
#     confirmed `empty` verdict; any other verdict is a loud refusal naming
#     the verdict (the text may sit unsubmitted in the composer - morning
#     diagnosis reads state/.helm-reset.refusal; nothing is ever retyped).
#
# PANE DISCOVERY (herdr, FM_HOME-scoped): the helm session is by definition
# the pi process holding this home's session lock (state/.lock), and herdr
# injected the pane identity into that process's environment, so:
#   1. FM_SUPERVISOR_TARGET - explicit "<herdr-session>:<pane-id>" override
#      (the away daemon's hook); still verified against the lock holder.
#   2. otherwise read state/.lock's holder pid, require it alive, and read
#      HERDR_PANE_ID / HERDR_SESSION from /proc/<pid>/environ, then prove the
#      pane's shell is an ancestor of the lock holder via `pane process-info`
#      plus a ps ppid walk (the guard against a stale environment after herdr
#      moved the pane). A missing /proc (non-Linux), a missing identity, or
#      any mismatch refuses; nothing is ever guessed between candidates.
#
# CONFIG (config/helm-reset, LOCAL + gitignored; ABSENT = feature off, a
# quiet exit 0 - schema owner: docs/configuration.md "Helm reset"):
#   enabled=true           absent file or enabled=false means off
#   window-start=01:00     local HH:MM, inclusive start (default 01:00)
#   window-end=02:00       local HH:MM, exclusive end (default 02:00)
#   dry-run=true           default true: nothing is sent until explicitly false
# Unknown keys, malformed times, and values other than true/false refuse
# loudly (refusal marker + exit 3): a typo must never silently flip the
# feature or its safety.
#
# INSTALL (opt-in; nothing system-wide is installed by default): print the
# systemd USER unit templates and install them with:
#   bin/fm-helm-reset.sh --print-unit service > ~/.config/systemd/user/fm-helm-reset.service
#   bin/fm-helm-reset.sh --print-unit timer  > ~/.config/systemd/user/fm-helm-reset.timer
#   systemctl --user daemon-reload && systemctl --user enable --now fm-helm-reset.timer
# The timer fires at the default window start; the script's own gates (not
# the timer) decide whether a given fire actually resets, so a stale or
# mistimed fire is a logged refusal, never a reset. ExecStart is generated
# from the running script's own path; set Environment=FM_HOME in the unit
# when the firstmate home is not the checkout the script lives in. The /stow
# pass itself stays a helm discipline (it runs at away entry); the
# continuation prompt only points the fresh session at the stowed handoff.
#
# USAGE: bin/fm-helm-reset.sh [--dry-run] [--print-unit [service|timer]] [--help]
#   --dry-run   force this run's dry-run posture regardless of config (can
#               only make a run safer; there is no flag that forces a send)
# Exits: 0 gates passed (reset performed, dry-run recorded, or feature off);
#   3 a gate refused (refusal marker written); 2 usage error.
#
# Test knobs (defaults are the production behavior): FM_HELM_RESET_NOW
# (HH:MM clock override), FM_HELM_RESET_CONFIG (config path override),
# FM_HELM_RESET_CREW_STATE_BIN (default bin/fm-crew-state.sh),
# FM_HELM_RESET_PS_BIN (default ps, the ancestry walk's process table),
# FM_PROC_ROOT_OVERRIDE (default /proc, shared with bin/fm-wake-lib.sh),
# FM_HELM_RESET_RESTART_WAIT (default 60s) and FM_HELM_RESET_POLL
# (default 1s) for the fresh-session wait, and FM_HELM_RESET_RETRIES /
# FM_HELM_RESET_SLEEP / FM_HELM_RESET_SETTLE for the submit cores.
# Requires: bash, jq (the herdr adapter's requirement). set -u safe.

set -u

FM_HELM_RESET_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_HELM_RESET_SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"

FM_HELM_RESET_REFUSE_EXIT=3
# The continuation prompt, verbatim from the approved helm-freshness design.
FM_HELM_RESET_PROMPT='Read the stowed handoff file if present (and the session-start digest) and continue working.'
FM_HELM_RESET_CONFIG="${FM_HELM_RESET_CONFIG:-$FM_HOME/config/helm-reset}"
FM_HELM_RESET_DEFAULT_WINDOW_START=01:00
FM_HELM_RESET_DEFAULT_WINDOW_END=02:00
FM_HELM_RESET_CREW_STATE_BIN="${FM_HELM_RESET_CREW_STATE_BIN:-$FM_HELM_RESET_SCRIPT_DIR/fm-crew-state.sh}"

# Shared wake-queue, lock, and pid-liveness helpers (also resolves STATE and
# creates it when missing, matching every other wake-library consumer).
# shellcheck source=bin/fm-wake-lib.sh
. "$FM_HELM_RESET_SCRIPT_DIR/fm-wake-lib.sh"
# Lease liveness comes from the contract's single owner.
# shellcheck source=bin/fm-lease-lib.sh
. "$FM_HELM_RESET_SCRIPT_DIR/fm-lease-lib.sh"

# The herdr adapter is sourced lazily by fm_backend_source (first pane read),
# so the gate path never pays for it.
# shellcheck source=bin/fm-backend.sh
. "$FM_HELM_RESET_SCRIPT_DIR/fm-backend.sh"

helm_reset_usage() {
  cat <<'EOF'
usage: bin/fm-helm-reset.sh [--dry-run] [--print-unit [service|timer]] [--help]

Gated bedtime reset for the primary pi helm: /new the helm session and submit
the continuation prompt so the fresh session resumes from the stowed handoff.
Every gate (away posture, empty wake queue, no live leases, no live non-done
workers, the configured window) must pass; config/helm-reset absent means the
feature is off. See the script header for the full contract.
EOF
}

# --- config ------------------------------------------------------------------

# helm_reset_config_read <config-path>: parse the LOCAL config into
# FM_HELM_RESET_{ENABLED,WINDOW_START,WINDOW_END,DRY_RUN}. An absent file
# leaves enabled=false (feature off). Any malformed line is a hard parse
# error (return 1 with stderr) rather than a silent default.
helm_reset_config_read() {  # <config-path>
  local path=$1 line key value lineno=0
  FM_HELM_RESET_ENABLED=false
  FM_HELM_RESET_WINDOW_START=$FM_HELM_RESET_DEFAULT_WINDOW_START
  FM_HELM_RESET_WINDOW_END=$FM_HELM_RESET_DEFAULT_WINDOW_END
  FM_HELM_RESET_DRY_RUN=true
  [ -f "$path" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in '#'*) continue ;; esac
    case "$line" in
      *=*) key=${line%%=*}; value=${line#*=} ;;
      *) echo "config error: $path line $lineno: expected key=value, got: $line" >&2; return 1 ;;
    esac
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    case "$key" in
      enabled) fm_helm_reset_parse_bool "$key" "$value" || return 1; FM_HELM_RESET_ENABLED=$value ;;
      window-start) fm_helm_reset_valid_hhmm "$value" || { echo "config error: $path line $lineno: $key must be HH:MM (00:00-23:59), got: $value" >&2; return 1; }; FM_HELM_RESET_WINDOW_START=$value ;;
      window-end) fm_helm_reset_valid_hhmm "$value" || { echo "config error: $path line $lineno: $key must be HH:MM (00:00-23:59), got: $value" >&2; return 1; }; FM_HELM_RESET_WINDOW_END=$value ;;
      dry-run) fm_helm_reset_parse_bool "$key" "$value" || return 1; FM_HELM_RESET_DRY_RUN=$value ;;
      *) echo "config error: $path line $lineno: unknown key: $key" >&2; return 1 ;;
    esac
  done < "$path"
  return 0
}

fm_helm_reset_parse_bool() {  # <key> <value>
  case "$2" in
    true|false) return 0 ;;
    *) echo "config error: $1 must be true or false, got: $2" >&2; return 1 ;;
  esac
}

fm_helm_reset_valid_hhmm() {  # <HH:MM>
  case "$1" in
    [0-9][0-9]:[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  [ "${1%%:*}" -lt 24 ] && [ "${1##*:}" -lt 60 ]
}

# helm_reset_in_window <now> <start> <end>: 0 when now is in [start, end)
# local time. start > end is a window wrapping past midnight. Returns 2 on a
# malformed operand so the caller can distinguish a config error from an
# ordinary out-of-window verdict.
helm_reset_in_window() {  # <now-HH:MM> <start-HH:MM> <end-HH:MM>
  local now start end
  now=$(fm_helm_reset_hhmm_minutes "$1") || return 2
  start=$(fm_helm_reset_hhmm_minutes "$2") || return 2
  end=$(fm_helm_reset_hhmm_minutes "$3") || return 2
  if [ "$start" -le "$end" ]; then
    [ "$now" -ge "$start" ] && [ "$now" -lt "$end" ]
  else
    [ "$now" -ge "$start" ] || [ "$now" -lt "$end" ]
  fi
}

fm_helm_reset_hhmm_minutes() {  # <HH:MM> -> minutes since midnight
  fm_helm_reset_valid_hhmm "$1" || return 1
  printf '%s\n' "$((10#${1%%:*} * 60 + 10#${1##*:}))"
}

# --- refusal markers ---------------------------------------------------------

# helm_reset_write_marker <path>: copy stdin into <path> atomically (the
# marker files are read by a human or the morning session at any moment).
helm_reset_write_marker() {  # <path>
  local path=$1 tmp="$1.tmp.$$"
  cat > "$tmp" && mv -f "$tmp" "$path"
}

# helm_reset_fail <gate> <reason>: record the refusal for morning diagnosis,
# report it, and exit 3. Never touches the pane.
helm_reset_fail() {  # <gate> <reason>
  local gate=$1 reason=$2 now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  {
    printf 'refused: %s\n' "$now"
    printf 'gate: %s\n' "$gate"
    printf 'reason: %s\n' "$reason"
    printf 'window: %s-%s local, dry-run=%s\n' \
      "$FM_HELM_RESET_WINDOW_START" "$FM_HELM_RESET_WINDOW_END" "$FM_HELM_RESET_DRY_RUN"
  } | helm_reset_write_marker "$STATE/.helm-reset.refusal"
  echo "helm-reset: refused: $gate - $reason" >&2
  exit "$FM_HELM_RESET_REFUSE_EXIT"
}

# --- gates -------------------------------------------------------------------

HELM_GATE_REASON=

# helm_reset_require <gate-name> <gate-function>: run one gate; on failure
# hand its HELM_GATE_REASON to the refusal. Gates never run twice.
helm_reset_require() {  # <gate-name> <gate-function>
  local gate=$1 fn=$2
  HELM_GATE_REASON=
  "$fn" && return 0
  helm_reset_fail "$gate" "${HELM_GATE_REASON:-gate failed without a reason}"
}

helm_reset_gate_away_posture() {
  [ -f "$STATE/.afk-contract" ] && return 0
  HELM_GATE_REASON="no away posture record at $STATE/.afk-contract; the reset only runs while the captain is away"
  return 1
}

helm_reset_gate_wake_queue() {
  local kind keys blocked=
  for kind in signal stale check heartbeat; do
    keys=$(fm_wake_queued_keys "$kind")
    [ -n "$keys" ] && blocked="$blocked $kind"
  done
  [ -z "$blocked" ] && return 0
  HELM_GATE_REASON="wake queue not empty (unacknowledged rows:$blocked)"
  return 1
}

helm_reset_gate_leases() {
  local file id
  # The reset evaluates leases from the main actor's perspective: any lease
  # the live helm session still holds names work under its hand.
  FM_SUPERVISION_ACTOR=main
  for file in "$STATE"/.lease-*; do
    [ -e "$file" ] || return 0
    id=${file##*/.lease-}
    fm_lease_valid_id "$id" || continue
    if fm_lease_live "$id"; then
      HELM_GATE_REASON="task '$id' holds a live supervision lease (state/.lease-$id)"
      return 1
    fi
  done
  return 0
}

helm_reset_gate_workers() {
  local meta id out verdict rc
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || return 0
    id=${meta##*/}
    id=${id%.meta}
    out=$("$FM_HELM_RESET_CREW_STATE_BIN" "$id" 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
      HELM_GATE_REASON="worker '$id' state unreadable (bin/fm-crew-state.sh failed); refusing rather than guessing"
      return 1
    fi
    verdict=$(printf '%s\n' "$out" | sed -n 's/^state: \([a-z]*\).*/\1/p' | head -1)
    case "$verdict" in
      done|unknown) ;; # finished, or no positive live evidence
      working|parked|blocked|paused|failed)
        HELM_GATE_REASON="worker '$id' is live and not done (state: $verdict)"
        return 1
        ;;
      *)
        HELM_GATE_REASON="worker '$id' reported an unreadable state ('$verdict')"
        return 1
        ;;
    esac
  done
  return 0
}

helm_reset_gate_window() {
  local now=${FM_HELM_RESET_NOW:-$(date +%H:%M)} rc
  helm_reset_in_window "$now" "$FM_HELM_RESET_WINDOW_START" "$FM_HELM_RESET_WINDOW_END"
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  if [ "$rc" -eq 2 ]; then
    HELM_GATE_REASON="invalid time in window check (now=$now window=$FM_HELM_RESET_WINDOW_START-$FM_HELM_RESET_WINDOW_END)"
  else
    HELM_GATE_REASON="outside the configured window ($FM_HELM_RESET_WINDOW_START-$FM_HELM_RESET_WINDOW_END local; now=$now)"
  fi
  return 1
}

# --- pane discovery ----------------------------------------------------------

# helm_reset_lock_pid: the session-lock holder pid, when it names a live
# process. The holder IS the primary helm session by definition.
helm_reset_lock_pid() {
  local pid
  [ -f "$STATE/.lock" ] || return 1
  pid=$(head -n 1 "$STATE/.lock" 2>/dev/null | tr -d '[:space:]')
  case "$pid" in
    ''|*[!0-9]*|0) return 1 ;;
  esac
  fm_pid_alive "$pid" || return 1
  printf '%s\n' "$pid"
}

# helm_reset_pane_target_from_environ <pid>: the herdr target herdr injected
# into the named process, as "<session>:<pane-id>".
helm_reset_pane_target_from_environ() {  # <pid>
  local proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc} raw pane session
  [ -r "$proc_root/$1/environ" ] || return 1
  raw=$(tr '\0' '\n' < "$proc_root/$1/environ" 2>/dev/null) || return 1
  pane=$(printf '%s\n' "$raw" | sed -n 's/^HERDR_PANE_ID=//p' | head -1)
  [ -n "$pane" ] || return 1
  session=$(printf '%s\n' "$raw" | sed -n 's/^HERDR_SESSION=//p' | head -1)
  printf '%s:%s\n' "${session:-default}" "$pane"
}

# helm_reset_pane_shell_pid <target>: the pane's shell pid from herdr's
# process view, with the pane-id agreement check the adapter's own proofs use.
helm_reset_pane_shell_pid() {  # <target>
  fm_backend_herdr_parse_target "$1" || return 1
  local out
  out=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane process-info --pane "$FM_BACKEND_HERDR_PANE" 2>/dev/null) || return 1
  printf '%s' "$out" | jq -er --arg pane "$FM_BACKEND_HERDR_PANE" \
    '.result.process_info
     | select(.pane_id == $pane)
     | .shell_pid
     | select(type == "number" and . > 1)
     | floor' 2>/dev/null
}

# helm_reset_pid_is_descendant_of <pid> <ancestor>: walk the ppid chain from
# <pid> up (bounded) looking for <ancestor>, using the process table one
# `ps -axo pid=,ppid=` snapshot (the same primitive the herdr adapter's
# process proofs use, overridable via FM_HELM_RESET_PS_BIN for tests).
helm_reset_pid_is_descendant_of() {  # <pid> <ancestor>
  local pid=$1 ancestor=$2 rows ppid depth=0
  rows=$("${FM_HELM_RESET_PS_BIN:-ps}" -axo pid=,ppid= 2>/dev/null) || return 1
  while [ "$depth" -lt 64 ]; do
    [ "$pid" = "$ancestor" ] && return 0
    case "$pid" in
      ''|*[!0-9]*|0) return 1 ;;
    esac
    ppid=$(printf '%s\n' "$rows" | awk -v p="$pid" '$1 == p { print $2; exit }')
    case "$ppid" in
      ''|*[!0-9]*) return 1 ;;
    esac
    pid=$ppid
    depth=$((depth + 1))
  done
  return 1
}

# helm_reset_discover: resolve the primary helm pane into HELM_TARGET, proving
# every step; any ambiguity or missing proof refuses.
helm_reset_discover() {
  local lock_pid target shell_pid
  fm_backend_source herdr || helm_reset_fail backend "herdr backend adapter unavailable"
  lock_pid=$(helm_reset_lock_pid) ||
    helm_reset_fail pane-lock "no live helm session lock holder ($STATE/.lock names no live process); nothing to reset"
  if [ -n "${FM_SUPERVISOR_TARGET:-}" ]; then
    target=$FM_SUPERVISOR_TARGET
  else
    target=$(helm_reset_pane_target_from_environ "$lock_pid") ||
      helm_reset_fail pane-discovery "cannot read the helm process's herdr pane identity (pid $lock_pid; needs /proc/<pid>/environ with HERDR_PANE_ID, or set FM_SUPERVISOR_TARGET)"
  fi
  fm_backend_target_exists herdr "$target" ||
    helm_reset_fail pane-missing "resolved helm pane '$target' does not exist in herdr"
  shell_pid=$(helm_reset_pane_shell_pid "$target") ||
    helm_reset_fail pane-proof "cannot read the helm pane's shell pid (pane process-info failed for '$target')"
  helm_reset_pid_is_descendant_of "$lock_pid" "$shell_pid" ||
    helm_reset_fail pane-proof "helm pane '$target' does not contain the session-lock holder pid $lock_pid in its process tree (stale pane identity)"
  HELM_TARGET=$target
}

# helm_reset_pane_agent_session <target>: herdr's registered pi session value
# (the session file herdr observed), or empty when it reports none.
helm_reset_pane_agent_session() {  # <target>
  fm_backend_herdr_parse_target "$1" || return 0
  fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" agent get "$FM_BACKEND_HERDR_PANE" 2>/dev/null |
    jq -r '.result.agent.agent_session.value // empty' 2>/dev/null
  return 0
}

# helm_reset_wait_fresh <target> <session-before-new>: wait until the fresh
# session is provable - the registered session value changed AND the composer
# reads empty; or, when herdr never offered a session value to compare, two
# consecutive empty composer reads. Bounded by FM_HELM_RESET_RESTART_WAIT.
helm_reset_wait_fresh() {  # <target> <session-before-new>
  local target=$1 before=$2 verdict session stable=0
  local wait=${FM_HELM_RESET_RESTART_WAIT:-60} poll=${FM_HELM_RESET_POLL:-1}
  local deadline=$(( $(date +%s) + wait ))
  while :; do
    session=$(helm_reset_pane_agent_session "$target")
    verdict=$(fm_backend_composer_state herdr "$target")
    if [ "$verdict" = empty ]; then
      stable=$((stable + 1))
    else
      stable=0
    fi
    if { [ -n "$before" ] && [ -n "$session" ] && [ "$session" != "$before" ]; } \
       || { [ -z "$before" ] && [ "$stable" -ge 2 ]; }; then
      [ "$verdict" = empty ] && return 0
    fi
    [ "$(date +%s)" -lt "$deadline" ] ||
      helm_reset_fail fresh-prompt "fresh helm prompt not confirmed within ${wait}s (session value was '${before:-unreadable}', now '${session:-unreadable}'; composer verdict: ${verdict:-unknown}); '/new' ran but the continuation prompt was NOT sent"
    sleep "$poll"
  done
}

# --- action ------------------------------------------------------------------

helm_reset_record_run() {  # <mode> <result>
  local mode=$1 result=$2 now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  {
    printf 'ran: %s\n' "$now"
    printf 'mode: %s\n' "$mode"
    printf 'target: %s\n' "${HELM_TARGET:-unknown}"
    printf 'result: %s\n' "$result"
  } | helm_reset_write_marker "$STATE/.helm-reset.last"
}

helm_reset_run() {
  local dry_run_flag=${1:-} verdict settle before_session
  local retries=${FM_HELM_RESET_RETRIES:-3} sleep_s=${FM_HELM_RESET_SLEEP:-0.4}
  local lock_rc
  helm_reset_config_read "$FM_HELM_RESET_CONFIG" ||
    helm_reset_fail config "invalid $FM_HELM_RESET_CONFIG (see the config error above)"
  if [ "$FM_HELM_RESET_ENABLED" != true ]; then
    echo "helm-reset: feature off (no enabled $FM_HELM_RESET_CONFIG); nothing to do"
    return 0
  fi
  [ "$dry_run_flag" = 1 ] && FM_HELM_RESET_DRY_RUN=true
  fm_lock_acquire_wait_bounded "$STATE/.helm-reset.lock" 5
  lock_rc=$?
  [ "$lock_rc" -eq 0 ] || helm_reset_fail run-lock "another helm reset run holds the run lock (state/.helm-reset.lock)"
  # helm_reset_fail exits, and this release is idempotent on ordinary returns.
  trap 'fm_lock_release "$STATE/.helm-reset.lock"' EXIT
  helm_reset_require away-posture helm_reset_gate_away_posture
  helm_reset_require wake-queue helm_reset_gate_wake_queue
  helm_reset_require leases helm_reset_gate_leases
  helm_reset_require workers helm_reset_gate_workers
  helm_reset_require window helm_reset_gate_window
  helm_reset_discover
  verdict=$(fm_backend_composer_state herdr "$HELM_TARGET")
  [ "$verdict" = empty ] ||
    helm_reset_fail composer "helm composer not confirmed empty before /new (verdict: ${verdict:-unknown})"
  if [ "$FM_HELM_RESET_DRY_RUN" = true ]; then
    helm_reset_record_run dry-run "all gates passed; composer confirmed empty; would /new and submit the continuation prompt"
    echo "helm-reset: dry-run: gates passed, helm pane $HELM_TARGET composer empty; nothing sent"
    return 0
  fi
  before_session=$(helm_reset_pane_agent_session "$HELM_TARGET")
  settle=${FM_HELM_RESET_SETTLE:-1.2} # slash command: let the completion popup settle (fm-send's slash rule)
  verdict=$(fm_backend_send_text_submit herdr "$HELM_TARGET" '/new' "$retries" "$sleep_s" "$settle")
  [ "$verdict" = empty ] ||
    helm_reset_fail new-submit "'/new' submit unconfirmed (verdict: ${verdict:-unknown}); nothing else was sent"
  helm_reset_wait_fresh "$HELM_TARGET" "$before_session"
  settle=${FM_HELM_RESET_SETTLE:-0.3}
  verdict=$(fm_backend_send_text_submit herdr "$HELM_TARGET" "$FM_HELM_RESET_PROMPT" "$retries" "$sleep_s" "$settle")
  [ "$verdict" = empty ] ||
    helm_reset_fail prompt-submit "continuation prompt submit unconfirmed (verdict: ${verdict:-unknown}); it may sit unsubmitted in the fresh composer"
  helm_reset_record_run reset "helmed /new and submitted the continuation prompt"
  echo "helm-reset: reset complete: /new ran on $HELM_TARGET and the continuation prompt was submitted"
  return 0
}

# --- systemd user unit templates ---------------------------------------------

helm_reset_print_unit() {  # <service|timer>
  local kind=$1 exec_start
  exec_start=$(cd "$FM_HELM_RESET_SCRIPT_DIR" && pwd)/fm-helm-reset.sh
  case "$kind" in
    service)
      cat <<EOF
[Unit]
Description=firstmate gated bedtime helm reset
# Safe to fire at any time: the script's own gates (away posture, empty wake
# queue, no held leases, no live non-done workers, the configured window,
# dry-run) make a mistimed fire a logged refusal, never a reset.

[Service]
Type=oneshot
ExecStart=$exec_start
# Uncomment and adjust when the firstmate home is not the checkout the script
# lives in:
#Environment=FM_HOME=%h/path/to/firstmate
# Uncomment and adjust when herdr is not on the user manager's PATH (for
# example it lives in %h/.local/bin): every herdr call must find the binary
# or the run refuses:
#Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
EOF
      ;;
    timer)
      cat <<'EOF'
[Unit]
Description=fire the firstmate gated bedtime helm reset at the window start

[Timer]
# Matches the default config window start (01:00 local). The script's gates
# still decide whether each fire resets; edit this when you change
# config/helm-reset's window-start.
OnCalendar=*-*-* 01:00:00
RandomizedDelaySec=10m
Persistent=true
Unit=fm-helm-reset.service

[Install]
WantedBy=timers.target
EOF
      ;;
  esac
}

helm_reset_main() {
  local dry_run_flag=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run_flag=1 ;;
      --print-unit)
        shift
        case "${1:-both}" in
          service|timer) helm_reset_print_unit "$1" ;;
          both) helm_reset_print_unit service; printf '\n'; helm_reset_print_unit timer ;;
          *) helm_reset_usage >&2; return 2 ;;
        esac
        return 0
        ;;
      -h|--help|help) helm_reset_usage; return 0 ;;
      *) helm_reset_usage >&2; return 2 ;;
    esac
    shift
  done
  helm_reset_run "$dry_run_flag"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  helm_reset_main "$@"
fi
