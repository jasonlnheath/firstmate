# Live test evidence: fm/pi-launch-hygiene-ports (8c9068f)

All transcripts were driven against the real product on this host: `bin/fm-spawn.sh`, `bin/fm-control.sh`,
`bin/fm-harness.sh`; real `pi 0.85.1`; real `tmux` on a private socket; a live local llama-server
(`qwen36` provider, 127.0.0.1:8036). Isolation: temp FM_HOME, throwaway HOME (`~/.pi/agent` = `auth.json {}` +
a `models.json` keying only `qwen36`), fake `treehouse get` (enters a pre-made worktree). The operator's real
`~/.pi/agent` and the fleet were never touched.

| file | scenario |
|---|---|
| 01-pi-spawn-refusals-live.txt | credential-less pin, provider-less pin, `default`, and empty model all refuse with exit 1 before any tmux window or state/ record exists |
| 02-pi-spawn-live-ok.txt | models.json-keyed custom provider launches a real Pi worker: full hardened launch line, no trust dialog, seed dir symlinks, `busy source=pi-ext event=agent-start` before "spawned", later `READY` + `agent-settled` |
| 03-pi-relaunch-refusals-pre-stop-live.txt | `fm-control.sh relaunch` onto a credential-less / provider-less / `default` pin refuses; the running worker's pane pid, busy record, and meta are untouched |
| 04-pi-start-gate-failure-live.txt | a worker that never fires agent_start fails the spawn: one-line `failed:` event carrying the pane tail, window closed, task record rolled back, sibling worker untouched |
| 05-pi-session-shutdown-closes-busy-live.txt | Escape -> `agent-settled` idle; `/quit` -> `session-shutdown` idle from the generated extension |
| 06-pi-relaunch-valid-herdr-link-live.txt | valid relaunch passes the start gate under a new gen; seed re-links the operator's herdr integration and the worker loads it |
| 07-fm-harness-validators-cli.txt | `validate-worker-model` / `validate-worker-credentials` edges: codex-native exempt, env leg scoped to pinned provider, secondmate and non-Pi pass, malformed auth.json and empty apiKey refuse |

Baseline suites run first (all passed): tests/fm-pi-harness.test.sh, tests/fm-control-relaunch.test.sh,
tests/fm-busy-adapter-wiring.test.sh, tests/fm-secondmate-harness.test.sh, tests/fm-spawn-dispatch-profile.test.sh.
