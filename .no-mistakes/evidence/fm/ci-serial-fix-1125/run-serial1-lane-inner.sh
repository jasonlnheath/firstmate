#!/usr/bin/env bash
# Inner script for the transient systemd user unit: runs the exact CI command
# for job "Behavior portable serial 1" and records its exit status.
# A clean process ancestry matters: this suite includes a test that emulates a
# Windows-tagged session lock, and its ownership check must find no harness
# process in the host's ancestry so the Windows ps -W bridge is consulted - the
# same shape a hosted CI runner has. Launching from inside a Claude Code session
# puts the real `claude` process in the ancestry and fails that one test
# (verified directly in fm-serial1-tagged-ownership-repro.txt).
set -u
wd=${1:?worktree} ev=${2:?evidence-dir} label=${3:?label}
rcfile="$ev/fm-serial1-$label.rc"
rc=125
trap 'echo "$rc" > "$rcfile"' EXIT
cd "$wd" || exit 0
bin/fm-test-run.sh --lane portable-serial-1of10 \
  --fail-on-gate-skip 'Pi extension typecheck prerequisite not found' \
  --json "$ev/fm-serial1-$label-timing.json" >"$ev/fm-serial1-$label-run.log" 2>&1
rc=$?
