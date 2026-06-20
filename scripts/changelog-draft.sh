#!/usr/bin/env bash
#
# changelog-draft.sh — print the commits since the last release tag as a
# starting point for a new changelog.json entry. It does NOT write anything;
# the changelog is hand-curated (commits → user-facing highlights). Pipe the
# output to yourself (or to Claude) and pick the changes worth announcing.
#
#     scripts/changelog-draft.sh            # since the latest v* tag
#     scripts/changelog-draft.sh v0.1.0     # since a specific tag
#
# Workflow to cut a release (see docs/VERSIONING.md):
#   1) scripts/changelog-draft.sh                  # review what changed
#   2) edit Septena/Resources/changelog.json       # add the curated entry
#   3) bump MARKETING_VERSION in project.yml        # the deliberate version pick
#   4) git tag vX.Y.Z                               # so "since last release" works
#   5) scripts/stamp-version.sh && archive          # build number from git count
set -euo pipefail

cd "$(dirname "$0")/.."

SINCE="${1:-}"
if [[ -z "$SINCE" ]]; then
  SINCE="$(git describe --tags --match 'v*' --abbrev=0 2>/dev/null || true)"
fi

VERSION="$(grep -E 'MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"(.*)".*/\1/')"
DATE="$(date +%Y-%m-%d)"
BUILD="$(git rev-list --count HEAD)"

if [[ -n "$SINCE" ]]; then
  RANGE="${SINCE}..HEAD"
  echo "# Commits since ${SINCE} (curate these into changelog.json):"
else
  RANGE="HEAD"
  echo "# No v* tag found — showing the full history. Curate into changelog.json:"
fi
echo

git log --no-merges --pretty='- %s' "$RANGE"

cat <<EOF

# ─── Skeleton for Septena/Resources/changelog.json (newest entry first) ───
    {
      "version": "${VERSION}",
      "build": ${BUILD},
      "date": "${DATE}",
      "name": null,
      "summary": null,
      "highlights": [
        { "title": "…", "detail": "…", "section": null }
      ]
    }
EOF
