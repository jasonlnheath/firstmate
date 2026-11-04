# Rig-portability fix: CI failure decode and local validation map

Base 80b4be38 -> target d7e49e40 (`fm/firstmate-ci-rig-portability`)

## What actually failed on PR 20 (run 41592126022) and what in the diff cures it

| Failing lane (PR 20 / PR 21) | Actual failing assertion (from CI log) | Root cause | Fix in this diff | Local validation |
|---|---|---|---|---|
| Test coverage guard (fail in 12s) | `comm: file 2 is not in sorted order` / `comm: input is not in sorted order` | guard sorted lists with `LC_ALL=C sort` but ran `comm` under the runner session's UTF-8 collation (`fm-backend.test.sh` vs `fm-backend-herdr.test.sh` order differently under en_US.UTF-8) | `LC_ALL=C comm` at every call in `bin/fm-test-run.sh` | BASE guard under `LANG=en_US.UTF-8`: exit 1 with the exact comm disorder abort; BASE under `LC_ALL=C`: exit 0; TARGET under `LANG=en_US.UTF-8`: exit 0 (`coverage-guard-base-utf8.log`, `coverage-guard-target-utf8.log`) |
| Behavior portable serial 1 (40m) | `not ok - hang: the bounded turn did not end` | `test_engine_turn_is_bounded_and_its_descendants_reaped` allowed the host-exit wait only 300 ticks; spawned-chain slowdown under hosted-runner load exceeded it | wait budget 300 -> 600 | full file run: the bounded-turn test passes (`supervision-host-file-run.log`: `ok - host: an engine turn is bounded, and tool processes outside its process group are reaped`) |
| Behavior portable serial 9 | `not ok - repository documentation audience check failed` | `docs/tasks/bootcamp-hibernate-auto-report.md` landed on main unclassified | entries added to `docs/documentation-audiences.json` | `bin/fm-doc-audience-check.sh` exit 0 (surfaces=138); adversarial: same check with the entry removed fails `unclassified: docs/tasks/bootcamp-hibernate-auto-report.md` (`doc-audience-minus-entry.log`) |
| Behavior portable parallel 1 | t3 live codex config guard | the rig's mise shim answers `command -v codex` but `codex --version` exits nonzero (`mise ERROR No version is set for shim: codex`); base function dies with `subprocess.CalledProcessError: Command '['codex', '--version']'` | `codex --version` usability check mirroring the gate's absent-binary skip; loud failure when explicitly requested | function-level before/after on the real shim (`t3-func-base-default.log` vs `t3-func-target-default.log`/`t3-func-target-live.log`); whole file run: 88 ok, 0 not-ok, skip line fired (`t3-file-run.log`) |
| Behavior portable parallel 2 | lint memory-failure test's mode-1 (per-root peak-RSS) assertions | mode 1 records RSS only through `/usr/bin/time`, which the Arch rig does not have; bounds-supported hosts ran and failed the bounded assertions | mode 1 now additionally requires `[ -x /usr/bin/time ]` | this host reproduces the rig: `/usr/bin/time` absent, bounds supported -> mode 0 alone; full lint file run 49 ok, 0 not-ok (`lint-file-run.log`) |
| Behavior portable serial 9 (subreaper class) | session-lock recycled-chain assertion required orphan ppid == 1 | the rig runner is a systemd --user service; its user manager is a child subreaper, so rig orphans reparent to it, never init | assertion accepts init or any live subreaper root | orphan probe on this host: an orphaned grandchild reparented to pid 1108 (systemd user manager), not 1; full session-lock file run 28 ok, 0 not-ok (`session-lock-file-run.log`) |
| Timing aggregate | downstream of the red lanes' missing timing artifacts | — | — | green on the target commit's CI run (see below) |
| Hosted-lane queueing 2.5-4h | normal tier packed past the old 30-min bound (Lint 1 28.3m in run 41694609235; Lint 2 cancelled at 30m), serial healthy duration up to ~50m on 2-core hosted | rig absorbed these lanes beside the fleet | normal tier 30 -> 45, serial tier 45 -> 60, policy tests updated | `tests/fm-ci-workflow.test.sh`: 12 ok incl. `normal tier jobs share one 45 minute budget`, `serial tier jobs share one 60 minute budget` (`ci-workflow-test.log`) |

## Two serial-lane files that cannot reach green from inside this gate worktree (pre-existing, not touched by the diff)

1. `tests/fm-turnend-foreign-owner-arm-fix.test.sh` (serial shard 9): its replacement-owner phase needs `fm-claude-stop-autoarm.sh` to arm the watcher, and `bin/fm-watch-arm.sh:193` deliberately refuses to arm from a disposable validation checkout unless the state lives in a lab-marked home. The repro symlinks its fixture `bin` to this gate worktree, so the arm is always refused here: `watcher: FAILED - refusing to arm from a disposable validation checkout: /tmp/.../nonowner/bin` (captured with a preserved-fixture diagnostic run). From CI's normal checkout the same commit passes it (run 41710979957, serial 9 green). The diff changes neither this test nor any product script it drives.
2. `tests/fm-supervision-host.test.sh` case `test_tagged_lock_holder_reaches_the_engine_whole`: the Windows-tagged lock path engages only when the host process has no real harness ancestry. Inside this gate session the ancestry contains the driving Claude process (`fm_harness_ancestry_pids` = 1346082), so `fm_session_lock_owned_by_self` is NO and the fixture host stands down. Detached via `setsid` (CI-like ancestry): `ancestry_pids = win:7204`, `trusted_id = tagged-session`, `owned_by_self = YES` — the bridge engages exactly as on the runner. Empirical pair: attached NO / detached YES (`fm-tagged-detached.out` content quoted in the PR evidence).

## Full CI-lane drives on this rig (target code, rig locale, fleet load, three lanes concurrent as CI runs them)

| lane | wall | scripts | ok | not ok |
|---|---|---|---|---|
| portable-parallel-1 (PR 21 red) | 34.2 min | 13 | 736 | 0 |
| portable-parallel-2 (PR 20+21 red) | 32.8 min | 13 | 712 | 0 |
| portable-serial-9of10 (PR 20 red) | 29.1 min | 32 | 686 | 1 — `fm-turnend-foreign-owner-arm-fix` refused to arm from the validation checkout (see limitations above) |

Lane walls under concurrent load (33-34 min for lanes hinting ~13.5 min) are live measurements supporting the normal-tier 30 -> 45 recalibration; the serial shard's 29.1 min here and 40 min on 2-core hosted runners support serial 45 -> 60.

## Remote corroboration (read-only observation, not driven by this phase)

- PR 20 checks: run 41592126022 — parallel 1/2, serial 1/9, coverage guard, timing aggregate all fail; serial 2-8, Herdr, Lint 1/2, Repo invariants pass.
- Target commit `d7e49e40` CI run 41710979957 (validation draft on the rig): **success** — all 19 jobs green incl. every previously-red lane.
