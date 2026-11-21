#!/usr/bin/env bash
# fm-second-look.sh - second-look verdict runner (Lesson 2 from AutoCraft)
#
# Reads an existing second-look verdict for the requested head and prints it,
# or prints 'unsure' and exits 1 when no verdict for that head exists. It does
# not spawn the reviewer itself and no firstmate code does either: spawning
# the independent adversarial agent - whose only job is to find a reason this
# change should NOT land - is an operator action pending firstmate wiring
# (docs/configuration.md "AutoCraft Hardening Lessons" owns the loop).
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
# Prints the stored verdict to stdout (exiting 0 only for clean). This script
# never writes the verdict file; the operator records the reviewer's verdict
# at state/<task-id>/.second-look/<pr-number>/current.verdict (with
# defect_reason=<text> for defect verdicts). The brief built below is the
# reviewer contract the operator hands to the spawned agent; no code
# consumes it.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-protected-paths-lib.sh
. "$SCRIPT_DIR/fm-protected-paths-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

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
# (bin/fm-pr-merge.sh arms FM_PR_NUMBER through fm_pr_url_parse), so the
# verdict this runner writes lands in the directory the gate reads.
PR_NUMBER=""
if fm_pr_url_parse "$PR_URL"; then
  PR_NUMBER="$FM_PR_NUMBER"
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
# shellcheck disable=SC2034 # The brief is the reviewer contract the operator hands to the spawned agent; no code consumes it.
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

# The spawn is operator-driven for now: nothing in firstmate dispatches a
# reviewer or calls this script. The merge gates read the verdict file
# directly through fm-protected-paths-lib.sh; this runner exists so the
# operator can query the recorded verdict for a head.

# Check if a verdict file has been recorded by the reviewer
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
      case "$VERDICT" in
        clean) exit 0 ;;
        *) exit 1 ;;
      esac
    fi
  fi
fi

# No verdict for this head exists yet. Without one:
# - If yolo is on and protected paths are touched, the merge gate refuses.
# - If yolo is off, the merge always escalates to the captain.
# The verdict must be recorded by the operator's reviewer; the merge gates
# (fm-pr-merge.sh, fm-merge-local.sh) check for it via
# fm-protected-paths-lib.sh before proceeding.

echo "unsure"
exit 1
