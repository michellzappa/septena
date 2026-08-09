#!/usr/bin/env bash
# Tag the current project.yml MARKETING_VERSION so GitHub Actions can publish
# the signed Septask Mac release.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/project.yml" | head -1)"
TAG="v$VERSION"
DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

cd "$ROOT"
[[ -z "$(git status --porcelain)" ]] || { echo "error: working tree dirty" >&2; exit 1; }
git rev-parse "$TAG" >/dev/null 2>&1 && { echo "error: $TAG already exists" >&2; exit 1; }

if [[ "$DRY" -eq 1 ]]; then
  echo "would create and push $TAG"
  exit 0
fi
git tag -a "$TAG" -m "Septask $VERSION"
git push origin "$TAG"
echo "Pushed $TAG; GitHub Actions will publish the signed macOS release."
