#!/usr/bin/env bash
# Evidence harness, systemd variant: runs the exact CI command for job
# "Behavior portable serial 1" inside a transient systemd user unit (clean
# process ancestry, as a hosted runner has), and samples every 2 s:
#   descendants - size of the unit's live process tree (its fixtures included)
#   root_args  - live processes whose command line names the run's unique
#                fixture tmp root (the harness's own reaper match)
#
# Usage: run-serial1-sampled-systemd.sh <label> <worktree-dir>
# Writes: fm-serial1-<label>-{run.log,processes.csv,summary.txt,timing.json,rc}
set -u
label=${1:?label}
wd=${2:?worktree}
ev=$(cd "$(dirname "$0")" && pwd)
log="$ev/fm-serial1-$label-run.log"
csv="$ev/fm-serial1-$label-processes.csv"
sum="$ev/fm-serial1-$label-summary.txt"
rcfile="$ev/fm-serial1-$label.rc"
: >"$csv"
rm -f "$rcfile"

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

unit="fm-serial1-$label-$(date +%s)"
systemd-run --user --collect --quiet --unit="$unit" \
  bash "$ev/run-serial1-lane-inner.sh" "$wd" "$ev" "$label" || exit 99

start=$(date +%s)
pid=''
until pid=$(systemctl --user show -p MainPID --value "$unit" 2>/dev/null) \
    && [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null; do
  state=$(systemctl --user is-active "$unit" 2>/dev/null || true)
  case "$state" in active|activating) ;; *) pid=''; break ;; esac
  sleep 0.2
done

root=''
while :; do
  state=$(systemctl --user is-active "$unit" 2>/dev/null || true)
  case "$state" in active|activating) ;; *) break ;; esac
  [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null || break
  pids=" $(descendant_pids "$pid")"
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

until [ -f "$rcfile" ]; do
  sleep 0.2
  [ $(( $(date +%s) - start )) -lt 300 ] || { echo 124 >"$rcfile"; break; }
done
rc=$(cat "$rcfile")
end=$(date +%s)

ok_total=$(grep -c '^ok - ' "$log"); ok_total=${ok_total:-0}
not_ok=$(grep -c '^not ok - ' "$log"); not_ok=${not_ok:-0}
{
  echo "label=$label"
  echo "worktree=$wd"
  echo "unit=$unit"
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
