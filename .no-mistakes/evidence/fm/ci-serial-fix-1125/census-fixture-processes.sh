#!/usr/bin/env bash
# Evidence helper: wait until <label>'s run has passed <threshold> tests, then
# census every live process in the lane's tree with a full ps listing.
#
# Usage: census-fixture-processes.sh <label> <threshold>
# Writes: fm-serial1-<label>-census-at-<threshold>-tests.txt
set -u
label=${1:?label}
threshold=${2:?threshold}
ev=$(cd "$(dirname "$0")" && pwd)
out="$ev/fm-serial1-$label-census-at-$threshold-tests.txt"
log="$ev/fm-serial1-$label-run.log"

until [ "$(grep -c '^ok - ' "$log" 2>/dev/null || true)" -ge "$threshold" ]; do
  sleep 3
done

# Find this run's fixture tmp root: the marker's owner must be the live bash
# running the supervision-host suite (so unrelated fm-* dirs never match).
root='' suite_pid=''
for dir in /tmp/fm-supervision-host.*/; do
  [ -f "$dir/.fm-test-fixture" ] || continue
  mp=$(sed -n '1p' "$dir/.fm-test-fixture" 2>/dev/null) || continue
  kill -0 "$mp" 2>/dev/null || continue
  args=$(tr '\0' ' ' < "/proc/$mp/cmdline" 2>/dev/null) || continue
  case "$args" in *fm-supervision-host.test.sh*) root=${dir%/}; suite_pid=$mp; break ;; esac
done
[ -n "$suite_pid" ] || { echo "no live suite found" >"$out"; exit 1; }

# Walk up from the suite bash to the lane runner.
runner=$suite_pid
while :; do
  ppid=$(ps -o ppid= -p "$runner" 2>/dev/null | tr -d '[:space:]')
  [ -n "$ppid" ] && [ "$ppid" -gt 1 ] || break
  rargs=$(tr '\0' ' ' < "/proc/$ppid/cmdline" 2>/dev/null) || break
  runner=$ppid
  case "$rargs" in *fm-test-run.sh*) break ;; esac
done

# Descendant closure from the runner, same snapshot method as the sampler.
frontier="$runner" all=''
while :; do
  found=$(ps -eo pid=,ppid= | awk -v P=" $frontier " '
    BEGIN { n = split(P, a, " "); for (i = 1; i <= n; i++) if (a[i] != "") keep[a[i]] = 1 }
    ($2 in keep) { printf "%s ", $1 }')
  [ -n "$found" ] || break
  all="$all $found"
  frontier="$found"
done

{
  echo "census: arm=$label at >= $threshold tests passed"
  echo "ok_lines=$(grep -c '^ok - ' "$log")"
  echo "fixture_root=$root"
  echo "runner_pid=$runner total_tree_processes=$(( $(printf '%s' "$all" | wc -w) + 1 )) (runner included)"
  echo
  ps -ww -o pid=,ppid=,etimes=,args= -p "$(printf '%s' "$runner $all" | tr -s ' ' ',' | sed 's/^,//;s/,$//')" 2>/dev/null
} >"$out"
