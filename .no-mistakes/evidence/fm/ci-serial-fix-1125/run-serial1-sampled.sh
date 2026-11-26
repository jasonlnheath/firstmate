#!/usr/bin/env bash
# Evidence harness for the fm/ci-serial-fix-1125 test phase.
#
# Runs the exact CI command for job "Behavior portable serial 1"
#   (bin/fm-test-run.sh --lane portable-serial-1of10 ...) from <worktree-dir>,
# and samples every 2 seconds while it runs:
#   descendants - size of the runner's live process tree, i.e. every process
#                the lane has alive at that moment (its fixtures included)
#   root_args  - live processes whose command line names the run's unique
#                fixture tmp root, the same match bin/fm-test-run.sh's own
#                reaper (tests/lib.sh fm_test_reap_root_processes) uses
#
# The fixture root is bound to this run by checking the .fm-test-fixture
# marker's owning pid is inside the runner's own tree, so unrelated fm-*
# tmp directories on the host never skew the counts.
#
# Usage: run-serial1-sampled.sh <label> <worktree-dir>
# Writes into this evidence directory:
#   fm-serial1-<label>-run.log        full runner output (ok lines, FM_TEST_*)
#   fm-serial1-<label>-processes.csv  epoch,ok_lines,descendants,root_args
#   fm-serial1-<label>-summary.txt    exit, duration, test counts, curve stats
#   fm-serial1-<label>-timing.json    the runner's --json timing artifact
set -u
label=${1:?label}
wd=${2:?worktree}
ev=$(cd "$(dirname "$0")" && pwd)
log="$ev/fm-serial1-$label-run.log"
csv="$ev/fm-serial1-$label-processes.csv"
sum="$ev/fm-serial1-$label-summary.txt"
json="$ev/fm-serial1-$label-timing.json"
: >"$log" || exit 99
: >"$csv" || exit 99

descendant_pids() {  # <pid> -> descendant pids, space separated, one snapshot
  local frontier="$1" out all=''
  while :; do
    out=$(ps -eo pid=,ppid= | awk -v P=" $frontier " '
      BEGIN { n = split(P, a, " "); for (i = 1; i <= n; i++) if (a[i] != "") keep[a[i]] = 1 }
      ($2 in keep) { printf "%s ", $1 }')
    [ -n "$out" ] || break
    all="$all $out"
    frontier="$out"
  done
  printf '%s\n' "$all"
}

find_fixture_root() {  # <space-padded pids> -> this run's tmp root, or nothing
  local dir marker_pid
  for dir in /tmp/fm-supervision-host.*/; do
    [ -f "$dir/.fm-test-fixture" ] || continue
    marker_pid=$(sed -n '1p' "$dir/.fm-test-fixture" 2>/dev/null) || continue
    case "$1" in *" $marker_pid "*) printf '%s\n' "${dir%/}"; return 0 ;; esac
  done
  return 1
}

cd "$wd" || { echo "cannot cd $wd" >&2; exit 99; }
start=$(date +%s)
bin/fm-test-run.sh --lane portable-serial-1of10 \
  --fail-on-gate-skip 'Pi extension typecheck prerequisite not found' \
  --json "$json" >"$log" 2>&1 &
runner=$!

root=''
while kill -0 "$runner" 2>/dev/null; do
  pids=" $(descendant_pids "$runner")"
  ok=$(grep -c '^ok - ' "$log" 2>/dev/null); ok=${ok:-0}
  ra=0
  [ -n "$root" ] || root=$(find_fixture_root "$pids")
  if [ -n "$root" ]; then
    ra=$(ps -ww -eo args= | ROOTPATH="$root/" \
      awk 'index($0, ENVIRON["ROOTPATH"]) { n++ } END { print n + 0 }')
  fi
  printf '%s,%s,%s,%s\n' "$(date +%s)" "$ok" "$(printf '%s' "$pids" | wc -w)" "$ra" >>"$csv"
  sleep 2
done
wait "$runner"; rc=$?
end=$(date +%s)

ok_total=$(grep -c '^ok - ' "$log"); ok_total=${ok_total:-0}
not_ok=$(grep -c '^not ok - ' "$log"); not_ok=${not_ok:-0}
{
  echo "label=$label"
  echo "worktree=$wd"
  echo "runner_exit=$rc"
  echo "duration_seconds=$((end - start))"
  echo "ok_lines=$ok_total"
  echo "not_ok_lines=$not_ok"
  echo "fixture_root=${root:-<not discovered>}"
  grep '^FM_TEST_END ' "$log" || true
  echo "samples=$(wc -l <"$csv")"
  echo "max_descendants=$(cut -d, -f3 "$csv" | sort -n | tail -1)"
  echo "median_descendants=$(cut -d, -f3 "$csv" | sort -n | awk '{a[NR]=$1} END {print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}')"
  echo "mean_descendants=$(cut -d, -f3 "$csv" | awk '{s+=$1} END {printf "%.1f", s/NR}')"
  echo "max_root_args=$(cut -d, -f4 "$csv" | sort -n | tail -1)"
  echo "median_root_args=$(cut -d, -f4 "$csv" | sort -n | awk '{a[NR]=$1} END {print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}')"
  echo "first_sample=$(head -1 "$csv")"
  echo "last_sample=$(tail -1 "$csv")"
} >"$sum"
exit "$rc"
