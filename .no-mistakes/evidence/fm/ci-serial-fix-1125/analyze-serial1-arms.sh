#!/usr/bin/env bash
# Post-run comparison of the two evidence arms (target = fix, base = before).
# Reads fm-serial1-{target,base}-{processes.csv,summary.txt,run.log} and the
# census files, and writes fm-serial1-arms-comparison.md into this directory.
set -u
ev=$(cd "$(dirname "$0")" && pwd)
out="$ev/fm-serial1-arms-comparison.md"

at_count() {  # <csv> <ok-count> -> median descendants among samples at that ok count
  awk -F, -v n="$2" '$2 == n { vals[++i] = $3 }
    END {
      if (i == 0) { print "-"; exit }
      # median
      for (a = 1; a <= i; a++) for (b = a + 1; b <= i; b++)
        if (vals[b] < vals[a]) { t = vals[a]; vals[a] = vals[b]; vals[b] = t }
      print (i % 2) ? vals[(i + 1) / 2] : (vals[i / 2] + vals[i / 2 + 1]) / 2
    }' "$1" 2>/dev/null
}

sum_field() {  # <summary> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

time_to() {  # <csv> <ok-count> -> minutes from first sample to reach that count
  awk -F, -v n="$2" '
    NR == 1 { first = $1 }
    $2 >= n { printf "%.1f", ($1 - first) / 60; exit }
    END { if (first == "") print "-" }' "$1" 2>/dev/null
}

tgt_csv="$ev/fm-serial1-target-processes.csv"
base_csv="$ev/fm-serial1-base-processes.csv"
tgt_sum="$ev/fm-serial1-target-summary.txt"
base_sum="$ev/fm-serial1-base-summary.txt"
tgt_log="$ev/fm-serial1-target-run.log"
base_log="$ev/fm-serial1-base-run.log"

{
  echo "# CI job \"Behavior portable serial 1\" (tests/fm-supervision-host.test.sh): before/after the per-test fixture sweep"
  echo
  echo "Arm \`base\` is the target commit's tree with exactly one file reverted:"
  echo "tests/fm-supervision-host.test.sh at base commit 71b1c749 (the 20-line fix"
  echo "removed); arm \`target\` is the change under test (64d8acf7). Both arms ran"
  echo "the exact CI command for the job, \`bin/fm-test-run.sh --lane"
  echo "portable-serial-1of10\`, sampled every 2 s for the size of the lane's live"
  echo "process tree. Host: local 32-core machine, so durations are indicative only;"
  echo "the CI-runner wall-clock claim stays with hosted CI."
  echo
  echo "## Run results"
  echo
  echo "| arm | runner exit | ok tests | not-ok | duration | max tree | median tree |"
  echo "|---|---|---:|---:|---:|---:|---:|"
  for arm in target base; do
    s="$ev/fm-serial1-$arm-summary.txt"
    [ -f "$s" ] || continue
    printf '| %s | %s | %s | %s | %ss | %s | %s |\n' "$arm" \
      "$(sum_field "$s" runner_exit)" "$(sum_field "$s" ok_lines)" \
      "$(sum_field "$s" not_ok_lines)" "$(sum_field "$s" duration_seconds)" \
      "$(sum_field "$s" max_descendants)" "$(sum_field "$s" median_descendants)"
  done
  echo
  echo "## Live process-tree size while the suite runs, by tests completed"
  echo
  echo "Median sample of the lane's live process-tree size (runner + script +"
  echo "fixtures) at each checkpoint of tests completed:"
  echo
  echo "| tests completed | target (fix) | base (before) |"
  echo "|---:|---:|---:|"
  for n in 1 8 16 24 32 42 54 62 74 80 84 88; do
    t=$(at_count "$tgt_csv" "$n"); b=$(at_count "$base_csv" "$n")
    [ "$t" = "-" ] && [ "$b" = "-" ] && continue
    printf '| %s | %s | %s |\n' "$n" "${t:--}" "${b:--}"
  done
  echo
  echo "## Minutes of wall clock to reach each checkpoint"
  echo
  echo "From each arm's 2 s samples: elapsed time from its first sample to the"
  echo "first sample at which that many tests had passed."
  echo
  echo "| tests completed | target (fix) | base (before) |"
  echo "|---:|---:|---:|"
  for n in 8 16 24 32 42 54 62 74 80 88; do
    t=$(time_to "$tgt_csv" "$n"); b=$(time_to "$base_csv" "$n")
    [ "$t" = "-" ] && [ "$b" = "-" ] && continue
    printf '| %s | %s | %s |\n' "$n" "${t:--}" "${b:--}"
  done
  echo
  echo "## Census excerpts"
  echo
  for arm in target base; do
    for n in 44 80; do
      f="$ev/fm-serial1-$arm-census-at-$n-tests.txt"
      [ -f "$f" ] || continue
        echo "### arm $arm, at >= $n tests passed"
        echo
        echo '```'
        cat "$f"
        echo '```'
        echo
    done
  done
} >"$out"
echo "wrote $out"
