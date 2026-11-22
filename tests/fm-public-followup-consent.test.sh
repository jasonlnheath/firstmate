#!/usr/bin/env bash
# Tests for exact-text consent gate (Lesson 3)
#
# Tests the consent gate behavior of bin/fm-x-reply.sh, the posting surface
# bin/fm-public-followup.sh deliver also routes through, by executing the real
# script under FMX_DRY_RUN and asserting its exit code and output for each
# consent-file state.
#
# Run from the firstmate repo root:
#   bash tests/fm-public-followup-consent.test.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${FM_STATE_OVERRIDE:-${TMPDIR:-/tmp}/fm-test-state-$$}"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$1"; }
cleanup() { rm -rf "$STATE"; }
trap cleanup EXIT

mkdir -p "$STATE/fm-public-followup-consent"

echo "=== Test: Real gate execution ==="

# Test 1: matching hash passes (fm-x-reply.sh with FMX_DRY_RUN)
echo -n "  Test 1: Real gate - matching hash passes... "
text="This is the approved reply text."
hash=$(printf '%s' "$text" | sha256sum | cut -d' ' -f1)
echo "$hash" > "$STATE/fm-public-followup-consent/test1.hash"
rc=0
output=$(FM_STATE_OVERRIDE="$STATE" FMX_DRY_RUN=1 "$SCRIPT_DIR/../bin/fm-x-reply.sh" "test1" "$text" 2>&1) || rc=$?
if [ $rc -eq 0 ] && echo "$output" | grep -q "^test1$"; then
  pass "fm-x-reply.sh passes with matching hash (FMX_DRY_RUN)"
else
  fail "expected exit 0 and stdout 'test1', got rc=$rc output='$output'"
fi

# Test 2: mismatched hash refuses (fm-x-reply.sh with FMX_DRY_RUN)
echo -n "  Test 2: Real gate - mismatched hash refuses... "
text="This is the approved reply text."
echo "wrong-hash-value" > "$STATE/fm-public-followup-consent/test2.hash"
rc=0
output=$(FM_STATE_OVERRIDE="$STATE" FMX_DRY_RUN=1 "$SCRIPT_DIR/../bin/fm-x-reply.sh" "test2" "$text" 2>&1) || rc=$?
if [ $rc -eq 2 ] && echo "$output" | grep -q "exact-text consent gate"; then
  pass "fm-x-reply.sh refuses with mismatched hash (exit 2)"
else
  fail "expected exit 2 and 'exact-text consent gate', got rc=$rc"
fi

# Test 3: no consent file passes (backward compatible)
echo -n "  Test 3: Real gate - no consent file passes... "
text="This is the reply text."
rm -f "$STATE/fm-public-followup-consent/test3.hash"
rc=0
output=$(FM_STATE_OVERRIDE="$STATE" FMX_DRY_RUN=1 "$SCRIPT_DIR/../bin/fm-x-reply.sh" "test3" "$text" 2>&1) || rc=$?
if [ $rc -eq 0 ] && echo "$output" | grep -q "^test3$"; then
  pass "fm-x-reply.sh passes with no consent file (backward compatible)"
else
  fail "expected exit 0 and stdout 'test3', got rc=$rc"
fi

# Test 4: empty hash file refuses (r4-7 fix)
echo -n "  Test 4: Real gate - empty hash file refuses... "
text="This is the reply text."
printf '' > "$STATE/fm-public-followup-consent/test4.hash"
rc=0
output=$(FM_STATE_OVERRIDE="$STATE" FMX_DRY_RUN=1 "$SCRIPT_DIR/../bin/fm-x-reply.sh" "test4" "$text" 2>&1) || rc=$?
if [ $rc -eq 2 ] && echo "$output" | grep -q "present but empty"; then
  pass "fm-x-reply.sh refuses with empty hash file (exit 2)"
else
  fail "expected exit 2 and 'present but empty', got rc=$rc"
fi

echo ""
echo "=== Test Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
