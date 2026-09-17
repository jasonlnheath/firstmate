#!/usr/bin/env bash
# Behavior tests for the Pi/pi-signed crewmate/scout launch hardening ported
# from the Claude adapter (bin/fm-spawn.sh launch_template, the seeded agent
# dir, and the post-launch gate):
#   1. A crewmate launch carries the three suppression variables
#      (PI_TELEMETRY=0, PI_OFFLINE=1, PI_SKIP_VERSION_CHECK=1), the isolated
#      PI_CODING_AGENT_DIR, --approve for per-run project trust, the
#      first-party task-channel statement through --append-system-prompt, and
#      the -e worker extension.
#   2. The seeded agent dir is created under state/ with auth.json symlinked
#      to the operator's own auth store and a telemetry-off settings.json,
#      and a missing or empty operator store refuses the launch before any
#      endpoint exists.
#   3. The post-launch gate passes when no project-trust dialog renders and
#      the busy classifier confirms the submitted brief, answers a rendered
#      dialog exactly once and then requires extension-confirmed busy, and
#      fails with endpoint cleanup when the dialog never clears.
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

# The spawn and its gate read pane state through node-free shell only, but the
# fake tmux writes busy records through bin/fm-busy-event.sh (a bash script),
# so PATH must carry a shell world. Carry the invoking node dir for parity with
# the fm-kimi-harness shape.
NODE_BIN=$(command -v node) || fail "test needs node"
NODE_BIN_DIR=$(dirname "$NODE_BIN")
BASE_PATH=${FM_TEST_BASE_PATH:-$NODE_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}

make_pi_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  send-keys)
    literal=
    prev=
    for a in "$@"; do
      if [ "$prev" = "-l" ]; then literal=$a; break; fi
      prev=$a
    done
    if [ -n "$literal" ]; then
      printf '%s\n' "$*" >> "${FM_FAKE_TMUX_CALL_LOG:-/dev/null}"
      case "$literal" in
        *--append-system-prompt*)
          printf '%s\n' "$literal" >> "${FM_FAKE_LAUNCH_LOG:?FM_FAKE_LAUNCH_LOG unset}"
          # Pi boots after the launch line lands; the dialog (when the run is
          # modeled as untrusted) only paints once the TUI is up, so the
          # submit Enter below must not answer it.
          if [ "${FM_FAKE_PI_TRUST:-clear}" = dialog ]; then
            printf 'booting\n' > "$FM_FAKE_PI_STATE"
          else
            printf 'launched\n' > "$FM_FAKE_PI_STATE"
          fi
          ;;
      esac
      exit 0
    fi
    printf '%s\n' "$*" >> "${FM_FAKE_TMUX_CALL_LOG:-/dev/null}"
    case " $* " in
      *' Enter '*)
        state=$(cat "$FM_FAKE_PI_STATE" 2>/dev/null || true)
        case "$state" in
          booting)
            # The TUI came up: the trust dialog is now on screen.
            printf 'dialog\n' > "$FM_FAKE_PI_STATE"
            ;;
          dialog)
            if [ "${FM_FAKE_PI_ANSWER:-works}" = works ]; then
              # The answered trust dialog lets pi submit the brief; the real
              # worker extension then proves the run started. Simulate that
              # proof exactly the way the real extension writes it: through
              # the real writer with the gen embedded in the generated
              # extension file.
              ext=$(sed -n "s/.*-e '\([^']*\.pi-ext\.ts\)'.*/\1/p" "$FM_FAKE_LAUNCH_LOG" | head -1)
              if [ -n "$ext" ] && [ -f "$ext" ]; then
                gen=$(sed -n 's/.*"--gen", "\([^"]*\)".*/\1/p' "$ext" | head -1)
                "$FM_TEST_FMROOT/bin/fm-busy-event.sh" apply \
                  "$(dirname "$ext")" "$(basename "$ext" .pi-ext.ts)" busy --gen "$gen" \
                  --source pi-ext --event agent-start >> "${FM_FAKE_PI_STATE}.applylog" 2>&1
              fi
              printf 'launched\n' > "$FM_FAKE_PI_STATE"
            fi
            ;;
        esac
        ;;
    esac
    exit 0
    ;;
  capture-pane)
    state=$(cat "$FM_FAKE_PI_STATE" 2>/dev/null || true)
    case "$state" in
      dialog)
        printf '────────────\n Project trust\n %s\n Saved decision: none\n Current session: untrusted\n → Trust\n   Trust parent folder (/)\n   Do not trust\n ↑↓ navigate  Enter save  Esc cancel\n────────────\n' "$FM_FAKE_PANE_PATH"
        ;;
      launched)
        printf 'Welcome to Pi.\n Type a message\n'
        ;;
      *)
        printf 'shell starting\n$ \n'
        ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/pi" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ]; then
  printf '%s\n' 'pi 0.85.1' 'Options: --help --tui-mode <mode> --approve, -a --append-system-prompt <text> --offline'
  exit 0
fi
echo "fake pi must never execute" >&2
exit 9
SH
  chmod +x "$fakebin/pi"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
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
  # case deletes it to prove the fail-closed refusal.
  mkdir -p "$home/user-home/.pi/agent"
  printf '%s\n' '{"test-provider":{"type":"api","key":"fm-test-key"}}' \
    >"$home/user-home/.pi/agent/auth.json"
  : > "$case_dir/launch.log"
  : > "$case_dir/tmux-calls.log"
  printf 'launched\n' > "$case_dir/pi.state"
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
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_PI_STATE="$case_dir/pi.state" \
    FM_FAKE_PI_TRUST="${FM_FAKE_PI_TRUST:-clear}" \
    FM_FAKE_PI_ANSWER="${FM_FAKE_PI_ANSWER:-works}" \
    FM_PI_READY_POLLS=4 FM_PI_POLL_INTERVAL=0 \
    FM_TEST_FMROOT="$ROOT" \
    PI_CODING_AGENT_DIR='' \
    HOME="$home/user-home" \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --harness pi --mode no-mistakes --yolo off "$@" 2>&1
}

enters_after_launch() {  # <tmux-call-log>
  # The spawn types treehouse get, two exports, the launch literal, and one
  # submit Enter before the gate runs; any Enter past that submit is a
  # gate-generated dialog answer.
  sed -n '/--append-system-prompt/,$p' "$1" | grep 'Enter' | tail -n +2 | wc -l
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
  assert_contains "$launch" "PI_OFFLINE=1" "pi launch did not disable startup network operations"
  assert_contains "$launch" "PI_SKIP_VERSION_CHECK=1" "pi launch did not disable the version check"
  assert_contains "$launch" "PI_CODING_AGENT_DIR=" "pi launch did not isolate the worker's agent dir"
  assert_contains "$launch" "--approve" "pi launch did not grant per-run project trust"
  assert_contains "$launch" "--append-system-prompt" "pi launch did not carry the task-channel statement"
  assert_contains "$launch" "first-party task instructions" "the task-channel statement lost its two-channel wording"
  assert_contains "$launch" "does not grant merge, destructive, security-sensitive" "the task-channel statement lost its authority disclaimer"
  assert_contains "$launch" "-e '$HOME_DIR/state/$id.pi-ext.ts'" "pi launch did not carry its worker extension"
  assert_not_contains "$launch" "__PI" "pi launch left a Pi placeholder unsubstituted"
  assert_not_contains "$launch" "__MODELFLAG__" "pi launch left its model placeholder unsubstituted"
  # The seed dir: auth symlink to the throwaway operator store, telemetry-off
  # settings, and nothing else written.
  seed="$HOME_DIR/state/pi-worker-agent"
  assert_present "$seed/auth.json" "pi seed did not link an auth store"
  [ -L "$seed/auth.json" ] || fail "pi seed auth.json must be a symlink, never a secret copy"
  [ "$(readlink "$seed/auth.json")" = "$HOME_DIR/user-home/.pi/agent/auth.json" ] \
    || fail "pi seed auth.json must point at the operator's own store"
  [ "$(cat "$seed/settings.json")" = '{"enableInstallTelemetry":false}' ] \
    || fail "pi seed settings.json must be the minimal telemetry-off seed"
  pass "fm-spawn: pi crewmate launch carries suppression, isolation, trust grant, task-channel statement, and a seeded agent dir"
}

test_pi_seed_fails_closed_without_operator_credentials() {
  local id rec out rc
  id="pi-noauth-z1-$$"
  rec=$(make_pi_spawn_case noauth "$id")
  read_pi_spawn_record "$rec"
  rm -f "$HOME_DIR/user-home/.pi/agent/auth.json"
  out=$(run_pi_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 1 "$rc" "a missing operator Pi auth store must refuse the launch"
  assert_contains "$out" "no Pi credentials" "the refusal must name the missing store"
  [ -e "$HOME_DIR/state/$id.meta" ] && fail "a refused launch must not publish task metadata"
  [ -s "$CASE_DIR/launch.log" ] && fail "a refused launch must never compose a launch command"
  pass "fm-spawn: pi crewmate launch refuses when the operator auth store is missing"
}

test_pi_gate_accepts_the_dialog_free_path_on_a_single_enter() {
  local id rec out rc enters
  id="pi-clear-z1-$$"
  rec=$(make_pi_spawn_case clear "$id")
  read_pi_spawn_record "$rec"
  out=$(run_pi_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "the dialog-free path should pass the gate: $out"
  enters=$(enters_after_launch "$CASE_DIR/tmux-calls.log")
  [ "$enters" -eq 0 ] || fail "the dialog-free path must answer nothing, sent $enters Enters"
  pass "fm-spawn: pi gate passes the --approve path without answering anything"
}

test_pi_gate_answers_a_rendered_dialog_once_then_requires_extension_proof() {
  local id rec out rc enters verdict
  id="pi-dialog-z1-$$"
  rec=$(make_pi_spawn_case dialog "$id")
  read_pi_spawn_record "$rec"
  out=$(FM_FAKE_PI_TRUST=dialog run_pi_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "an answered dialog followed by a running turn should pass: $out"
  enters=$(enters_after_launch "$CASE_DIR/tmux-calls.log")
  [ "$enters" -eq 1 ] || fail "a rendered dialog must be answered exactly once, post-launch Enters sent: $enters"
  verdict=$(fm_busy_classify tmux fake:w pi "$id" "$HOME_DIR/state")
  [ "$verdict" = "busy pi-ext" ] \
    || fail "the post-dialog pass must rest on extension-confirmed busy, got '$verdict'"
  pass "fm-spawn: pi gate answers a rendered trust dialog once and requires extension-confirmed busy"
}

test_pi_gate_fails_and_cleans_up_when_the_dialog_never_clears() {
  local id rec out rc
  id="pi-stuck-z1-$$"
  rec=$(make_pi_spawn_case stuck "$id")
  read_pi_spawn_record "$rec"
  out=$(FM_FAKE_PI_TRUST=dialog FM_FAKE_PI_ANSWER=stuck run_pi_spawn "$CASE_DIR" "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 1 "$rc" "a dialog that never clears must fail the spawn"
  assert_contains "$out" "did not start processing its brief after the project-trust dialog was answered" \
    "the failure must name the answered-dialog wedge"
  assert_grep "failed: pi did not start processing its brief" "$HOME_DIR/state/$id.status" \
    "the failed gate must append a failed status event"
  pass "fm-spawn: pi gate fails the spawn with a status event when the trust dialog wedges"
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
test_pi_gate_accepts_the_dialog_free_path_on_a_single_enter
test_pi_gate_answers_a_rendered_dialog_once_then_requires_extension_proof
test_pi_gate_fails_and_cleans_up_when_the_dialog_never_clears
test_pi_crewmate_launch_never_strips_project_reach

echo "all fm-pi-harness tests passed"
