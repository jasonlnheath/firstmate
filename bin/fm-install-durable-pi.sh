#!/usr/bin/env bash
# fm-install-durable-pi.sh - install the pinned durable-pi checkout for the
# config-gated durable-watcher path (docs/durable-watchers.md owns the
# operator contract; docs/durable-watchers-feasibility.md owns the research
# evidence behind the pin).
#
# Clones github.com/disler/durable-pi at the pinned commit below and runs
# `npm ci` in apps/dpi-backend, so the gated watcher host and benchmark have
# the exact verified backend build. The checkout is home runtime tooling, not
# repo content: it lands in the caller-supplied destination (typically
# $FM_HOME/state/durable-pi, the host's default search path) and nothing in
# firstmate's tracked files depends on it existing.
#
# Requires: git, npm, network access to github.com and the npm registry.
# Refuses without downloading when the destination already holds a checkout,
# when a pin is missing for this platform, or when git/npm are absent.
#
# Usage:
#   fm-install-durable-pi.sh <destination-directory>
#   fm-install-durable-pi.sh --pin          print the pinned commit
set -eu

# Pinned content commit of github.com/disler/durable-pi verified in
# docs/durable-watchers-feasibility.md (2026-11-04, dpi-backend 1.0.3,
# Node v26.8.1, faux provider, restart-mid-tool resume).
PIN=37165c619573dbaf425463038bbffecfe576beec
REPO=https://github.com/disler/durable-pi.git

case "${1:-}" in
  --pin)
    printf '%s\n' "$PIN"
    exit 0
    ;;
esac

DESTINATION=${1:?usage: fm-install-durable-pi.sh <destination-directory>|--pin}

die() {
  printf 'fm-install-durable-pi.sh: %s\n' "$*" >&2
  exit 1
}

command -v git >/dev/null 2>&1 || die "git is required but not installed"
command -v npm >/dev/null 2>&1 || die "npm is required but not installed"

if [ -d "$DESTINATION/apps/dpi-backend/src" ]; then
  die "destination already holds a durable-pi checkout: $DESTINATION/apps/dpi-backend (remove it first to re-install)"
fi

parent=$(dirname "$DESTINATION")
mkdir -p "$parent" || die "cannot create $parent"

# Clone into a staging sibling, verify the pinned commit exists, then move into
# place, so a failed clone or an unknown pin never leaves a half checkout.
staging=$(mktemp -d "$parent/.durable-pi-staging.XXXXXX")
trap 'rm -rf "$staging"' EXIT

git clone --quiet "$REPO" "$staging/checkout" || die "clone of $REPO failed"
git -C "$staging/checkout" cat-file -e "$PIN^{commit}" 2>/dev/null ||
  die "pinned commit $PIN not found in $REPO; the repository moved - re-verify and re-pin before installing"
git -C "$staging/checkout" checkout --quiet "$PIN" ||
  die "checkout of pinned commit $PIN failed"

( cd "$staging/checkout/apps/dpi-backend" && npm ci --no-audit --no-fund --loglevel=error ) ||
  die "npm ci in apps/dpi-backend failed"

mv "$staging/checkout" "$DESTINATION" ||
  die "cannot move the checkout into $DESTINATION"

installed=$(git -C "$DESTINATION" rev-parse HEAD)
[ "$installed" = "$PIN" ] || die "installed HEAD $installed does not match pin $PIN"

printf 'installed: %s at %s\n' "$DESTINATION" "$PIN"
printf 'backend: %s/apps/dpi-backend\n' "$DESTINATION"
