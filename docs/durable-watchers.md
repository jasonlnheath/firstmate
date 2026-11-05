# Durable watchers

Audience: operator-current.
This document owns the durable-watcher path's usage contract: hosting a standing watcher (the board-keeper shape) on a pinned durable-pi backend so context compaction manages the context wall and a restart resumes the same session instead of rebuilding it.
[`docs/configuration.md`](configuration.md) "Durable watchers" owns the definition schema, [`docs/durable-watchers-feasibility.md`](durable-watchers-feasibility.md) owns the research evidence behind the pin, and each script's header owns its mechanics.

## Gate and rollback

The path is inert unless the home opts in by creating `config/durable-watchers/<name>.conf` definition files.
No other firstmate file references the path, so with no definitions today's watcher behavior is byte-identical.
Rolling back is one of three moves, in increasing scope: never opt in, delete the definition (the watcher returns to its ordinary session path), or revert the PR, which removes only added files.
Durable state lives under `state/durable-watchers/` and the pinned checkout under the configured checkout directory; both are home data, not repo content, and can be deleted without touching anything else.

## Install

The backend comes from `github.com/disler/durable-pi` at the commit pinned in `bin/fm-install-durable-pi.sh` (the feasibility record owns the verification evidence for that pin).
Install it into the default search path, or another directory named by `config/durable-pi-dir`:

```sh
bin/fm-install-durable-pi.sh state/durable-pi
```

The installer needs git, npm, and network access.
An absent checkout makes every arm refuse with that hint; nothing falls back silently.
Upgrades are a deliberate re-pin: update the pin in the installer, re-run the live verification, then reinstall into a fresh directory.

## Run a watcher

```sh
bin/fm-durable-watch.sh arm keeper          # host loop in the foreground
bin/fm-durable-watch.sh send keeper "refresh the board"
bin/fm-durable-watch.sh status keeper
bin/fm-durable-watch.sh stop keeper
```

`arm` ensures the backend (one owned instance per watcher unless the definition attaches to a `backend_url`), creates or resumes the session, applies the prompt file as agent instructions, then polls the watcher's steering inbox.
Each message is submitted with the message id as its requestId, so a repeated delivery is admitted once.
`send` is file-first: it appends to `state/durable-watchers/<name>.inbox/` and works while the host is down.
`stop` ends the owned backend by its recorded pid; durable state stays on disk and the next `arm` resumes in place.
Each watcher owns its own data directory, port, and token; the token never leaves the home.

## Benchmark

```sh
bin/fm-durable-watch-bench.sh --cycles 6 --bytes-per-cycle 800
```

One command runs a comparable watch-keeper scenario twice over one scratch backend and prints a plain comparison table: per-cycle token cost, wall time, context growth, restart recovery cost, and steer delivery reliability.
The default faux model is free and deterministic; its token counts are synthetic and measure structure, not cost.
Pass `--provider` and `--model` plus the provider's API key in the environment for real numbers.
`--scratch DIR` keeps the run's evidence JSON files, and `render` reprints a table from two recorded evidence files without a backend.

## Known limits

- Request bodies are capped at 256kb by the backend, which bounds the baseline rebuild message and the scenario size.
- The pinned pi-durable tool set has no image input yet, so a visual keeper works through textual tool output (DOM and JS proofs, pixel-diff CLIs).
- dpi-backend agents use its fixed shipped tool set; the pilot runs on bash and the shipped tools only.
- The device token is a shell on the host: bind to loopback only and never expose the port.
