#!/usr/bin/env bash
# Generate the Sparkle appcast and public landing page deployed to the custom
# GitHub Pages domain. The ZIP itself remains a GitHub Release asset.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE="${1:?usage: $0 ARCHIVE VERSION TAG OUTPUT_DIR}"
VERSION="${2:?usage: $0 ARCHIVE VERSION TAG OUTPUT_DIR}"
TAG="${3:?usage: $0 ARCHIVE VERSION TAG OUTPUT_DIR}"
OUTPUT="${4:?usage: $0 ARCHIVE VERSION TAG OUTPUT_DIR}"
REPO="${GITHUB_REPOSITORY:-septena/septena}"

[[ -f "$ARCHIVE" ]] || { echo "error: archive not found: $ARCHIVE" >&2; exit 1; }
[[ -n "${SPARKLE_PRIVATE_ED_KEY:-}" ]] || {
  echo "error: SPARKLE_PRIVATE_ED_KEY is required" >&2; exit 1;
}

TOOL="${SPARKLE_GENERATE_APPCAST:-}"
if [[ -z "$TOOL" ]]; then
  TOOL="$(find "$ROOT" "$HOME/Library/Developer/Xcode/DerivedData" \
    -type f -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast' \
    -perm -111 -print 2>/dev/null | head -1 || true)"
fi
[[ -x "$TOOL" ]] || {
  echo "error: Sparkle generate_appcast not found; set SPARKLE_GENERATE_APPCAST" >&2
  exit 1
}

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT"
cp "$ARCHIVE" "$OUTPUT/Septask-macOS.zip"
DOWNLOAD_PREFIX="https://github.com/$REPO/releases/download/$TAG"
printf '%s' "$SPARKLE_PRIVATE_ED_KEY" | "$TOOL" "$OUTPUT" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --ed-key-file - \
  --maximum-versions 10

cat > "$OUTPUT/CNAME" <<'EOF'
updates.centaur-labs.io
EOF
cat > "$OUTPUT/index.html" <<EOF
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Septask updates</title>
<style>body{font:16px -apple-system,BlinkMacSystemFont,sans-serif;max-width:42rem;margin:5rem auto;padding:0 1.5rem;color:#222}a{color:#6d4aff}</style>
<h1>Septask updates</h1>
<p>Current release: <strong>$VERSION</strong>.</p>
<p><a href="https://github.com/$REPO/releases/tag/$TAG">Release notes and downloads on GitHub</a></p>
<p>This page publishes the signed update feed used by Septask for macOS.</p>
</html>
EOF

echo "Generated $OUTPUT/appcast.xml for Septask $VERSION ($TAG)"
