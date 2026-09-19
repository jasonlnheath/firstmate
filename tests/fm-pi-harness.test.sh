#!/usr/bin/env bash
# Behavior tests for the Pi/pi-signed crewmate/scout launch hardening ported
# from the Claude adapter (bin/fm-spawn.sh launch_template, the seeded agent
# dir, and the post-launch start gate):
#   1. A crewmate launch carries the two suppression variables
#      (PI_TELEMETRY=0, PI_SKIP_VERSION_CHECK=1) and never PI_OFFLINE, the isolated
#      PI_CODING_AGENT_DIR, --approve for per-run project trust, the
#      first-party task-channel statement through --append-system-prompt, and
#      the -e worker extension.
#   2. The seeded agent dir is created under state/ with auth.json symlinked
#      to the operator's own auth store and no settings.json of its own; the
#      operator's models.json and herdr-managed Pi integration are linked
#      across when present and dropped again when absent, re-established on
#      every launch; a launch with no credential source Pi could use for the
#      pinned provider (no entry for it in the operator store, no apiKey of
#      its own on it in models.json, no credential variable for it; the
#      Codex-authenticated codex-native provider exempt) refuses before any
#      endpoint or per-task state exists (state/<id>.pi-ext.ts is written
#      only after the window, so its absence is the evidence), and so does
#      a launch without a concrete <provider>/<id> model, because the seed
#      carries no saved default for Pi to fall back on and the credential
#      guard is scoped to the named provider.
#   3. The post-launch gate passes only on the worker extension's own busy
#      record: a worker that boots after the launch line passes once its
#      agent_start lands, and a worker that never starts fails the spawn with
#      a status event even though the spawn's own pre-launch seed reads busy;
#      that event carries the pane's last output, since the failure closes
#      the window nobody could inspect afterwards.
# The secondmate arm's opposite shape (suppression without the task-worker
# statement, isolation, or --approve) is pinned in
# tests/fm-secondmate-harness.test.sh, which owns the secondmate spawn world.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. Drop the
# ambient markers so the asserted verdicts do not depend on which harness
# launched the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  ATLASSIAN_AGENT_TYPE ROVODEV_CLI GEMINI_CLI AGENT FM_OMP_HARNESS

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-pi-harness)

# The spawn and its gate read busy state through node-free shell only, but the
# fake worker start writes busy records through bin/fm-busy-event.sh (a bash
# script), so PATH must carry a shell world. Carry the invoking node dir for
# parity with the fm-kimi-harness shape.
NODE_BIN=$(command -v node) || fail "test needs node"
NODE_BIN_DIR=$(dirname "$NODE_BIN")
BASE_PATH=${FM_TEST_BASE_PATH:-$NODE_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}

make_pi_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_test_make_spawn_fakebin "$dir" gh-axi gh)
  cat > "$fakebin/pi" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ]; then
  # Real Pi 0.85.1 initializes a missing agent dir even on --help: it writes
  # auth.json = {} and models-store.json = {} before printing usage, so the
  # spawn's TUI-mode probe leaves a never-authenticated operator with an
  # empty-but-present store by the time the seed guard runs.
  agent_dir="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
  mkdir -p "$agent_dir"
  for f in auth.json models-store.json; do
    [ -e "$agent_dir/$f" ] || printf '{}' >"$agent_dir/$f"
  done
  printf '%s\n' 'pi 0.85.1' 'Options: --help --tui-mode <mode> --approve, -a --append-system-prompt <text> --offline'
  exit 0
fi
echo "fake pi must never execute" >&2
exit 9
SH
  chmod +x "$fakebin/pi"
  printf '%s\n' "$fakebin"
}

make_pi_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_pi_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" pi
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  # The operator Pi auth store every real crewmate machine has; the noauth
  # case removes the whole agent dir to prove the fail-closed refusal on a
  # never-authenticated operator.
  mkdir -p "$home/user-home/.pi/agent"
  printf '%s\n' '{"test-provider":{"type":"api","key":"fm-test-key"}}' \
    >"$home/user-home/.pi/agent/auth.json"
  : > "$case_dir/launch.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_pi_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_pi_spawn() {
  local case_dir=$1 home=$2 wt=$3 fakebin=$4 id=$5
  shift 5
  local model=${FM_TEST_PI_MODEL-test-provider/fm-test}
  [ -z "$model" ] || set -- --model "$model" "$@"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_PI_START="${FM_FAKE_PI_START:-now}" \
    FM_PI_READY_POLLS="${FM_PI_READY_POLLS:-40}" FM_PI_POLL_INTERVAL=0.05 \
    PI_CODING_AGENT_DIR='' \
    HOME="$home/user-home" \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --harness pi --mode no-mistakes --yolo off "$@" 2>&1
}

test_pi_crewmate_launch_carries_the_ported_hardening() {
  local id rec out rc launch seed
  id="pi-hard-z1-$$"
  rec=$(make_pi_spawn_case launch "$id")
  read_pi_spawn_record "$rec"
  out=$(run_pi_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "pi crewmate spawn should succeed: $out"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "$FAKEBIN_DIR/pi" "pi launch did not pin the resolved absolute binary"
  assert_contains "$launch" "--tui-mode regular" "pi launch omitted the advertised regular-TUI override"
  assert_contains "$launch" "PI_TELEMETRY=0" "pi launch did not suppress install telemetry"
  assert_not_contains "$launch" "PI_OFFLINE" "pi launch must keep catalog refresh and tool download reachable; PI_OFFLINE exceeds the telemetry-suppression port"
  assert_contains "$launch" "PI_SKIP_VERSION_CHECK=1" "pi launch did not disable the version check"
  assert_contains "$launch" "PI_CODING_AGENT_DIR=" "pi launch did not isolate the worker's agent dir"
  assert_contains "$launch" "--approve" "pi launch did not grant per-run project trust"
  assert_contains "$launch" "--append-system-prompt" "pi launch did not carry the task-channel statement"
  assert_contains "$launch" "first-party task instructions" "the task-channel statement lost its two-channel wording"
  assert_contains "$launch" "does not grant merge, destructive, security-sensitive" "the task-channel statement lost its authority disclaimer"
  assert_contains "$launch" "-e '$HOME_DIR/state/$id.pi-ext.ts'" "pi launch did not carry its worker extension"
  assert_contains "$launch" "--model 'test-provider/fm-test'" "pi launch did not pin the requested model"
  assert_not_contains "$launch" "__PI" "pi launch left a Pi placeholder unsubstituted"
  assert_not_contains "$launch" "__MODELFLAG__" "pi launch left its model placeholder unsubstituted"
  # The seed dir: auth symlink to the throwaway operator store, no seeded
  # settings (PI_TELEMETRY=0 on the launch line owns telemetry), and no
  # provider catalog or herdr integration link when the operator has neither.
  seed="$HOME_DIR/state/pi-worker-agent"
  assert_present "$seed/auth.json" "pi seed did not link an auth store"
  [ -L "$seed/auth.json" ] || fail "pi seed auth.json must be a symlink, never a secret copy"
  [ "$(readlink "$seed/auth.json")" = "$HOME_DIR/user-home/.pi/agent/auth.json" ] \
    || fail "pi seed auth.json must point at the operator's own store"
  assert_absent "$seed/settings.json" "pi seed must not carry a settings.json; PI_TELEMETRY=0 on the launch line owns telemetry"
  assert_absent "$seed/models.json" "pi seed must not carry a models.json when the operator has none"
  assert_absent "$seed/extensions/herdr-agent-state.ts" \
    "pi seed must not carry a herdr integration the operator never installed"
  pass "fm-spawn: pi crewmate launch carries suppression, isolation, trust grant, task-channel statement, and a seeded agent dir"
}

test_pi_seed_fails_closed_without_operator_credentials() {
  local id rec out rc
  id="pi-noauth-z1-$$"
  rec=$(make_pi_spawn_case noauth "$id")
  read_pi_spawn_record "$rec"
  # A never-authenticated operator has no ~/.pi/agent at all; the spawn's own
  # `pi --help` probe then creates it with auth.json = {} (fake mirrors real
  # 0.85.1), which the seed guard must still treat as no credentials.
  rm -rf "$HOME_DIR/user-home/.pi/agent"
  out=$(run_pi_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 1 "$rc" "a never-authenticated operator Pi must refuse the launch"
  assert_contains "$out" "no Pi credentials" "the refusal must name the missing store"
  [ "$(cat "$HOME_DIR/user-home/.pi/agent/auth.json" 2>/dev/null)" = '{}' ] \
    || fail "the --help probe must have initialized an empty auth store before the guard ran"
  [ -e "$HOME_DIR/state/$id.meta" ] && fail "a refused launch must not publish task metadata"
  [ -e "$HOME_DIR/state/$id.pi-ext.ts" ] && fail "a credential refusal must land before any endpoint or per-task state exists"
  [ -s "$CASE_DIR/launch.log" ] && fail "a refused launch must never compose a launch command"
  pass "fm-spawn: pi crewmate launch refuses when the operator auth store is missing"
}

# auth.json is not Pi's only credential source (Pi 0.85.1 docs/models.md): a
# models.json provider may carry its own apiKey, a dummy literal for a
# keyless local server included, and a built-in provider may be keyed by
# its environment variable. Either lets the worker run when it keys the
# provider the pin names, so the fail-closed guard must stand aside for
# them and refuse only a pin nothing keys.
test_pi_seed_requires_the_auth_entry_for_the_pinned_provider() {
  local id rec out rc agent
  id="pi-authother-z1-$$"
  rec=$(make_pi_spawn_case authother "$id")
  read_pi_spawn_record "$rec"
  agent="$HOME_DIR/user-home/.pi/agent"
  printf '%s\n' '{"anthropic":{"type":"oauth","refresh":"r","access":"a","expires":0}}' >"$agent/auth.json"
  out=$(CEREBRAS_API_KEY='' FM_TEST_PI_MODEL=cerebras/fm-test run_pi_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 1 "$rc" "another provider's login must not key the pinned provider: $out"
  assert_contains "$out" "no Pi credentials" "the refusal must name the missing credentials"
  assert_contains "$out" "holds no cerebras entry" "the refusal must name the auth entry it looked for"
  [ -e "$HOME_DIR/state/$id.pi-ext.ts" ] && fail "a credential refusal must land before any endpoint or per-task state exists"
  [ -s "$CASE_DIR/launch.log" ] && fail "a refused launch must never compose a launch command"
  pass "fm-spawn: pi seed refuses when the auth store keys only another provider"
}

# The pi-codex-native adapter authenticates through the Codex App Server's
# own login and never reads Pi's auth store (the verified lab in
# tests/fm-pi-codex-native.test.sh runs it on an agent dir with none), so a
# codex-native pin is the one the guard must not gate.
test_pi_seed_exempts_codex_native_from_the_credential_guard() {
  local id rec out rc
  id="pi-codexnative-z1-$$"
  rec=$(make_pi_spawn_case codexnative "$id")
  read_pi_spawn_record "$rec"
  printf '{}' >"$HOME_DIR/user-home/.pi/agent/auth.json"
  out=$(FM_TEST_PI_MODEL=codex-native/gpt-6-astra run_pi_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --effort ultra)
  rc=$?
  expect_code 0 "$rc" "a codex-native pin must launch without a Pi auth entry: $out"
  assert_contains "$(cat "$CASE_DIR/launch.log")" "--model 'codex-native/gpt-6-astra'" "the launch must carry the native pin"
  pass "fm-spawn: pi seed leaves codex-native to the Codex login"
}

test_pi_seed_accepts_models_json_provider_with_its_own_api_key() {
  local id rec out rc agent
  id="pi-modelkey-z1-$$"
  rec=$(make_pi_spawn_case modelkey "$id")
  read_pi_spawn_record "$rec"
  agent="$HOME_DIR/user-home/.pi/agent"
  printf '{}' >"$agent/auth.json"
  printf '%s\n' '{"providers":{"flashnext":{"baseUrl":"http://127.0.0.1:8039/v1","api":"openai-completions","apiKey":"dummy","models":[{"id":"Qwen3.8-Flash-Next"}]}}}' \
    >"$agent/models.json"
  out=$(FM_TEST_PI_MODEL=flashnext/Qwen3.8-Flash-Next run_pi_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "a keyless-local dispatch keyed by its models.json apiKey must launch: $out"
  assert_contains "$(cat "$CASE_DIR/launch.log")" "--model 'flashnext/Qwen3.8-Flash-Next'" \
    "the launch must carry the custom-provider pin"
  pass "fm-spawn: pi seed lets a models.json provider's own apiKey stand in for an empty auth store"
}

test_pi_seed_refuses_models_json_provider_without_api_key() {
  local id rec out rc agent
  id="pi-modelnokey-z1-$$"
  rec=$(make_pi_spawn_case modelnokey "$id")
  read_pi_spawn_record "$rec"
  agent="$HOME_DIR/user-home/.pi/agent"
  printf '{}' >"$agent/auth.json"
  printf '%s\n' '{"providers":{"flashnext":{"baseUrl":"http://127.0.0.1:8039/v1","api":"openai-completions","models":[{"id":"Qwen3.8-Flash-Next"}]}}}' \
    >"$agent/models.json"
  out=$(FM_TEST_PI_MODEL=flashnext/Qwen3.8-Flash-Next run_pi_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 1 "$rc" "a custom provider with neither auth entry nor apiKey must refuse: $out"
  assert_contains "$out" "no Pi credentials" "the refusal must name the missing credentials"
  assert_contains "$out" "declares no flashnext provider with its own apiKey" "the refusal must name the models.json provider it checked"
  id="pi-modelotherkey-z1-$$"
  rec=$(make_pi_spawn_case modelotherkey "$id")
  read_pi_spawn_record "$rec"
  agent="$HOME_DIR/user-home/.pi/agent"
  printf '{}' >"$agent/auth.json"
  printf '%s\n' '{"providers":{"flashnext":{"baseUrl":"http://127.0.0.1:8039/v1","api":"openai-completions","apiKey":"dummy","models":[{"id":"Qwen3.8-Flash-Next"}]}}}' \
    >"$agent/models.json"
  out=$(CEREBRAS_API_KEY='' FM_TEST_PI_MODEL=cerebras/fm-test run_pi_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 1 "$rc" "another provider's models.json apiKey must not key the pinned provider: $out"
  assert_contains "$out" "declares no cerebras provider with its own apiKey" "the refusal must name the pinned provider it looked for"
  [ -s "$CASE_DIR/launch.log" ] && fail "a refused launch must never compose a launch command"
  pass "fm-spawn: pi seed still refuses a models.json provider that carries no apiKey"
}

test_pi_seed_accepts_env_credential_for_the_pinned_provider() {
  local id rec out rc agent
  id="pi-envkey-z1-$$"
  rec=$(make_pi_spawn_case envkey "$id")
  read_pi_spawn_record "$rec"
  agent="$HOME_DIR/user-home/.pi/agent"
  printf '{}' >"$agent/auth.json"
  out=$(CEREBRAS_API_KEY=fm-test-env FM_TEST_PI_MODEL=cerebras/fm-test run_pi_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "a pinned provider keyed by its environment variable must launch: $out"
  assert_contains "$(cat "$CASE_DIR/launch.log")" "--model 'cerebras/fm-test'" "the launch must carry the pin"
  pass "fm-spawn: pi seed lets the pinned provider's credential variable stand in for an empty auth store"
}

test_pi_seed_refuses_env_credential_that_is_unset_or_for_another_provider() {
  local id rec out rc agent
  id="pi-envnokey-z1-$$"
  rec=$(make_pi_spawn_case envnokey "$id")
  read_pi_spawn_record "$rec"
  agent="$HOME_DIR/user-home/.pi/agent"
  printf '{}' >"$agent/auth.json"
  out=$(CEREBRAS_API_KEY='' FM_TEST_PI_MODEL=cerebras/fm-test run_pi_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 1 "$rc" "an empty credential variable must not count: $out"
  assert_contains "$out" "CEREBRAS_API_KEY" "the refusal must name the variable Pi would have read"
  id="pi-envother-z1-$$"
  rec=$(make_pi_spawn_case envother "$id")
  read_pi_spawn_record "$rec"
  printf '{}' >"$HOME_DIR/user-home/.pi/agent/auth.json"
  out=$(CEREBRAS_API_KEY='' GROQ_API_KEY=fm-test-env FM_TEST_PI_MODEL=cerebras/fm-test run_pi_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 1 "$rc" "another provider's variable must not key the pinned provider: $out"
  assert_contains "$out" "no Pi credentials" "the refusal must name the missing credentials"
  [ -s "$CASE_DIR/launch.log" ] && fail "a refused launch must never compose a launch command"
  pass "fm-spawn: pi seed refuses when the pinned provider's credential variable is unset"
}

# Pi reads models.json from the agent dir only, so a seed without the
# operator's catalog would fail --model resolution for every custom-provider
# dispatch (a local llama-server, a proxy): Pi 0.85.1 exits 1 on that before
# the TUI, and the start gate would time out on the dead pane. The herdr-managed Pi integration is what reports
# agent_status to `herdr agent get`. Both are linked, never copied, and
# re-established on every launch so the seed tracks the operator's store.
test_pi_seed_links_operator_models_and_herdr_integration_per_launch() {
  local id id2 rec out rc seed agent
  id="pi-models-z1-$$"
  id2="pi-models-z2-$$"
  rec=$(make_pi_spawn_case models "$id")
  read_pi_spawn_record "$rec"
  agent="$HOME_DIR/user-home/.pi/agent"
  mkdir -p "$agent/extensions"
  printf '%s\n' '{"providers":{"local":{"baseUrl":"http://127.0.0.1:8036/v1","api":"openai-completions","models":[{"id":"local-model"}]}}}' \
    >"$agent/models.json"
  printf '%s\n' '// installed by herdr' '// HERDR_INTEGRATION_ID=pi' 'export default function () {}' \
    >"$agent/extensions/herdr-agent-state.ts"
  out=$(run_pi_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "pi crewmate spawn should succeed: $out"
  seed="$HOME_DIR/state/pi-worker-agent"
  [ -L "$seed/models.json" ] || fail "pi seed must link the operator's models.json, never copy it"
  [ "$(readlink "$seed/models.json")" = "$agent/models.json" ] \
    || fail "pi seed models.json must point at the operator's own catalog"
  [ "$(cat "$seed/models.json")" = "$(cat "$agent/models.json")" ] \
    || fail "the worker must read the operator's live provider catalog through the seed"
  [ -L "$seed/extensions/herdr-agent-state.ts" ] \
    || fail "pi seed must link the operator's herdr-managed Pi integration"
  [ "$(readlink "$seed/extensions/herdr-agent-state.ts")" = "$agent/extensions/herdr-agent-state.ts" ] \
    || fail "pi seed herdr integration must point at the herdr-managed file"

  # The operator removes both; the next launch must drop the links rather
  # than leave the worker on a stale catalog or a dangling extension.
  rm -f "$agent/models.json" "$agent/extensions/herdr-agent-state.ts"
  fm_test_spawn_brief "$HOME_DIR" "$id2"
  out=$(run_pi_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id2")
  rc=$?
  expect_code 0 "$rc" "second pi crewmate spawn should succeed: $out"
  [ ! -L "$seed/models.json" ] && [ ! -e "$seed/models.json" ] \
    || fail "pi seed must drop the models.json link once the operator has no catalog"
  [ ! -L "$seed/extensions/herdr-agent-state.ts" ] && [ ! -e "$seed/extensions/herdr-agent-state.ts" ] \
    || fail "pi seed must drop the herdr integration link once it is uninstalled"
  pass "fm-spawn: pi seed links the operator's models.json and herdr integration and re-establishes both per launch"
}

# The spawn arms busy/fm-spawn before it types the launch line, so a gate
# that accepted any trusted busy verdict would pass before Pi had even
# booted. A worker that comes up after the launch line and fires agent_start
# passes; the pass must rest on the extension's own record.
test_pi_gate_waits_for_the_worker_extension_start() {
  local id rec out rc verdict
  id="pi-start-z1-$$"
  rec=$(make_pi_spawn_case start "$id")
  read_pi_spawn_record "$rec"
  out=$(FM_FAKE_PI_START=delayed run_pi_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "a worker that boots and fires agent_start should pass the gate: $out"
  verdict=$(fm_busy_classify tmux fake:w pi "$id" "$HOME_DIR/state")
  [ "$verdict" = "busy pi-ext" ] \
    || fail "the gate's pass must rest on extension-confirmed busy, got '$verdict'"
  assert_contains "$out" "spawned $id" "a passed gate must report the spawn"
  pass "fm-spawn: pi gate waits past the pre-launch seed for the worker extension's agent_start"
}

# A Pi that dies on boot, parks on a diagnostic, or never fires agent_start
# leaves only the spawn's own seed behind; the seed must never count as
# proof of a started worker. The failure closes the window, so whatever Pi
# printed before dying (0.85.1 reports an unresolvable --model pin to the
# pane and exits 1 before the TUI) must survive on the status event, and
# nothing may point the operator at the window that no longer exists.
test_pi_gate_fails_when_the_worker_never_starts() {
  local id rec out rc status
  id="pi-dead-z1-$$"
  rec=$(make_pi_spawn_case dead "$id")
  read_pi_spawn_record "$rec"
  out=$(FM_FAKE_PI_START=never FM_PI_READY_POLLS=6 \
    FM_FAKE_PANE_CAPTURE=$'$ pi --model x/y\nError: Model "x/y" not found.\nAvailable models: none\n\n   ' \
    run_pi_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 1 "$rc" "a worker that never starts must fail the spawn"
  assert_contains "$out" "worker extension never reported agent_start" \
    "the failure must name the missing start proof"
  status=$(grep '^failed: pi did not start processing its brief' "$HOME_DIR/state/$id.status") \
    || fail "the failed gate must append a failed status event"
  [ "$(printf '%s\n' "$status" | wc -l)" -eq 1 ] || fail "the failed status event must stay one line"
  assert_contains "$status" 'last pane output: $ pi --model x/y|Error: Model "x/y" not found.|Available models: none' \
    "the failed status event must carry the pane's last output, blank lines dropped"
  assert_contains "$out" 'last pane output: $ pi --model x/y|Error: Model "x/y" not found.' \
    "the failure must report the pane's last output"
  assert_not_contains "$out" "inspect window" "the failure must not point at the window it closes"
  assert_not_contains "$out" "spawned $id" "a failed gate must never report the spawn"

  id="pi-dead-z2-$$"
  rec=$(make_pi_spawn_case dead-nocapture "$id")
  read_pi_spawn_record "$rec"
  out=$(FM_FAKE_PI_START=never FM_PI_READY_POLLS=6 FM_FAKE_PANE_CAPTURE='' \
    run_pi_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 1 "$rc" "a worker that never starts must fail the spawn"
  status=$(grep '^failed: pi did not start processing its brief' "$HOME_DIR/state/$id.status") \
    || fail "the failed gate must append a failed status event"
  assert_not_contains "$status" "last pane output" "an empty capture must not fabricate pane output"
  assert_not_contains "$out" "inspect window" "an empty capture must drop the inspect-window clause rather than misdirect"
  pass "fm-spawn: pi gate fails the spawn with a status event carrying the pane's last output"
}

# A bare id or id:level pattern is one Pi 0.85.1 would resolve against its
# own catalog, but it names no provider for the credential guard to scope
# to, so a crewmate/scout pin must be <provider>/<id>.
test_pi_worker_launch_refuses_without_a_concrete_model() {
  local id rec out rc model tag
  for model in '' default glm-5.3 sonnet:high; do
    tag=${model:-empty}; tag=${tag//:/-}
    id="pi-nomodel-$tag-z1-$$"
    rec=$(make_pi_spawn_case "nomodel-$tag" "$id")
    read_pi_spawn_record "$rec"
    out=$(FM_TEST_PI_MODEL="$model" run_pi_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
    rc=$?
    expect_code 1 "$rc" "a pi crewmate launch with model '${model:-<empty>}' must be refused: $out"
    assert_contains "$out" "config/crew-dispatch.json" "the refusal must name the dispatch pin as the fix"
    assert_contains "$out" "--model" "the refusal must name the explicit flag as the fix"
    assert_contains "$out" "<provider>/<id>" "the refusal must name the pin shape"
    [ -e "$HOME_DIR/state/$id.meta" ] && fail "a refused launch must not publish task metadata"
    [ -e "$HOME_DIR/state/$id.pi-ext.ts" ] && fail "a model refusal must land before any endpoint or per-task state exists"
    [ -s "$CASE_DIR/launch.log" ] && fail "a refused launch must never compose a launch command"
  done
  pass "fm-spawn: pi crewmate launch refuses when no concrete <provider>/<id> model resolves"
}

test_pi_crewmate_launch_never_strips_project_reach() {
  local id rec out rc launch
  id="pi-reach-z1-$$"
  rec=$(make_pi_spawn_case reach "$id")
  read_pi_spawn_record "$rec"
  out=$(run_pi_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "pi crewmate spawn should succeed: $out"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_not_contains "$launch" "--no-skills" "isolation must not disable skill discovery; project .agents/skills are reached through --approve"
  assert_not_contains "$launch" "--no-context-files" "isolation must not drop the project's own AGENTS.md"
  pass "fm-spawn: pi isolation never strips project context files or project skills"
}

test_pi_crewmate_launch_carries_the_ported_hardening
test_pi_seed_fails_closed_without_operator_credentials
test_pi_seed_requires_the_auth_entry_for_the_pinned_provider
test_pi_seed_exempts_codex_native_from_the_credential_guard
test_pi_seed_accepts_models_json_provider_with_its_own_api_key
test_pi_seed_refuses_models_json_provider_without_api_key
test_pi_seed_accepts_env_credential_for_the_pinned_provider
test_pi_seed_refuses_env_credential_that_is_unset_or_for_another_provider
test_pi_seed_links_operator_models_and_herdr_integration_per_launch
test_pi_gate_waits_for_the_worker_extension_start
test_pi_gate_fails_when_the_worker_never_starts
test_pi_worker_launch_refuses_without_a_concrete_model
test_pi_crewmate_launch_never_strips_project_reach

echo "all fm-pi-harness tests passed"
