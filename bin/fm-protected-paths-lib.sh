# fm-protected-paths-lib.sh - merge-content gate helpers (Lesson 1 from AutoCraft)
#
# This library provides:
#   1. Reading the protected-path list (global + per-project override)
#   2. Checking a set of diff paths against the protected list
#   3. Reading/writing second-look verdicts for merge gating
#
# The protected-path list is in config/protected-paths (global) and
# optionally config/protected-paths in a project's worktree (per-project override).
# When a project has its own file, it replaces the global list entirely.
#
# Second-look verdicts are stored in state/<task-id>/.second-look/<pr-number>.verdict
# with the format: verdict=<clean|defect|unsure> head=<commit-sha> time=<epoch>
# An unsure verdict "sticks" for any future head of the same PR chain until a
# clean verdict is recorded.

# fm_protected_paths_list <project-dir-or-empty>:
#   Prints one glob pattern per line to stdout.
#   If <project-dir-or-empty> is a non-empty directory, reads its
#   config/protected-paths (per-project override). Otherwise reads the
#   global config/protected-paths.
#   Returns 0 on success, 2 if neither file exists (missing config),
#   3 if the file exists but contains no non-comment, non-empty lines.
_fm_pp_list_rc=0
fm_protected_paths_list() {
  _fm_pp_list_rc=0
  local proj_dir="${1:-}"
  local paths_file

  if [ -n "$proj_dir" ] && [ -d "$proj_dir" ]; then
    paths_file="$proj_dir/config/protected-paths"
    if [ -f "$paths_file" ] && [ ! -L "$paths_file" ]; then
      local filtered
      filtered=$(cat "$paths_file" | grep -v '^\s*#' | grep -v '^\s*$' || true)
      if [ -z "$filtered" ]; then
        _fm_pp_list_rc=3
        return 3
      fi
      printf '%s\n' "$filtered"
      return 0
    fi
  fi

  # Fall back to global list
  paths_file="$FM_ROOT/config/protected-paths"
  if [ -f "$paths_file" ] && [ ! -L "$paths_file" ]; then
    local filtered
    filtered=$(cat "$paths_file" | grep -v '^\s*#' | grep -v '^\s*$' || true)
    if [ -z "$filtered" ]; then
      _fm_pp_list_rc=3
      return 3
    fi
    printf '%s\n' "$filtered"
    return 0
  fi

  return 2
}

# fm_protected_paths_check <diff-paths-file> <project-dir-or-empty>:
#   Checks each path in <diff-paths-file> (one per line) against the
#   protected-path list. Prints matching paths to stdout, one per line.
#   Returns 0 if any paths match, 1 if none match.
fm_protected_paths_check() {
  local diff_file="$1"
  local proj_dir="${2:-}"
  local patterns
  local matched=()
  local list_rc=0

  patterns=$(fm_protected_paths_list "$proj_dir") || list_rc=$?
  # Return code 2 means missing config (fail-closed for security gate)
  [ "$list_rc" -eq 2 ] && return 3
  # Return code 3 means config exists but is empty (fail-closed for security gate)
  [ "$list_rc" -eq 3 ] && return 3
  [ "$list_rc" -eq 1 ] && return 1

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    # Skip paths that are only added (not modified/deleted) - we gate on changes to existing files
    # Check against each pattern
    while IFS= read -r pattern; do
      [ -n "$pattern" ] || continue
      # Use bash glob matching
      # shellcheck disable=SC2254
      case "$path" in
        $pattern)
          matched+=("$path")
          break
          ;;
      esac
    done <<< "$patterns"
  done < "$diff_file"

  if [ "${#matched[@]}" -gt 0 ]; then
    printf '%s\n' "${matched[@]}"
    return 0
  fi
  return 1
}

# fm_protected_paths_check_diff <diff-output>:
#   Checks git diff output (raw format) against protected paths.
#   Prints matching paths to stdout. Returns 0 if any match.
#   Usage: git diff --name-status HEAD..BRANCH | fm_protected_paths_check_diff
fm_protected_paths_check_diff() {
  local proj_dir="${1:-}"
  local matched=()

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # Extract the path (after status tab)
    local path="${line##*$'\t'}"
    [ -n "$path" ] || continue

    local patterns
    patterns=$(fm_protected_paths_list "$proj_dir") || continue

    while IFS= read -r pattern; do
      [ -n "$pattern" ] || continue
      # shellcheck disable=SC2254
      case "$path" in
        $pattern)
          matched+=("$path")
          break
          ;;
      esac
    done <<< "$patterns"
  done

  if [ "${#matched[@]}" -gt 0 ]; then
    printf '%s\n' "${matched[@]}"
    return 0
  fi
  return 1
}

# Second-look verdict storage:
#   Verdicts live in state/<task-id>/.second-look/<pr-number>.verdict
#   Format:
#     verdict=<clean|defect|unsure>
#     head=<commit-sha>
#     time=<unix-epoch>
#     defect_reason=<free text, single line>

# fm_second_look_verdict_dir <state-dir> <task-id> <pr-number>:
#   Returns the directory path for this PR's second-look verdicts.
#   Creates the directory if it doesn't exist.
fm_second_look_verdict_dir() {
  local state_dir="$1"
  local task_id="$2"
  local pr_number="$3"
  local verdict_dir="$state_dir/$task_id/.second-look/$pr_number"

  mkdir -p "$verdict_dir" 2>/dev/null || return 1
  printf '%s' "$verdict_dir"
}

# fm_second_look_read_verdict <verdict-dir>:
#   Reads the current verdict file. Prints the verdict (clean/defect/unsure)
#   to stdout. Returns 1 if no verdict exists.
fm_second_look_read_verdict() {
  local verdict_dir="$1"
  local verdict_file="$verdict_dir/current.verdict"

  [ -f "$verdict_file" ] && [ ! -L "$verdict_file" ] \
    || return 1

  grep '^verdict=' "$verdict_file" 2>/dev/null | cut -d= -f2-
}

# fm_second_look_write_verdict <verdict-dir> <verdict> <head-sha> [<reason>]:
#   Writes a new verdict, replacing any existing one.
#   verdict must be clean, defect, or unsure.
#   Returns 0 on success, 1 on failure.
fm_second_look_write_verdict() {
  local verdict_dir="$1"
  local verdict="$2"
  local head_sha="$3"
  local reason="${4:-}"
  local epoch
  epoch=$(date +%s)
  local verdict_file="$verdict_dir/current.verdict"

  case "$verdict" in
    clean|defect|unsure) ;;
    *) echo "error: invalid second-look verdict: $verdict" >&2; return 1 ;;
  esac

  {
    printf 'verdict=%s\n' "$verdict"
    printf 'head=%s\n' "$head_sha"
    printf 'time=%s\n' "$epoch"
    if [ -n "$reason" ]; then
      printf 'defect_reason=%s\n' "$reason"
    fi
  } > "$verdict_file"

  # Ensure only the owner can read/write
  chmod 600 "$verdict_file" 2>/dev/null || true
  return 0
}

# fm_second_look_verdict_sticks <verdict-dir> <new-verdict>:
#   Returns 0 if the new verdict sticks (is accepted), 1 if it is blocked
#   by an older unsure/defect verdict on the same PR.
#   "unsure" verdicts stick until a clean verdict clears them.
#   "defect" verdicts stick until a clean verdict clears them.
fm_second_look_verdict_sticks() {
  local verdict_dir="$1"
  local new_verdict="$2"
  local history_file="$verdict_dir/history"

  [ -f "$verdict_dir/current.verdict" ] \
    || return 0  # No existing verdict, new one is accepted

  local current
  current=$(fm_second_look_read_verdict "$verdict_dir") || return 0

  # A clean verdict clears the slate
  [ "$current" = "clean" ] && return 0

  # An unsure verdict sticks: only a clean verdict clears it
  if [ "$current" = "unsure" ]; then
    [ "$new_verdict" = "clean" ] && return 0
    return 1  # New verdict blocked by stuck unsure
  fi

  # A defect verdict sticks: only a clean verdict clears it
  if [ "$current" = "defect" ]; then
    [ "$new_verdict" = "clean" ] && return 0
    return 1  # New verdict blocked by stuck defect
  fi

  return 0
}

# fm_second_look_get_stuck_reason <verdict-dir>:
#   Returns the reason why the current verdict sticks, or empty if it doesn't.
fm_second_look_get_stuck_reason() {
  local verdict_dir="$1"
  local current
  current=$(fm_second_look_read_verdict "$verdict_dir") || return 0

  case "$current" in
    unsure)
      printf 'an unsure second-look verdict is still active for this PR; a clean verdict is required before auto-merge'
      ;;
    defect)
      local reason
      reason=$(grep '^defect_reason=' "$verdict_dir/current.verdict" 2>/dev/null | cut -d= -f2-)
      if [ -n "$reason" ]; then
        printf 'a second-look defect verdict is still active: %s' "$reason"
      else
        printf 'a second-look defect verdict is still active for this PR; a clean verdict is required before auto-merge'
      fi
      ;;
  esac
}
