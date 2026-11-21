set -eu
# Tripwire for the shared-workspace invariant (header comment): the
# spawn lineage gate needs this checkout's real root commits, so a
# shallow workspace fails loudly here rather than deep inside
# spawn-based suites.
if [ "$(git rev-parse --is-shallow-repository)" != false ]; then
  # A sibling run's depth-1 checkout can shallow the shared workspace
  # between this job's checkout and this step; re-fetch first.
  git fetch --unshallow origin >/dev/null 2>&1 || true
fi
if [ "$(git rev-parse --is-shallow-repository)" != false ] && [ -f .git/shallow ]; then
  # git can leave .git/shallow listing commits whose recorded parents
  # are already local after a full --unshallow fetch. Dropping the
  # stale file is safe exactly when every listed commit's recorded
  # parents exist locally, which proves the history is complete; a
  # genuine truncation keeps the file and fails the assert below.
  stale=true
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    # Parse parents from the raw commit object: unlike rev-list,
    # cat-file ignores the shallow file, so a truly missing parent is
    # detectable even while the boundary is listed.
    object=$(git cat-file -p "$entry" 2>/dev/null) || { stale=false; continue; }
    for parent in $(printf '%s\n' "$object" | sed -n 's/^parent \([0-9a-f]\{40\}\)$/\1/p'); do
      git cat-file -e "$parent^{commit}" 2>/dev/null || stale=false
    done
  done < .git/shallow
  if [ "$stale" = true ]; then
    rm -f .git/shallow
  fi
fi
[ "$(git rev-parse --is-shallow-repository)" = false ] || {
  echo "::error::the runner checkout is shallow; the spawn lineage gate would refuse spawns. Every self-hosted job must check out with fetch-depth: 0."
  exit 1
}
git rev-list --max-parents=0 HEAD >/dev/null
