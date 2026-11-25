#!/usr/bin/env bash
# tests/fm-afk-telegram.test.sh - the away posture carrying Telegram as its
# reach channel (the Telegram channel plan's S2). The entry announcement and
# read-back name the channel the record carries, and a captain note that
# arrives while away is answered through the inbox reply surface, whose
# receipt hook delivers exactly one answer line to the captain's Telegram.
# The engine is always the fake hermes and the target is always a fixture id,
# so no test ever reaches a live Telegram conversation.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-afk-telegram)
CONTRACT="$ROOT/bin/fm-afk-contract.sh"
INBOX_BIN="$ROOT/bin/fm-inbox.sh"
LAUNCH="$ROOT/bin/fm-afk-launch.sh"
FAKE_TARGET="telegram:424242"
REACH_TELEGRAM="Telegram is this away window's channel: your messages there get a prompt answer, and only decisions, review-ready work or PRs, real failures, finished requested work, and auto merges reach you."

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
fm_test_fake_hermes "$FAKEBIN"

make_home() {  # <name> [with-lane]
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  if [ "${2:-}" = with-lane ]; then
    printf '%s\n' "$FAKE_TARGET" > "$home/config/tg-target"
  fi
  printf '%s\n' "$home"
}

contract_field() {  # <home> <field>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" "$CONTRACT" field "$2"
}

enter_away() {  # <home> [enter-args...]
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    "$LAUNCH" enter "$@"
}

run_inbox() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" PATH="$FAKEBIN:$PATH" "$INBOX_BIN" "$@"
}

reset_hermes() { rm -f "$FAKEBIN/hermes.log" "$FAKEBIN/hermes.exit"; }

hermes_calls() {
  if [ -f "$FAKEBIN/hermes.log" ]; then
    grep -c '^CALL ' "$FAKEBIN/hermes.log" || true
  else
    printf '0\n'
  fi
}

hermes_bodies() {
  if [ -f "$FAKEBIN/hermes.log" ]; then
    sed -n 's/^BODY //p' "$FAKEBIN/hermes.log"
  else
    true
  fi
}

note_id_from_json() {  # <json>
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'
}

# The /afk entry path itself announces the reach profile the record carries:
# Telegram while the outbound lane is configured, never hold-for-return-only.
test_away_entry_with_the_lane_announces_telegram_as_the_reach_channel() {
  local home out
  home=$(make_home announce-lane with-lane)
  out=$(enter_away "$home" 2>&1) || fail "away entry with the lane configured failed: $out"
  [ "$(contract_field "$home" reach_channels)" = telegram ] \
    || fail "the away record did not carry the telegram reach channel"
  assert_contains "$out" "$REACH_TELEGRAM" "the entry announcement did not name Telegram as the away channel"
  assert_not_contains "$out" 'hold-for-return only' "a telegram away window was announced as hold-for-return only"
  assert_not_contains "$out" 'No phone channel is configured' "a telegram away window was announced as channel-less"
  assert_contains "$out" "  reach: $REACH_TELEGRAM" "the read-back did not render the telegram reach line"
  pass "an away entry with the outbound lane announces Telegram as the reach channel"
}

# Plan test 6: a reach_channels: telegram record with no words; a note filed
# from the lane; a stub away session answers it through the inbox reply
# surface, and the receipt hook delivers exactly one answer line while the
# reply record becomes the durable answer.
test_an_away_note_is_answered_with_one_pushed_line() {
  local home out id
  reset_hermes
  home=$(make_home answer-note with-lane)
  enter_away "$home" >/dev/null 2>&1 || fail "away entry failed"
  [ -z "$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$CONTRACT" words)" ] \
    || fail "fixture: the away record should carry no words"
  out=$(printf 'status of the windows fix?\n' | run_inbox "$home" note --source tg --json -) \
    || fail "filing a captain note from the lane failed: $out"
  id=$(note_id_from_json "$out")
  assert_grep "check: captain inbox note $id" "$home/state/.wake-queue" "the note did not announce its wake row"
  out=$(FM_SUPERVISION_ACTOR=branch run_inbox "$home" reply "$id" 'the fix is green; its PR is up for review') \
    || fail "answering the note through the inbox reply surface failed: $out"
  assert_present "$home/state/inbox/.replies/$id" "the reply record was not written"
  assert_present "$home/state/inbox/$id.note" "an answered note stays pending for the drain's visibility belt"
  [ "$(hermes_calls)" = 1 ] || fail "the answer pushed $(hermes_calls) lines, not exactly one"
  assert_equals 'fm: the fix is green; its PR is up for review' "$(hermes_bodies)" "the pushed answer line is wrong"
  pass "an away note is answered in one act: the reply record plus exactly one pushed Telegram line"
}

# Plan test 6, the hold arm: a note the away session must not act on is held
# for the return, and the pushed line opens with the held-for-return wording.
test_a_note_the_away_session_cannot_act_on_is_held_for_return() {
  local home out id
  reset_hermes
  home=$(make_home hold-note with-lane)
  enter_away "$home" >/dev/null 2>&1 || fail "away entry failed"
  out=$(printf 'discard task-x and its unlanded work\n' | run_inbox "$home" note --source tg --json -) \
    || fail "filing the hold-note failed: $out"
  id=$(note_id_from_json "$out")
  out=$(FM_SUPERVISION_ACTOR=branch run_inbox "$home" reply "$id" 'held for your return - a discard is never-set, so it waits for you') \
    || fail "holding the note failed: $out"
  [ "$(hermes_calls)" = 1 ] || fail "the hold pushed $(hermes_calls) lines, not exactly one"
  assert_equals 'fm: held for your return - a discard is never-set, so it waits for you' "$(hermes_bodies)" \
    "the held line lost its held-for-return wording"
  pass "a note the away session cannot act on is held with the held-for-return reply line"
}

# The lane is a local fact, never a repo default: without config/tg-target the
# away answer still records the reply, the push fails closed into the lane's
# journal, and the engine is never invoked.
test_an_away_answer_without_the_lane_still_records_the_reply() {
  local home out id
  reset_hermes
  home=$(make_home answer-no-lane)
  enter_away "$home" >/dev/null 2>&1 || fail "away entry failed"
  [ "$(contract_field "$home" reach_channels)" = none ] \
    || fail "fixture: the away record should carry no reach channel"
  out=$(printf 'what is task-y doing?\n' | run_inbox "$home" note --source tg --json -) \
    || fail "filing the lane-less note failed: $out"
  id=$(note_id_from_json "$out")
  out=$(FM_SUPERVISION_ACTOR=branch run_inbox "$home" reply "$id" 'task-y is still building; nothing new') \
    || fail "answering without the lane failed: $out"
  assert_present "$home/state/inbox/.replies/$id" "the reply record was not written without the lane"
  assert_present "$home/state/tg/journal.jsonl" "the failed push was not journaled for retry"
  [ "$(hermes_calls)" = 0 ] || fail "the engine was invoked without a configured lane"
  pass "an away answer without the lane records the reply, fails closed into the journal, and sends nothing"
}

test_away_entry_with_the_lane_announces_telegram_as_the_reach_channel
test_an_away_note_is_answered_with_one_pushed_line
test_a_note_the_away_session_cannot_act_on_is_held_for_return
test_an_away_answer_without_the_lane_still_records_the_reply
