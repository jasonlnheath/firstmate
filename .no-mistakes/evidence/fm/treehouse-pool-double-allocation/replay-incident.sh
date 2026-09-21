#!/usr/bin/env bash
# Manual replay of the 2026-09 pool double-allocation incident against the real
# bin/fm-spawn.sh CLI, using the repo's own fixture builders for the isolated
# world (fake tmux pane + no-op treehouse, throwaway FM_HOME under /tmp).
#
# Phase 1 - the exact incident: pool slot <pool>/1/relmgr is still recorded to
#           live task whitelist-list-identity (meta worktree= + .fm-slot-owner
#           claim) whose worker process exited, so the pool re-hands the slot;
#           a fresh spawn of whitelist-verb-sweep must refuse it.
# Phase 2 - same shape but the holder's claim file was lost: the record alone
#           must still refuse the slot.
# Phase 3 - reconcile: the holder's record is removed (what fm-teardown does);
#           the same spawn must now claim the slot and launch.
set -u

REPO=/home/jason/.no-mistakes/worktrees/5a4bc58bcad7/01M3295M350XHQHZQH8Y1T722D
. "$REPO/tests/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-incident-replay)

# build <case-name> <spawn-id>: home + project + pool slot 1 + fake toolchain.
build() {
  local name=$1 id=$2
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJECT_DIR="$CASE_DIR/project"
  SLOT_DIR="$CASE_DIR/pool/1/relmgr"
  FAKEBIN_DIR=$(make_spawn_fakebin "$CASE_DIR/fake")
  fm_test_spawn_home "$HOME_DIR" codex
  fm_test_spawn_brief "$HOME_DIR" "$id" "Sweep whitelist verbs."
  fm_git_worktree "$PROJECT_DIR" "$SLOT_DIR" "slot-$name"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$SLOT_DIR" \
    > "$CASE_DIR/pool/treehouse-state.json"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
}

run_spawn() {  # <id>
  fm_test_run_spawn "$HOME_DIR" "$SLOT_DIR" "$FAKEBIN_DIR" \
    "$1" "$PROJECT_DIR" --scout
}

hdr() { printf '\n===== %s =====\n' "$*"; }

# --- Phase 1: the exact incident --------------------------------------------
hdr "PHASE 1: fresh spawn is handed a pool slot a live task still holds"
build live-holder whitelist-verb-sweep
P1_HOME=$HOME_DIR P1_PROJECT=$PROJECT_DIR P1_SLOT=$SLOT_DIR P1_FAKEBIN=$FAKEBIN_DIR
HOLDER=whitelist-list-identity
fm_write_meta "$HOME_DIR/state/$HOLDER.meta" \
  "endpoint_task_id=$HOLDER" "worktree=$SLOT_DIR" \
  "project=$PROJECT_DIR" "kind=scout"
printf 'task=%s\nhome=%s\n' "$HOLDER" "$HOME_DIR" > "$(dirname "$SLOT_DIR")/.fm-slot-owner"
echo "pre-spawn state:"
echo "  holder record : $HOME_DIR/state/$HOLDER.meta"
sed 's/^/    /' "$HOME_DIR/state/$HOLDER.meta"
echo "  slot claim    : $(dirname "$SLOT_DIR")/.fm-slot-owner"
sed 's/^/    /' "$(dirname "$SLOT_DIR")/.fm-slot-owner"
echo
echo "\$ fm-spawn.sh whitelist-verb-sweep <project> --scout   (pool hands out slot 1)"
set +e
OUT=$(run_spawn whitelist-verb-sweep)
STATUS=$?
set -e
printf '%s\n' "$OUT"
echo "exit status: $STATUS"
echo "post-spawn state:"
[ ! -e "$HOME_DIR/state/whitelist-verb-sweep.meta" ] \
  && echo "  no metadata published for the refused spawn: yes" \
  || echo "  no metadata published for the refused spawn: NO (BUG)"
echo "  holder claim preserved:"
sed 's/^/    /' "$(dirname "$SLOT_DIR")/.fm-slot-owner"

# --- Phase 2: record alone (claim lost) --------------------------------------
hdr "PHASE 2: same incident with the holder's claim file lost (record alone)"
build lost-claim whitelist-verb-pairing
HOLDER2=whitelist-logo-concepts
fm_write_meta "$HOME_DIR/state/$HOLDER2.meta" \
  "endpoint_task_id=$HOLDER2" "worktree=$SLOT_DIR" \
  "project=$PROJECT_DIR" "kind=scout"
echo "holder record exists, no .fm-slot-owner claim file on the slot"
echo
echo "\$ fm-spawn.sh whitelist-verb-pairing <project> --scout"
set +e
OUT=$(run_spawn whitelist-verb-pairing)
STATUS=$?
set -e
printf '%s\n' "$OUT"
echo "exit status: $STATUS"

# --- Phase 3: reconcile then respawn -----------------------------------------
hdr "PHASE 3: holder record removed (teardown), same spawn now succeeds"
rm -f "$P1_HOME/state/$HOLDER.meta"
HOME_DIR=$P1_HOME PROJECT_DIR=$P1_PROJECT SLOT_DIR=$P1_SLOT FAKEBIN_DIR=$P1_FAKEBIN
echo "\$ fm-spawn.sh whitelist-verb-sweep <project> --scout   (again)"
set +e
OUT=$(run_spawn whitelist-verb-sweep)
STATUS=$?
set -e
printf '%s\n' "$OUT"
echo "exit status: $STATUS"
echo "post-spawn state:"
echo "  slot claim now:"
sed 's/^/    /' "$(dirname "$SLOT_DIR")/.fm-slot-owner"
echo "  spawned task records worktree:"
grep '^worktree=' "$HOME_DIR/state/whitelist-verb-sweep.meta" | sed 's/^/    /'
