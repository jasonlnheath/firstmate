#!/usr/bin/env bash
# tests/fm-helm-reset.test.sh - the gated bedtime helm reset
# (bin/fm-helm-reset.sh): the config schema and its fail-closed parse errors,
# every gate refusing with its marker (away posture, wake queue, live leases,
# live non-done workers, the wrap-safe time window), the lock-holder pane
# discovery with its stale-identity ancestry proof, the composer guard, the
# dry-run rehearsal that sends nothing, the real /new + continuation-prompt
# sequence against a scripted fake herdr CLI, and the fresh-session proof.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-helm-reset.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-helm-reset-tests)

# A herdr pane identity leaked in from the developer's own terminal must never
# reach discovery or the adapter; discovery reads only the lock holder's env.
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
unset FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND
unset FAKE_CREW_STATE FAKE_CREW_STATE_RC FAKE_PS_PARENT FAKE_PROCESS_INFO_PANE FAKE_DIR

LOCKPID=$$            # alive by construction; the fake lock holder + lease pid
FAKE_SHELL_PID=4242   # the fake pane shell the ancestry walk must find
FAKE_PANE=wX:p1
export FAKE_SHELL_PID FAKE_PANE
FM_HELM_RESET_NOW=01:30
export FM_HELM_RESET_NOW
# Keep the submit cores and waits instant in tests.
FM_HELM_RESET_SLEEP=0
FM_HELM_RESET_SETTLE=0
FM_HELM_RESET_RESTART_WAIT=2
FM_HELM_RESET_POLL=0.05

make_home() {  # <name> -> home dir on stdout
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/config"
  printf '%s\n' "$dir"
}

write_config() {  # <home> <lines...>
  local home=$1
  shift
  : > "$home/config/helm-reset"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >> "$home/config/helm-reset"
  done
}

write_afk_contract() {  # <home>
  printf 'version: 1\nconfirmed: x\n' > "$1/state/.afk-contract"
}

write_queue_row() {  # <home> <kind> <key>
  printf '%s\t1\t%s\t%s\tpayload\n' "$(date +%s)" "$2" "$3" >> "$1/state/.wake-queue"
}

# run_reset <home> <argv...>: run the script with the shared fast fixture
# environment (per-call FAKE_* / FM_HELM_RESET_NOW prefixes inherit through).
run_reset() {  # <home> <argv...>
  local home=$1
  shift
  set +e
  RUN_OUT=$(env -u FM_SUPERVISOR_TARGET -u FM_SUPERVISOR_BACKEND \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_HELM_RESET_CONFIG="$home/config/helm-reset" \
    FM_HELM_RESET_PS_BIN="$TMP_ROOT/fakebin/ps" \
    FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/proc" \
    FM_HELM_RESET_CREW_STATE_BIN="$TMP_ROOT/fakebin/fm-crew-state.sh" \
    FM_HELM_RESET_SLEEP="$FM_HELM_RESET_SLEEP" FM_HELM_RESET_SETTLE="$FM_HELM_RESET_SETTLE" \
    FM_HELM_RESET_RESTART_WAIT="$FM_HELM_RESET_RESTART_WAIT" FM_HELM_RESET_POLL="$FM_HELM_RESET_POLL" \
    FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0 \
    PATH="$TMP_ROOT/fakebin:$PATH" \
    "$SCRIPT" "$@" 2>&1)
  RUN_RC=$?
  set -e
}

# --- the scripted fake world -------------------------------------------------

# install_fakes: one fake `herdr` (canned, stateful around /new), a fake `ps`
# whose table proves the lock pid descends from the pane shell (unless
# FAKE_PS_PARENT says otherwise), and a fake bin/fm-crew-state.sh emitting
# FAKE_CREW_STATE. The fake herdr simulates pi faithfully enough for the
# submit cores: after it sees `pane send-text /new` it flips agent_session.value
# from session-a to session-b, and it serves screen-after-new as the composer
# from then on (the scene decides whether that screen is empty or pending).
install_fakes() {
  local fb="$TMP_ROOT/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
DIR="${FAKE_DIR:?}"
PANE="${FAKE_PANE:-wX:p1}"
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$DIR/log"
sub=${1:-}; shift 2>/dev/null || true
sub2=${1:-}; shift 2>/dev/null || true
case "$sub $sub2" in
  "status --json")
    printf '{"client":{"version":"0.8.0","channel":"stable","protocol":20},"server":{"status":"running","running":true,"version":"0.8.0","protocol":20,"compatible":true,"session":"default","restart_needed":false}}\n'
    exit 0 ;;
  "pane get")
    if [ "${1:-}" = "$PANE" ]; then
      printf '{"id":"c","result":{"pane":{"agent":"pi","agent_status":"idle","pane_id":"%s","tab_id":"wX:t1","workspace_id":"wX"},"type":"pane_info"}}\n' "$PANE"
      exit 0
    fi
    printf '{"id":"c","error":{"code":"pane_not_found","message":"no such pane"}}\n' >&2
    exit 1 ;;
  "agent get")
    session="$DIR/session-a.jsonl"
    [ -e "$DIR/new-sent" ] && session="$DIR/session-b.jsonl"
    printf '{"id":"c","result":{"agent":{"agent":"pi","agent_status":"idle","pane_id":"%s","agent_session":{"kind":"path","source":"herdr:pi","value":"%s"}},"type":"agent_info"}}\n' "$PANE" "$session"
    exit 0 ;;
  "pane process-info")
    printf '{"id":"c","result":{"process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"pi","argv0":"pi","argv":["pi"],"cmdline":"pi"}]}},"type":"pane_process_info"}\n' \
      "${FAKE_PROCESS_INFO_PANE:-$PANE}" "$FAKE_SHELL_PID" "$FAKE_SHELL_PID" "$FAKE_SHELL_PID"
    exit 0 ;;
  "pane read")
    screen="$DIR/screen-empty"
    if [ -e "$DIR/new-sent" ] && [ -e "$DIR/screen-after-new" ]; then
      # First post-/new composer read still sees the confirmed empty composer;
      # from the second read on the scene's after-new screen applies. A scene
      # that pre-seeds .reads=1 models a swallowed Enter (first read pending).
      reads=$(( $(cat "$DIR/.reads" 2>/dev/null || echo 0) + 1 ))
      printf '%s\n' "$reads" > "$DIR/.reads"
      [ "$reads" -gt 1 ] && screen="$DIR/screen-after-new"
    fi
    cat "$screen"
    exit 0 ;;
  "pane send-text")
    # herdr's send-text takes the pane id first, then the text.
    printf '%s\n' "${2:-}" > "$DIR/last-typed"
    [ "${2:-}" = "/new" ] && touch "$DIR/new-sent"
    exit 0 ;;
  "pane send-keys")
    exit 0 ;;
esac
  exit 0
SH
  chmod +x "$fb/herdr"
  # The ps fake bakes in the real fixture pids but keeps the lock holder's
  # parent overridable at runtime via FAKE_PS_PARENT.
  cat > "$fb/ps" <<'SH'
#!/usr/bin/env bash
parent=${FAKE_PS_PARENT:-@@SHELL@@}
printf '%s 1\n' '@@SHELL@@'
printf '%s %s\n' '@@LOCK@@' "$parent"
exit 0
SH
  sed -i "s/@@SHELL@@/$FAKE_SHELL_PID/g; s/@@LOCK@@/$LOCKPID/g" "$fb/ps"
  chmod +x "$fb/ps"
  cat > "$fb/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: %s \xc2\xb7 source: none \xc2\xb7 fixture\n' "${FAKE_CREW_STATE:-done}"
exit "${FAKE_CREW_STATE_RC:-0}"
SH
  chmod +x "$fb/fm-crew-state.sh"
  # The composer screens: an empty pi separated pair, and a pending one.
  printf '%s\n%s\n%s\n%s\n' \
    '────────────────────────────' '' '' '────────────────────────────' \
    > "$TMP_ROOT/screen-empty"
  printf '%s\n%s\n%s\n' \
    '────────────────────────────' 'half typed thought' '────────────────────────────' \
    > "$TMP_ROOT/screen-pending"
}

# make_scene <name> -> home dir: a home passing every gate inside a working
# fake world, with lock holder, /proc environ, and pane identity all agreeing.
# After a simulated /new the fresh composer is empty (the normal pi restart).
# Each scene gets its OWN fake dir (fake pane state like new-sent/last-typed
# must never leak between tests); FAKE_DIR is derived from the scene name.
FAKE_DIR_BASE="$TMP_ROOT/fakedir"

make_scene() {  # <name> -> home dir
  local home dir
  home=$(make_home "$1")
  install_fakes
  mkdir -p "$TMP_ROOT/proc/$LOCKPID"
  printf 'HERDR_ENV=1\0HERDR_PANE_ID=%s\0HERDR_SESSION=default\0' "$FAKE_PANE" \
    > "$TMP_ROOT/proc/$LOCKPID/environ"
  printf '%s\n' "$LOCKPID" > "$home/state/.lock"
  dir="$FAKE_DIR_BASE/$1"
  mkdir -p "$dir"
  : > "$dir/log"
  cp "$TMP_ROOT/screen-empty" "$dir/screen-empty"
  cp "$TMP_ROOT/screen-empty" "$dir/screen-after-new"
  write_afk_contract "$home"
  write_config "$home" 'enabled=true'
  printf '%s\n' "$home"
}

# run_scene <home> <argv...>: run_reset with FAKE_DIR pointed at the scene's
# own fake dir, derived from the home's basename.
run_scene() {  # <home> <argv...>
  local home=$1
  shift
  FAKE_DIR="$FAKE_DIR_BASE/${home##*/}" run_reset "$home" "$@"
}

# --- pure window logic (source the script; the main guard keeps it inert) ----

test_window_unit() {
  local home="$TMP_ROOT/window-unit-home"
  mkdir -p "$home/state"
  FM_HOME="$home"
  FM_STATE_OVERRIDE="$home/state"
  FM_HELM_RESET_CONFIG="$home/config/helm-reset"
  # shellcheck source=bin/fm-helm-reset.sh
  . "$SCRIPT"
  helm_reset_in_window 01:00 01:00 02:00 || fail "window: inclusive start refused"
  helm_reset_in_window 01:59 01:00 02:00 || fail "window: inside refused"
  helm_reset_in_window 02:00 01:00 02:00 && fail "window: exclusive end accepted"
  helm_reset_in_window 00:15 23:30 01:30 || fail "window: wrap after midnight refused"
  helm_reset_in_window 23:30 23:30 01:30 || fail "window: wrap start refused"
  helm_reset_in_window 12:00 23:30 01:30 && fail "window: wrap daytime accepted"
  helm_reset_in_window 7:30 01:00 02:00 && fail "window: malformed now accepted"
  pass "window check boundaries and midnight wrap"
}

# --- config ------------------------------------------------------------------

test_config_absent_is_quiet_off() {
  local home
  home=$(make_home config-absent)
  run_reset "$home"
  expect_code 0 "$RUN_RC" "absent config exits 0"
  assert_contains "$RUN_OUT" "feature off" "absent config says feature off"
  assert_absent "$home/state/.helm-reset.refusal" "absent config writes no refusal"
  assert_absent "$home/state/.helm-reset.last" "absent config writes no run record"
  pass "absent config is a quiet feature-off no-op"
}

test_config_disabled_is_quiet_off() {
  local home
  home=$(make_home config-disabled)
  write_config "$home" 'enabled=false'
  run_reset "$home"
  expect_code 0 "$RUN_RC" "disabled config exits 0"
  assert_absent "$home/state/.helm-reset.refusal" "disabled config writes no refusal"
  pass "enabled=false is a quiet feature-off no-op"
}

test_config_errors_refuse_loudly() {
  local home out rc
  home=$(make_home config-bad)
  write_config "$home" 'enabled=true' 'unknown-key=1'
  set +e
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_HELM_RESET_CONFIG="$home/config/helm-reset" "$SCRIPT" 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "unknown config key refuses"
  assert_contains "$out" "unknown key" "unknown config key names itself"
  assert_grep "gate: config" "$home/state/.helm-reset.refusal" "unknown-key refusal marker names the config gate"

  write_config "$home" 'enabled=true' 'window-start=25:00'
  set +e
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_HELM_RESET_CONFIG="$home/config/helm-reset" "$SCRIPT" 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "malformed window-start refuses"
  assert_contains "$out" "HH:MM" "malformed time names the HH:MM format"

  write_config "$home" 'enabled=true' 'dry-run=yes'
  set +e
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_HELM_RESET_CONFIG="$home/config/helm-reset" "$SCRIPT" 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "non-boolean dry-run refuses"
  assert_contains "$out" "true or false" "non-boolean names the allowed values"
  pass "config parse errors refuse loudly with a marker"
}

test_config_defaults_window_and_dryrun() {
  local home
  home=$(make_home config-defaults)
  write_config "$home" 'enabled=true'
  write_afk_contract "$home"
  FM_HELM_RESET_NOW=03:00 run_reset "$home"
  expect_code 3 "$RUN_RC" "out-of-window run with default window refuses"
  assert_grep "gate: window" "$home/state/.helm-reset.refusal" "default window gate fired"
  assert_grep "window: 01:00-02:00 local, dry-run=true" \
    "$home/state/.helm-reset.refusal" "marker names the default window and the default dry-run"
  pass "defaults: window 01:00-02:00 and dry-run=true"
}

# --- gates -------------------------------------------------------------------

test_gate_away_posture() {
  local home
  home=$(make_scene gate-away)
  rm -f "$home/state/.afk-contract"
  run_scene "$home"
  expect_code 3 "$RUN_RC" "no away record refuses"
  assert_grep "gate: away-posture" "$home/state/.helm-reset.refusal" "refusal names the away gate"
  assert_contains "$RUN_OUT" "captain is away" "refusal explains the away requirement"
  assert_absent "$TMP_ROOT/fakedir/log" "a refused run never touches the pane"
  pass "gate 1: no away posture record refuses"
}

test_gate_wake_queue() {
  local home
  home=$(make_scene gate-queue)
  write_queue_row "$home" check upstream-pr
  run_scene "$home"
  expect_code 3 "$RUN_RC" "queued row refuses"
  assert_grep "gate: wake-queue" "$home/state/.helm-reset.refusal" "refusal names the queue gate"
  assert_contains "$RUN_OUT" "unacknowledged rows" "refusal names the unacknowledged rows"
  write_queue_row "$home" signal stale-worker
  run_scene "$home"
  assert_contains "$RUN_OUT" "signal check" "refusal lists every queued kind"
  pass "gate 2: unacknowledged wake rows refuse"
}

test_gate_leases() {
  local home
  home=$(make_scene gate-leases)
  printf 'main\t%s\t123\n' "$LOCKPID" > "$home/state/.lease-taska"
  run_scene "$home"
  expect_code 3 "$RUN_RC" "live lease refuses"
  assert_grep "gate: leases" "$home/state/.helm-reset.refusal" "refusal names the lease gate"
  assert_contains "$RUN_OUT" "task 'taska'" "refusal names the leased task"
  # A stale lease (holder pid dead) passes; the run reaches the dry-run action.
  rm -f "$home/state/.lease-taska"
  printf 'main\t999999999\t123\n' > "$home/state/.lease-stale"
  run_scene "$home"
  expect_code 0 "$RUN_RC" "stale lease passes the gate (dry-run default)"
  assert_grep "mode: dry-run" "$home/state/.helm-reset.last" "stale-lease run reached the action as a dry run"
  pass "gate 3: a live lease refuses and a stale lease passes"
}

test_gate_workers() {
  local home dir
  home=$(make_scene gate-workers)
  dir="$FAKE_DIR_BASE/gate-workers"
  printf 'window=x\nharness=pi\nkind=ship\nbackend=herdr\n' > "$home/state/w1.meta"
  FAKE_DIR="$dir" FAKE_CREW_STATE=working run_reset "$home"
  expect_code 3 "$RUN_RC" "working worker refuses"
  assert_grep "gate: workers" "$home/state/.helm-reset.refusal" "refusal names the workers gate"
  assert_contains "$RUN_OUT" "w1" "refusal names the live worker"

  FAKE_DIR="$dir" FAKE_CREW_STATE=parked run_reset "$home"
  assert_grep "gate: workers" "$home/state/.helm-reset.refusal" "parked worker refuses too"

  FAKE_DIR="$dir" FAKE_CREW_STATE="done" run_reset "$home"
  expect_code 0 "$RUN_RC" "done worker passes (dry-run default)"

  FAKE_DIR="$dir" FAKE_CREW_STATE=unknown run_reset "$home"
  expect_code 0 "$RUN_RC" "unknown worker state passes (no positive live evidence)"

  FAKE_DIR="$dir" FAKE_CREW_STATE=garbage run_reset "$home"
  expect_code 3 "$RUN_RC" "unreadable worker verdict refuses"
  assert_contains "$RUN_OUT" "unreadable state" "refusal explains the unreadable verdict"

  FAKE_DIR="$dir" FAKE_CREW_STATE_RC=1 run_reset "$home"
  expect_code 3 "$RUN_RC" "failing crew-state read refuses"
  assert_contains "$RUN_OUT" "state unreadable" "refusal explains the instrument failure"
  pass "gate 4: live non-done workers refuse; done/unknown pass; unreadable refuses"
}

test_gate_window() {
  local home
  home=$(make_scene gate-window)
  FM_HELM_RESET_NOW=00:59 run_scene "$home"
  expect_code 3 "$RUN_RC" "before the window refuses"
  assert_grep "gate: window" "$home/state/.helm-reset.refusal" "refusal names the window gate"
  # 01:00 is the inclusive start: the run proceeds into the fake world.
  FM_HELM_RESET_NOW=01:00 run_scene "$home"
  expect_code 0 "$RUN_RC" "window start is inclusive"
  # 02:00 is the exclusive end.
  FM_HELM_RESET_NOW=02:00 run_scene "$home"
  expect_code 3 "$RUN_RC" "window end is exclusive"
  # A wrap-past-midnight window admits the small hours.
  write_config "$home" 'enabled=true' 'window-start=23:30' 'window-end=01:30'
  FM_HELM_RESET_NOW=00:15 run_scene "$home"
  expect_code 0 "$RUN_RC" "wrap window admits 00:15"
  FM_HELM_RESET_NOW=12:00 run_scene "$home"
  expect_code 3 "$RUN_RC" "wrap window refuses noon"
  pass "gate 5: window boundaries, exclusivity, and midnight wrap"
}

# --- discovery ---------------------------------------------------------------

test_discovery_refusals() {
  local home
  home=$(make_scene disc-none)
  rm -f "$home/state/.lock"
  run_scene "$home"
  expect_code 3 "$RUN_RC" "no lock refuses"
  assert_grep "gate: pane-lock" "$home/state/.helm-reset.refusal" "refusal names the lock gate"

  printf '%s\n' 999999999 > "$home/state/.lock"
  run_scene "$home"
  assert_grep "gate: pane-lock" "$home/state/.helm-reset.refusal" "dead lock holder refuses"

  printf '%s\n' "$LOCKPID" > "$home/state/.lock"
  printf 'HOME=%s\0' "$home" > "$TMP_ROOT/proc/$LOCKPID/environ"
  run_scene "$home"
  assert_grep "gate: pane-discovery" "$home/state/.helm-reset.refusal" "environ without HERDR_PANE_ID refuses"

  printf 'HERDR_PANE_ID=%s\0HERDR_SESSION=default\0' wX:other > "$TMP_ROOT/proc/$LOCKPID/environ"
  run_scene "$home"
  assert_grep "gate: pane-missing" "$home/state/.helm-reset.refusal" "nonexistent pane refuses"

  printf 'HERDR_PANE_ID=%s\0HERDR_SESSION=default\0' "$FAKE_PANE" > "$TMP_ROOT/proc/$LOCKPID/environ"
  FAKE_PS_PARENT=1 run_scene "$home"
  assert_grep "gate: pane-proof" "$home/state/.helm-reset.refusal" "pane whose tree lacks the lock holder refuses"

  FAKE_PS_PARENT=$FAKE_SHELL_PID FAKE_PROCESS_INFO_PANE=wY:p9 run_scene "$home"
  assert_grep "gate: pane-proof" "$home/state/.helm-reset.refusal" "pane-id disagreement in process-info refuses"
  pass "discovery refuses on every missing or contradictory proof"
}

test_discovery_explicit_override() {
  local home
  home=$(make_scene disc-override)
  # The override names the pane directly and skips the environ read entirely.
  FM_SUPERVISOR_TARGET="default:$FAKE_PANE" run_scene "$home"
  expect_code 0 "$RUN_RC" "explicit target override runs (dry-run default)"
  assert_grep "target: default:$FAKE_PANE" "$home/state/.helm-reset.last" "run record names the overridden target"
  # An override whose pane fails the ancestry proof still refuses.
  FAKE_PS_PARENT=1 FM_SUPERVISOR_TARGET="default:$FAKE_PANE" run_scene "$home"
  assert_grep "gate: pane-proof" "$home/state/.helm-reset.refusal" "overridden pane still proves the lock holder"
  pass "explicit FM_SUPERVISOR_TARGET override is honored but still proven"
}

# --- action: dry-run rehearsal, composer guard, and the real sends -----------

test_dry_run_sends_nothing() {
  local home log
  home=$(make_scene dry-run)
  log="$FAKE_DIR_BASE/dry-run/log"
  run_scene "$home"
  expect_code 0 "$RUN_RC" "full dry-run integration run exits 0"
  assert_grep "mode: dry-run" "$home/state/.helm-reset.last" "run record says dry-run"
  assert_contains "$RUN_OUT" "dry-run: gates passed" "stdout names the dry-run outcome"
  assert_contains "$RUN_OUT" "$FAKE_PANE" "stdout names the resolved pane"
  assert_present "$log" "dry-run performed the pane discovery reads"
  assert_absent "$FAKE_DIR_BASE/dry-run/last-typed" "dry-run never types anything"
  assert_absent "$FAKE_DIR_BASE/dry-run/new-sent" "dry-run never sends /new"
  assert_absent "$home/state/.helm-reset.refusal" "a passing dry run writes no refusal"
  pass "dry run: full rehearsal, nothing sent"
}

test_composer_guard_refuses() {
  local home
  home=$(make_scene composer-guard)
  write_config "$home" 'enabled=true' 'dry-run=false'
  cp "$TMP_ROOT/screen-pending" "$FAKE_DIR_BASE/composer-guard/screen-empty"
  run_scene "$home"
  expect_code 3 "$RUN_RC" "pending composer refuses even with dry-run off"
  assert_grep "gate: composer" "$home/state/.helm-reset.refusal" "refusal names the composer gate"
  assert_contains "$RUN_OUT" "not confirmed empty" "refusal names the composer verdict"
  assert_absent "$FAKE_DIR_BASE/composer-guard/last-typed" "nothing was typed into a pending composer"
  assert_absent "$FAKE_DIR_BASE/composer-guard/new-sent" "no /new was sent"
  pass "composer guard: a non-empty composer refuses before anything is sent"
}

test_real_reset_sends_new_then_prompt() {
  local home log dir new_line prompt_line enters typed_prompt
  home=$(make_scene real-send)
  dir="$FAKE_DIR_BASE/real-send"
  log="$dir/log"
  write_config "$home" 'enabled=true' 'dry-run=false'
  run_scene "$home"
  expect_code 0 "$RUN_RC" "real reset exits 0"
  assert_grep "mode: reset" "$home/state/.helm-reset.last" "run record says reset"
  assert_contains "$RUN_OUT" "continuation prompt was submitted" "stdout reports the reset"
  assert_grep "send-text" "$log" "the fake saw send-text calls"
  assert_present "$dir/new-sent" "the fake observed /new and flipped its session"
  typed_prompt='Read the stowed handoff file if present (and the session-start digest) and continue working.'
  new_line=$(grep -n $'\x1f/new' "$log" | head -1 | cut -d: -f1)
  prompt_line=$(grep -n "$typed_prompt" "$log" | head -1 | cut -d: -f1)
  [ -n "$new_line" ] || fail "the /new send-text is missing from the log"
  [ -n "$prompt_line" ] || fail "the continuation prompt send-text is missing from the log"
  [ "$new_line" -lt "$prompt_line" ] || fail "the continuation prompt must be sent after /new"
  enters=$(grep -c "send-keys" "$log")
  [ "$enters" -ge 2 ] || fail "expected at least two Enter submissions, got $enters"
  assert_absent "$home/state/.helm-reset.refusal" "a clean reset writes no refusal"
  pass "real reset: /new then the continuation prompt, both submit-confirmed"
}

test_new_submit_unconfirmed_refuses() {
  local home dir
  home=$(make_scene new-unconfirmed)
  dir="$FAKE_DIR_BASE/new-unconfirmed"
  write_config "$home" 'enabled=true' 'dry-run=false'
  # A swallowed Enter leaves '/new' sitting in the composer: pre-seed the
  # fake's read counter so the FIRST post-/new composer read is the pending
  # after-new screen (the submit confirmation must fail at once).
  printf '1\n' > "$dir/.reads"
  cp "$TMP_ROOT/screen-pending" "$dir/screen-after-new"
  run_scene "$home"
  expect_code 3 "$RUN_RC" "unconfirmed /new refuses"
  assert_grep "gate: new-submit" "$home/state/.helm-reset.refusal" "refusal names the new-submit gate"
  assert_absent "$home/state/.helm-reset.last" "a refused run records no completion"
  pass "an unconfirmed /new refuses instead of sending the prompt into the void"
}

test_fresh_prompt_stall_refuses() {
  local home dir
  home=$(make_scene fresh-stall)
  dir="$FAKE_DIR_BASE/fresh-stall"
  write_config "$home" 'enabled=true' 'dry-run=false'
  # The session value changes (session-b) but the composer never reads empty
  # again: the wait must time out and refuse BEFORE the continuation prompt.
  cp "$TMP_ROOT/screen-pending" "$dir/screen-after-new"
  run_scene "$home"
  expect_code 3 "$RUN_RC" "stalled fresh prompt refuses"
  assert_grep "gate: fresh-prompt" "$home/state/.helm-reset.refusal" "refusal names the fresh-prompt gate"
  assert_contains "$RUN_OUT" "continuation prompt was NOT sent" "refusal says the prompt was not sent"
  assert_equals "/new" "$(cat "$dir/last-typed")" "only /new was typed"
  pass "a stalled restart refuses without sending the continuation prompt"
}

# --- CLI surface -------------------------------------------------------------

test_print_unit_and_help() {
  local out rc
  set +e
  out=$("$SCRIPT" --print-unit service 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "print-unit service exits 0"
  assert_contains "$out" "ExecStart=$ROOT/bin/fm-helm-reset.sh" "service unit points at the real script path"
  assert_contains "$out" "Type=oneshot" "service unit is oneshot"
  set +e
  out=$("$SCRIPT" --print-unit timer 2>&1)
  rc=$?
  set -e
  assert_contains "$out" 'OnCalendar=*-*-* 01:00:00' "timer fires at the default window start"
  assert_contains "$out" "Persistent=true" "timer is persistent"
  assert_contains "$out" "Unit=fm-helm-reset.service" "timer names the service"
  set +e
  out=$("$SCRIPT" --print-unit bogus 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "unknown unit name is a usage error"
  set +e
  out=$("$SCRIPT" --help 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "--help exits 0"
  assert_contains "$out" "usage:" "help prints usage"
  set +e
  out=$("$SCRIPT" --nonsense 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "unknown flag is a usage error"
  pass "--print-unit templates, --help, and usage errors"
}

# --- run ---------------------------------------------------------------------

test_window_unit
test_config_absent_is_quiet_off
test_config_disabled_is_quiet_off
test_config_errors_refuse_loudly
test_config_defaults_window_and_dryrun
test_gate_away_posture
test_gate_wake_queue
test_gate_leases
test_gate_workers
test_gate_window
test_discovery_refusals
test_discovery_explicit_override
test_dry_run_sends_nothing
test_composer_guard_refuses
test_real_reset_sends_new_then_prompt
test_new_submit_unconfirmed_refuses
test_fresh_prompt_stall_refuses
test_print_unit_and_help

echo "all fm-helm-reset tests passed"
