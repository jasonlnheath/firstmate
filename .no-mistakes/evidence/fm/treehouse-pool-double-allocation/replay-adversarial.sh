#!/usr/bin/env bash
# Adversarial boundary drives for the pool-slot live-holder screen, against the
# real bin/fm-spawn.sh CLI.
#
# A - cross-home claim: the slot's .fm-slot-owner names a task of ANOTHER home
#     (whose records this home cannot read). Documented behavior: the screen
#     cannot prove the holder live, so allocation keeps the pre-screen path
#     (claim replacement) instead of wedging. Expect: spawn proceeds, exit 0.
# B - aliased holder record: a task record of THIS home names a symlinked alias
#     of the slot directory, not the literal path the pool handed out. The
#     screen compares realpaths, so this must still refuse. Expect: exit 1.
set -u

REPO=/home/jason/.no-mistakes/worktrees/5a4bc58bcad7/01M3295M350XHQHZQH8Y1T722D
. "$REPO/tests/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-adversarial-replay)

build() {
  local name=$1 id=$2
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJECT_DIR="$CASE_DIR/project"
  SLOT_DIR="$CASE_DIR/pool/1/relmgr"
  FAKEBIN_DIR=$(make_spawn_fakebin "$CASE_DIR/fake")
  fm_test_spawn_home "$HOME_DIR" codex
  fm_test_spawn_brief "$HOME_DIR" "$id" "Adversarial boundary drive."
  fm_git_worktree "$PROJECT_DIR" "$SLOT_DIR" "slot-$name"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$SLOT_DIR" \
    > "$CASE_DIR/pool/treehouse-state.json"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
}

run_spawn() {
  fm_test_run_spawn "$HOME_DIR" "$SLOT_DIR" "$FAKEBIN_DIR" \
    "$1" "$PROJECT_DIR" --scout
}

hdr() { printf '\n===== %s =====\n' "$*"; }

# --- A: cross-home claim must not wedge allocation ---------------------------
hdr "A: slot claimed by a task of another home - spawn must not wedge"
build cross-home cross-home-spawn
OTHER_HOME="$TMP_ROOT/cross-home/other-home"
mkdir -p "$OTHER_HOME/state"
printf 'task=other-home-task\nhome=%s\n' "$OTHER_HOME" \
  > "$(dirname "$SLOT_DIR")/.fm-slot-owner"
echo "slot claim names task of another home (record unreadable from here):"
sed 's/^/  /' "$(dirname "$SLOT_DIR")/.fm-slot-owner"
echo
echo "\$ fm-spawn.sh cross-home-spawn <project> --scout"
set +e
OUT=$(run_spawn cross-home-spawn)
STATUS=$?
set -e
printf '%s\n' "$OUT"
echo "exit status: $STATUS (expected 0: no wedge; claim replaced per pre-screen behavior)"
echo "slot claim now:"
sed 's/^/  /' "$(dirname "$SLOT_DIR")/.fm-slot-owner"

# --- B: aliased holder record must still refuse ------------------------------
hdr "B: holder record names a symlinked alias of the same slot - must refuse"
build alias alias-spawn
mkdir -p "$TMP_ROOT/alias/alias-root"
ln -s "$TMP_ROOT/alias/pool" "$TMP_ROOT/alias/alias-root/pool-alias"
HOLDER=alias-holder
ALIASED_SLOT="$TMP_ROOT/alias/alias-root/pool-alias/1/relmgr"
fm_write_meta "$HOME_DIR/state/$HOLDER.meta" \
  "endpoint_task_id=$HOLDER" "worktree=$ALIASED_SLOT" \
  "project=$PROJECT_DIR" "kind=scout"
echo "holder record worktree= (a symlink alias, not the literal slot path):"
grep '^worktree=' "$HOME_DIR/state/$HOLDER.meta" | sed 's/^/  /'
readlink "$TMP_ROOT/alias/alias-root/pool-alias" | sed 's/^/  alias -> /'
echo
echo "\$ fm-spawn.sh alias-spawn <project> --scout   (pool hands the real path)"
set +e
OUT=$(run_spawn alias-spawn)
STATUS=$?
set -e
printf '%s\n' "$OUT"
echo "exit status: $STATUS (expected 1: realpath match proves the live holder)"
