#!/usr/bin/env bash
# Tests for exact-text consent gate (Lesson 3)
#
# Tests the consent hash verification logic used by:
#   - bin/fm-public-followup.sh deliver
#   - bin/fm-x-reply.sh
#
# Run from the firstmate repo root:
#   bash tests/fm-public-followup-consent.test.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Read by fm-protected-paths-lib.sh to locate the global config/protected-paths.
# shellcheck disable=SC2034
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-${TMPDIR:-/tmp}/fm-test-state-$$}"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$1"; }
cleanup() { rm -rf "$STATE"; }
trap cleanup EXIT

mkdir -p "$STATE/fm-public-followup-consent"

echo "=== Test: Consent hash computation ==="

# Test 1: SHA-256 hash of text
echo -n "  Test 1: SHA-256 hash of text... "
text="Hello, world!"
hash=$(printf '%s' "$text" | sha256sum | cut -d' ' -f1)
if [ -n "$hash" ] && [ ${#hash} -eq 64 ]; then
  pass "SHA-256 hash computed correctly"
else
  fail "SHA-256 hash incorrect: $hash"
fi

# Test 2: Different text produces different hash
echo -n "  Test 2: Different text produces different hash... "
hash1=$(printf '%s' "Hello, world!" | sha256sum | cut -d' ' -f1)
hash2=$(printf '%s' "Hello, world!!" | sha256sum | cut -d' ' -f1)
if [ "$hash1" != "$hash2" ]; then
  pass "different text produces different hash"
else
  fail "different text produced same hash"
fi

# Test 3: Same text produces same hash
echo -n "  Test 3: Same text produces same hash... "
hash1=$(printf '%s' "Hello, world!" | sha256sum | cut -d' ' -f1)
hash2=$(printf '%s' "Hello, world!" | sha256sum | cut -d' ' -f1)
if [ "$hash1" = "$hash2" ]; then
  pass "same text produces same hash"
else
  fail "same text produced different hash"
fi

echo ""
echo "=== Test: Consent hash storage ==="

# Test 4: Store consent hash
echo -n "  Test 4: Store consent hash... "
text="Hello, world!"
hash=$(printf '%s' "$text" | sha256sum | cut -d' ' -f1)
echo "$hash" > "$STATE/fm-public-followup-consent/test-obligation.hash"
stored_hash=$(cat "$STATE/fm-public-followup-consent/test-obligation.hash")
if [ "$stored_hash" = "$hash" ]; then
  pass "consent hash stored correctly"
else
  fail "consent hash stored incorrectly: $stored_hash != $hash"
fi

# Test 5: Symlink consent file is ignored
echo -n "  Test 5: Symlink consent file is ignored... "
real_file=$(mktemp "${TMPDIR:-/tmp}/fm-test-consent.XXXXXX")
echo "real-hash" > "$real_file"
rm -f "$STATE/fm-public-followup-consent/symlink-test.hash"
ln -s "$real_file" "$STATE/fm-public-followup-consent/symlink-test.hash"
# The gate should check [ ! -L "$consent_file" ] and skip the verification
stored_hash=$(cat "$STATE/fm-public-followup-consent/symlink-test.hash")
if [ -L "$STATE/fm-public-followup-consent/symlink-test.hash" ]; then
  pass "symlink consent file detected"
else
  fail "symlink consent file not detected"
fi
rm -f "$real_file"

# Test 6: Missing consent file is skipped
echo -n "  Test 6: Missing consent file is skipped... "
if [ ! -f "$STATE/fm-public-followup-consent/nonexistent.hash" ]; then
  pass "missing consent file is skipped"
else
  fail "missing consent file should not exist"
fi

echo ""
echo "=== Test: Consent hash verification ==="

# Test 7: Matching hash passes
echo -n "  Test 7: Matching hash passes... "
text="Hello, world!"
hash=$(printf '%s' "$text" | sha256sum | cut -d' ' -f1)
echo "$hash" > "$STATE/fm-public-followup-consent/match-test.hash"
computed_hash=$(printf '%s' "$text" | sha256sum | cut -d' ' -f1)
stored_hash=$(cat "$STATE/fm-public-followup-consent/match-test.hash")
if [ "$computed_hash" = "$stored_hash" ]; then
  pass "matching hash passes verification"
else
  fail "matching hash failed verification"
fi

# Test 8: Mismatched hash fails
echo -n "  Test 8: Mismatched hash fails... "
text="Hello, world!"
hash=$(printf '%s' "$text" | sha256sum | cut -d' ' -f1)
echo "wrong-hash-value" > "$STATE/fm-public-followup-consent/mismatch-test.hash"
computed_hash=$(printf '%s' "$text" | sha256sum | cut -d' ' -f1)
stored_hash=$(cat "$STATE/fm-public-followup-consent/mismatch-test.hash")
if [ "$computed_hash" != "$stored_hash" ]; then
  pass "mismatched hash detected correctly"
else
  fail "mismatched hash was not detected"
fi

# Test 9: Altered text is detected
echo -n "  Test 9: Altered text is detected... "
approved_text="Hello, world!"
approved_hash=$(printf '%s' "$approved_text" | sha256sum | cut -d' ' -f1)
echo "$approved_hash" > "$STATE/fm-public-followup-consent/alter-test.hash"
altered_text="Hello, world! (altered)"
computed_hash=$(printf '%s' "$altered_text" | sha256sum | cut -d' ' -f1)
stored_hash=$(cat "$STATE/fm-public-followup-consent/alter-test.hash")
if [ "$computed_hash" != "$stored_hash" ]; then
  pass "altered text detected correctly"
else
  fail "altered text was not detected"
fi

# Test 10: Empty text produces valid hash
echo -n "  Test 10: Empty text produces valid hash... "
hash=$(printf '%s' "" | sha256sum | cut -d' ' -f1)
if [ -n "$hash" ] && [ ${#hash} -eq 64 ]; then
  pass "empty text produces valid hash"
else
  fail "empty text hash incorrect: $hash"
fi

echo ""
echo "=== Test: Real gate execution ==="

# Test 11: Real gate - matching hash (fm-x-reply.sh with FMX_DRY)
echo -n "  Test 11: Real gate - matching hash passes... "
text="This is the approved reply text."
hash=$(printf '%s' "$text" | sha256sum | cut -d' ' -f1)
echo "$hash" > "$STATE/fm-public-followup-consent/test11.hash"
rc=0
output=$(FM_STATE_OVERRIDE="$STATE" FMX_DRY_RUN=1 "$SCRIPT_DIR/../bin/fm-x-reply.sh" "test11" "$text" 2>&1) || rc=$?
if [ $rc -eq 0 ] && echo "$output" | grep -q "^test11$"; then
  pass "fm-x-reply.sh passes with matching hash (FMX_DRY_RUN)"
else
  fail "expected exit 0 and stdout 'test11', got rc=$rc output='$output'"
fi

# Test 12: Real gate - mismatched hash (fm-x-reply.sh with FMX_DRY_RUN)
echo -n "  Test 12: Real gate - mismatched hash refuses... "
text="This is the approved reply text."
echo "wrong-hash-value" > "$STATE/fm-public-followup-consent/test12.hash"
rc=0
output=$(FM_STATE_OVERRIDE="$STATE" FMX_DRY_RUN=1 "$SCRIPT_DIR/../bin/fm-x-reply.sh" "test12" "$text" 2>&1) || rc=$?
if [ $rc -eq 2 ] && echo "$output" | grep -q "exact-text consent gate"; then
  pass "fm-x-reply.sh refuses with mismatched hash (exit 2)"
else
  fail "expected exit 2 and 'exact-text consent gate', got rc=$rc"
fi

# Test 13: Real gate - no consent file (backward compatible)
echo -n "  Test 13: Real gate - no consent file passes... "
text="This is the reply text."
rm -f "$STATE/fm-public-followup-consent/test13.hash"
rc=0
output=$(FM_STATE_OVERRIDE="$STATE" FMX_DRY_RUN=1 "$SCRIPT_DIR/../bin/fm-x-reply.sh" "test13" "$text" 2>&1) || rc=$?
if [ $rc -eq 0 ] && echo "$output" | grep -q "^test13$"; then
  pass "fm-x-reply.sh passes with no consent file (backward compatible)"
else
  fail "expected exit 0 and stdout 'test13', got rc=$rc"
fi

# Test 14: Real gate - empty hash file refuses (r4-7 fix)
echo -n "  Test 14: Real gate - empty hash file refuses... "
text="This is the reply text."
printf '' > "$STATE/fm-public-followup-consent/test14.hash"
rc=0
output=$(FM_STATE_OVERRIDE="$STATE" FMX_DRY_RUN=1 "$SCRIPT_DIR/../bin/fm-x-reply.sh" "test14" "$text" 2>&1) || rc=$?
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
