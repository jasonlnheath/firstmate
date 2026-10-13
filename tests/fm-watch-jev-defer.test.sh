#!/usr/bin/env bash
# tests/fm-watch-jev-defer.test.sh - the Jev pre-screen integration in
# bin/fm-watch.sh (the overnight Jev plan's item 4.1 / candidate C1, widened by
# the 2026-10-12 routine-wake ask to the no-verb signal batch and the
# first-sight non-terminal stale surface): an optional typed classifier consult
# on the wedge escalation path and the two routine surfaces, fail-soft in
# every outcome and bounded to one silent deferral per quiet stretch. These
# tests drive a real fm-watch.sh subprocess whose consult is pointed at a
# recording fake screener, so every case asserts watcher behavior (absorb,
# defer, escalate, markers, wakes) through the public interface with no
# network. Coverage: the 2026-08-14 regression shape (a demonstrably working
# crew behind a static pane, all deterministic probes negative, tool banners in
# the tail) absorbs once and escalates on the second consult with today's
# byte-identical reason; deterministic evidence keeps the consult at zero;
# a key-absent home escalates exactly as today; below-floor, wrong-verdict,
# error, and malformed responses escalate with no marker left behind; the
# deferral budget clears on a pane hash change and after a delivered re-surface;
# the confidence floor comes from config/jev-wedge-floor with the 0.8 default;
# and the busy-over-age path reaches the same consult.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-jev-defer)

ack_stopped_cycle() {  # <state>
  local state=$1 err sequence generation
  err="$state/.test-cycle-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

set_mtime() {  # <epoch> <file>
  local epoch=$1 f=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$f"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$f"
  fi
}

seen_sig() {
  local reported size ident
  case "$1" in
    *.status)
      reported=$(status_observed_signature "$1")
      size=$(size_of "$1")
      ident=$(_fm_open_decisions_file_ident "$1")
      printf 'v2\t%s\t%s@%s' "$reported" "$size" "$ident"
      ;;
    *)
      if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
      ;;
  esac
}

size_of() { LC_ALL=C wc -c < "$1" | tr -d '[:space:]'; }

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

wait_poll_cycle() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-300} beat first now i=0
  beat="$state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat")
    [ -n "$first" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    if [ -n "$now" ] && [ "$now" != "$first" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Install the recording fake screener and echo its path. The fake answers from
# FM_FAKE_JEV_MODE (clear|off|error|malformed) with FM_FAKE_JEV_CHOICE and
# FM_FAKE_JEV_CONF fixing the clear block, records every invocation's argv and
# the exact input-file bytes to FM_FAKE_JEV_LOG, and exits 0 on every outcome
# exactly like the real bin/fm-jev-screen.sh contract.
make_fake_jev_screener() {  # <case-dir>
  local dir=$1
  cat > "$dir/jev-screen-fake" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_JEV_LOG:?FM_FAKE_JEV_LOG}
input='' args='' prev=''
for a in "$@"; do
  args="$args[$a]"
  case "$prev" in --idle-secs|--window) ;; *)
    case "$a" in -*) ;; *) input=$a ;; esac ;;
  esac
  prev=$a
done
{
  printf 'argv %s\n' "$args"
  cat "$input" 2>/dev/null || true
  printf '\n[end]\n'
} >> "$log"
case "${FM_FAKE_JEV_MODE:-clear}" in
  off)
    echo "screen: off (TYPESAFE_API_KEY absent)" >&2
    exit 0
    ;;
  error)
    printf 'screen:\n  status: error\n  reason: http 000 after 5 ms\n'
    exit 0
    ;;
  malformed)
    printf 'screen:\n  status: clear\n  choice: actively-working\n'
    exit 0
    ;;
  clear)
    printf 'screen:\n  status: clear\n  choice: %s\n  confidence: %s\n  latency_ms: 312\n  tokens: 340/28\n' \
      "${FM_FAKE_JEV_CHOICE:-actively-working}" "${FM_FAKE_JEV_CONF:-0.92}"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$dir/jev-screen-fake"
  printf '%s\n' "$dir/jev-screen-fake"
}

record_pi_busy() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" busy --gen "$gen" \
    --source pi-ext --event agent-start
}

# Common at-threshold fixture: a ship crew behind a static idle pane whose
# status is non-terminal, whose hash is already classified stale, and whose
# wedge timer is backdated past the threshold, so the very first poll lands on
# the at-threshold branch where the pre-screen consult lives. The pane text is
# written to <case-dir>/pane.txt, the file watch_jev_bg hands the fake tmux.
# Echoes the case dir; callers add case-specific markers and env.
make_jev_case() {  # <name> <window> <task> <pane-text>
  local name=$1 window=$2 task=$3 pane_text=$4 dir state sig key pane_hash back
  dir=$(make_case "$name")
  state="$dir/state"
  printf '%s' "$pane_text" > "$dir/pane.txt"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/$task.meta"
  printf 'working: implementing\n' > "$state/$task.status"
  sig=$(seen_sig "$state/$task.status")
  printf '%s' "$sig" > "$state/.seen-${task}_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "$pane_text")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  back=$(( $(date +%s) - 500 ))
  echo "$back" > "$state/.stale-since-$key"
  set_mtime "$back" "$state/.stale-since-$key"
  mkdir -p "$dir/config"
  make_fake_jev_screener "$dir" >/dev/null
  : > "$dir/jev.log"
  printf '%s\n' "$dir"
}

# Launch the watcher for one of these cases with the fake screener wired in and
# the knobs pinned to the stale path only. Extra env assignments may follow.
watch_jev_bg() {  # <case-dir> <out> [env assignments...]
  local dir=$1 out=$2
  shift 2
  local fakebin="$dir/fakebin" window
  window=$(sed -n 's/^window=//p' "$dir/state"/*.meta | head -n 1)
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" \
    FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$dir/state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_CONFIG_OVERRIDE="$dir/config" \
    FM_JEV_WEDGE_SCREENER="$dir/jev-screen-fake" FM_FAKE_JEV_LOG="$dir/jev.log" \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_FAKE_CREW_STATE='state: working · source: run-step · ci running' \
    "$@" "$WATCH" > "$out" &
}

jev_case_key() {  # <case-dir> -> the window key the watcher uses for markers
  local dir=$1 window
  window=$(sed -n 's/^window=//p' "$dir/state"/*.meta | head -n 1)
  printf '%s' "$window" | tr ':/.' '___'
}

# The 2026-08-14 regression shape, replayed: a working crew behind a static
# pane whose tail shows live tool banners, every deterministic probe negative.
# A high-confidence actively-working screen absorbs exactly one threshold
# window; the second consult escalates with today's byte-identical reason.
test_jev_prescreen_absorbs_once_then_escalates_unchanged() {
  local dir state key out drain_out pid back count
  dir=$(make_jev_case jev-regression "test:fm-jev1" jev1 "● Bash(ls -la /workspace)
● Read(src/worker.py)
● Edit(tests/worker.test.sh)
Running: bash tests/worker.test.sh")
  state="$dir/state"; key=$(jev_case_key "$dir")
  out="$dir/watch.out"; drain_out="$dir/drain.out"

  # Phase A: first high-confidence consult defers.
  FM_FAKE_JEV_MODE=clear FM_FAKE_JEV_CONF=0.92 watch_jev_bg "$dir" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher escaped the first jev deferral and exited: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "the jev deferral printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "the jev deferral enqueued a wake"; }
  [ "$(cat "$state/.writing-deferred-$key" 2>/dev/null || true)" = 1 ] \
    || { reap "$pid"; fail "the first jev deferral did not record deferral count 1"; }
  back=$(( $(date +%s) - 500 ))
  [ "$(cat "$state/.stale-since-$key" 2>/dev/null || echo 0)" -gt "$back" ] \
    || { reap "$pid"; fail "the jev deferral did not restart the idle timer"; }
  grep -F 'Jev pre-screen: actively-working at confidence 0.92' "$state/.watch-triage.log" >/dev/null \
    || { reap "$pid"; fail "the deferral triage line did not name the screen verdict"; }
  grep -F 'argv [--idle-secs]' "$dir/jev.log" >/dev/null \
    || { reap "$pid"; fail "the consult did not pass the idle age"; }
  grep -E 'argv .*\[--window\]\[test:fm-jev1\]' "$dir/jev.log" >/dev/null \
    || { reap "$pid"; fail "the consult did not pass the window identity"; }
  grep -F 'Running: bash tests/worker.test.sh' "$dir/jev.log" >/dev/null \
    || { reap "$pid"; fail "the consult did not receive the pane tail"; }
  count=$(grep -c '^argv ' "$dir/jev.log")
  [ "$count" = 1 ] || { reap "$pid"; fail "expected exactly one consult in the deferred window, saw $count"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional phase-A watcher stop"

  # Phase B: the second consecutive consult escalates exactly as today.
  back=$(( $(date +%s) - 500 ))
  echo "$back" > "$state/.stale-since-$key"
  set_mtime "$back" "$state/.stale-since-$key"
  : > "$out"
  FM_FAKE_JEV_MODE=clear FM_FAKE_JEV_CONF=0.92 watch_jev_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "the second consecutive jev defer did not escalate: $(cat "$out")"
  grep -E "^stale: test:fm-jev1 \(idle [0-9]+s, possible wedge, escalation 1\)$" "$out" >/dev/null \
    || fail "the post-bound escalation was not today's byte-identical wedge reason: $(cat "$out")"
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || true)" = 1 ] \
    || fail "the post-bound escalation was not counted"
  [ ! -e "$state/.writing-deferred-$key" ] \
    || fail "the deferral count outlived the escalation that cleared the chain"
  count=$(grep -c '^argv ' "$dir/jev.log")
  [ "$count" = 2 ] || fail "expected exactly two consults across both windows, saw $count"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the escalation failed"
  count=$(grep "$(printf '\tstale\t')" "$drain_out" | grep -cF 'test:fm-jev1')
  [ "$count" = 1 ] || fail "expected exactly one queued stale wake, saw $count"
  pass "the jev pre-screen absorbs one threshold window, then escalates with today's unchanged reason"
}

# Deterministic evidence keeps the consult at zero: a pane whose worktree is
# being written defers on that harder signal and the screener never runs.
test_jev_prescreen_never_consults_when_deterministic_evidence_defers() {
  local dir state key out pid wt
  dir=$(make_jev_case jev-write-evidence "test:fm-jev2" jev2 "idle, tail quiet")
  state="$dir/state"; key=$(jev_case_key "$dir"); out="$dir/watch.out"
  wt="$dir/wt"
  mkdir -p "$wt/src"
  printf 'worktree=%s\n' "$wt" >> "$state/jev2.meta"
  printf 'int main(void) { return 0; }\n' > "$wt/src/main.c"
  FM_FAKE_JEV_MODE=clear FM_FAKE_JEV_CONF=0.92 watch_jev_bg "$dir" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher wedge-escalated a pane deferred by worktree-write evidence: $(cat "$out")"
  fi
  [ -e "$state/.writing-since-$key" ] || { reap "$pid"; fail "the write deferral chain marker was not recorded"; }
  [ ! -s "$dir/jev.log" ] || { reap "$pid"; fail "the screener was consulted although deterministic evidence deferred"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional watcher stop"
  pass "positive deterministic evidence defers with zero pre-screen consults"
}

# A key-absent home escalates exactly as today: the opt-in gate lives in the
# screener (whose own suite pins that no network call is made), and the empty
# verdict leaves the watcher's behavior byte-identical.
test_jev_prescreen_key_absent_escalates_as_today() {
  local dir state key out drain_out pid
  dir=$(make_jev_case jev-off "test:fm-jev3" jev3 "idle, tail quiet")
  state="$dir/state"; key=$(jev_case_key "$dir"); out="$dir/watch.out"; drain_out="$dir/drain.out"
  FM_FAKE_JEV_MODE=off watch_jev_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "a key-absent home did not escalate on today's schedule: $(cat "$out")"
  grep -E "^stale: test:fm-jev3 \(idle [0-9]+s, possible wedge, escalation 1\)$" "$out" >/dev/null \
    || fail "the key-absent escalation was not today's byte-identical wedge reason: $(cat "$out")"
  [ ! -e "$state/.writing-deferred-$key" ] || fail "a key-absent consult left a deferral marker behind"
  [ "$(grep -c '^argv ' "$dir/jev.log")" = 1 ] \
    || fail "expected the single consult subprocess, saw $(grep -c '^argv ' "$dir/jev.log")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the escalation failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F 'test:fm-jev3' >/dev/null \
    || fail "the key-absent escalation was not queued"
  pass "a key-absent home escalates exactly as today with the screener's off verdict"
}

# Fail-soft pins: a below-floor confidence, a non-working verdict, a screen
# error, and a malformed block each produce today's escalation, no deferral
# marker, and exit 0 from the screener contract.
run_fail_soft_case() {  # <name> <mode> <choice> <conf>
  local name=$1 mode=$2 choice=$3 conf=$4 dir state key out pid
  dir=$(make_jev_case "jev-$name" "test:fm-$name" "$name" "idle, tail quiet")
  state="$dir/state"; key=$(jev_case_key "$dir"); out="$dir/watch.out"
  FM_FAKE_JEV_MODE=$mode FM_FAKE_JEV_CHOICE=$choice FM_FAKE_JEV_CONF=$conf watch_jev_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 \
    || fail "the $name outcome did not escalate on today's schedule: $(cat "$out")"
  grep -E "^stale: test:fm-$name \(idle [0-9]+s, possible wedge, escalation 1\)$" "$out" >/dev/null \
    || fail "the $name escalation was not today's byte-identical wedge reason: $(cat "$out")"
  [ ! -e "$state/.writing-deferred-$key" ] || fail "the $name outcome left a deferral marker behind"
  [ ! -e "$state/.writing-since-$key" ] || fail "the $name outcome left a write chain behind"
  if [ "$mode" = error ]; then
    grep -F 'escalating unchanged (http 000 after 5 ms)' "$state/.watch-triage.log" >/dev/null \
      || fail "the screen-error outcome did not log its reason as the no-verdict diagnostic"
  fi
}

test_jev_prescreen_fail_soft_verdicts_escalate_as_today() {
  run_fail_soft_case below-floor clear actively-working 0.5
  run_fail_soft_case other-verdict clear stalled 0.95
  run_fail_soft_case screen-error error actively-working 0.92
  run_fail_soft_case malformed malformed actively-working 0.92
  pass "below-floor, non-working, error, and malformed screens all escalate unchanged with no markers"
}

# The one-defer budget clears on a pane hash change: a new quiet stretch on new
# bytes gets a fresh budget, so a churn-and-stall pane cannot accumulate bound
# credit, while the watcher never suppresses the escalation it still owes.
test_jev_defer_budget_clears_on_pane_hash_change() {
  local dir state key out pid back pane_hash
  dir=$(make_jev_case jev-hash-clear "test:fm-jev5" jev5 "first quiet stretch")
  state="$dir/state"; key=$(jev_case_key "$dir"); out="$dir/watch.out"
  FM_FAKE_JEV_MODE=clear FM_FAKE_JEV_CONF=0.92 watch_jev_bg "$dir" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher escaped the first jev deferral: $(cat "$out")"
  fi
  [ "$(cat "$state/.writing-deferred-$key" 2>/dev/null || true)" = 1 ] \
    || { reap "$pid"; fail "the first jev deferral did not record count 1"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional phase-A watcher stop"

  # The pane changes: the hash-change poll must reset the budget.
  printf '%s' 'second quiet stretch, new bytes' > "$dir/pane.txt"
  : > "$out"
  FM_FAKE_JEV_MODE=clear FM_FAKE_JEV_CONF=0.92 watch_jev_bg "$dir" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "the hash-change poll exited unexpectedly: $(cat "$out")"
  fi
  [ ! -e "$state/.writing-deferred-$key" ] \
    || { reap "$pid"; fail "a pane hash change did not clear the deferral budget"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional hash-change watcher stop"

  # The new quiet stretch reaches the threshold and gets a fresh deferral.
  pane_hash=$(hash_text "second quiet stretch, new bytes")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  back=$(( $(date +%s) - 500 ))
  echo "$back" > "$state/.stale-since-$key"
  set_mtime "$back" "$state/.stale-since-$key"
  : > "$out"
  FM_FAKE_JEV_MODE=clear FM_FAKE_JEV_CONF=0.92 watch_jev_bg "$dir" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "the fresh budget did not defer the new quiet stretch: $(cat "$out")"
  fi
  [ "$(cat "$state/.writing-deferred-$key" 2>/dev/null || true)" = 1 ] \
    || { reap "$pid"; fail "the new quiet stretch did not restart at deferral count 1"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional final watcher stop"
  pass "a pane hash change clears the one-defer budget for the next quiet stretch"
}

# A delivered re-surface wake clears the budget: the shared throttle marker
# newer than the count marker is the watcher's own record that firstmate was
# woken since the last defer, so the bound it guards was met.
test_jev_defer_budget_clears_after_a_delivered_resurface() {
  local dir state key out pid now
  dir=$(make_jev_case jev-resurface-clear "test:fm-jev6" jev6 "quiet behind a fresh recheck")
  state="$dir/state"; key=$(jev_case_key "$dir"); out="$dir/watch.out"
  now=$(date +%s)
  printf '1\n' > "$state/.writing-deferred-$key"
  set_mtime "$(( now - 100 ))" "$state/.writing-deferred-$key"
  : > "$state/.writing-resurfaced-$key"
  set_mtime "$(( now - 10 ))" "$state/.writing-resurfaced-$key"
  FM_FAKE_JEV_MODE=clear FM_FAKE_JEV_CONF=0.92 watch_jev_bg "$dir" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a consult after a delivered re-surface escalated instead of deferring: $(cat "$out")"
  fi
  [ "$(cat "$state/.writing-deferred-$key" 2>/dev/null || true)" = 1 ] \
    || { reap "$pid"; fail "a delivered re-surface did not restart the deferral budget at 1"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional watcher stop"
  pass "a delivered re-surface wake clears the one-defer budget"
}

# The confidence floor comes from config/jev-wedge-floor; a malformed value and
# an absent file both mean the 0.8 default, and the floor compares inclusive.
test_jev_defer_floor_comes_from_config() {
  local dir state key out pid
  dir=$(make_jev_case jev-floor-high "test:fm-jev7" jev7 "quiet under a raised floor")
  state="$dir/state"; key=$(jev_case_key "$dir"); out="$dir/watch.out"
  printf '0.95\n' > "$dir/config/jev-wedge-floor"
  FM_FAKE_JEV_MODE=clear FM_FAKE_JEV_CONF=0.92 watch_jev_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "a 0.92 verdict under a 0.95 floor did not escalate: $(cat "$out")"
  [ ! -e "$state/.writing-deferred-$key" ] || fail "a below-config-floor verdict left a deferral marker behind"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional watcher stop"

  dir=$(make_jev_case jev-floor-low "test:fm-jev8" jev8 "quiet under a lowered floor")
  state="$dir/state"; key=$(jev_case_key "$dir"); out="$dir/watch.out"
  printf '0.5\n' > "$dir/config/jev-wedge-floor"
  FM_FAKE_JEV_MODE=clear FM_FAKE_JEV_CONF=0.6 watch_jev_bg "$dir" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a 0.6 verdict under a 0.5 floor did not defer: $(cat "$out")"
  fi
  [ "$(cat "$state/.writing-deferred-$key" 2>/dev/null || true)" = 1 ] \
    || { reap "$pid"; fail "the config-lowered floor did not defer at 0.6"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional watcher stop"

  dir=$(make_jev_case jev-floor-default "test:fm-jev9" jev9 "quiet at the default floor")
  state="$dir/state"; key=$(jev_case_key "$dir"); out="$dir/watch.out"
  FM_FAKE_JEV_MODE=clear FM_FAKE_JEV_CONF=0.8 watch_jev_bg "$dir" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a 0.8 verdict at the default 0.8 floor did not defer: $(cat "$out")"
  fi
  [ "$(cat "$state/.writing-deferred-$key" 2>/dev/null || true)" = 1 ] \
    || { reap "$pid"; fail "the default floor did not defer an exactly-at-floor verdict"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional watcher stop"

  # A malformed value never reaches the comparison: a multi-dot typo and an
  # out-of-range number both mean the documented 0.8, so an above-default
  # verdict still defers instead of silently disabling the feature (or, on an
  # awk that string-compares, deferring everything).
  dir=$(make_jev_case jev-floor-typo "test:fm-jev10" jev10 "quiet under a mistyped floor")
  state="$dir/state"; key=$(jev_case_key "$dir"); out="$dir/watch.out"
  printf '0..8\n' > "$dir/config/jev-wedge-floor"
  FM_FAKE_JEV_MODE=clear FM_FAKE_JEV_CONF=0.92 watch_jev_bg "$dir" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "the multi-dot floor typo did not fall back to 0.8 and defer: $(cat "$out")"
  fi
  [ "$(cat "$state/.writing-deferred-$key" 2>/dev/null || true)" = 1 ] \
    || { reap "$pid"; fail "the multi-dot floor typo did not defer at the 0.8 fallback"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional watcher stop"

  dir=$(make_jev_case jev-floor-range "test:fm-jev11" jev11 "quiet under an out-of-range floor")
  state="$dir/state"; key=$(jev_case_key "$dir"); out="$dir/watch.out"
  printf '5\n' > "$dir/config/jev-wedge-floor"
  FM_FAKE_JEV_MODE=clear FM_FAKE_JEV_CONF=0.92 watch_jev_bg "$dir" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "the out-of-range floor did not fall back to 0.8 and defer: $(cat "$out")"
  fi
  [ "$(cat "$state/.writing-deferred-$key" 2>/dev/null || true)" = 1 ] \
    || { reap "$pid"; fail "the out-of-range floor did not defer at the 0.8 fallback"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional watcher stop"
  pass "the deferral floor comes from config/jev-wedge-floor and compares inclusive, defaulting to 0.8 on an absent or malformed file"
}

# --- routine-wake triage: the pre-screen widened past the wedge path ---------
#
# The captain's 2026-10-12 ask: echoes and benign polls get Jev-classified
# before they cost a helm turn. Two routine surfaces forward wakes today that a
# typed pane read can clear: the no-verb signal batch (a bare turn-end or a
# working: note whose crew state is unknown) and the first-sight non-terminal
# stale surface. Both consult the SAME screener, the SAME config floor, and the
# SAME fail-soft posture as the wedge path: only a high-confidence
# actively-working pane absorbs, every other verdict - and Jev itself
# unreachable - forwards exactly as today, and captain-relevant,
# decision-owned, afk, and secondmate-status wakes are never classified at all.

# Signal-path fixture: a ship crew whose status note or bare turn-end is the
# whole new span, every deterministic proof negative (unknown crew state, churn
# absorb not configured), and whose pane text is written to <case-dir>/pane.txt
# for the fake tmux. The fake screener records every consult to jev.log.
make_jev_signal_case() {  # <name> <task> <pane-text> [status-line]
  local name=$1 id=$2 pane_text=$3 status_line=${4:-} dir state
  dir=$(make_case "$name")
  state="$dir/state"
  mkdir -p "$dir/config"
  printf '%s' "$pane_text" > "$dir/pane.txt"
  printf 'window=test:fm-%s\nkind=ship\n' "$id" > "$state/$id.meta"
  [ -z "$status_line" ] || printf '%s\n' "$status_line" > "$state/$id.status"
  make_fake_jev_screener "$dir" >/dev/null
  : > "$dir/jev.log"
  printf '%s\n' "$dir"
}

# Launch the watcher for a signal case. A slow poll leaves the signal absorb's
# assertions many ticks clear of the stale backbone this static fixture pane
# would otherwise reach.
watch_jev_signal_bg() {  # <case-dir> <out> [env assignments...]
  local dir=$1 out=$2
  shift 2
  local fakebin="$dir/fakebin" window
  window=$(sed -n 's/^window=//p' "$dir/state"/*.meta | head -n 1)
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" \
    FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$dir/state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_CONFIG_OVERRIDE="$dir/config" \
    FM_JEV_WEDGE_SCREENER="$dir/jev-screen-fake" FM_FAKE_JEV_LOG="$dir/jev.log" \
    FM_STALE_ESCALATE_SECS=999999 FM_PAUSE_RESURFACE_SECS=999999 \
    FM_POLL=3 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$@" "$WATCH" > "$out" &
}

# A no-verb signal whose pane the pre-screen classifies actively-working at or
# above the floor is absorbed: no wake, no queue row, suppressor advanced, and
# the consult received the pane tail and the window identity.
test_jev_routine_signal_active_pane_absorbed() {
  local dir state out pid
  dir=$(make_jev_signal_case jev-routine-absorb jevrs1 "● Bash(make lint)
● Edit(bin/fm-watch.sh)
Running: bash tests/fm-watch.test.sh" "working: implementing the widen step")
  state="$dir/state"; out="$dir/watch.out"
  FM_FAKE_JEV_MODE=clear FM_FAKE_JEV_CONF=0.92 \
    FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' \
    watch_jev_signal_bg "$dir" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "the watcher surfaced a no-verb signal the pre-screen cleared: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "the pre-screened benign signal printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "the pre-screened benign signal enqueued a durable wake"; }
  [ -s "$state/.seen-jevrs1_status" ] \
    || { reap "$pid"; fail "the pre-screened benign signal did not advance its .seen-* suppressor"; }
  grep -F 'Jev pre-screen: actively-working at confidence 0.92' "$state/.watch-triage.log" >/dev/null \
    || { reap "$pid"; fail "the absorb triage line did not name the screen verdict"; }
  grep -F 'Running: bash tests/fm-watch.test.sh' "$dir/jev.log" >/dev/null \
    || { reap "$pid"; fail "the routine consult did not receive the pane tail"; }
  grep -E 'argv .*\[--window\]\[test:fm-jevrs1\]' "$dir/jev.log" >/dev/null \
    || { reap "$pid"; fail "the routine consult did not pass the window identity"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional watcher stop"
  pass "a no-verb signal whose pane screens actively-working at the floor is absorbed"
}

# A non-working verdict on the same routine wake forwards exactly as today: the
# crew may be done, waiting, or wedged, and the classifier never silences that.
test_jev_routine_signal_waiting_pane_forwarded() {
  local dir state out drain_out pid
  dir=$(make_jev_signal_case jev-routine-wait jevrs2 "idle at prompt, nothing running" "working: step finished, next queued")
  state="$dir/state"; out="$dir/watch.out"; drain_out="$dir/drain.out"
  FM_FAKE_JEV_MODE=clear FM_FAKE_JEV_CONF=0.9 FM_FAKE_JEV_CHOICE=waiting-at-prompt \
    FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' \
    watch_jev_signal_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "a waiting-pane no-verb signal was not forwarded: $(cat "$out")"
  grep -F "signal: $state/jevrs2.status" "$out" >/dev/null \
    || fail "the forwarded signal was not today's byte-identical reason: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the forwarded signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F 'jevrs2.status' >/dev/null \
    || fail "the forwarded signal was not queued"
  pass "a no-verb signal whose pane screens waiting-at-prompt forwards exactly as today"
}

# Captain-relevant content is never classified: a done: append surfaces without
# a single consult, whatever the screener would have answered.
test_jev_routine_signal_captain_relevant_never_consulted() {
  local dir state out pid
  dir=$(make_jev_signal_case jev-routine-done jevrs3 "● PR ready: https://github.com/example/repo/pull/12" \
    "done: PR https://github.com/example/repo/pull/12 checks green")
  state="$dir/state"; out="$dir/watch.out"
  FM_FAKE_JEV_MODE=clear FM_FAKE_JEV_CONF=0.99 \
    FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' \
    watch_jev_signal_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "a done: signal did not surface: $(cat "$out")"
  grep -F "signal: $state/jevrs3.status" "$out" >/dev/null \
    || fail "the done: signal was not today's byte-identical reason: $(cat "$out")"
  [ ! -s "$dir/jev.log" ] || fail "a captain-relevant signal was classified: $(cat "$dir/jev.log")"
  pass "a captain-relevant done: signal surfaces with zero pre-screen consults"
}

# Away posture: the daemon owns triage, so the watcher queues and exits on the
# routine wake without consulting the classifier at all.
test_jev_routine_signal_afk_never_consulted() {
  local dir state out pid
  dir=$(make_jev_signal_case jev-routine-afk jevrs4 "● Bash(make lint)
Running: bash tests/x.sh" "working: implementing")
  state="$dir/state"; out="$dir/watch.out"
  : > "$state/.afk"
  FM_FAKE_JEV_MODE=clear FM_FAKE_JEV_CONF=0.99 \
    FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' \
    watch_jev_signal_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "an afk routine signal was not handed to the daemon: $(cat "$out")"
  grep -F "signal: $state/jevrs4.status" "$out" >/dev/null \
    || fail "the afk signal was not today's byte-identical reason: $(cat "$out")"
  [ ! -s "$dir/jev.log" ] || fail "an afk-owned routine signal was classified: $(cat "$dir/jev.log")"
  pass "an afk routine signal is queued for the daemon with zero pre-screen consults"
}

# Jev unreachable is today's behavior, never a new wedge: an off verdict and a
# screen error both forward the routine wake with today's byte-identical reason
# and leave no deferral marker behind.
test_jev_routine_signal_jev_unreachable_forwards() {
  local mode dir state out pid
  for mode in off error; do
    dir=$(make_jev_signal_case "jev-routine-$mode" "jevrs5$mode" "● Bash(make lint)" "working: implementing")
    state="$dir/state"; out="$dir/watch.out"
    FM_FAKE_JEV_MODE=$mode \
      FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' \
      watch_jev_signal_bg "$dir" "$out"
    pid=$!
    wait_for_exit "$pid" 100 || fail "the $mode outcome did not forward the routine signal: $(cat "$out")"
    grep -F "signal: $state/jevrs5$mode.status" "$out" >/dev/null \
      || fail "the $mode outcome was not today's byte-identical reason: $(cat "$out")"
    [ ! -e "$state/.writing-deferred-$(jev_case_key "$dir")" ] \
      || fail "the $mode outcome left a deferral marker behind"
  done
  pass "an unreachable Jev forwards the routine signal exactly as today"
}

# The widened consults share the wedge path's threshold mechanism: the same
# config/jev-wedge-floor file governs them, and the comparison is inclusive.
test_jev_routine_signal_floor_from_config() {
  local dir state out pid
  dir=$(make_jev_signal_case jev-routine-floor-high jevrs6 "● Bash(make lint)
Running: bash tests/x.sh" "working: implementing")
  state="$dir/state"; out="$dir/watch.out"
  printf '0.95\n' > "$dir/config/jev-wedge-floor"
  FM_FAKE_JEV_MODE=clear FM_FAKE_JEV_CONF=0.92 \
    FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' \
    watch_jev_signal_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "a 0.92 verdict under a 0.95 floor did not forward: $(cat "$out")"
  grep -F "signal: $state/jevrs6.status" "$out" >/dev/null \
    || fail "the below-floor forward was not today's reason: $(cat "$out")"

  dir=$(make_jev_signal_case jev-routine-floor-low jevrs7 "● Bash(make lint)
Running: bash tests/x.sh" "working: implementing")
  state="$dir/state"; out="$dir/watch.out"
  printf '0.5\n' > "$dir/config/jev-wedge-floor"
  FM_FAKE_JEV_MODE=clear FM_FAKE_JEV_CONF=0.6 \
    FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' \
    watch_jev_signal_bg "$dir" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a 0.6 verdict under a 0.5 floor did not absorb: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "the at-floor absorb printed a wake reason: $(cat "$out")"; }
  grep -F 'Jev pre-screen: actively-working at confidence 0.6' "$state/.watch-triage.log" >/dev/null \
    || { reap "$pid"; fail "the config-lowered floor did not absorb at 0.6"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional watcher stop"
  pass "the routine consults read the same config/jev-wedge-floor, compared inclusively"
}

# A secondmate's .status append is the parent-directed reply stream and is never
# classified: it surfaces with zero consults whatever the screener would say.
test_jev_routine_signal_secondmate_status_never_classified() {
  local dir state out pid
  dir=$(make_jev_signal_case jev-routine-mate jevrs8 "● Bash(make lint)
Running: bash tests/x.sh" "working: mate progress note")
  state="$dir/state"; out="$dir/watch.out"
  printf 'window=test:fm-jevrs8\nkind=secondmate\n' > "$state/jevrs8.meta"
  FM_FAKE_JEV_MODE=clear FM_FAKE_JEV_CONF=0.99 \
    FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' \
    watch_jev_signal_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "a secondmate status signal did not surface: $(cat "$out")"
  grep -F "signal: $state/jevrs8.status" "$out" >/dev/null \
    || fail "the secondmate signal was not today's byte-identical reason: $(cat "$out")"
  [ ! -s "$dir/jev.log" ] || fail "a secondmate status signal was classified: $(cat "$dir/jev.log")"
  pass "a secondmate .status signal surfaces with zero pre-screen consults"
}

# A mixed no-verb batch - the pre-screen clears the first pane and refuses the
# second - forwards, and the fired wake must not leave the cleared pane's
# benign classification in the triage log: that log records why a wake did not
# fire, so its benign lines may only be written once the whole batch passes
# and the absorb actually happens.
test_jev_routine_signal_mixed_batch_forwards_without_benign_line() {
  local dir state out pid consults
  dir=$(make_jev_signal_case jev-routine-mixed jev-jmixa "● Bash(make lint)
Running: bash tests/fm-watch.test.sh" "working: implementing the widen step")
  state="$dir/state"; out="$dir/watch.out"
  printf 'window=test:fm-jev-jmixb\nkind=ship\n' > "$state/jev-jmixb.meta"
  printf 'working: implementing the widen step\n' > "$state/jev-jmixb.status"
  cat > "$dir/jev-screen-fake" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_JEV_LOG:?FM_FAKE_JEV_LOG}
input='' args='' prev=''
for a in "$@"; do
  args="$args[$a]"
  case "$prev" in --idle-secs|--window) ;; *)
    case "$a" in -*) ;; *) input=$a ;; esac ;;
  esac
  prev=$a
done
{
  printf 'argv %s\n' "$args"
  cat "$input" 2>/dev/null || true
  printf '\n[end]\n'
} >> "$log"
case "$*" in
  *fm-jev-jmixb*)
    printf 'screen:\n  status: clear\n  choice: waiting-at-prompt\n  confidence: 0.9\n  latency_ms: 312\n  tokens: 340/28\n'
    ;;
  *)
    printf 'screen:\n  status: clear\n  choice: actively-working\n  confidence: 0.92\n  latency_ms: 312\n  tokens: 340/28\n'
    ;;
esac
exit 0
SH
  chmod +x "$dir/jev-screen-fake"
  FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' \
    watch_jev_signal_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "a mixed no-verb batch was not forwarded: $(cat "$out")"
  grep -F "signal: $state/jev-jmixa.status" "$out" >/dev/null \
    || fail "the mixed batch was not today's byte-identical reason: $(cat "$out")"
  consults=$(grep -c '^argv' "$dir/jev.log")
  [ "$consults" = 2 ] || fail "the mixed batch did not screen exactly both panes: $(cat "$dir/jev.log")"
  if [ -e "$state/.watch-triage.log" ] \
    && grep -qF 'benign no-verb signal' "$state/.watch-triage.log"; then
    fail "the forwarded mixed batch left a benign triage line: $(cat "$state/.watch-triage.log")"
  fi
  pass "a mixed no-verb batch forwards without logging the passing pane's benign line"
}

# Stale-path widening: the FIRST inconclusive sight of a static pane consults
# the same pre-screen. A high-confidence actively-working read absorbs and
# starts the ordinary wedge timer, so the existing one-defer wedge budget stays
# the bounded backstop: the next threshold window defers once, the one after
# escalates with today's byte-identical reason.
test_jev_first_sight_stale_absorbed_then_bounded_chain() {
  local dir state key out pid back window i
  window="test:fm-jevfs1"
  dir=$(make_case jev-fresh-sight)
  state="$dir/state"; key=$(printf '%s' "$window" | tr ':/.' '___'); out="$dir/watch.out"
  printf '%s' '● Bash(make lint)
● Edit(bin/fm-watch.sh)
Running: bash tests/fm-watch.test.sh' > "$dir/pane.txt"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/jevfs1.meta"
  printf 'working: implementing\n' > "$state/jevfs1.status"
  prime_status_seen "$state" "$state/jevfs1.status"
  mkdir -p "$dir/config"
  make_fake_jev_screener "$dir" >/dev/null
  : > "$dir/jev.log"
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_JEV_WEDGE_SCREENER="$dir/jev-screen-fake" \
    FM_FAKE_JEV_LOG="$dir/jev.log" FM_FAKE_JEV_MODE=clear FM_FAKE_JEV_CONF=0.92 \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    grep -Fq 'first sight' "$state/.watch-triage.log" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "the watcher surfaced a first-sight stale the pre-screen cleared: $(cat "$out")"; }
    sleep 0.1; i=$((i + 1))
  done
  [ "$i" -lt 100 ] || { reap "$pid"; fail "the first-sight stale was never pre-screened"; }
  [ ! -s "$out" ] || { reap "$pid"; fail "the first-sight absorb printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "the first-sight absorb enqueued a durable wake"; }
  [ -s "$state/.stale-since-$key" ] \
    || { reap "$pid"; fail "the first-sight absorb did not start the wedge timer"; }
  grep -F 'Jev pre-screen: actively-working at confidence 0.92, first sight' "$state/.watch-triage.log" >/dev/null \
    || { reap "$pid"; fail "the first-sight triage line did not name the screen verdict"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional phase-A watcher stop"

  # Phase B: the wedge timer crosses its threshold; the wedge path's own
  # consult defers exactly once, so no helm turn yet.
  back=$(( $(date +%s) - 500 ))
  echo "$back" > "$state/.stale-since-$key"
  set_mtime "$back" "$state/.stale-since-$key"
  : > "$out"
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_JEV_WEDGE_SCREENER="$dir/jev-screen-fake" \
    FM_FAKE_JEV_LOG="$dir/jev.log" FM_FAKE_JEV_MODE=clear FM_FAKE_JEV_CONF=0.92 \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "the post-first-sight wedge window did not defer: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "the wedge deferral printed a wake reason: $(cat "$out")"; }
  [ "$(cat "$state/.writing-deferred-$key" 2>/dev/null || true)" = 1 ] \
    || { reap "$pid"; fail "the wedge consult did not record its one-defer budget"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional phase-B watcher stop"

  # Phase C: a second consecutive defer is refused; today's wedge escalation.
  back=$(( $(date +%s) - 500 ))
  echo "$back" > "$state/.stale-since-$key"
  set_mtime "$back" "$state/.stale-since-$key"
  : > "$out"
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_JEV_WEDGE_SCREENER="$dir/jev-screen-fake" \
    FM_FAKE_JEV_LOG="$dir/jev.log" FM_FAKE_JEV_MODE=clear FM_FAKE_JEV_CONF=0.92 \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "the second consecutive defer did not escalate: $(cat "$out")"
  grep -E "^stale: test:fm-jevfs1 \(idle [0-9]+s, possible wedge, escalation 1\)$" "$out" >/dev/null \
    || fail "the final escalation was not today's byte-identical wedge reason: $(cat "$out")"
  pass "a first-sight stale the pre-screen clears absorbs into the existing bounded wedge chain"
}

# A non-working verdict on the first inconclusive sight forwards immediately,
# exactly as the surface does today: the finish is never left waiting.
test_jev_first_sight_stale_waiting_pane_surfaced() {
  local dir state out pid window
  window="test:fm-jevfs2"
  dir=$(make_case jev-fresh-sight-wait)
  state="$dir/state"; out="$dir/watch.out"
  printf '%s' 'idle at prompt, nothing running' > "$dir/pane.txt"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/jevfs2.meta"
  printf 'working: implementing\n' > "$state/jevfs2.status"
  prime_status_seen "$state" "$state/jevfs2.status"
  mkdir -p "$dir/config"
  make_fake_jev_screener "$dir" >/dev/null
  : > "$dir/jev.log"
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_JEV_WEDGE_SCREENER="$dir/jev-screen-fake" \
    FM_FAKE_JEV_LOG="$dir/jev.log" FM_FAKE_JEV_MODE=clear FM_FAKE_JEV_CONF=0.9 \
    FM_FAKE_JEV_CHOICE=waiting-at-prompt \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a waiting first-sight stale was not surfaced: $(cat "$out")"
  grep -E "^stale: test:fm-jevfs2$" "$out" >/dev/null \
    || fail "the forwarded first-sight stale was not today's byte-identical reason: $(cat "$out")"
  pass "a waiting first-sight stale forwards immediately with today's reason"
}

# The busy-over-age path reaches the same consult: a busy pane with no completed
# turn past BUSY_TURN_MAX_SECS hands its crossed bound to the wedge timer with
# the pane tail in hand, so the pre-screen covers it too.
test_jev_prescreen_covers_the_busy_over_age_path() {
  local dir state key out pid window pane_hash back sig
  window="test:fm-jevbusy"
  dir=$(make_case jev-busy-path)
  state="$dir/state"; key=$(printf '%s' "$window" | tr ':/.' '___'); out="$dir/watch.out"
  printf '%s' 'Working... tool banner in flight' > "$dir/pane.txt"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/jevbusy.meta"
  record_pi_busy "$state" jevbusy
  printf 'working: setup complete\n' > "$state/jevbusy.status"
  sig=$(seen_sig "$state/jevbusy.status"); printf '%s' "$sig" > "$state/.seen-jevbusy_status"
  pane_hash=$(hash_text "Working... tool banner in flight")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  touch -t 200001010000 "$state/jevbusy.meta"
  mkdir -p "$dir/config"
  make_fake_jev_screener "$dir" >/dev/null
  : > "$dir/jev.log"
  back=$(( $(date +%s) - 500 ))
  echo "$back" > "$state/.stale-since-$key"
  set_mtime "$back" "$state/.stale-since-$key"
  PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_JEV_WEDGE_SCREENER="$dir/jev-screen-fake" \
    FM_FAKE_JEV_LOG="$dir/jev.log" FM_FAKE_JEV_MODE=clear FM_FAKE_JEV_CONF=0.92 \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_FAKE_CREW_STATE='state: working · source: run-step · ci running' "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "the busy-over-age pane was not deferred by the pre-screen: $(cat "$out")"
  fi
  [ "$(cat "$state/.writing-deferred-$key" 2>/dev/null || true)" = 1 ] \
    || { reap "$pid"; fail "the busy-over-age deferral did not record count 1"; }
  grep -F 'Working... tool banner in flight' "$dir/jev.log" >/dev/null \
    || { reap "$pid"; fail "the busy-path consult did not receive the pane tail"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional watcher stop"
  pass "the busy-over-age path reaches the same pre-screen consult with its pane tail"
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
  exit 0
fi

test_jev_prescreen_absorbs_once_then_escalates_unchanged
test_jev_prescreen_never_consults_when_deterministic_evidence_defers
test_jev_prescreen_key_absent_escalates_as_today
test_jev_prescreen_fail_soft_verdicts_escalate_as_today
test_jev_defer_budget_clears_on_pane_hash_change
test_jev_defer_budget_clears_after_a_delivered_resurface
test_jev_defer_floor_comes_from_config
test_jev_prescreen_covers_the_busy_over_age_path
test_jev_routine_signal_active_pane_absorbed
test_jev_routine_signal_waiting_pane_forwarded
test_jev_routine_signal_captain_relevant_never_consulted
test_jev_routine_signal_afk_never_consulted
test_jev_routine_signal_jev_unreachable_forwards
test_jev_routine_signal_floor_from_config
test_jev_routine_signal_secondmate_status_never_classified
test_jev_routine_signal_mixed_batch_forwards_without_benign_line
test_jev_first_sight_stale_absorbed_then_bounded_chain
test_jev_first_sight_stale_waiting_pane_surfaced
