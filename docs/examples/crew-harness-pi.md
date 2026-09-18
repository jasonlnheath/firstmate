# Example: `config/crew-harness` for a Pi-first operator

Copy the line below into a local, gitignored `config/crew-harness` in your firstmate home when your crewmates and scouts should launch on Pi.

```text
pi
```

The file holds one adapter name; every crewmate and scout spawn then uses Pi, while the primary keeps its own harness.
To pin Pi for secondmate launches too, write `pi` into `config/secondmate-harness` instead, which also accepts optional model and effort tokens.
Select the signed wrapper with `pi-signed` only when that executable is installed; firstmate refuses rather than falling back to `pi`.
Pi crewmates get firstmate's full worker hardening automatically: isolated agent state, per-run project trust, the first-party task-channel statement, and suppressed telemetry and update checks.
Because that isolated agent state carries no saved default model, every Pi crewmate or scout launch needs a concrete model in the `<provider>/<id>` shape: pin one per rule in `config/crew-dispatch.json` (see `docs/examples/crew-dispatch.json`) or pass `--model <provider>/<id>` on the spawn; a launch without one, or with a bare id such as `glm-5.3` or `sonnet:high` that names no provider, is refused before any pane opens rather than landing on Pi's own per-provider default or catalog match, and a relaunch onto such a pin is refused before the running worker is stopped.
The pinned model's provider also needs a credential Pi can reach: its own `/login` entry in the operator's `auth.json`, an `apiKey` on it in the operator's `models.json` (a dummy value is enough for a keyless local server), or its environment variable such as `OPENAI_API_KEY`; a launch with none of the three for that provider is refused before any pane opens, and a relaunch onto it before the running worker is stopped (a `codex-native/...` pin is exempt, since it signs in through Codex itself).
See `docs/configuration.md` "Harness support" for the resolution order and `.agents/skills/harness-adapters/references/harness/pi.md` for the verified adapter facts.
