# Example: `config/crew-harness` for a Pi-first operator

Copy the line below into a local, gitignored `config/crew-harness` in your firstmate home when your crewmates and scouts should launch on Pi.

```text
pi
```

The file holds one adapter name; every crewmate and scout spawn then uses Pi, while the primary keeps its own harness.
To pin Pi for secondmate launches too, write `pi` into `config/secondmate-harness` instead, which also accepts optional model and effort tokens.
Select the signed wrapper with `pi-signed` only when that executable is installed; firstmate refuses rather than falling back to `pi`.
Pi crewmates get firstmate's full worker hardening automatically: isolated agent state, per-run project trust, the first-party task-channel statement, and suppressed telemetry and update checks.
See `docs/configuration.md` "Harness support" for the resolution order and `.agents/skills/harness-adapters/references/harness/pi.md` for the verified adapter facts.
