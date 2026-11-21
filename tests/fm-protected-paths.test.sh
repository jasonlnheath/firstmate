#!/usr/bin/env bash
# Tests for bin/fm-protected-paths-lib.sh (Lesson 1: merge-content gates)
#
# Run from the firstmate repo root:
#   bash tests/fm-protected-paths.test.sh
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

echo "=== Test: fm_protected_paths_list ==="

# Test 1: Tracked default list exists
echo -n "  Test 1: Tracked default protected-paths list exists... "
result=$(fm_protected_paths_list)
if [ -n "$result" ]; then
  pass "default list has $(echo "$result" | wc -l) patterns"
else
  fail "default list is empty"
fi

# Test 2: Default list contains CI patterns
echo -n "  Test 2: Default list contains CI patterns... "
if echo "$result" | grep -q '^\.github/workflows/\*$'; then
  pass "contains .github/workflows pattern"
else
  fail "missing .github/workflows pattern"
fi

# Test 3: Default list contains lockfile patterns
echo -n "  Test 3: Default list contains lockfile patterns... "
if echo "$result" | grep -q 'package-lock\.json'; then
  pass "contains package-lock.json pattern"
else
  fail "missing package-lock.json pattern"
fi

# Test 4: Default list contains agent instruction patterns
echo -n "  Test 4: Default list contains agent instruction patterns... "
if echo "$result" | grep -q 'AGENTS\.md'; then
  pass "contains AGENTS.md pattern"
else
  fail "missing AGENTS.md pattern"
fi

# Test 5: Per-project override replaces the tracked default
echo -n "  Test 5: Per-project override replaces the tracked default... "
mkdir -p "$STATE/test-project/config"
echo "*.sh" > "$STATE/test-project/config/protected-paths"
result=$(fm_protected_paths_list "$STATE/test-project")
if [ "$result" = "*.sh" ]; then
  pass "per-project override replaces global"
else
  fail "per-project override did not replace global (got: $result)"
fi

# Test 6: Missing per-project file falls back to the tracked default
echo -n "  Test 6: Missing per-project file falls back to the tracked default... "
mkdir -p "$STATE/test-project2"
result=$(fm_protected_paths_list "$STATE/test-project2")
if [ -n "$result" ]; then
  pass "falls back to global when per-project file missing"
else
  fail "did not fall back to global"
fi

echo ""
echo "=== Test: fm_protected_paths_check ==="

# Test 7: Protected path is detected
echo -n "  Test 7: Protected path is detected... "
diff_file=$(mktemp "${TMPDIR:-/tmp}/fm-test-diff.XXXXXX")
printf '%s\n' '.github/workflows/ci.yml' > "$diff_file"
result=$(fm_protected_paths_check "$diff_file")
rm -f "$diff_file"
if [ -n "$result" ]; then
  pass "detected protected path"
else
  fail "did not detect protected path"
fi

# Test 8: Non-protected path is not detected
# Use a project with empty protected-paths to test non-protected paths
echo -n "  Test 8: Non-protected path is not detected... "
mkdir -p "$STATE/empty-protected-project/config"
: > "$STATE/empty-protected-project/config/protected-paths"
diff_file=$(mktemp "${TMPDIR:-/tmp}/fm-test-diff.XXXXXX")
printf '%s\n' 'src/utils/helper.js' > "$diff_file"
result=$(fm_protected_paths_check "$diff_file" "$STATE/empty-protected-project") || true
rm -f "$diff_file"
if [ -z "$result" ]; then
  pass "did not flag non-protected path"
else
  fail "incorrectly flagged non-protected path: $result"
fi

# Test 9: Multiple protected paths are detected
echo -n "  Test 9: Multiple protected paths are detected... "
diff_file=$(mktemp "${TMPDIR:-/tmp}/fm-test-diff.XXXXXX")
printf '%s\n' '.github/workflows/ci.yml' > "$diff_file"
printf '%s\n' 'package-lock.json' >> "$diff_file"
printf '%s\n' 'src/utils/helper.toml' >> "$diff_file"
result=$(fm_protected_paths_check "$diff_file" || true)
rm -f "$diff_file"
if echo "$result" | grep -q '\.github/workflows/ci\.yml' && \
   echo "$result" | grep -q 'package-lock\.json'; then
  pass "detected multiple protected paths"
else
  fail "did not detect all protected paths (got: $result)"
fi

# Test 10: Non-protected path among protected paths is excluded
echo -n "  Test 10: Non-protected path among protected paths is excluded... "
diff_file=$(mktemp "${TMPDIR:-/tmp}/fm-test-diff.XXXXXX")
printf '%s\n' '.github/workflows/ci.yml' > "$diff_file"
printf '%s\n' 'src/utils/helper.toml' >> "$diff_file"
printf '%s\n' 'README.md' >> "$diff_file"
result=$(fm_protected_paths_check "$diff_file" || true)
rm -f "$diff_file"
if echo "$result" | grep -q '\.github/workflows/ci\.yml' && \
   ! echo "$result" | grep -q 'README\.md' && \
   ! echo "$result" | grep -q 'src/utils/helper\.toml'; then
  pass "excluded non-protected path"
else
  fail "incorrectly included or excluded paths (got: $result)"
fi

echo ""
echo "=== Test: Second-look verdict storage ==="

# Test 11: Verdict directory creation
echo -n "  Test 11: Verdict directory creation... "
verdict_dir=$(fm_second_look_verdict_dir "$STATE" "test-task" "123")
if [ -d "$verdict_dir" ]; then
  pass "verdict directory created"
else
  fail "verdict directory not created"
fi

# Test 12: Write and read clean verdict
echo -n "  Test 12: Write and read clean verdict... "
fm_second_look_write_verdict "$verdict_dir" "clean" "abc123"
verdict=$(fm_second_look_read_verdict "$verdict_dir")
if [ "$verdict" = "clean" ]; then
  pass "wrote and read clean verdict"
else
  fail "expected clean, got: $verdict"
fi

# Test 13: Write and read defect verdict
echo -n "  Test 13: Write and read defect verdict... "
fm_second_look_write_verdict "$verdict_dir" "defect" "def456" "found a bug"
verdict=$(fm_second_look_read_verdict "$verdict_dir")
if [ "$verdict" = "defect" ]; then
  pass "wrote and read defect verdict"
else
  fail "expected defect, got: $verdict"
fi

# Test 14: Defect verdict is read correctly
echo -n "  Test 14: Defect verdict is read correctly... "
verdict=$(fm_second_look_read_verdict "$verdict_dir")
if [ "$verdict" = "defect" ]; then
  pass "defect verdict read correctly"
else
  fail "expected defect, got: $verdict"
fi

# Test 15: Clean verdict overwrites and is read
echo -n "  Test 15: Clean verdict overwrites and is read... "
fm_second_look_write_verdict "$verdict_dir" "clean" "ghi789"
verdict=$(fm_second_look_read_verdict "$verdict_dir")
if [ "$verdict" = "clean" ]; then
  pass "clean verdict overwrites and is read"
else
  fail "expected clean, got: $verdict"
fi

# Test 16: Unsure verdict overwrites clean and is read
echo -n "  Test 16: Unsure verdict overwrites clean... "
fm_second_look_write_verdict "$verdict_dir" "unsure" "jkl012"
verdict=$(fm_second_look_read_verdict "$verdict_dir")
if [ "$verdict" = "unsure" ]; then
  pass "unsure verdict overwrites clean and is read"
else
  fail "expected unsure, got: $verdict"
fi

# Test 17: Clean verdict overwrites unsure and is read
echo -n "  Test 17: Clean verdict overwrites unsure... "
fm_second_look_write_verdict "$verdict_dir" "clean" "mno345"
verdict=$(fm_second_look_read_verdict "$verdict_dir")
if [ "$verdict" = "clean" ]; then
  pass "clean verdict overwrites unsure and is read"
else
  fail "expected clean, got: $verdict"
fi

# Test 18 (was 14): Stale-head verdict is not read by runner
echo -n "  Test 18: Stale-head verdict is not read by runner... "
# Write verdict for PR 999 with head A
verdict_dir_999=$(fm_second_look_verdict_dir "$STATE" "test-task" "999")
mkdir -p "$verdict_dir_999" 2>/dev/null
fm_second_look_write_verdict "$verdict_dir_999" "clean" "head_a_sha"
# Runner with same PR but different head should NOT print "clean" (head binding)
output=$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/../bin/fm-second-look.sh" --task-id "test-task" \
    --pr-url "https://github.com/test/repo/pull/999" \
    --head "head_b_sha" 2>/dev/null) || true
if [ "$output" != "clean" ]; then
  pass "runner ignores stale-head verdict (head binding works)"
else
  fail "runner should not print 'clean' for stale head, got '$output'"
fi

# Test 19: Invalid verdict is rejected
echo -n "  Test 19: Invalid verdict is rejected... "
if ! fm_second_look_write_verdict "$verdict_dir" "invalid" "pqr678" 2>/dev/null; then
  pass "invalid verdict rejected"
else
  fail "invalid verdict was not rejected"
fi

# Test 20: No verdict returns failure
echo -n "  Test 20: No verdict returns failure... "
mkdir -p "$STATE/empty-verdict-dir"
if ! fm_second_look_read_verdict "$STATE/empty-verdict-dir"; then
  pass "no verdict returns failure"
else
  fail "no verdict did not return failure"
fi

# Test 21: Stuck reason is reported for defect
echo -n "  Test 21: Stuck reason is reported for defect... "
fm_second_look_write_verdict "$verdict_dir" "defect" "stu901" "found a critical bug"
reason=$(fm_second_look_get_stuck_reason "$verdict_dir")
if echo "$reason" | grep -q "defect" && echo "$reason" | grep -q "critical bug"; then
  pass "stuck reason includes defect and reason"
else
  fail "stuck reason incorrect (got: $reason)"
fi

echo ""
echo "=== Test Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
