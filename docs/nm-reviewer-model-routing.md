# No-Mistakes Tiered Reviewer Model Routing

Stops the no-mistakes reviewer from burning Claude session quota by routing
all standard pipeline invocations through `glm-5.3` at `xhigh` effort instead
of inheriting the operator's global Claude Code `model: opus` pin.

## Architecture

| Phase | Model | Effort | Purpose |
|-------|-------|--------|---------|
| Review (find-and-fix loop) | glm-5.3 | xhigh | Code review, finding, fixing |
| Fix auto-apply | glm-5.3 | xhigh | Automated fix commits |
| Document | glm-5.3 | xhigh | Documentation updates |
| Lint | glm-5.3 | xhigh | Lint fixes |
| Test | glm-5.3 | xhigh | Test execution and fixes |
| PR | glm-5.3 | xhigh | PR body generation |
| CI-fix | glm-5.3 | xhigh | CI repair |
| **Risk-gated opus final pass** | claude-opus-5 | high | Verification of high-risk deliveries only |

## Configuration

The pin lives in the no-mistakes global config (`~/.no-mistakes/config.yaml`) and has
two parts that must both be present:

```yaml
# Tiered reviewer: use claude-glm wrapper (sets ANTHROPIC_BASE_URL=Z.AI)
# so no-mistakes never inherits the operator's global "model": "opus" pin.
agent_path_override:
  claude: claude-glm

agent_config:
  claude:
    model: glm-5.3[1m]
    effort: xhigh
```

The `claude-glm` wrapper is the load-bearing half: it launches Claude Code against
the Z.AI endpoint, so no-mistakes invocations never inherit the operator's global
Claude Code settings pin (`~/.claude/settings.json` `"model": "opus"`) or its
Anthropic routing. The `agent_config` pin then selects `glm-5.3[1m]` at `xhigh`
effort for all no-mistakes Claude Code invocations. The operator's global pin is
left untouched — it still applies to interactive Claude Code sessions.

**Zero Anthropic quota consumed by standard runs.**

## Risk-Gated Opus Final Pass

For high-risk, contested, or product-facing deliveries, an opus final verification
pass adds architectural-level catching power. This pass is **not automatic** — it
requires explicit captain authorization and runs short by consuming the GLM handoff
file.

### Risk-Gate Criteria

Trigger the opus final pass when the delivery meets **any** of these conditions:

1. **Launch-path changes** — code that affects the product's public API, user-facing
   behavior, or the primary execution path (e.g., `bin/fm-spawn.sh`, `bin/fm-watch.sh`,
   `bin/fm-send.sh`, core orchestration logic).

2. **Security-sensitive changes** — anything that touches authentication, authorization,
   credential handling, token management, secret storage, or access control.

3. **Contested findings** — the GLM find-and-fix loop produced findings that could not
   be resolved through the normal review-fix cycle (e.g., ask-user findings escalated
   to the captain, or the reviewer identified structural concerns that the fixer could
   not independently validate).

4. **Product-facing gates** — changes that ship to the captain's end users or that
   alter the operator-facing interface (e.g., AGENTS.md updates that change fleet
   behavior, skill definitions, or operational procedures).

### When NOT to Trigger

Do **not** trigger the opus final pass for:

- Documentation-only changes (README updates, doc formatting, comment fixes)
- Mechanical changes (renames, refactors with no behavioral change, formatting)
- Low-risk internal tooling (scripts that only affect firstmate-internal operations)
- Configuration changes that only affect local development environment

### How to Trigger

When the captain authorizes a risk-gated opus final pass:

1. Complete the standard no-mistakes run with the GLM find-and-fix loop.
2. The GLM pass writes the handoff file (see below).
3. The operator runs a separate no-mistakes invocation via a temporary config swap
   that sets `agent_config.claude.model` to `claude-opus-5` and removes the
   `agent_path_override.claude: claude-glm` entry, so the invocation uses the
   native Claude binary and reaches Anthropic instead of the Z.AI-routed wrapper.
4. The opus pass reads the handoff file to start warm and short.

## Handoff File

The GLM find-and-fix loop writes a handoff file so the opus final pass starts warm
and short. The opus pass reads this file before reviewing the diff.

### Location

```
.no-mistakes/handoff-<run-id>.yaml
```

### Format

```yaml
run_id: <no-mistakes run ID>
branch: <feature branch name>
base: <base branch>
model: glm-5.3[1m]
effort: xhigh
risk_assessment: low|medium|high
findings:
  - id: <finding ID>
    severity: error|warning|info
    file: <file path>
    line: <line number>
    description: <what the reviewer found>
    action: no-op|auto-fix|ask-user
    status: fixed|open|resolved|escalated
    ruling: <if resolved, the captain's or reviewer's ruling>
open_questions:
  - <question that needs opus attention>
rulings_applied:
  - <decision the GLM pass made that opus should know about>
summary: <one-line summary of what the GLM pass did and what it found>
```

### Handoff File Lifecycle

1. **Written**: The GLM find-and-fix loop writes the handoff file at the end of the
   standard run, before the PR is opened.
2. **Read**: The opus final pass reads the handoff file as its first action, using
   it to scope its review to the GLM's findings and open questions.
3. **Archived**: After the opus pass completes (or is skipped), the handoff file is
   archived under `.no-mistakes/handoff-archived/` with the date appended.

## Implementation Notes

- No-mistakes 1.75.2 does not have native per-round reviewer model configuration.
  This tiered architecture is implemented at the run level via the global
  `agent_path_override` and `agent_config` settings.
- The `agent_config.claude` setting applies to ALL Claude Code invocations by
  no-mistakes, not just the reviewer. This is intentional — the entire pipeline
  benefits from the cheaper, faster glm-5.3 model.
- For the opus final pass, the operator must temporarily swap both the model
  setting and the `claude-glm` path override. This is a manual step that
  requires captain authorization.
- The operator's global Claude Code settings pin (`~/.claude/settings.json`
  `"model": "opus"`) is never modified. It still applies to interactive Claude Code
  sessions and any tool that does not use no-mistakes' `agent_config` override.
