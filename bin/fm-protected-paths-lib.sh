#!/usr/bin/env bash
# fm-protected-paths-lib.sh - merge-content gate helpers (Lesson 1 from AutoCraft)
#
# This library provides:
#   1. Reading the protected-path list (tracked default + per-project override)
#   2. Checking a set of diff paths against the protected list
#   3. Reading/writing second-look verdicts for merge gating
#
# The protected-path list resolves in exactly two steps:
#   1. <project>/config/protected-paths - a project's own list; when present it
#      replaces the tracked default entirely. A present-but-empty file disarms
#      the gate, so every merge in that project is refused until the list is
#      restored (fail-closed).
#   2. bin/fm-protected-paths.default - the tracked default list this repo
#      maintains, carrying the adopted classes (CI/workflow configuration,
#      agent-instruction files, lockfiles, submodule pointers, binaries).
# An absent default is a broken installation and is also fail-closed.
#
# Second-look verdicts are stored in state/<task-id>/.second-look/<pr-number>/current.verdict
# with the format: verdict=<clean|defect|unsure> head=<commit-sha> time=<epoch>
# A verdict is bound to the head it reviewed: the merge gates compare the stored
# head against the current head, and a verdict for another head is treated as
# absent, so a new commit can never inherit an old clean verdict.

# fm_protected_paths_list <project-dir-or-empty>:
#   Prints one glob pattern per line to stdout.
#   If <project-dir-or-empty> is a non-empty directory carrying its own
#   config/protected-paths, that per-project list replaces the default.
#   Otherwise the tracked default bin/fm-protected-paths.default is printed.
#   Returns 0 on success, 2 if no list file exists (broken installation),
#   3 if the resolved file exists but contains no non-comment, non-empty lines
#   (a deliberately disarmed gate; callers refuse the merge).
fm_protected_paths_list() {
  local proj_dir="${1:-}"
  local paths_file filtered

  if [ -n "$proj_dir" ] && [ -d "$proj_dir" ]; then
    paths_file="$proj_dir/config/protected-paths"
    if [ -f "$paths_file" ] && [ ! -L "$paths_file" ]; then
      filtered=$(grep -v '^[[:space:]]*#' "$paths_file" | grep -v '^[[:space:]]*$' || true)
      if [ -z "$filtered" ]; then
        return 3
      fi
      printf '%s\n' "$filtered"
      return 0
    fi
  fi

  # Tracked default list ships with the repo, next to this library in bin/.
  # Resolve it from the library's own directory so a fabricated or alternate
  # FM_ROOT cannot strand the gate without its list.
  local lib_dir
  lib_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) 2>/dev/null || lib_dir=$FM_ROOT
  paths_file="$lib_dir/fm-protected-paths.default"
  if [ -f "$paths_file" ] && [ ! -L "$paths_file" ]; then
    filtered=$(grep -v '^[[:space:]]*#' "$paths_file" | grep -v '^[[:space:]]*$' || true)
    if [ -z "$filtered" ]; then
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
  # Return code 2 means no list file exists anywhere (broken installation):
  # refuse rather than merge unguarded.
  [ "$list_rc" -eq 2 ] && return 3
  # Return code 3 means the resolved file exists but is empty (a deliberately
  # disarmed gate): refuse rather than merge unguarded.
  [ "$list_rc" -eq 3 ] && return 3
  [ "$list_rc" -eq 1 ] && return 1

  while IFS= read -r path; do
    [ -n "$path" ] || continue
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

# Second-look verdict storage:
#   Verdicts live in state/<task-id>/.second-look/<pr-number>/current.verdict
#   Format:
#     verdict=<clean|defect|unsure>
#     head=<commit-sha>
#   Local-only merges use pr-number=0.
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
