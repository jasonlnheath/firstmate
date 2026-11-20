#!/usr/bin/env bash
# Tests for bin/fm-second-look.sh (Lesson 2: adversarial second-look runner)
#
# Run from the firstmate repo root:
#   bash tests/fm-second-look.test.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The list fm-protected-paths-lib.sh resolves: a project's own
# config/protected-paths when present, else the tracked
# bin/fm-protected-paths.default next to the library (FM_ROOT is only the
# lib's fallback anchor for that default).
# shellcheck disable=SC2034
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-${TMPDIR:-/tmp}/fm-test-state-$$}"

# shellcheck source=bin/fm-protected-paths-lib.sh
. "$SCRIPT_DIR/../bin/fm-protected-paths-lib.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$1"; }
cleanup() { rm -rf "$STATE"; }
trap cleanup EXIT

mkdir -p "$STATE"

echo "=== Test: Second-look runner invocation ==="

# Test 1: Runner prints 'unsure' when no verdict exists
echo -n "  Test 1: Runner prints 'unsure' when no verdict exists... "
output=$("$SCRIPT_DIR/../bin/fm-second-look.sh" --task-id "test-task" \
    --pr-url "https://github.com/test/repo/pull/123" \
    --head "abc123def456" 2>/dev/null) || true
if [ "$output" = "unsure" ]; then
  pass "runner prints 'unsure' and exits 1 when no verdict exists"
else
  fail "expected stdout 'unsure', got '$output'"
fi

# Test 2: Runner rejects missing required arguments
echo -n "  Test 2: Runner rejects missing required arguments... "
if "$SCRIPT_DIR/../bin/fm-second-look.sh" --task-id "test-task" 2>/dev/null; then
  fail "runner should reject missing arguments"
else
  pass "runner rejects missing arguments"
fi

# Test 3: Runner rejects invalid arguments
echo -n "  Test 3: Runner rejects invalid arguments... "
if "$SCRIPT_DIR/../bin/fm-second-look.sh" --invalid-flag 2>/dev/null; then
  fail "runner should reject invalid arguments"
else
  pass "runner rejects invalid arguments"
fi

echo ""
echo "=== Test: Verdict persistence ==="

# Test 4: Verdict from a spawned reviewer is read
echo -n "  Test 4: Verdict from a spawned reviewer is read... "
verdict_dir=$(fm_second_look_verdict_dir "$STATE" "test-task" "123")
fm_second_look_write_verdict "$verdict_dir" "clean" "abc123def456"
verdict=$(fm_second_look_read_verdict "$verdict_dir")
if [ "$verdict" = "clean" ]; then
  pass "verdict written and read correctly"
else
  fail "verdict read incorrectly: $verdict"
fi

# Test 5: Runner reads existing verdict via FM_STATE_OVERRIDE
echo -n "  Test 5: Runner reads existing verdict via FM_STATE_OVERRIDE... "
verdict_dir=$(fm_second_look_verdict_dir "$STATE" "test-task" "123")
fm_second_look_write_verdict "$verdict_dir" "clean" "abc123def456"
output=$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/../bin/fm-second-look.sh" --task-id "test-task" \
    --pr-url "https://github.com/test/repo/pull/123" \
    --head "abc123def456" 2>/dev/null) || true
if [ "$output" = "clean" ]; then
  pass "runner prints 'clean' and exits 0 when verdict matches head"
else
  fail "expected stdout 'clean', got '$output'"
fi

# Test 6: Verdict with defect reason
echo -n "  Test 6: Verdict with defect reason... "
verdict_dir=$(fm_second_look_verdict_dir "$STATE" "test-task" "456")
fm_second_look_write_verdict "$verdict_dir" "defect" "def456ghi789" "found a critical security issue"
verdict=$(fm_second_look_read_verdict "$verdict_dir")
reason=$(fm_second_look_get_stuck_reason "$verdict_dir")
if [ "$verdict" = "defect" ] && echo "$reason" | grep -q "security"; then
  pass "defect verdict with reason stored and read correctly"
else
  fail "defect verdict incorrect: verdict=$verdict, reason=$reason"
fi

# Test 7: Verdict with unsure reason
echo -n "  Test 7: Verdict with unsure reason... "
verdict_dir=$(fm_second_look_verdict_dir "$STATE" "test-task" "789")
fm_second_look_write_verdict "$verdict_dir" "unsure" "ghi789jkl012"
verdict=$(fm_second_look_read_verdict "$verdict_dir")
if [ "$verdict" = "unsure" ]; then
  pass "unsure verdict stored and read correctly"
else
  fail "unsure verdict incorrect: $verdict"
fi

echo ""
echo "=== Test: Blocking verdicts for the current head ==="

# Test 8: Unsure verdict for the current head blocks the runner
echo -n "  Test 8: Unsure verdict for the current head blocks the runner... "
verdict_dir=$(fm_second_look_verdict_dir "$STATE" "test-task" "101")
fm_second_look_write_verdict "$verdict_dir" "unsure" "abc101def"
rc=0
output=$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/../bin/fm-second-look.sh" --task-id "test-task" \
    --pr-url "https://github.com/test/repo/pull/101" \
    --head "abc101def" 2>"$STATE/test8.stderr") || rc=$?
if [ "$output" = "unsure" ] && [ "$rc" -eq 1 ] \
    && grep -q '^BLOCKED:' "$STATE/test8.stderr"; then
  pass "unsure verdict for the current head prints the verdict and BLOCKED, exits 1"
else
  fail "expected stdout 'unsure', exit 1, BLOCKED on stderr; got '$output' rc=$rc"
fi

# Test 9: Defect verdict for the current head blocks the runner and carries the reason
echo -n "  Test 9: Defect verdict for the current head blocks the runner... "
verdict_dir=$(fm_second_look_verdict_dir "$STATE" "test-task" "102")
fm_second_look_write_verdict "$verdict_dir" "defect" "def102ghi" "found a critical bug"
rc=0
output=$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/../bin/fm-second-look.sh" --task-id "test-task" \
    --pr-url "https://github.com/test/repo/pull/102" \
    --head "def102ghi" 2>"$STATE/test9.stderr") || rc=$?
if [ "$output" = "defect" ] && [ "$rc" -eq 1 ] \
    && grep -q '^BLOCKED:.*found a critical bug' "$STATE/test9.stderr"; then
  pass "defect verdict for the current head prints the verdict and its reason, exits 1"
else
  fail "expected stdout 'defect', exit 1, BLOCKED with the reason on stderr; got '$output' rc=$rc"
fi

# Test 10: Clean verdict allows runner to proceed
echo -n "  Test 10: Clean verdict allows runner to proceed... "
verdict_dir=$(fm_second_look_verdict_dir "$STATE" "test-task" "103")
fm_second_look_write_verdict "$verdict_dir" "clean" "ghi"
output=$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/../bin/fm-second-look.sh" --task-id "test-task" \
    --pr-url "https://github.com/test/repo/pull/103" \
    --head "ghi" 2>/dev/null) || true
if [ "$output" = "clean" ]; then
  pass "clean verdict allows runner to proceed"
else
  fail "expected 'clean', got '$output'"
fi

echo ""
echo "=== Test: PR number extraction ==="

# Test 12: Runner derives PR number from GitHub PR URL
echo -n "  Test 12: Runner derives PR number from GitHub PR URL... "
# Write a verdict for PR 123, then run the runner with a GitHub URL
verdict_dir=$(fm_second_look_verdict_dir "$STATE" "test-task" "123")
fm_second_look_write_verdict "$verdict_dir" "clean" "abc123def456"
output=$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/../bin/fm-second-look.sh" --task-id "test-task" \
    --pr-url "https://github.com/test/repo/pull/123" \
    --head "abc123def456" 2>/dev/null) || true
if [ "$output" = "clean" ]; then
  pass "runner derives PR 123 from GitHub URL and reads verdict"
else
  fail "expected 'clean', got '$output'"
fi

# Test 13: Runner derives PR number from GitLab MR URL
echo -n "  Test 13: Runner derives PR number from GitLab MR URL... "
# Write a verdict for PR 456, then run the runner with a GitLab URL
verdict_dir=$(fm_second_look_verdict_dir "$STATE" "test-task" "456")
fm_second_look_write_verdict "$verdict_dir" "clean" "def456ghi789"
output=$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/../bin/fm-second-look.sh" --task-id "test-task" \
    --pr-url "https://gitlab.com/test/repo/-/merge_requests/456" \
    --head "def456ghi789" 2>/dev/null) || true
if [ "$output" = "clean" ]; then
  pass "runner derives PR 456 from GitLab URL and reads verdict"
else
  fail "expected 'clean', got '$output'"
fi

# Test 14: Runner uses default PR number (0) for unknown URLs
echo -n "  Test 14: Runner uses default PR number (0) for unknown URLs... "
# Write a verdict for PR 0, then run the runner with an unknown URL
verdict_dir=$(fm_second_look_verdict_dir "$STATE" "test-task" "0")
fm_second_look_write_verdict "$verdict_dir" "clean" "ghi789jkl012"
output=$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/../bin/fm-second-look.sh" --task-id "test-task" \
    --pr-url "https://unknown.example.com/repo/abc/789" \
    --head "ghi789jkl012" 2>/dev/null) || true
if [ "$output" = "clean" ]; then
  pass "runner uses default PR 0 for unknown URL and reads verdict"
else
  fail "expected 'clean', got '$output'"
fi

# Test 15: Runner derives the PR number on a Forgejo host no hostname grep names
echo -n "  Test 15: Runner derives the PR number on a codeberg pulls URL... "
# Write a verdict for PR 77, then run the runner with a codeberg URL: the
# hostname contains neither 'forgejo' nor 'gitea', so only the gate's own
# URL parser can derive 77.
verdict_dir=$(fm_second_look_verdict_dir "$STATE" "test-task" "77")
fm_second_look_write_verdict "$verdict_dir" "clean" "eee777fff"
output=$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/../bin/fm-second-look.sh" --task-id "test-task" \
    --pr-url "https://codeberg.org/test/repo/pulls/77" \
    --head "eee777fff" 2>/dev/null) || true
if [ "$output" = "clean" ]; then
  pass "runner derives PR 77 from a codeberg pulls URL"
else
  fail "expected 'clean', got '$output'"
fi

echo ""
echo "=== Test Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
