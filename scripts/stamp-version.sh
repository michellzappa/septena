#!/usr/bin/env bash
#
# stamp-version.sh — set the build number (CFBundleVersion) from the git commit
# count, so every archive carries a monotonically-increasing, conflict-free
# build number without anyone hand-bumping it.
#
# Run this right before archiving for TestFlight / the App Store:
#
#     scripts/stamp-version.sh
#     # …then Product ▸ Archive (or xcodebuild archive)
#
# It rewrites the single CURRENT_PROJECT_VERSION line in Config/Base.xcconfig.
# The marketing version (MARKETING_VERSION in project.yml) is a separate,
# deliberate decision — this script never touches it. See docs/VERSIONING.md.
#
# Idempotent: running it twice on the same commit produces the same number.
set -euo pipefail

cd "$(dirname "$0")/.."

XCCONFIG="Config/Base.xcconfig"
COUNT="$(git rev-list --count HEAD)"

if [[ ! -f "$XCCONFIG" ]]; then
  echo "error: $XCCONFIG not found" >&2
  exit 1
fi

# Replace the value after `CURRENT_PROJECT_VERSION =` in place.
/usr/bin/sed -i '' -E "s/^(CURRENT_PROJECT_VERSION = ).*/\1${COUNT}/" "$XCCONFIG"

echo "Stamped build number → ${COUNT} (in ${XCCONFIG})"
echo "Marketing version stays $(grep -E 'MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"(.*)".*/\1/')"
