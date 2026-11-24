#!/usr/bin/env bash
# tests/fm-telegram-note.test.sh - the Telegram note submit helper and receipts.
#
# Covers the S1 inbound contract: the helper's stdin/file-only body (quoting
# can never break it), its single-purpose exit codes (filing status passes
# through; a failing receipt push cannot change them), the request-id
# replay that makes a same-day retry idempotent and a next-day re-send fresh,
# the note receipts (accepted, picked up, answered) pushed through the
# outbound lane for source=tg notes, the full note lifecycle sending only the
# three catalog receipts and never looping a new note, the opt-in boundary
# (non-tg notes never reach the lane), and the lane-off fail-closed posture
# that never loses a note. No test sends anything: the engine is always the
# fake hermes and the target is always a fixture id.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-telegram-note)
INBOX_BIN="$ROOT/bin/fm-inbox.sh"
NOTE_BIN="$ROOT/bin/fm-telegram-note.sh"
TG_BIN="$ROOT/bin/fm-tg.sh"
FAKE_TARGET="telegram:424242"

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
fm_test_fake_hermes "$FAKEBIN"

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

make_clock() {
  local clock="$TMP_ROOT/$1.clock"
  printf '1700000000.000\n' > "$clock"
  printf '%s\n' "$clock"
}

set_target() {  # <home>
  printf '%s\n' "$FAKE_TARGET" > "$1/config/tg-target"
}

reset_hermes() { rm -f "$FAKEBIN/hermes.log" "$FAKEBIN/hermes.exit"; }

fake_hermes_exit() { printf '%s\n' "$1" > "$FAKEBIN/hermes.exit"; }

hermes_calls() {
  if [ -f "$FAKEBIN/hermes.log" ]; then
    grep -c '^CALL ' "$FAKEBIN/hermes.log" || true
  else
    printf '0\n'
  fi
}

hermes_bodies() {  # every sent line, in order
  [ -f "$FAKEBIN/hermes.log" ] && sed -n 's/^BODY //p' "$FAKEBIN/hermes.log" || true
}

json_get() {
  python3 -c 'import json,sys
v=json.load(sys.stdin)
for k in sys.argv[1:]:
    if isinstance(v, list) and k.lstrip("-").isdigit():
        v=v[int(k)]
    else:
        v=v[k]
print(v)' "$@"
}

count_notes() {  # <home> -> pending plus handled notes
  find "$1/state/inbox" -name '*.note' 2>/dev/null | wc -l | tr -d ' '
}

count_wakes() {
  if [ -f "$1/state/.wake-queue" ]; then
    grep -c 'inbox:' "$1/state/.wake-queue" || true
  else
    printf '0\n'
  fi
}

# run_note <home> [file]; stdin passes through when no file is given.
# NOTE_STATE overrides the state directory for failure injection.
run_note() {
  local home=$1 file=${2:-}
  if [ -n "$file" ]; then
    FM_HOME="$home" FM_STATE_OVERRIDE="${NOTE_STATE:-$home/state}" \
      FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
      FM_TG_TEST_CLOCK="${TG_CLOCK:-}" PATH="$FAKEBIN:$PATH" \
      "$NOTE_BIN" "$file"
  else
    FM_HOME="$home" FM_STATE_OVERRIDE="${NOTE_STATE:-$home/state}" \
      FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
      FM_TG_TEST_CLOCK="${TG_CLOCK:-}" PATH="$FAKEBIN:$PATH" \
      "$NOTE_BIN"
  fi
}

run_inbox() {
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_TG_TEST_CLOCK="${TG_CLOCK:-}" \
    PATH="$FAKEBIN:$PATH" "$INBOX_BIN" "$@"
}

run_tg() {
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_TG_TEST_CLOCK="${TG_CLOCK:-}" PATH="$FAKEBIN:$PATH" "$TG_BIN" "$@"
}

journal_file() { printf '%s/state/tg/journal.jsonl\n' "$1"; }

journal_lines() {
  if [ -r "$(journal_file "$1")" ]; then
    wc -l < "$(journal_file "$1")" | tr -d ' '
  else
    printf '0\n'
  fi
}

journal_field() {  # <home> <key> <row-index> <field>
  python3 - "$(journal_file "$1")" "$2" "$3" "$4" <<'PY'
import json, sys
path, key, index, field = sys.argv[1:5]
rows = []
for line in open(path, encoding="utf-8"):
    line = line.strip()
    if line:
        row = json.loads(line)
        if row.get("key") == key:
            rows.append(row)
print(rows[int(index)][field])
PY
}

# --- quoting: the body is never argv, and arrives byte-identical -------------

reset_hermes
home=$(make_home quoting)
set_target "$home"
TG_CLOCK=$(make_clock quoting)
body=$'line one with \'quotes\' "doubles" \\backslash\\ and $dollar `ticks`\nline two\n'
out=$(printf '%s' "$body" | run_note "$home") || fail "the helper should file the note"
first_id=$(printf '%s' "$out" | json_get id)
assert_equals "created" "$(printf '%s' "$out" | json_get outcome)" "the note is created"
assert_equals "True" "$(printf '%s' "$out" | json_get announced)" "the note is announced"
stored=$(run_inbox "$home" receipts --all-pending | json_get pending 0 body)
assert_equals "${body%$'\n'}" "$stored" "the note body is byte-identical after quoting hazards"
assert_equals "1" "$(count_wakes "$home")" "one wake for the filed note"
assert_equals "1" "$(hermes_calls)" "one receipt push for the filing"
assert_equals "fm: got it - note $first_id" "$(hermes_bodies)" \
  "the accepted receipt line is the catalog wording"
# The same body through a file argument, argv carrying only the path.
reset_hermes
file_home=$(make_home quoting-file)
set_target "$file_home"
note_file="$TMP_ROOT/quoting-note.txt"
printf '%s' "$body" > "$note_file"
out=$(run_note "$file_home" "$note_file") || fail "the helper should file from a file"
file_id=$(printf '%s' "$out" | json_get id)
stored=$(run_inbox "$file_home" receipts --all-pending | json_get pending 0 body)
assert_equals "${body%$'\n'}" "$stored" "the file-arg body is byte-identical too"
assert_equals "1" "$(hermes_calls)" "one receipt push for the file filing"
assert_equals "fm: got it - note $file_id" "$(hermes_bodies)" \
  "the file filing pushes the same catalog line"
pass "quoting: stdin and file bodies arrive byte-identical, never argv"

# --- single purpose: filing status is the exit status ------------------------

# A filing failure (nothing saved) is exit 1 with no JSON success on stdout.
home=$(make_home filing-fail)
blocker="$TMP_ROOT/state-blocker"
printf 'not a directory\n' > "$blocker"
NOTE_STATE="$blocker"
stdout_file="$TMP_ROOT/filing-stdout.txt"
set +e
printf 'words that cannot be filed\n' | run_note "$home" > "$stdout_file" 2>/dev/null
rc=$?
set -e
expect_code 1 "$rc" "a filing failure exits 1, nothing saved"
assert_equals "0" "$(wc -c < "$stdout_file" | tr -d ' ')" \
  "a filing failure prints no success-shaped line on stdout"
pass "filing failure: exit 1, no success line"
NOTE_STATE=""

# A saved-but-unannounced note is exit 3 with the JSON still printed. The
# helper runs from a copied bin/ without the wake lib, so announcement fails
# exactly the way a broken sibling checkout would.
isolated="$TMP_ROOT/isolated-bin"
reset_hermes
mkdir -p "$isolated/bin"
cp "$INBOX_BIN" "$isolated/bin/fm-inbox.sh"
cp "$NOTE_BIN" "$isolated/bin/fm-telegram-note.sh"
chmod +x "$isolated/bin/fm-inbox.sh" "$isolated/bin/fm-telegram-note.sh"
home=$(make_home unannounced)
set_target "$home"
set +e
out=$(printf 'saved but not announced\n' \
  | FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_TG_TEST_CLOCK="${TG_CLOCK:-}" \
    PATH="$FAKEBIN:$PATH" "$isolated/bin/fm-telegram-note.sh")
rc=$?
set -e
expect_code 3 "$rc" "saved-but-unannounced passes through as exit 3"
assert_contains "$out" '"announced":false' "the JSON reports the unannounced state"
assert_equals "1" "$(count_notes "$home")" "the note is saved despite the wake failure"
assert_equals "0" "$(hermes_calls)" "no receipt is pushed for an unannounced note"
pass "saved-unannounced: exit 3, no receipt push"

# --- request-id replay: same-day retry is a replay, next day is fresh ---------

reset_hermes
home=$(make_home replay)
set_target "$home"
TG_CLOCK=$(make_clock replay)
body='the same words from telegram'
first=$(printf '%s\n' "$body" | run_note "$home") || fail "first submission should succeed"
first_id=$(printf '%s' "$first" | json_get id)
assert_equals "created" "$(printf '%s' "$first" | json_get outcome)" "first is created"
sleep 1.1
second=$(printf '%s\n' "$body" | run_note "$home") || fail "a same-day retry should succeed"
assert_equals "replay" "$(printf '%s' "$second" | json_get outcome)" \
  "a same-day retry of the same body is a replay"
assert_equals "$first_id" "$(printf '%s' "$second" | json_get id)" \
  "the replay returns the original note id"
assert_equals "1" "$(count_notes "$home")" "the same body files one note per day"
assert_equals "1" "$(count_wakes "$home")" "the replay appends no second wake"
assert_equals "1" "$(hermes_calls)" "the replay's receipt push is an already-sent no-op"
assert_equals "1" "$(journal_lines "$home")" "the replay journals no second accepted row"
printf '1700086400.000\n' > "$TG_CLOCK"
third=$(printf '%s\n' "$body" | run_note "$home") || fail "a next-day re-send should succeed"
third_id=$(printf '%s' "$third" | json_get id)
assert_equals "created" "$(printf '%s' "$third" | json_get outcome)" "next day files fresh"
[ "$third_id" != "$first_id" ] || fail "the next-day note is a different note"
assert_equals "2" "$(count_notes "$home")" "the next-day re-send files a second note"
assert_equals "2" "$(count_wakes "$home")" "the second note appends its own wake"
assert_equals "2" "$(hermes_calls)" "the second note pushes a second accepted line"
pass "request-id replay: same-day idempotent, next-day fresh"

# --- a failing receipt push never loses the note ------------------------------

reset_hermes
home=$(make_home push-fail)
set_target "$home"
TG_CLOCK=$(make_clock push-fail)
fake_hermes_exit 1
out=$(printf 'answer me\n' | run_note "$home") \
  || fail "the helper exits with the filing status even when the push fails"
assert_equals "True" "$(printf '%s' "$out" | json_get saved)" "the note is saved"
assert_equals "1" "$(count_notes "$home")" "exactly one note is filed"
push_id=$(printf '%s' "$out" | json_get id)
assert_equals "1" "$(journal_lines "$home")" "the failed push is journaled"
assert_equals "1" "$(journal_field "$home" "note.$push_id.accepted" 0 rc)" \
  "the journal row records the failed receipt"
fake_hermes_exit 0
printf '1700000061.000\n' > "$TG_CLOCK"
out=$(run_tg "$home" retry) || fail "the drain's retry delivers the receipt"
assert_equals "2" "$(hermes_calls)" "the retry re-sends the receipt exactly once"
assert_equals "0" "$(journal_field "$home" "note.$push_id.accepted" 1 rc)" \
  "the retry row records the delivery"
assert_equals "fm: got it - note $push_id" "$(sed -n '$s/^BODY //p' "$FAKEBIN/hermes.log")" \
  "the delivered line is the accepted receipt"
run_tg "$home" retry >/dev/null || fail "an idle retry should exit 0"
assert_equals "2" "$(hermes_calls)" "the delivered receipt is never re-sent"
pass "a failing receipt push never loses the note"

# --- the full lifecycle sends only the catalog receipts -----------------------

reset_hermes
home=$(make_home lifecycle)
set_target "$home"
TG_CLOCK=$(make_clock lifecycle)
out=$(printf 'please check the builds\n' | run_note "$home") || fail "the note should file"
note_id=$(printf '%s' "$out" | json_get id)
run_inbox "$home" drain --ack "$note_id" >/dev/null 2>&1 || fail "drain --ack failed"
run_inbox "$home" reply "$note_id" "the nightly build is green" >/dev/null 2>&1 \
  || fail "reply failed"
assert_equals "1" "$(count_notes "$home")" "exactly one note file ever exists"
assert_equals "1" "$(count_wakes "$home")" "exactly one wake row ever exists"
assert_equals "3" "$(hermes_calls)" "the lifecycle sends exactly the three receipts"
expected_bodies="fm: got it - note $note_id
fm: picked up - note $note_id
fm: the nightly build is green"
assert_equals "$expected_bodies" "$(hermes_bodies)" \
  "the three receipts are the catalog lines, in order"
set +e
dup_out=$(run_inbox "$home" reply "$note_id" "a second answer" 2>&1)
dup_rc=$?
set -e
expect_code 1 "$dup_rc" "a second reply for one note is refused"
assert_contains "$dup_out" "reply already recorded" "the refusal names the rule"
assert_equals "3" "$(hermes_calls)" "the refused second reply pushes nothing"
assert_equals "1" "$(count_notes "$home")" "no push ever created a new note"
pass "lifecycle: three catalog receipts, one note, one wake, no loop"

# --- the receipt hooks are opt-in behind source=tg ----------------------------

reset_hermes
home=$(make_home opt-in)
# No config/tg-target: a tg note's pushes fail closed into the journal.
tg_out=$(printf 'via the lane\n' | run_inbox "$home" note --source tg --json -) \
  || fail "note --source tg should file"
tg_id=$(printf '%s' "$tg_out" | json_get id)
run_inbox "$home" drain --ack "$tg_id" >/dev/null 2>&1
run_inbox "$home" reply "$tg_id" "an answer" >/dev/null 2>&1
assert_equals "2" "$(journal_lines "$home")" "the tg note's receipts reach the lane"
assert_equals "4" "$(journal_field "$home" "note.$tg_id.pickedup" 0 rc)" \
  "the picked-up receipt fails closed while the lane is off"
assert_equals "4" "$(journal_field "$home" "note.$tg_id.answered" 0 rc)" \
  "the answered receipt fails closed while the lane is off"
plain_out=$(run_inbox "$home" note "plain words")
plain_id=${plain_out#queued }
plain_id=${plain_id%%$'\n'*}
printf 'board pick\n' \
  | run_inbox "$home" note --source lavish --request-id l1 --json - >/dev/null \
  || fail "note --source lavish should file"
run_inbox "$home" drain --ack "$plain_id" >/dev/null 2>&1
run_inbox "$home" reply "$plain_id" "another answer" >/dev/null 2>&1
assert_equals "2" "$(journal_lines "$home")" "non-tg notes never touch the lane"
assert_equals "0" "$(hermes_calls)" "no engine call for non-tg notes"
pass "receipt hooks fire only for source=tg notes"

# --- a reply from a minimal branch-shaped environment still pushes ------------

reset_hermes
home=$(make_home branch-reply)
set_target "$home"
TG_CLOCK=$(make_clock branch-reply)
out=$(printf 'a note while away\n' | run_note "$home") || fail "the note should file"
branch_id=$(printf '%s' "$out" | json_get id)
env -i PATH="$FAKEBIN:/usr/bin:/bin" HOME="$HOME" FM_HOME="$home" \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_CONFIG_OVERRIDE="$home/config" \
  "$INBOX_BIN" reply "$branch_id" "answered from the branch" >/dev/null 2>&1 \
  || fail "a branch-shaped reply should succeed"
assert_equals "2" "$(hermes_calls)" \
  "the filing's accepted receipt and the reply's answer both push"
assert_contains "$(hermes_bodies)" "fm: answered from the branch" \
  "the pushed line is the reply text with the fm: prefix"
assert_equals "0" "$(journal_field "$home" "note.$branch_id.answered" 0 rc)" \
  "the answered receipt is journaled as delivered"
pass "a reply from a minimal branch-shaped env pushes the answer"

# --- lane off end to end: nothing lost, delivered once configured -------------

reset_hermes
home=$(make_home lane-off)
TG_CLOCK=$(make_clock lane-off)
out=$(printf 'are you there\n' | run_note "$home") \
  || fail "filing succeeds while the lane is off"
off_id=$(printf '%s' "$out" | json_get id)
assert_equals "True" "$(printf '%s' "$out" | json_get announced)" \
  "the note is announced while the lane is off"
assert_equals "0" "$(hermes_calls)" "nothing is sent while the lane is off"
assert_equals "1" "$(journal_lines "$home")" "the accepted receipt is journaled as refused"
run_inbox "$home" drain --ack "$off_id" >/dev/null 2>&1
run_inbox "$home" reply "$off_id" "held for your return - the merge waits" >/dev/null 2>&1
assert_equals "3" "$(journal_lines "$home")" "each receipt fail-closes into the journal"
assert_equals "0" "$(hermes_calls)" "still nothing sent while the lane is off"
set_target "$home"
printf '1700000061.000\n' > "$TG_CLOCK"
run_tg "$home" retry >/dev/null || fail "retry should deliver the queued receipts"
assert_equals "3" "$(hermes_calls)" "the three queued receipts are delivered"
delivered=$(hermes_bodies)
assert_contains "$delivered" "fm: got it - note $off_id" "the accepted receipt is delivered"
assert_contains "$delivered" "fm: picked up - note $off_id" "the picked-up receipt is delivered"
assert_contains "$delivered" "fm: held for your return - the merge waits" \
  "the answered receipt is delivered"
assert_equals "1" "$(count_notes "$home")" "the note was never lost or duplicated"
pass "lane off: the note is never lost, receipts deliver after opt-in"

# --- usage: the command line carries only one optional file path -------------

home=$(make_home usage)
set +e
out=$(printf 'words\n' | FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
  PATH="$FAKEBIN:$PATH" "$NOTE_BIN" one-file two-file 2>&1)
rc=$?
set -e
expect_code 2 "$rc" "extra positional arguments are a usage error"
assert_contains "$out" "usage" "the refusal prints the usage"
assert_equals "0" "$(count_notes "$home")" "a usage refusal files nothing"
pass "usage: argv carries only one optional file path"
