#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-gate-override.sh (GATE-O6, GATE-O7).
#
# The shell helper owns the status readout and the scripted off. The window
# itself opens only through the extension's operator-facing /jev-override
# command, so the helper has no "on" verb to test - these rows cover the
# helper-level half of the O suite (plan v2 §12.9); the wiring half lives in
# tests/fm-primary-turnend-guard-jev-wiring.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-jev-gate-override)
FIX_HOME="$TMP_ROOT/home"
FIX_BIN="$FIX_HOME/bin"
FIX_STATE="$TMP_ROOT/state"
HELPER="$ROOT/bin/fm-jev-gate-override.sh"
TRANSPORT_SRC="$ROOT/bin/fm-jev-pretool-check.sh"
POLICY_SRC="$ROOT/bin/fm-jev-gate-policy.mjs"
BASE_PATH=$PATH

mkdir -p "$FIX_STATE"

# Build a fixture home with copies of the transport and policy plus a real
# git checkout, then drive real gate traffic through the transport so the
# status readout has genuine counters, events, and breaker state to show.
fm_git_init_commit "$FIX_HOME"
mkdir -p "$FIX_BIN" "$FIX_HOME/config"
cp "$TRANSPORT_SRC" "$FIX_BIN/"
cp "$POLICY_SRC" "$FIX_BIN/"
printf 'enforce\n' > "$FIX_HOME/config/jev-gate"

FAKE_SCREENER="$TMP_ROOT/fake-screener.sh"
cat > "$FAKE_SCREENER" <<'SH'
#!/usr/bin/env bash
printf 'command:\n  status: clear\n  choice: benign\n  confidence: 0.9\n  latency_ms: 12\n  tokens: 100/20\n'
SH
chmod +x "$FAKE_SCREENER"

gt() {  # gt <command-text>: one real transport run from the fixture home
  (cd "$FIX_HOME" && printf '%s' "$1" | \
    env FM_HOME="$FIX_HOME" FM_STATE_OVERRIDE="$FIX_STATE" \
      FM_JEV_COMMAND_SCREENER="$FAKE_SCREENER" \
      "$FIX_BIN/fm-jev-pretool-check.sh" >/dev/null 2>&1)
}

helper() {  # helper <args...>: the override readout against the fixture state
  FM_HOME="$FIX_HOME" FM_STATE_OVERRIDE="$FIX_STATE" "$HELPER" "$@"
}

echo "1..2"

# GATE-O6: `off` with no window open is an idempotent no-op that exits 0.
{
  set +e
  helper off > "$TMP_ROOT/o6a" 2>&1
  code_a=$?
  helper off > "$TMP_ROOT/o6b" 2>&1
  code_b=$?
  set -e
  expect_code 0 "$code_a" "GATE-O6 first off exit"
  expect_code 0 "$code_b" "GATE-O6 second off exit"
  pass "GATE-O6: off without a window is an idempotent no-op"
}

# GATE-O7: status after known traffic prints the window state (closed), the
# counters, the breaker state, the chain-verification result, and the
# false-block proxy line.
{
  gt 'rm -rf /'
  gt 'rm -rf /etc'
  gt 'ls -la'
  status_out=$(helper status 2>&1)
  status_code=$?
  expect_code 0 "$status_code" "GATE-O7 status exit"
  assert_contains "$status_out" "closed" "GATE-O7 window closed"
  assert_contains "$status_out" "block_regex" "GATE-O7 counters shown"
  assert_contains "$status_out" "breaker" "GATE-O7 breaker state"
  assert_contains "$status_out" "chain" "GATE-O7 chain verification"
  assert_contains "$status_out" "false-block proxy" "GATE-O7 proxy line"
  pass "GATE-O7: status shows window, counters, breaker, chain, proxy"
}

echo "All tests complete."
