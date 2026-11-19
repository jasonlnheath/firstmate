#!/usr/bin/env bash
# Tests for bin/fm-protected-paths-lib.sh (Lesson 1: merge-content gates)
#
# Run from the firstmate repo root:
#   bash tests/fm-protected-paths.test.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# Test 1: Global list exists
echo -n "  Test 1: Global protected-paths list exists... "
result=$(fm_protected_paths_list)
if [ -n "$result" ]; then
  pass "global list has $(echo "$result" | wc -l) patterns"
else
  fail "global list is empty"
fi

# Test 2: Global list contains CI patterns
echo -n "  Test 2: Global list contains CI patterns... "
if echo "$result" | grep -q '\.github/workflows/\*\.yml'; then
  pass "contains .github/workflows pattern"
else
  fail "missing .github/workflows pattern"
fi

# Test 3: Global list contains lockfile patterns
echo -n "  Test 3: Global list contains lockfile patterns... "
if echo "$result" | grep -q 'package-lock\.json'; then
  pass "contains package-lock.json pattern"
else
  fail "missing package-lock.json pattern"
fi

# Test 4: Global list contains agent instruction patterns
echo -n "  Test 4: Global list contains agent instruction patterns... "
if echo "$result" | grep -q 'AGENTS\.md'; then
  pass "contains AGENTS.md pattern"
else
  fail "missing AGENTS.md pattern"
fi

# Test 5: Per-project override replaces global
echo -n "  Test 5: Per-project override replaces global... "
mkdir -p "$STATE/test-project/config"
echo "*.sh" > "$STATE/test-project/config/protected-paths"
result=$(fm_protected_paths_list "$STATE/test-project")
if [ "$result" = "*.sh" ]; then
  pass "per-project override replaces global"
else
  fail "per-project override did not replace global (got: $result)"
fi

# Test 6: Missing per-project file falls back to global
echo -n "  Test 6: Missing per-project file falls back to global... "
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
> "$STATE/empty-protected-project/config/protected-paths"
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
   echo "$result" | grep -q 'README\.md' && \
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

# Test 14: Stuck defect verdict blocks new non-clean verdict
echo -n "  Test 14: Stuck defect verdict blocks new non-clean verdict... "
# After Test 13, verdict is 'defect'. Passing 'unsure' should be blocked.
if ! fm_second_look_verdict_sticks "$verdict_dir" "unsure"; then
  pass "stuck defect blocks new non-clean verdict"
else
  fail "stuck defect should block new non-clean verdict"
fi

# Test 15: Clean verdict clears stuck verdict
echo -n "  Test 15: Clean verdict clears stuck verdict... "
fm_second_look_write_verdict "$verdict_dir" "clean" "ghi789"
if fm_second_look_verdict_sticks "$verdict_dir" "clean"; then
  pass "clean verdict clears stuck verdict"
else
  fail "clean verdict did not clear stuck verdict"
fi

# Test 16: Unsure verdict sticks
echo -n "  Test 16: Unsure verdict sticks... "
# After Test 15, verdict is 'clean'. Write 'unsure' first.
fm_second_look_write_verdict "$verdict_dir" "unsure" "jkl012"
# Passing 'unsure' should be blocked by the stuck unsure verdict.
if ! fm_second_look_verdict_sticks "$verdict_dir" "unsure"; then
  pass "unsure verdict sticks"
else
  fail "unsure verdict did not stick"
fi

# Test 17: Clean verdict clears unsure verdict
echo -n "  Test 17: Clean verdict clears unsure verdict... "
fm_second_look_write_verdict "$verdict_dir" "clean" "mno345"
if fm_second_look_verdict_sticks "$verdict_dir" "clean"; then
  pass "clean verdict clears unsure verdict"
else
  fail "clean verdict did not clear unsure verdict"
fi

# Test 18: Invalid verdict is rejected
echo -n "  Test 18: Invalid verdict is rejected... "
if ! fm_second_look_write_verdict "$verdict_dir" "invalid" "pqr678" 2>/dev/null; then
  pass "invalid verdict rejected"
else
  fail "invalid verdict was not rejected"
fi

# Test 19: No verdict returns failure
echo -n "  Test 19: No verdict returns failure... "
mkdir -p "$STATE/empty-verdict-dir"
if ! fm_second_look_read_verdict "$STATE/empty-verdict-dir"; then
  pass "no verdict returns failure"
else
  fail "no verdict did not return failure"
fi

# Test 20: Stuck reason is reported for defect
echo -n "  Test 20: Stuck reason is reported for defect... "
fm_second_look_write_verdict "$verdict_dir" "defect" "stu901" "found a critical bug"
reason=$(fm_second_look_get_stuck_reason "$verdict_dir")
if echo "$reason" | grep -q "defect" && echo "$reason" | grep -q "critical bug"; then
  pass "stuck reason includes defect and reason"
else
  fail "stuck reason incorrect (got: $reason)"
fi

echo ""
echo "=== Test: fm_protected_paths_check_diff ==="

# Test 21: Diff output with protected paths
echo -n "  Test 21: Diff output with protected paths... "
diff_output=$(mktemp "${TMPDIR:-/tmp}/fm-test-diff-output.XXXXXX")
printf 'M\t.github/workflows/ci.yml\nM\tsrc/utils/helper.toml\nM\tREADME.md\n' > "$diff_output"
result=$(cat "$diff_output" | fm_protected_paths_check_diff "$STATE")
rm -f "$diff_output"
if echo "$result" | grep -q '\.github/workflows/ci\.yml' && \
   echo "$result" | grep -q 'README\.md' && \
   ! echo "$result" | grep -q 'src/utils/helper\.toml'; then
  pass "diff check detected protected paths"
else
  fail "diff check incorrect (got: $result)"
fi

echo ""
echo "=== Test Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
