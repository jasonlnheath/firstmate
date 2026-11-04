# Evidence index — fm/firstmate-ci-rig-portability (base 80b4be38 → target 38e88ca5)

Every lane was driven on the validation host, which reproduces the rig's hostile
conditions exactly: `LANG=en_US.UTF-8` with `LC_ALL` unset (en_US collation
disagrees with `LC_ALL=C` on names like `fm-lint.test.sh` vs
`fm-lint-workflows.test.sh`), a mise `codex` shim that answers `command -v` but
exits nonzero on `--version`, no `/usr/bin/time`, and a systemd --user manager
(a subreaper) in the process ancestry. Base-commit adversarial runs used a
standalone `git archive 80b4be38` tree in /tmp (removed after the run).

| # | Scenario | Target | Base (adversarial) |
|---|----------|--------|--------------------|
| S1 | Coverage guard (`bin/fm-test-run.sh --check-coverage`) under the rig locale | `s1-coverage-guard-target-rig-locale.log`: `FM_TEST_COVERAGE ok total=296 ... parallel_unhinted=0 serial_unhinted=24`, rc=0 | `s1-coverage-guard-base-rig-locale.err`: `comm: file 2 is not in sorted order` + `comm: input is not in sorted order`, rc=1 — the exact rig failure the intent cites |
| S2 | fm-test-run contract tests (`tests/fm-test-run.test.sh`) under the rig locale | runs 1-3 green (`s2-fm-test-run-target-run{1,2,3}.log`, failed=0 ×3; nondeterminism class re-driven) | `s2-fm-test-run-base.log`: `comm: file 2 is not in sorted order`, failed=1 — the review-fix sibling at lines 28-29 |
| S3 | Tier recalibration policy (`tests/fm-ci-workflow.test.sh`, parses ci.yml with ruby) | `s3-ci-workflow-policy-target.log`: "normal tier jobs share one 45 minute budget", "serial tier jobs share one 60 minute budget", rc=0 | `s3-ci-workflow-base-policy-vs-target-workflow.log`: base policy vs new workflow → `not ok - normal tier must be the single 30-minute shared budget, got 45`, rc=1 — policy and workflow are enforced bidirectionally |
| S4 | t3code guard vs the rig's broken codex shim (`tests/fm-backend-t3code.test.sh`) | `s4-t3code-target.log`: green with `skip: live: codex not runnable (a PATH entry answered but --version failed)`; `s4-t3code-target-explicit-request.log`: `FM_T3_CODEX_CONFIG_LIVE=1` → `not ok - FM_T3_CODEX_CONFIG_LIVE was requested but codex is not runnable` (loud, rc=1) | `s4-t3code-base.log`: `subprocess.CalledProcessError: Command '['codex', '--version']' returned non-zero exit status 1` → `not ok - installed Codex failed the tracked configuration guard`, rc=1 |
| S5 | fm-lint memory-retry test on a host without `/usr/bin/time` (`tests/fm-lint.test.sh`) | `s5-fm-lint-target.log`: green, failed=0 (unbounded mode only) | `s5-fm-lint-base.log`: `not ok - the fallback attempts lost per-root RSS reporting: unavailable`, rc=1 |
| S6 | session-lock recycled chain under a subreaper (`tests/fm-session-lock-ancestry.test.sh`) | `s6-session-lock-target.log`: 28/28 ok, rc=0 (orphan accepted under the live user-manager subreaper) | `s6-session-lock-base.log`: `not ok - the pty-host was not reparented to init after the daemon ended`, rc=1 |
| S7 | supervision-host bounded-turn budget (`wait_until 600` changed line) | `s7-supervision-host-target-isolated.log` line 99: `ok - host: an engine turn is bounded, and tool processes outside its process group are reaped` — the changed assertion ran and passed live. The file cannot complete on this host at EITHER commit (see note below) | `s7-supervision-host-base-isolated.log`: same file, same later failure point — pre-existing, host-specific |
| S8 | Backlog read bound honors the workflow's shard env | `s8-backlog-read-bound-target.log`: suite green; `s8-backlog-bound-env-drive.log`: direct drive of `fm_backlog_row_probe` — default → rc=124 at 10s, `FM_BACKLOG_ROW_TIMEOUT_SECS=30` → rc=124 at 30s | n/a (new env; default behavior unchanged) |
| S9 | Docs audience classification for the two bootcamp reports | `s9-doc-audience-check-target.log`: `fm-doc-audience-check: ok surfaces=138 local_links=1056`, rc=0; `s9-documentation-audiences-test-target.log`: serial-lane suite green | `s9-doc-audience-check-base.log`: `unclassified: docs/tasks/bootcamp-3finger-middleclick-report.md, docs/tasks/bootcamp-hibernate-auto-report.md`, rc=1 |
| S10 | CI lint partitions at the tip, exactly as CI runs them (pinned ShellCheck 0.11.0 + actionlint 1.7.12 in /tmp, `FM_LINT_REQUIRE_BOUNDS=1 FM_LINT_JOBS=1 --partition Nof2`) | `s10-lint-partition-1-target.log` (269 roots) and `s10-lint-partition-2-target.log`: both `fm-lint-workflows.sh: 3 workflow files valid`, EXIT=0 | n/a |

Note on S7: `tests/fm-supervision-host.test.sh` dies at
`test_host_outside_the_lock_owner_stands_down` ("supervision-host stood down:
this session does not own supervision") on this host at base AND target, in
isolation and under load, and under load the two runs additionally failed at
two different earlier timing-sensitive assertions. The changed line sits
before that point and passed live in the isolated target run. CI runs this
file on dedicated ubuntu-latest hosted runners ("no two stateful scripts share
a machine"), where it passes; this host-specific later failure predates the
change and is not implicated by it.
