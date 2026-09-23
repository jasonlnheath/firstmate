# Live validation: fm/helm-freshness-hook (bin/fm-helm-reset.sh)

Real product drive on 2026-09-23 (~10:14-10:20 local): the real
`bin/fm-helm-reset.sh` against a REAL herdr 0.9.1 server (isolated
`fm-lab-helm-reset-live-*` named session via the repo's own
`bin/fm-herdr-lab.sh`, fleet-state tripwire guarding the live default
session) and a REAL pi 0.85.1 TUI in a lab pane, booted with an isolated
`PI_CODING_AGENT_DIR` and a capture extension (submitted input captured
byte-exact; turns aborted before any provider call; no credentials, no
model, no tokens). State gates were satisfied with real state files; the
window gate evaluated the real wall clock (no FM_HELM_RESET_NOW override).

## Scenario evidence

| Scenario | Result | Key evidence |
|---|---|---|
| S1 absent config = quiet feature-off | pass | `s1-absent-config.*` (exit 0, "feature off", no markers, nothing submitted) |
| S2 out-of-window (default 01:00-02:00 at 10:15) refuses | pass | `s2-out-of-window.*` (exit 3, `gate: window`) |
| S3 no away posture refuses | pass | `s3-no-away.*` (exit 3, `gate: away-posture`) |
| S4 unacknowledged wake row refuses | pass | `s4-wake-queue.*` (exit 3, `gate: wake-queue`) |
| S5a dry-run rehearsal (environ discovery) sends nothing | pass | `s5a-dryrun-environ.*`, `s5a-reverify.out.txt` (mode: dry-run, capture empty, 0 session files) |
| S5b dry-run via FM_SUPERVISOR_TARGET override | pass | `s5b-dryrun-override.*` (override branch, mode: dry-run) |
| S6 pending composer refuses before /new; draft survives | pass | `s6-composer-guard.*`, `s6-with-draft.screen.txt`, `s6-after.screen.txt` |
| S7 real reset: /new + continuation prompt | pass | `s7-real-reset.*`, `s7-after.screen.txt` (pi rendered "✓ New session started"), capture holds the exact prompt |

## The fresh-session proof paths

- Live path driven: herdr reported no `agent_session` value for the
  synthetic pi (its observation needs the production pi integration), so
  `helm_reset_wait_fresh` used the two-consecutive-empty-polls fallback —
  the exact branch the round-1 approved fix restricted to the no-value
  case. It returned only after pi's real "✓ New session started"
  (`s7-before.screen.txt` vs `s7-after.screen.txt` diff in
  `s7.session-change.diff`).
- Known-value path (value must CHANGE; empty polls never suffice): not
  drivable live here; proven by
  `tests/fm-helm-reset.test.sh::test_fresh_wait_requires_session_change_when_known`,
  which FAILS on the pre-fix code and passes on a4b928c — see
  `regression-prefix-revert.txt`.

## Baseline rig proof

`baseline.pi-environ.txt` (real herdr-injected HERDR_PANE_ID/HERDR_SESSION
in the pi process's /proc environ), `baseline.process-info.json` (real
shell_pid/foreground pi), `baseline.screen.txt` (real pi composer),
`baseline.agent.json` (herdr registered `agent: pi, idle`).

Lab session torn down; only the untouched default session remains.
