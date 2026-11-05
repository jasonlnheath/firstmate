# Durable-watcher feasibility

Audience: maintainer-verification.
This record owns the version-scoped research evidence and the feasibility verdict for Firstmate's config-gated durable-watcher path for the standing-watcher class.
[`docs/durable-watchers.md`](durable-watchers.md) owns the operator-facing usage and rollback contract, and [`docs/configuration.md`](configuration.md) owns the config schema.

Research target named by the captain: `github.com/disler/durable-pi`, the "headless checkpointed-state agent framework" built on `@earendil-works/pi-durable`.
Candidate use: hosting standing watchers (the board-keeper shape) whose pain today is context-wall decay forcing scheduled fresh restarts that rebuild context and lose working knowledge.

## Research target identity

- Repository: `github.com/disler/durable-pi`, single commit `37165c619573dbaf425463038bbffecfe576beec` dated 2026-10-11, MIT license (Copyright 2026 IndyDevDan).
- The repository is a content drop, not a developed project: one commit, no issue tracker activity observed in the clone.
- It packages four apps over the upstream harness: `dpi-backend` (device server, REST v1 + SSE), `dpi-sdk` (wire contract and client, not published to npm), `dpi-tui`, `dpi-playground` (web hub), plus a proactive demo.
- Upstream harness: `@earendil-works/pi-durable` on npm, MIT, `1.0.0` released 2026-10-01 through `1.5.0` by 2026-11-02 (checked 2026-11-04 via `npm view`), self-described "Experimental. The API changes without notice between releases."
- `dpi-backend` pins `@earendil-works/pi-durable` 1.0.3 exactly, while npm has moved to 1.5.0 in one month: upstream churn is real and any adoption must pin by version and re-verify on upgrade.
- Engine requirement: Node >= 22.19 (repo pins 24). Verified working on this host's Node v26.8.1.

## Findings

### Actual API (dpi-backend v1, verified live 2026-11-04)

All routes live under `/v1` with `Authorization: Bearer <DPI_TOKEN>`; only `GET /healthz` is open (`apps/dpi-backend/API.md` owns the full route table; evidence below is what this record verified by running the server).

- `POST /v1/sessions` `{name, cwd, model:{provider, modelId}}` creates a session; each session is one harness and one SQLite database (`sessions/<id>/agent.sqlite`).
- `POST /v1/sessions/:s/agents/:a/messages` `{content, whenBusy?: followUp|steer|reject, requestId, waitMs?}` submits work; `requestId` is admitted exactly once, so retries are safe; `waitMs` long-polls the outcome (verified `202 queued` then `200 done`).
- `GET /v1/sessions/:s/submissions/:id?waitMs=` reacquires a submission after restart and long-polls it (verified returning `done` for a submission submitted before a restart).
- `GET .../agents/:a/transcript?format=markdown|json` and `GET .../agents/:a/entries?scope=all|active` read stored history; assistant entries carry per-turn provider usage (`input`, `output`, `cacheRead`, `cacheWrite`, `totalTokens`, `cost`), and the session stream reports cumulative per-model usage.
- `GET /v1/sessions/:s/inspect` reports scheduler state and outstanding tasks or submissions for recovery inspection.
- `PATCH /v1/sessions/:s/compaction` adjusts automatic-compaction thresholds; defaults are a background summary at 200k tokens and a blocking one at 250k, refit to smaller windows.
- Server-sent events stream `hello -> snapshot -> deltas`; a reconnect starts from a fresh snapshot and nothing replays, so a killed client loses nothing.
- `DPI_PROVIDER=faux` selects a deterministic free model (`faux/echo`) that can run bash tool calls (`!command` prompts), so the whole path runs headless with no model key.

### Maturity

- Young but test-covered: `just check` runs 33 unit suites across SDK, backend, hub, and TUI on the faux model; `just test ui` runs 28 web checks; `just test e2e` covers TUI + web on one run, steer from the web, both clients closed, device restarted mid-tool, and fork (per the repository README's checked table, unverified by this record).
- Single-maintainer content repo with no release engineering; the durable layer itself lives upstream in the pi monorepo (`packages/durable`) and ships as versioned npm releases with changelogs and breaking-change sections.
- Verdict: usable for a gated pilot when pinned, not yet a stable dependency surface; the gate must treat the pinned checkout as a runtime dependency installed per home, exactly like the pinned shellcheck and actionlint builds.

### Storage model

- One SQLite database per session (`agent.sqlite`) plus device-level `catalog.sqlite` and `app-state.sqlite` under `DPI_DATA_DIR` (default `~/.dpi/backend`); the hub keeps only a device registry.
- SQLite runs in WAL mode with `synchronous = NORMAL`: commits survive process crashes; the newest commits may be lost on power or host failure (upstream storage doc, restated in `ai_docs/durable_pi/readme.md`).
- A JSONL append-only backend with optional per-commit fsync exists as an alternative storage adapter.
- One process owns a storage at a time; there is no cross-process locking, so a Firstmate host must own exactly one backend instance per data directory.
- Conversations are transcripts of immutable entries; queued input, running generation, tool output, and spend are committed documents updated before anything is shown.

### Crash-resume semantics (verified live 2026-11-04)

Proven end to end on this host with `dpi-backend` 1.0.3, Node v26.8.1, faux provider, scratch data dir `/tmp/dpi-bench-proof`:

- Send, wait, and idempotency: `!echo proof-alpha` with `requestId: pf-1` returned `{"submissionId":10,"status":"done","answer":{"entryId":17,"text":"Tool finished: proof-alpha"}}`; resubmitting the identical request returned the identical stored answer, not a second run.
- Steer while busy: with a slow turn running (`requestId: pf-2`), a second submission with `whenBusy: "steer"` joined the running work (`entry #23` appears between the busy turn's entries) and was answered.
- Restart mid-tool: a `!sleep 20` bash call (`requestId: pf-5`) was killed with the server 4 seconds in; after restarting the server on the same data dir, the transcript shows the tool call preserved, then resumed and completed, and `GET .../submissions/31?waitMs=5000` returned `{"submissionId":31,"status":"done","answer":{"entryId":37,"text":"Tool finished:"}}`.
- Transcript continuity across the restart: entries `#17` through `#37` read as one history in one session; nothing was lost or duplicated.
- Upstream statement agrees: an interrupted tool result is marked interrupted so the agent decides what happens next, and replay-safe tools may rerun; exactly-once external effects still need their own idempotency.

## Fit verdict for the standing-watcher class

The library is usable for the pilot shape. The board keeper's actions are bash- and CLI-reachable (git, lavish-axi, chrome-devtools-axi, curl), and `dpi-backend`'s fixed toolset (`read`, `write`, `edit`, `bash`, plus playground tools) covers that surface. Durable compaction addresses the context-wall decay directly, and crash-resume removes the fresh-restart context rebuild cost.

Known limitations, each a real constraint on the pilot:

- No image input: `@earendil-works/pi-durable` tools "Reading images is not supported yet" (1.0.3 doc snapshot), and dpi-backend's `read` does not return images. A visual keeper must work through textual tool output (DOM and JS proofs, pixel-diff CLIs) until upstream adds image reading.
- Fixed toolset per agent in dpi-backend; custom tools require editing the backend checkout, which this design refuses to do. The pilot runs on the shipped toolset only.
- Experimental upstream churn: pin by exact version, re-run the live verification, and re-pin deliberately on upgrade.
- Security posture: the device token is a shell on the host. Bind `127.0.0.1` only, generate the token per home, and never expose the port.
- The pinned `dpi-backend` depends on `@earendil-works/pi-durable` 1.0.3 while npm is at 1.5.0; upgrade is a deliberate re-pin with fresh verification, never an ambient `npm update`.

## Design

Rollback is the hard requirement, so the whole feature is additive and inert by default.

- Gate: the path exists only when a home opts in by creating `config/durable-watchers/<name>.conf` definition files (schema owned by [`docs/configuration.md`](configuration.md) "Durable watchers"). With no such files, nothing in Firstmate references the new scripts, and today's watcher behavior is byte-identical.
- Runtime dependency: the pinned `disler/durable-pi` checkout, installed per home by `bin/fm-install-durable-pi.sh` (clone at the pinned commit plus `npm ci` in `apps/dpi-backend`), located by `config/durable-pi-dir` (default `$FM_HOME/state/durable-pi`). Absent checkout means a clean refusal naming the installer, never a fallback.
- Host: `bin/fm-durable-watch.sh` owns one watcher conversation: start or find the backend for that watcher's data dir, ensure the session, resume outstanding work, poll the watcher's file-first steering inbox, submit each message with the message id as `requestId` and `whenBusy: steer`, and append one-line status events to its own log. It never touches fleet status files, wake machinery, or delivery paths.
- Bench: `bin/fm-durable-watch-bench.sh` runs a comparable scenario twice over one scratch backend and prints a plain comparison table. Measured rows: per-cycle token cost (provider usage summed from the usage API), wall time per cycle, context growth (active-context size across cycles), restart and recovery cost (kill and restart the backend mid-scenario; time to next completed cycle and duplicated-submission count), and steer delivery reliability (submitted, answered, missed). Default mode is faux and free; a real provider can be selected through flags for true cost numbers.
- Tests: portable contract tests run everywhere with a fixture HTTP server standing in for the backend (gate refusals, config parsing, inbox protocol, request idempotency, table shape); live-path tests against a real pinned checkout capability-skip with an explicit notice when the checkout is absent, following the harness-dependent check rule.

## Rollback

Three levels, in order:

1. Do not opt in: with no `config/durable-watchers/` entries the path is unreachable; no other file changes behavior.
2. Opt out: delete the definition file or the directory; the watcher returns to the ordinary session path. Durable state stays on disk under `state/durable-watchers/` and can be archived or deleted without touching anything else.
3. Remove the feature: revert the PR. It adds new files plus doc sections and removes or moves nothing, so `git revert` restores the tree exactly. The runtime checkout under `state/durable-pi` is home data, not repo content, and is deleted with `rm -rf` if desired.

## Adversarial pass findings folded into the design

- "Byte-identical when off" needs proof, not assertion: the portable tests assert that no existing script references the new paths and that the gate refusals are the only reachable surface without config.
- A killed bench backend must not leak into a live home: the bench owns its own scratch data dir, port, and token, and verifies `/healthz` against its own port before and after.
- Steer delivery during a busy run must not silently drop: the bench counts a steer as delivered only when a distinct answer entry follows it, and the host records unanswered submissions by submission id for inspection.
- The faux model's token counts are synthetic, so faux numbers measure structure (cycles, context size, restart recovery, delivery), not cost; the table labels the mode so no faux row can be read as a cost claim.
- Request-id reuse across host restarts must resolve to the same stored submission, or steering double-fires; the portable tests pin the message-id-to-request-id mapping as stable across restarts.
- A home running two watchers must not share one SQLite storage owner: each watcher definition gets its own data dir, port, and token.
