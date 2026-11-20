#!/usr/bin/env bash
# fm-second-look.sh - adversarial second-look reviewer (Lesson 2 from AutoCraft)
#
# Spawns an independent reviewer agent to re-review a merge head with an
# adversarial posture: find reasons NOT to land the change.
#
# Verdicts:
#   clean   - no defects found; auto-merge may proceed
#   defect  - defects found; auto-merge is blocked, escalates to captain
#   unsure  - uncertain; auto-merge is blocked, escalates to captain
#
# The reviewer is always a different session from the implementation worker.
# Verdicts are stored durably in state/<task-id>/.second-look/<pr-number>.
#
# Usage:
#   fm-second-look.sh --task-id <id> --pr-url <url> --head <sha> [--project <dir>]
#
# Outputs the verdict to stdout (clean/defect/unsure) and writes the verdict
# file. On defect or unsure, also writes defect_reason=<text>.
#
# The spawn uses the standard harness dispatch (via fm-spawn.sh) to ensure
# consistent model selection and quota routing. The reviewer brief is built
# here and passed as a steer.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-protected-paths-lib.sh
. "$SCRIPT_DIR/fm-protected-paths-lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: fm-second-look.sh --task-id <id> --pr-url <url> --head <sha> [--project <dir>]

Adversarial second-look reviewer. Spawns an independent agent to review
the merge head and produce a verdict (clean/defect/unsure).
EOF
}

# Parse arguments
TASK_ID=
PR_URL=
HEAD_SHA=
PROJECT_DIR=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --task-id) shift; TASK_ID="${1:-}" ;;
    --pr-url)  shift; PR_URL="${1:-}" ;;
    --head)    shift; HEAD_SHA="${1:-}" ;;
    --project) shift; PROJECT_DIR="${1:-}" ;;
    --help|-h) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

[ -n "$TASK_ID" ] || { echo "error: --task-id is required" >&2; exit 2; }
[ -n "$PR_URL" ]  || { echo "error: --pr-url is required" >&2; exit 2; }
[ -n "$HEAD_SHA" ] || { echo "error: --head is required" >&2; exit 2; }

# Derive PR number from URL using the same parser as the merge gate
PR_NUMBER=""
if echo "$PR_URL" | grep -q 'github.com\|github\.com\.'; then
  PR_NUMBER=$(echo "$PR_URL" | grep -oP 'pull/(\d+)' | grep -oP '\d+' || true)
elif echo "$PR_URL" | grep -q 'gitlab'; then
  PR_NUMBER=$(echo "$PR_URL" | grep -oP 'merge_requests/(\d+)' | grep -oP '\d+' || true)
elif echo "$PR_URL" | grep -q 'forgejo\|gitea'; then
  PR_NUMBER=$(echo "$PR_URL" | grep -oP 'pulls/(\d+)' | grep -oP '\d+' || true)
fi

if [ -z "$PR_NUMBER" ]; then
  PR_NUMBER="0"
fi

VERDICT_DIR=$(fm_second_look_verdict_dir "$STATE" "$TASK_ID" "$PR_NUMBER")

# Check if a verdict already exists and sticks
EXISTING_VERDICT=""
EXISTING_HEAD=""
if [ -f "$VERDICT_DIR/current.verdict" ]; then
  EXISTING_VERDICT=$(fm_second_look_read_verdict "$VERDICT_DIR")
  # Read the head that the verdict was recorded for
  EXISTING_HEAD=$(grep '^head=' "$VERDICT_DIR/current.verdict" 2>/dev/null | cut -d= -f2- || true)
fi

# If a verdict exists, check if it applies to the current head
if [ -n "$EXISTING_VERDICT" ]; then
  # If we have a --head argument, compare it to the stored head
  if [ -n "$HEAD_SHA" ]; then
    if [ -z "$EXISTING_HEAD" ] || [ "$EXISTING_HEAD" != "$HEAD_SHA" ]; then
      # Verdict is for a different head (or no head recorded) - treat as absent
      EXISTING_VERDICT=""
    fi
  fi
  # If no --head was provided, use the verdict as-is (backward compatible)
  if [ -n "$EXISTING_VERDICT" ]; then
    case "$EXISTING_VERDICT" in
      clean)
        echo "clean"
        exit 0
        ;;
      defect|unsure)
        STUCK_REASON=$(fm_second_look_get_stuck_reason "$VERDICT_DIR")
        echo "$EXISTING_VERDICT"
        echo "BLOCKED: $STUCK_REASON" >&2
        exit 1
        ;;
    esac
  fi
fi

# Build the adversarial brief for the reviewer agent
# This is the "independent agent whose only job is to find a reason this
# change should NOT land"
BRIEF="## Adversarial second-look review

You are an independent code reviewer with an adversarial posture. Your ONLY
job is to find reasons why this change should NOT land.

## What to look for
- Bugs that existing tests miss (edge cases, off-by-one, null/empty handling)
- Security issues (injection, path traversal, auth bypass, information leak)
- Quiet behavior changes (API contract violations, breaking changes)
- Performance regressions (O(n²) loops, unnecessary allocations, blocking I/O)
- Side effects (global state mutation, race conditions, signal handling)
- Test coverage gaps (new code paths without corresponding tests)
- Documentation inconsistencies (code does X but docs say Y)
- Dependency issues (new dependencies with security advisories, license changes)

## Constraints
- You are reviewing the diff between the base commit and the current head.
- Do NOT rewrite the code. Report findings as a list of issues.
- Do NOT assume good faith - review as if the author is trying to sneak
  something past you.
- If you find nothing wrong, say so clearly: the change is clean.

## The change to review
PR URL: $PR_URL
Head commit: $HEAD_SHA
Project: ${PROJECT_DIR:-unspecified}

## Output format
Your response MUST start with one of these verdict lines:
  VERDICT: clean
or
  VERDICT: defect
or
  VERDICT: unsure

Followed by your findings. For defect verdicts, list each finding as:
  FINDING: <severity> - <description>
where severity is critical, high, medium, or low.

For unsure verdicts, explain what information is missing that prevents
a confident assessment.

Remember: your job is to find reasons NOT to land. If you find nothing,
that is a valid finding - report it as clean.
"

# Write the brief to a temp file
BRIEF_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-second-look-brief.XXXXXX")
printf '%s' "$BRIEF" > "$BRIEF_FILE"

# The second-look runner needs to spawn an independent agent.
# The harness dispatch is handled by firstmate - this script is designed
# to be called by firstmate's supervision loop, which spawns the reviewer
# as a separate crewmate with this brief.
#
# For now, output the verdict as a no-op pending firstmate integration.
# The actual spawn happens through firstmate's dispatch.

# In the full implementation, firstmate would:
# 1. Spawn a crewmate with this brief
# 2. Wait for the crewmate to produce a verdict file
# 3. Read the verdict and apply the gate logic

# For the merge gate integration, this script is called from
# fm-pr-merge.sh and fm-merge-local.sh. The verdict is checked before
# the merge proceeds.

# Since this is a library-style script called by merge scripts,
# and the actual agent spawn is orchestrated by firstmate,
# we need to handle the case where firstmate provides the verdict
# via the verdict file (written by a spawned crewmate).

# Check if a verdict file was written by a spawned reviewer
if [ -f "$VERDICT_DIR/current.verdict" ]; then
  VERDICT=$(fm_second_look_read_verdict "$VERDICT_DIR")
  if [ -n "$VERDICT" ]; then
    # Apply the same head binding as the early block
    if [ -n "$HEAD_SHA" ]; then
      stored_head=$(grep '^head=' "$VERDICT_DIR/current.verdict" 2>/dev/null | cut -d= -f2- || true)
      if [ -z "$stored_head" ] || [ "$stored_head" != "$HEAD_SHA" ]; then
        # Verdict is for a different head - fall through to fresh review
        VERDICT=""
      fi
    fi
    if [ -n "$VERDICT" ]; then
      echo "$VERDICT"
      rm -f "$BRIEF_FILE"
      case "$VERDICT" in
        clean) exit 0 ;;
        *) exit 1 ;;
      esac
    fi
  fi
fi

# No verdict exists yet - this is called by the merge gate which needs
# to decide whether to proceed. The verdict must be produced by firstmate
# spawning a reviewer. Without a verdict:
# - If yolo is on AND no second-look verdict exists, the merge gate
#   checks if protected paths are touched. If yes, it refuses.
# - If yolo is off, the merge always escalates to the captain.

# This script is primarily a specification and library for the gate logic.
# The actual adversarial review is performed by firstmate spawning a crewmate.
# The merge gate (fm-pr-merge.sh) checks for the verdict before proceeding.

rm -f "$BRIEF_FILE"
echo "unsure"
exit 1
