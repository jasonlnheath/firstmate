#!/usr/bin/env bash
# tests/fm-tg.test.sh - the outbound Telegram lane (bin/fm-tg.sh).
#
# Covers the S1 send contract of the Telegram channel plan: the engine
# invocation shape and exit-code passthrough, key dedupe (one event is one
# line), the append-only journal as the dedupe oracle and its fail-closed
# refusal on corruption, retry of unsent keys after the 60 s grace with the
# per-invocation cap, fail-closed lane-off and missing-hermes behavior with a
# journaled reason, the hermes resolution order including the broken-symlink
# case the v1 design missed, body normalization, the target never appearing
# in any output, and lock-serialized sends holding the 1.1 s minimum spacing
# through the fake clock seam. No test sends anything: the engine is always
# the fake hermes and the target is always a fixture id.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-tg)
TG_BIN="$ROOT/bin/fm-tg.sh"
FAKE_TARGET="telegram:424242"

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
fm_test_fake_hermes "$FAKEBIN"

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
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

# A stub hermes at an arbitrary path that records its invocations elsewhere,
# for the resolution-order cases where the engine is not the PATH fake.
make_stub_hermes() {  # <exe-path> <log-path>
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<SH
#!/usr/bin/env bash
printf 'STUB %s\n' "\$*" >> "$2"
exit 0
SH
  chmod +x "$1"
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

# run_tg <home> <args...>; stdin passes through. TG_CLOCK, TG_HOME, and
# TG_PATH override the clock seam, HOME, and PATH for one invocation.
run_tg() {
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_TG_TEST_CLOCK="${TG_CLOCK:-}" HOME="${TG_HOME:-$HOME}" \
    PATH="${TG_PATH:-$FAKEBIN:$PATH}" "$TG_BIN" "$@"
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

journal_at_gaps() {  # <home> -> gaps between consecutive row `at` values
  python3 - "$(journal_file "$1")" <<'PY'
import json, sys
ats = [json.loads(line)["at"] for line in open(sys.argv[1], encoding="utf-8")
       if line.strip()]
print(" ".join("%.3f" % (b - a) for a, b in zip(ats, ats[1:])))
PY
}

# --- send: engine shape, stdin body, journal row ----------------------------

reset_hermes
home=$(make_home send-ok)
set_target "$home"
TG_CLOCK=$(make_clock send-ok)
out=$(printf 'fm: got it - note 1\n' | run_tg "$home" send --key note.1.accepted) \
  || fail "a send with the lane configured should succeed"
assert_contains "$out" "sent note.1.accepted" "send reports the key it sent"
assert_equals "1" "$(hermes_calls)" "one engine call for one send"
assert_equals "send --to $FAKE_TARGET --quiet --file -" \
  "$(sed -n '1s/^CALL //p' "$FAKEBIN/hermes.log")" \
  "the engine call is hermes send --to <target> --quiet --file -"
assert_equals "fm: got it - note 1" "$(sed -n 's/^BODY //p' "$FAKEBIN/hermes.log" | head -n 1)" \
  "the line travels on stdin, never argv"
assert_equals "1" "$(journal_lines "$home")" "one journal row for one attempt"
assert_equals "0" "$(journal_field "$home" note.1.accepted 0 rc)" \
  "the row records the success"
assert_equals "fm: got it - note 1" "$(journal_field "$home" note.1.accepted 0 line)" \
  "the row records the sent line"
pass "send: engine shape, stdin body, journal row"

# --- dedupe: one event key is one line --------------------------------------

out=$(printf 'fm: got it - note 1\n' | run_tg "$home" send --key note.1.accepted) \
  || fail "a repeat of a sent key should exit 0"
assert_contains "$out" "already-sent note.1.accepted" "a sent key is a no-op"
assert_equals "1" "$(hermes_calls)" "a sent key is not sent twice"
assert_equals "1" "$(journal_lines "$home")" "a sent key writes no second journal row"
pass "dedupe: one event key is one line"

# --- body normalization: one line, capped -----------------------------------

reset_hermes
home=$(make_home normalize)
set_target "$home"
TG_CLOCK=$(make_clock normalize)
printf 'line one\nline two\tand a tab\n' \
  | run_tg "$home" send --key n.multiline >/dev/null \
  || fail "a multi-line body should send as one line"
assert_equals "line one line two and a tab" \
  "$(sed -n 's/^BODY //p' "$FAKEBIN/hermes.log" | head -n 1)" \
  "newlines and tabs collapse to single spaces"
python3 -c 'print("x" * 400)' | run_tg "$home" send --key n.long >/dev/null \
  || fail "a long body should send truncated"
long_body=$(sed -n '$s/^BODY //p' "$FAKEBIN/hermes.log")
assert_equals "300" "${#long_body}" "the sent line is capped at 300 characters"
pass "body normalization: one line, capped"

# --- usage errors: nothing is sent ------------------------------------------

reset_hermes
set +e
out=$(printf '' | run_tg "$home" send --key n.empty 2>&1)
rc=$?
set -e
expect_code 2 "$rc" "an empty line is a usage error"
assert_equals "0" "$(hermes_calls)" "no engine call for an empty line"
set +e
out=$(printf 'words\n' | run_tg "$home" send --key 'bad key' 2>&1)
rc=$?
set -e
expect_code 2 "$rc" "a key with spaces is a usage error"
assert_equals "0" "$(hermes_calls)" "no engine call for a bad key"
set +e
out=$(printf 'words\n' | run_tg "$home" send --source 'not a source' --key k.source 2>&1)
rc=$?
set -e
expect_code 2 "$rc" "an unsafe source label is a usage error"
assert_equals "0" "$(hermes_calls)" "no engine call for a bad source"
pass "usage errors refuse before any engine call"

# --- send failure: passthrough exit, journaled, no target leak --------------

reset_hermes
home=$(make_home send-fail)
set_target "$home"
TG_CLOCK=$(make_clock send-fail)
fake_hermes_exit 1
set +e
out=$(printf 'fm: got it - note 2\n' | run_tg "$home" send --key note.2.accepted 2>&1)
rc=$?
set -e
expect_code 1 "$rc" "an engine failure passes through as exit 1"
assert_not_contains "$out" "$FAKE_TARGET" "the target never appears in fm-tg output"
assert_equals "1" "$(hermes_calls)" "one engine call was made"
assert_equals "1" "$(journal_lines "$home")" "the failed attempt is journaled"
assert_equals "1" "$(journal_field "$home" note.2.accepted 0 rc)" \
  "the row records the failure"
pass "send failure: passthrough exit, journaled, no target leak"

# An engine usage error (exit 2) passes through the same way.
fake_hermes_exit 2
set +e
out=$(printf 'fm: got it - note 2b\n' | run_tg "$home" send --key note.2b.accepted 2>&1)
rc=$?
set -e
expect_code 2 "$rc" "an engine usage error passes through as exit 2"
assert_equals "2" "$(journal_field "$home" note.2b.accepted 0 rc)" \
  "the row records the engine usage failure"
pass "engine usage errors pass through"

# --- retry: 60 s grace, one delivery, failed view ---------------------------

reset_hermes
home=$(make_home retry)
set_target "$home"
TG_CLOCK=$(make_clock retry)
fake_hermes_exit 1
printf 'fm: got it - note 3\n' | run_tg "$home" send --key note.3.accepted \
  >/dev/null 2>&1 || true
fake_hermes_exit 0
failed_view=$(run_tg "$home" failed) || fail "failed should exit 0"
assert_contains "$failed_view" "note.3.accepted" "failed lists the unsent key"
assert_contains "$failed_view" "fm: got it - note 3" "failed shows the queued line"
run_tg "$home" retry >/dev/null || fail "retry should exit 0 with nothing eligible"
assert_equals "1" "$(hermes_calls)" "a failure younger than 60 s is not retried"
printf '1700000061.000\n' > "$TG_CLOCK"
out=$(run_tg "$home" retry) || fail "retry after the grace should succeed"
assert_contains "$out" "retried note.3.accepted" "retry reports the key it delivered"
assert_equals "2" "$(hermes_calls)" "retry re-sends the unsent key exactly once"
assert_equals "fm: got it - note 3" "$(sed -n 's/^BODY //p' "$FAKEBIN/hermes.log" | head -n 1)" \
  "retry sends the journaled line"
assert_equals "2" "$(journal_lines "$home")" "the retry attempt appends one row"
assert_equals "0" "$(journal_field "$home" note.3.accepted 1 rc)" \
  "the retry row records the success"
failed_view=$(run_tg "$home" failed) || fail "failed should exit 0 when clean"
assert_equals "" "$failed_view" "no unsent keys remain after the retry"
run_tg "$home" retry >/dev/null || fail "an idle retry should exit 0"
assert_equals "2" "$(hermes_calls)" "a clean retry sends nothing"
pass "retry: 60 s grace, one delivery, failed view"

# A retry whose engine still fails exits 1 and leaves the key unsent.
reset_hermes
home=$(make_home retry-fail)
set_target "$home"
TG_CLOCK=$(make_clock retry-fail)
fake_hermes_exit 1
printf 'still failing\n' | run_tg "$home" send --key note.4.accepted >/dev/null 2>&1 || true
printf '1700000061.000\n' > "$TG_CLOCK"
set +e
out=$(run_tg "$home" retry 2>&1)
rc=$?
set -e
expect_code 1 "$rc" "a retry that fails again exits 1"
assert_equals "2" "$(hermes_calls)" "the retry attempted the send"
assert_equals "1" "$(journal_field "$home" note.4.accepted 1 rc)" \
  "the second failed attempt is journaled"
pass "retry failures exit 1 and stay queued"

# --- retry cap: at most 5 keys per invocation --------------------------------

reset_hermes
home=$(make_home retry-cap)
set_target "$home"
TG_CLOCK=$(make_clock retry-cap)
fake_hermes_exit 1
for i in 1 2 3 4 5 6 7; do
  printf 'cap line %s\n' "$i" | run_tg "$home" send --key "cap.$i" >/dev/null 2>&1 || true
done
assert_equals "7" "$(hermes_calls)" "seven failed sends are journaled"
fake_hermes_exit 0
printf '1700000100.000\n' > "$TG_CLOCK"
run_tg "$home" retry >/dev/null || fail "retry should deliver the cap"
assert_equals "12" "$(hermes_calls)" "a retry re-sends at most 5 keys (7 + 5)"
unsent=$(run_tg "$home" failed | grep -c '^cap\.' || true)
assert_equals "2" "$unsent" "the remaining unsent keys stay visible"
pass "retry cap: at most 5 keys per invocation"

# --- lane off: fail closed, journaled, delivered once configured -------------

reset_hermes
home=$(make_home lane-off)
TG_CLOCK=$(make_clock lane-off)
set +e
out=$(printf 'fm: picked up - note 9\n' | run_tg "$home" send --key note.9.pickedup 2>&1)
rc=$?
set -e
expect_code 4 "$rc" "an unconfigured lane fails closed"
assert_contains "$out" "tg-target" "the refusal names the missing config file"
assert_equals "0" "$(hermes_calls)" "nothing is sent when the lane is off"
assert_equals "1" "$(journal_lines "$home")" "the refusal is journaled"
assert_equals "4" "$(journal_field "$home" note.9.pickedup 0 rc)" \
  "the row records lane-off"
assert_contains "$(journal_field "$home" note.9.pickedup 0 reason)" "tg-target" \
  "the row carries the reason"
set +e
out=$(run_tg "$home" retry 2>&1)
rc=$?
set -e
expect_code 4 "$rc" "retry fails closed while the lane is off"
assert_equals "1" "$(journal_lines "$home")" "retry adds no rows while off"
assert_equals "0" "$(hermes_calls)" "retry sends nothing while the lane is off"
set_target "$home"
printf '1700000061.000\n' > "$TG_CLOCK"
run_tg "$home" retry >/dev/null || fail "retry should deliver once configured"
assert_equals "1" "$(hermes_calls)" "the queued line is delivered after opt-in"
assert_equals "0" "$(journal_field "$home" note.9.pickedup 1 rc)" \
  "the delivered row records success"
pass "lane off: fail closed, journaled, delivered once configured"

# --- hermes resolution order --------------------------------------------------

# PATH wins when a hermes is on it, even with a venv install present.
reset_hermes
res="$TMP_ROOT/resolve-a"
make_stub_hermes "$res/.hermes/hermes-agent/.venv/bin/hermes" "$res/venv.log"
home=$(make_home resolve-a)
set_target "$home"
TG_PATH="$FAKEBIN:/usr/bin:/bin"
TG_HOME="$res"
printf 'resolve a\n' | run_tg "$home" send --key r.a >/dev/null \
  || fail "PATH hermes should serve the send"
assert_equals "1" "$(hermes_calls)" "the PATH hermes is used when present"
[ -f "$res/venv.log" ] && fail "the venv fallback must not run when PATH resolves hermes"
pass "resolution: PATH wins"

# With no PATH hermes, the canonical venv path is used.
reset_hermes
res="$TMP_ROOT/resolve-b"
make_stub_hermes "$res/.hermes/hermes-agent/.venv/bin/hermes" "$res/venv.log"
home=$(make_home resolve-b)
set_target "$home"
TG_PATH="/usr/bin:/bin"
TG_HOME="$res"
printf 'resolve b\n' | run_tg "$home" send --key r.b >/dev/null \
  || fail "the venv hermes should serve the send"
stub_calls=$(grep -c '^STUB ' "$res/venv.log" || true)
assert_equals "1" "$stub_calls" "the venv absolute path is used"
assert_equals "0" "$(hermes_calls)" "the PATH fake was not invoked"
pass "resolution: the venv absolute path is the first fallback"

# With no PATH hermes and no venv, a live ~/.local/bin/hermes link is used.
reset_hermes
res="$TMP_ROOT/resolve-c"
make_stub_hermes "$res/live-hermes" "$res/local.log"
mkdir -p "$res/.local/bin"
ln -s "$res/live-hermes" "$res/.local/bin/hermes"
home=$(make_home resolve-c)
set_target "$home"
TG_PATH="/usr/bin:/bin"
TG_HOME="$res"
printf 'resolve c\n' | run_tg "$home" send --key r.c >/dev/null \
  || fail "the live local hermes link should serve the send"
stub_calls=$(grep -c '^STUB ' "$res/local.log" || true)
assert_equals "1" "$stub_calls" "a live ~/.local/bin/hermes link is used"
pass "resolution: a live local link is the last fallback"

# A broken ~/.local/bin/hermes symlink is not a usable hermes.
reset_hermes
res="$TMP_ROOT/resolve-d"
mkdir -p "$res/.local/bin"
ln -s "$res/gone/bin/hermes" "$res/.local/bin/hermes"
home=$(make_home resolve-d)
set_target "$home"
TG_PATH="/usr/bin:/bin"
TG_HOME="$res"
TG_CLOCK=""
set +e
out=$(printf 'resolve d\n' | run_tg "$home" send --key r.d 2>&1)
rc=$?
set -e
expect_code 5 "$rc" "no usable hermes is a loud failure, not a send"
assert_contains "$out" "no usable hermes" "the failure says what is missing"
assert_equals "1" "$(journal_lines "$home")" "the refusal is journaled"
assert_equals "5" "$(journal_field "$home" r.d 0 rc)" "the row records no-hermes"
pass "resolution: a broken symlink is not a hermes (the v1 gap)"

# An explicit config/tg-hermes-bin wins over every discovery path.
reset_hermes
res="$TMP_ROOT/resolve-e"
make_stub_hermes "$res/override-hermes" "$res/override.log"
home=$(make_home resolve-e)
set_target "$home"
printf '%s\n' "$res/override-hermes" > "$home/config/tg-hermes-bin"
TG_PATH="$FAKEBIN:/usr/bin:/bin"
TG_HOME="$res"
printf 'resolve e\n' | run_tg "$home" send --key r.e >/dev/null \
  || fail "the configured hermes should serve the send"
stub_calls=$(grep -c '^STUB ' "$res/override.log" || true)
assert_equals "1" "$stub_calls" "config/tg-hermes-bin wins"
assert_equals "0" "$(hermes_calls)" "the PATH fake was not invoked"
pass "resolution: config/tg-hermes-bin overrides discovery"

# --- a corrupt journal refuses to send ---------------------------------------

reset_hermes
home=$(make_home corrupt)
set_target "$home"
TG_PATH="$FAKEBIN:$PATH"
mkdir -p "$home/state/tg"
printf 'this is not json\n' >> "$(journal_file "$home")"
set +e
out=$(printf 'corrupt\n' | run_tg "$home" send --key c.bad 2>&1)
rc=$?
set -e
expect_code 2 "$rc" "a corrupt journal refuses to send"
assert_contains "$out" "journal" "the refusal names the journal"
assert_equals "0" "$(hermes_calls)" "nothing was sent from a corrupt journal"
pass "a corrupt journal fails closed"

# --- rate limit: serialized sends hold the 1.1 s spacing ----------------------

reset_hermes
home=$(make_home rate)
set_target "$home"
TG_CLOCK=$(make_clock rate)
start=$(date +%s.%N)
for i in 1 2 3 4 5; do
  printf 'rate %s\n' "$i" | run_tg "$home" send --key "rate.$i" >/dev/null \
    || fail "rate-limited send $i should succeed"
done
end=$(date +%s.%N)
wall=$(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.2f", b - a }')
assert_equals "5" "$(hermes_calls)" "five rapid sends all go through"
assert_equals "5" "$(journal_lines "$home")" "five sends journal five rows"
gaps=$(journal_at_gaps "$home")
printf '%s\n' "$gaps" | tr ' ' '\n' | awk 'NF && $1 < 1.099 { bad = 1 } END { exit bad }' \
  || fail "sends must be spaced at least 1.1 s apart (float noise aside): $gaps"
awk -v w="$wall" 'BEGIN { exit (w < 4.0) ? 0 : 1 }' \
  || fail "five sends took ${wall}s: the fake clock must avoid real rate-limit sleeps"
pass "rate limit: 1.1 s spacing, no real sleeps under the fake clock"

# --- concurrent sends serialize under the send lock ---------------------------

reset_hermes
home=$(make_home concurrent)
set_target "$home"
TG_CLOCK=$(make_clock concurrent)
( printf 'first\n' | run_tg "$home" send --key cc.1 >/dev/null 2>&1 ) &
( printf 'second\n' | run_tg "$home" send --key cc.2 >/dev/null 2>&1 ) &
wait
assert_equals "2" "$(hermes_calls)" "both concurrent sends completed"
assert_equals "2" "$(journal_lines "$home")" "both concurrent sends journaled"
gaps=$(journal_at_gaps "$home")
printf '%s\n' "$gaps" | tr ' ' '\n' | awk 'NF && $1 < 1.099 { bad = 1 } END { exit bad }' \
  || fail "concurrent sends must serialize with 1.1 s spacing: $gaps"
pass "concurrent sends serialize under the send lock"

# --- failed with no journal at all -------------------------------------------

home=$(make_home failed-empty)
out=$(run_tg "$home" failed) || fail "failed with no journal should exit 0"
assert_equals "" "$out" "failed prints nothing when nothing was ever attempted"
pass "failed: empty journal is empty output"
