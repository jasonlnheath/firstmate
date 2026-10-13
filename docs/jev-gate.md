# Jev damage-control gate

The Jev gate is a local-only damage-control screen for commands typed into the Pi helm session.
It is captain-controlled, ships inactive, and changes nothing until this home opts in.

## Posture

Activation is a local config presence flag: `config/jev-gate` in this firstmate home.
Absent means the gate is inert; every command runs exactly as before.
`enforce` means matching commands are blocked with a plain-text reason.
`shadow` (or any other value) means log-only: matching commands run, and the near miss is recorded for pilot tuning.
The confidence floor comes from `config/jev-gate-floor` using the same ladder as the Jev pre-screen (default 0.8).

## Scope

The gate is scoped to the helm session's own command path (the supervision branch's pretool seat), and it enforces four independent layers before any judgment:

1. The seat only gates the primary Pi helm session; a second Pi session in this home (a foreign holder of the home lock) is never gated.
2. The checkout must be a plain firstmate checkout where git-dir equals git-common-dir (the [`docs/cd-guard.md`](cd-guard.md) shape), so a spawned pool worktree or any other linked worktree is out of scope.
3. The resolved home must not be a secondmate home.
4. A per-task worker context (`FM_TASK_ID`) makes the gate inert.

Outside that scope the gate does not exist; crewmate workers are never gated by it.

## Deny catalog

The regex stage recognizes a closed list of catastrophic shapes; each deny carries a `[JG-Rn]` label and cites its stage and confidence:

- `rm-protected` - forced recursive `rm` (`-rf`, `-r --force`) whose operand resolves into a protected path: `/`, system roots, `$HOME`/`~`, the firstmate home, its `state`/`data`/`projects`/`config`/`.env`, or key home dotdirs (`~/.ssh`, `~/.gnupg`, and similar). Unforced `rm -r` consults the screener instead, and so does a forced `rm` whose operands - a bare `*` resolves against the current directory - stay outside the protected set.
- `git-push-force` - any forced push (`--force`, `-f`, `+refspec`).
- `dd-device` - `dd of=` aimed at a device node.
- `mkfs` - any `mkfs.*` or `mke2fs` invocation.
- `partition-write` - `wipefs`/`blkdiscard` always, and `fdisk`/`sfdisk`/`parted`/`gdisk`/`sgdisk` aimed at a `/dev` operand.
- `chmod-recursive-root` - recursive `chmod` to mode `777` or `000` on a protected path; other recursive permission changes consult.
- `redirect-protected` - output redirection into a protected path (`/dev/null`, `/dev/stdout`, and `/dev/stderr` are carved out), including `state/.lock` inside the firstmate home.
- `overwrite-protected` - `shred`/`truncate` overwrite of a protected path; `cp`/`mv`/`tee` overwrites consult.
- `power-op` - `shutdown`, `reboot`, `halt`, `poweroff`, and their `systemctl poweroff`/`reboot` and `init 0`/`6` spellings.
- `git-discard-primary` - discard-shaped git operations (`reset --hard`, `checkout -- .`, `clean -fd`, `restore`) that could tear down unlanded work in the primary checkout.

`fm-teardown --force` in the primary checkout consults the screener rather than blocking deterministically, so a captain-approved force can still pass through an override.

## Jev screen

Commands that are not regex-denied but carry a marker (`sudo`, `rm -rf` outside protected paths, `git reset --hard` outside the primary checkout, `--force`, firstmate force verbs, and others) consult the Jev screener (`bin/fm-jev-command-screen.sh`).
The screener sends the command text to the `TYPESAFE_API_KEY` Jev model ([`docs/configuration.md`](configuration.md) owns the shared key contract) inside an 8 KiB input window and gets back one of `benign`, `grey-reversible`, `destructive`, or `uncertain` with a confidence.
`destructive` at or above the floor blocks with a `[JG-J1]` reason; anything else allows.
An out-of-vocabulary or malformed reply is treated as an error and allows.

## Failure semantics

Every screener problem (missing key, timeout, HTTP error, malformed reply) fails open: the command is allowed, a counter is bumped, and the event is recorded.
After 3 consecutive failures the breaker opens for a 5 minute cooldown; while open, marker commands allow without consulting, and the first success closes it.
A wall-clock self-alarm (default: timeout + 5 seconds) reaps a hung evaluation and allows the command.

## Override window

The captain can open a bounded override window in the helm session with `/jev-override <reason> [--ttl N]` (1-60 minutes, default 15).
While the window is open, `destructive` verdicts that would block are recorded and allowed instead.
The window lives in the extension's memory only; the shell helper `bin/fm-jev-gate-override.sh` reports status (`status`) and requests a close (`off`).
The published `state/jev-gate/override-status` view is advisory; the extension never reads it back as authority.
The close request is advisory too: `off` clears the published view and records an `override_close` audit event, but the in-memory window ends only via `/jev-override off`, TTL expiry, or session shutdown.

## Audit records

All gate activity is appended to `state/jev-gate/events.jsonl` as a hash-chained journal (each line commits the previous line's sha256, starting from a `chain-header`), rotated at 1 MiB with 3 rotations kept.
Matching counters live in `state/jev-gate/counters`.
`bin/fm-jev-gate-override.sh status` verifies the chain, prints counters, the breaker, and the override view, and exits non-zero on a broken chain.
Command text persists only under `state/jev-gate/`: events cap the command at 4 KiB and redact `Bearer`/`Authorization` material, and the screener input is one mode-0600 temp file deleted after the consult.
The screener prompt carries the command and its resolved operand paths and nothing else - `TYPESAFE_API_KEY` reaches the request as a header, never as prompt text.

## Testing

Development-verification tests live in `tests/fm-jev-command-screen.test.sh`, `tests/fm-jev-pretool-check.test.sh`, `tests/fm-jev-gate-override.test.sh`, and `tests/fm-primary-turnend-guard-jev-wiring.test.sh`.
