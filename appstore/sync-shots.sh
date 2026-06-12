#!/usr/bin/env bash
# Pull raw captures from scripts/screenshots.sh output into appstore/raw/.
#   appstore/sync-shots.sh            # syncs light + dark if present
set -euo pipefail
cd "$(dirname "$0")"

SRC="$HOME/Desktop/septena-screenshots"
[ -d "$SRC" ] || { echo "No captures at $SRC — run scripts/screenshots.sh first"; exit 1; }

for AP in light dark; do
  [ -d "$SRC/$AP" ] || continue
  mkdir -p "raw/iphone69/$AP"
  cp "$SRC/$AP"/*.png "raw/iphone69/$AP/" 2>/dev/null || true
  echo "✓ raw/iphone69/$AP ← $(ls "raw/iphone69/$AP" | wc -l | tr -d ' ') captures"
done
