#!/usr/bin/env bash
# Regression tests for fm-spawn's live-holder screen on Treehouse pool slots.
#
# Twice in one evening the pool handed a fresh spawn a slot a live task still
# held: a paused task's worker process had exited, so the pool's process lease
# lapsed even though the task's record stayed live, and the allocating spawn
# accepted the slot without cross-checking this home's own records - its claim
# step then replaced the previous holder's .fm-slot-owner claim, destroying the
# very evidence teardown's reassigned-slot guard relies on.
# These tests drive the real spawn path with a fake terminal and prove the
# allocation now refuses a slot a live task record or live claim still holds,
# preserves that evidence, and still reclaims a slot whose holder is really
# gone.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-slot-live-holder)

# make_case <name> <id> builds a home, a project, and a Treehouse pool slot at
# <case>/pool/1/repo whose treehouse-state.json makes fm_treehouse_pool_slot
# recognize it, so a spawn of <id> reaches the claim site.
make_case() {
  local name=$1 id=$2 case_dir home project slot fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  slot="$case_dir/pool/1/repo"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id" "Exercise pool slot live-holder refusal for $id."
  fm_git_worktree "$project" "$slot" "slot-$name"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$slot" \
    > "$case_dir/pool/treehouse-state.json"
  fm_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$case_dir|$home|$project|$slot|$fakebin"
}

read_case_record() {
  IFS='|' read -r _ HOME_DIR PROJECT_DIR SLOT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local id=$1
  fm_test_run_spawn "$HOME_DIR" "$SLOT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR" --scout
}

write_holder_claim() {  # <holder-id>
  printf 'task=%s\nhome=%s\n' "$1" "$HOME_DIR" \
    > "$(dirname "$SLOT_DIR")/.fm-slot-owner"
}

# The exact incident: the pool hands a fresh spawn a slot whose claim and task
# record both still name a live holder. The spawn must refuse, name the holder,
# and leave the holder's claim untouched for teardown's guard.
test_slot_held_by_live_claim_and_meta_is_refused() {
  local id=slot-holder-refused-z1 holder=whitelist-holder out status
  holder="holder-$id"
  id="spawn-$id"
  rec=$(make_case live-holder "$id")
  read_case_record "$rec"
  fm_write_meta "$HOME_DIR/state/$holder.meta" \
    "endpoint_task_id=$holder" "worktree=$SLOT_DIR" \
    "project=$PROJECT_DIR" "kind=scout"
  write_holder_claim "$holder"

  set +e
  out=$(run_spawn "$id")
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "spawn accepted a pool slot a live task still holds"$'\n'"$out"
  assert_contains "$out" "still holds that worktree" \
    "the refusal did not say a live record holds the worktree"
  assert_contains "$out" "$holder" \
    "the refusal did not name the live holder task"
  assert_contains "$out" "$SLOT_DIR" \
    "the refusal did not name the contested pool slot"
  assert_contains "$(cat "$(dirname "$SLOT_DIR")/.fm-slot-owner")" "task=$holder" \
    "the refused spawn overwrote the live holder's slot claim"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a slot held by a live claim and record is refused with its evidence preserved"
}

# A lost or never-written claim must not defeat the screen: the task record
# alone proves the slot is still held.
test_slot_held_by_live_meta_alone_is_refused() {
  local id=slot-meta-holder-z2 holder out status
  holder="holder-$id"
  id="spawn-$id"
  rec=$(make_case live-meta "$id")
  read_case_record "$rec"
  fm_write_meta "$HOME_DIR/state/$holder.meta" \
    "endpoint_task_id=$holder" "worktree=$SLOT_DIR" \
    "project=$PROJECT_DIR" "kind=scout"

  set +e
  out=$(run_spawn "$id")
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "spawn accepted a pool slot a live task record still holds"$'\n'"$out"
  assert_contains "$out" "$holder" \
    "the refusal did not name the live holder task"
  [ ! -e "$(dirname "$SLOT_DIR")/.fm-slot-owner" ] \
    || fail "the refused spawn claimed the slot while refusing it"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a slot held by a live record alone is refused even with no claim file"
}

# A claim naming a task whose record is already gone is a stale claim from a
# cleaned-up task: the spawn must reclaim the slot for the new task, exactly as
# before the screen existed.
test_stale_claim_for_a_gone_holder_is_replaced() {
  local id=slot-stale-claim-z3 out status
  id="spawn-$id"
  rec=$(make_case stale-claim "$id")
  read_case_record "$rec"
  write_holder_claim "torn-down-holder"

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should reclaim a slot whose holder record is gone"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_contains "$(cat "$(dirname "$SLOT_DIR")/.fm-slot-owner")" "task=$id" \
    "the spawn did not replace the stale claim with its own"
  assert_grep "worktree=$SLOT_DIR" "$HOME_DIR/state/$id.meta" \
    "the reclaiming spawn did not record the slot as its worktree"
  pass "a stale claim naming a gone holder is replaced by the new task's claim"
}

# A free slot with no prior records keeps its ordinary path: claim written,
# worker launched, worktree recorded.
test_free_slot_claims_and_launches() {
  local id=slot-free-z4 out status
  id="spawn-$id"
  rec=$(make_case free-slot "$id")
  read_case_record "$rec"

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed on a free pool slot"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_contains "$(cat "$(dirname "$SLOT_DIR")/.fm-slot-owner")" "task=$id" \
    "the spawn did not claim the free slot"
  assert_grep "worktree=$SLOT_DIR" "$HOME_DIR/state/$id.meta" \
    "the spawn did not record the slot as its worktree"
  pass "a free pool slot is claimed and launched as before"
}

test_slot_held_by_live_claim_and_meta_is_refused
test_slot_held_by_live_meta_alone_is_refused
test_stale_claim_for_a_gone_holder_is_replaced
test_free_slot_claims_and_launches

echo "# all fm-spawn-slot-live-holder tests passed"
