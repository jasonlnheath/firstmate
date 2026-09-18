# Pi and Pi-signed

The combined contract is genuine: Pi and the signed wrapper expose the same verified CLI and TUI behavior.
Worker launch facts re-verified on 2026-09-17 against installed Pi 0.85.1 (help, dist, and a live disposable session) unless a fact gives another version.
`pi-signed` is an optional distribution, not a Pi install prerequisite: it is not installed on this Linux machine, its adapter tables stay valid from the 0.82.0 verification, and selection refuses rather than falls back when the wrapper is absent.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | The Firstmate-owned extension's `agent_start` marks busy and `agent_settled`, confirmed by `ctx.isIdle()`, marks idle; `session_shutdown` also marks idle, so every orderly end closes (quit, process exit, same-process replacement); this covers retries, compaction, tool loops, and queued continuations. |
| Exit command | `/quit`. |
| Interrupt | Single Escape; a manual interrupt fires `turn_end` and `agent_settled` (live-verified 2026-09-17 on 0.85.1), so unlike Claude the busy record closes natively on interrupt. |
| Skill invocation | `/skill:<name>`, for example `/skill:no-mistakes`; live-verified 2026-09-17 on 0.85.1 that the command loads and the model begins executing the named skill (this is what `enableSkillCommands` registers by default). |
| Model flag | `--model <model>`; omitting it on a crewmate or scout launch is refused rather than left to Pi's own default (see Task-worker launch hardening below), while a secondmate may omit it. |
| Effort flag | `--thinking <low\|medium\|high\|xhigh\|max>`; 0.85.1 also accepts `off` and `minimal`, which sit below the shared vocabulary's floor and are deliberately unreachable rather than remapped onto low, and both identities expose the same levels and completed the same model-qualified max-thinking smoke. |
| Model discovery | Run the selected executable as `<executable> --list-models [search]`; Pi's installed `docs/models.md` owns how built-in, extension-registered, and custom provider/model entries reach that list. |

Native Codex sessions may request `ultra` through the native extension flag described by `../../../bin/fm-spawn.sh`; it is separate from Pi's thinking levels.
Pi has no permission system, so workers are always autonomous.
Pi's installed `packages/coding-agent/docs/settings.md` UI and display section documents `regular` as the `tuiMode` default and `fullscreen` as experimental.
Fullscreen can bury steering messages by rewriting scrollback, so Firstmate avoids it when the installed CLI supports the override.
`../../../bin/fm-spawn.sh --help` owns the executable-pinning and version-safe launch mechanics.

Pi-signed is the signed wrapper identity verified on version 0.82.0.
Firstmate records `pi-signed` without normalization and refuses rather than falling back to `pi` when that wrapper is unavailable.
The observed signed process tree has an exact `pi-signed` wrapper parent with the Pi application as its child, while tmux reports the foreground command as the exact `pi-launcher` name for either selected executable.
The installed plain `pi` command also execs that signed launcher.
The router's Detection section owns how launch markers and ancestry select between the identities.

Keep the instructions as one positional argument.
Multiple positional arguments become separate queued messages; the spawn template already preserves the one-argument shape.

A project trust dialog can appear on the first Pi run in any not-yet-trusted directory, including a clean worktree.
Firstmate crewmate and scout launches grant project trust per run with `--approve`, which sets Pi's trust override so the dialog is never constructed, and the post-launch gate then requires the worker extension's own busy record (`pi-ext`-sourced busy or idle under the launch's gen) before the spawn reports success; the spawn's own pre-launch `fm-spawn` seed never counts as start proof, so a Pi that dies on boot or never fires `agent_start` fails the spawn.
The per-run grant writes no standing consent; human sessions and secondmate launches still meet the dialog, and a decision persists per path in the agent dir's `trust.json`, so later human spawns in the same pooled slot skip it.
Before trust resolves, Pi loads context files, user/global extensions, and CLI `-e` extensions, so brief delivery is never gated, but project `.agents/skills` only become reachable once trust resolves.

## Task-worker launch hardening

`../../../bin/fm-spawn.sh` ports the Claude adapter's launch hygiene to every Pi crewmate and scout launch; a `--secondmate` launch is a primary under its own supervisor contract and carries only the suppression variables.
`--append-system-prompt` establishes the same first-party task-channel statement Claude workers get: the brief and the Firstmate instruction inbox are first-party, everything else stays untrusted, and the statement grants no merge, destructive, or security-sensitive authority.
`PI_CODING_AGENT_DIR` points the worker at a deliberately seeded per-home directory under the supervising home's `state/pi-worker-agent/`, keeping the operator's global `AGENTS.md`, skills, extensions, settings, and session history out of the worker.
The seed carries a symlinked `auth.json` to the operator's own store (never a copy, re-established every launch, launch refused when the store is missing or holds no provider entry - the `{}` that 0.85.1 writes on `pi --help` when it initializes a never-authenticated agent dir, which the spawn's own TUI-mode probe triggers before the seed runs; one accepted cost: 0.85.1 serializes credential mutation with a lockfile beside the `auth.json` path it was given without resolving symlinks, so a worker locks `state/pi-worker-agent/auth.json.lock` while the operator's own Pi locks `~/.pi/agent/auth.json.lock`, and for an OAuth-backed provider a refresh the operator session and a worker both start inside the five-minute expiry window is no longer serialized between them, which can fail one side's turn with `OAuth refresh failed` and, where the provider rotates refresh tokens, leave the store holding a rotated-out token that forces a re-login; workers still share one lock among themselves, and an api-key-only store such as this host's is unaffected), a symlinked `models.json` when the operator has one (Pi reads the custom provider catalog from the agent dir only, so without it a crew-dispatch rule naming a local or proxied provider would fail `--model` resolution, which 0.85.1 reports as a startup error and exits 1 on before the TUI, leaving a dead pane for the start gate to time out on; Pi's derived `models-store.json` lands beside it and the worker refreshes it itself), a symlinked `extensions/herdr-agent-state.ts` when the herdr-managed Pi integration is installed (it reports `agent_status` to `herdr agent get` and disables itself outside a herdr pane), and no `settings.json` of its own (Pi consults that file for telemetry only when `PI_TELEMETRY` is unset, and every worker launch sets it to `0`, so Pi writes its own on first run); the two optional links are dropped again on the next launch once their source is gone, and worker session transcripts land under the seed's `sessions/` by design, retained rather than auto-deleted.
Isolation never strips project reach: project context files load from the working directory regardless of the agent dir, project `.agents/skills` stay reachable through per-run trust, and the home-level `~/.agents/skills/` directory is outside `PI_CODING_AGENT_DIR`'s reach by Pi's own discovery design, which is load-bearing because the `no-mistakes` skill lives there.
Isolation does strip the operator's saved default model and thinking level, because those live in the `settings.json` the seed does not carry: a model-less launch on 0.85.1 would fall through `findInitialModel` to the first provider in Pi's own hardcoded order that has a key in `auth.json`, so `bin/fm-spawn.sh` refuses a crewmate or scout launch whose model is empty or `default` before any endpoint exists, naming the fix (pin a model in `config/crew-dispatch.json` or pass `--model <provider>/<id>`); secondmate launches are exempt because their panes are primaries on the operator's own agent dir.
`PI_TELEMETRY=0` and `PI_SKIP_VERSION_CHECK=1` suppress install telemetry and the pi.dev version check for this launch only; `PI_OFFLINE` is deliberately not set, because on 0.85.1 it would also stop the worker refreshing the provider catalog into its seed's `models-store.json` and downloading `rg`/`fd` into the seed's `bin/` where the host lacks them, both of which an operator session does freely.
Pi ships no model-drafted feedback tool, so unlike Claude there is no feedback surface to suppress.

## Worker turn-end extension

`../../../bin/fm-spawn.sh` keeps the worker turn-end extension in `state/`, outside the worktree, because project-local extension files worsen the trust gate and pollute the project.
The extension listens for Pi's `turn_end` event, not `agent_end`, so supervision is notified after each completed turn rather than only when the whole run exits.
`session_shutdown` releases busy the same way Claude's `SessionEnd` hook does, so an orderly end that never reaches `agent_settled` can never leave a stale busy record; live-verified 2026-09-17 on 0.85.1 that `/quit` fires it, while process death fires nothing and remains the endpoint-death override.
Native-harness progress uses the separate generation-bound marker owned by `../../../bin/fm-busy-event.sh`; it never fabricates Pi turn completion.
Pi sets `PI_CODING_AGENT=true` for its children as its harness-detection marker.

## Primary integration

The primary turn-end behavior was verified on 2026-07-09 with Pi 0.80.5.
`.pi/extensions/fm-primary-turnend-guard.ts` listens for logical-run `agent_settled`, not per-tool-loop `turn_end`, and uses `pi.sendUserMessage(..., { deliverAs: "followUp" })` to force one guarded follow-up when `../../../bin/fm-turnend-guard.sh` returns 2.
Without `deliverAs: "followUp"`, Pi rejects the send while the agent is still processing.
On native Windows, the extension runs its session-start, both PreToolUse, turn-end, and operational-input Bash helpers through `bash`; macOS and Linux invoke those helpers directly.

The primary watcher protocol also requires `.pi/extensions/fm-primary-pi-watch.ts`.
The Pi engine auto-discovers both tracked project-local extensions once the project is trusted.
The model arms through the `fm_watch_arm_pi` tool, never through a foreground shell arm.
Native-harness adapters can discover the same guarded FirstMate tools and operational message allowlist through the public Pi event-bus contract in `.pi/extensions/lib/fm-native-contract.ts`; no Pi built-in tools cross that contract.
The tool result and clean-exit fallback are owned by `../../../docs/supervision-protocols/pi.md`.
`../../../bin/fm-session-start.sh` reports when the live Pi-family session has not loaded both extensions and points at the selected executable after project trust as the fix, with `-e` as a trust-free fallback.

When a secondmate is launched on Pi or Pi-signed, `../../../bin/fm-spawn.sh --secondmate` launches the selected executable with both `-e .pi/extensions/fm-primary-turnend-guard.ts` and `-e .pi/extensions/fm-primary-pi-watch.ts`.
Both files already exist in the secondmate home's git worktree.
The PreToolUse-equivalent watcher-arm seatbelt returns `{block: true}` from the `tool_call` event.
