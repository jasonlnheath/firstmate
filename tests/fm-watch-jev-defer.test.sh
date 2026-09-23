#!/usr/bin/env bash
# tests/fm-watch-jev-defer.test.sh - the Jev wedge pre-screen integration in
# bin/fm-watch.sh (the overnight Jev plan's item 4.1 / candidate C1): an
# optional typed classifier consult on the wedge escalation path, fail-soft in
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
  pass "the deferral floor comes from config/jev-wedge-floor and compares inclusive, defaulting to 0.8"
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
