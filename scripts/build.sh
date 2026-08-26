#!/bin/bash
# Locked Xcode build — serializes builds across parallel agent sessions and the
# hourly commit-cron (~/Library/Scripts/auto-git-commit.sh shares this lock).
#
# Why a lock: 3–5 Claude sessions + the cron can otherwise run concurrent
# xcodebuild/xcodegen against shared state and corrupt incremental builds.
# Builds the repo this script LIVES in (not the cwd), so it does the right thing
# when called as "<main-worktree>/scripts/build.sh" from elsewhere.
#
# Usage:  scripts/build.sh [scheme] [destination]
#   defaults: Septena (iOS, embeds watch+widgets+live activity), generic/platform=iOS
set -o pipefail

LOCKDIR="/tmp/auto-build.lock.d"
STALE=3600          # steal the lock if older than 1h (a hung build/cron)
MAX_WAIT=1800       # give up after 30m of waiting

SCHEME="${1:-Septena}"
DEST="${2:-generic/platform=iOS}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" \
  || { echo "build.sh: not inside a git repo"; exit 1; }

# Fail fast on the watchOS SDK/runtime gap, BEFORE taking the lock. The iOS
# `Septena` scheme embeds the watch app, so xcodebuild resolves a watch
# destination; if no installed simulator runtime matches the watchOS SDK the
# active Xcode ships, it dies — either at the scheme precondition ("watchOS X
# must be installed") or deeper down in actool compiling the complication's
# asset catalog. Both are the same mismatch wearing different hats, and neither
# says what to do about it. Checking here costs ~200ms and saves a full build
# cycle plus a lock hold that the cron and 3-5 parallel sessions are queued on.
# NEVER auto-install the runtime: that's a multi-GB download and the user's call.
# Both iOS app schemes embed a watch app (see each target's `dependencies:` in
# project.yml: Septena→SeptenaWatch, Septask→SeptaskWatch) — the Mac schemes
# don't, and must not be gated.
if [ "$SCHEME" = "Septena" ] || [ "$SCHEME" = "Septask" ]; then
  want="$(xcodebuild -showsdks 2>/dev/null \
          | sed -n 's/.*-sdk watchsimulator\([0-9][0-9.]*\).*/\1/p' | head -1)"
  if [ -n "$want" ] && ! xcrun simctl list runtimes 2>/dev/null \
       | grep -q "watchOS $want"; then
    have="$(xcrun simctl list runtimes 2>/dev/null \
            | sed -n 's/^watchOS \([0-9][0-9.]*\) .*/\1/p' | paste -sd', ' -)"
    cat >&2 <<EOF
build.sh: can't build '$SCHEME' — no watchOS simulator runtime matches this Xcode.
  Xcode ships watchOS SDK: $want
  Installed runtimes:      ${have:-none}
This scheme embeds the watch app, and there is no flag to skip an embedded
target. Nothing is wrong with the project — Xcode.app works because you pick a
concrete destination it can resolve.
  * Change doesn't touch watch code? Gate it on macOS instead:
        scripts/build.sh SeptenaMac 'platform=macOS'
        scripts/build.sh SeptaskMac 'platform=macOS'
  * Change DOES touch watch code? Stop and tell the user: only they can decide
    to install the watchOS $want runtime (multi-GB). Do not download it.
EOF
    exit 2
  fi
fi

# Design-system guardrail, BEFORE the lock (it's a grep — costs nothing, and a
# convention violation shouldn't wait behind another session's compile). Blocks
# only on the rules that have caused real bugs; typography notes are advisory.
# SEPTENA_SKIP_LINT=1 bypasses.
if [ -x "$REPO/scripts/lint-design.sh" ]; then
  if ! "$REPO/scripts/lint-design.sh"; then
    echo "build.sh: design lint failed — not building."
    exit 3
  fi
fi

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
# Also key by toolchain (DEVELOPER_DIR): a beta-Xcode build sharing the stable
# toolchain's incremental state corrupts it (e.g. actool/simulator-runtime
# mismatches seen 2026-07-11), so each toolchain gets its own cache.
DERIVED="/tmp/septena-agent-derived/$(printf '%s' "$REPO|${DEVELOPER_DIR:-default}" | shasum | cut -c1-12)"

echo "build.sh: building $SCHEME [$DEST] in $REPO (derived: $DERIVED)"
( cd "$REPO" && xcodebuild -scheme "$SCHEME" -destination "$DEST" -configuration Debug \
    -derivedDataPath "$DERIVED" build )
