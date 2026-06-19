#!/bin/bash
# Locked Xcode build — serializes builds across parallel agent sessions and the
# hourly commit-cron (~/Library/Scripts/septena-git-commit.sh shares this lock).
#
# Why a lock: 3–5 Claude sessions + the cron can otherwise run concurrent
# xcodebuild/xcodegen against shared state and corrupt incremental builds.
# Builds the repo this script LIVES in (not the cwd), so it does the right thing
# when called as "<main-worktree>/scripts/build.sh" from elsewhere.
#
# Usage:  scripts/build.sh [scheme] [destination]
#   defaults: Septena (iOS, embeds watch+widgets+live activity), generic/platform=iOS
set -o pipefail

LOCKDIR="/tmp/septena-build.lock.d"
STALE=3600          # steal the lock if older than 1h (a hung build/cron)
MAX_WAIT=1800       # give up after 30m of waiting

SCHEME="${1:-Septena}"
DEST="${2:-generic/platform=iOS}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" \
  || { echo "build.sh: not inside a git repo"; exit 1; }

waited=0
until mkdir "$LOCKDIR" 2>/dev/null; do
  age=$(( $(date +%s) - $(stat -f%m "$LOCKDIR" 2>/dev/null || date +%s) ))
  if [ "$age" -gt "$STALE" ]; then
    echo "build.sh: stealing stale lock (age ${age}s)"; rmdir "$LOCKDIR" 2>/dev/null; continue
  fi
  if [ "$waited" -ge "$MAX_WAIT" ]; then
    echo "build.sh: lock held >${MAX_WAIT}s, giving up"; exit 1
  fi
  echo "build.sh: waiting for build lock… (${waited}s)"; sleep 5; waited=$((waited+5))
done
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

# Isolate CLI builds from Xcode's DerivedData. xcodebuild's default DerivedData
# is keyed by the .xcodeproj path, so a build.sh run on the MAIN tree lands in
# the SAME folder Xcode uses for device Run. These CLI builds come out UNSIGNED
# (no keychain/profile resolution in an agent shell), so Xcode then treats the
# unsigned .app as up-to-date, installs it as-is, and the device rejects it with
# "No code signature found." Give CLI builds their own per-repo DerivedData
# (keyed by path, like the cron's $CRON_DERIVED) so they can never poison the
# IDE's products. Worktrees, already on distinct paths, stay isolated too.
DERIVED="/tmp/septena-agent-derived/$(printf '%s' "$REPO" | shasum | cut -c1-12)"

echo "build.sh: building $SCHEME [$DEST] in $REPO (derived: $DERIVED)"
( cd "$REPO" && xcodebuild -scheme "$SCHEME" -destination "$DEST" -configuration Debug \
    -derivedDataPath "$DERIVED" build )
