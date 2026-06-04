#!/usr/bin/env bash
# Capture App Store / marketing screenshots from the demo-seeded app.
#
#   scripts/screenshots.sh [light|dark]   (default: light)
#
# Builds + runs the SeptenaUITests/ScreenshotTests UI test, which launches the
# app with `-SeptenaSeed demo` (in-memory store, CloudKit off, curated data),
# walks the key screens, and saves each as an attachment. We then extract the
# PNGs to ~/Desktop/septena-screenshots/<appearance>/ and open the folder.
set -euo pipefail

APPEARANCE="${1:-light}"
SIM_NAME="iPhone 16 Pro Max"           # App Store 6.9"
OUT="$HOME/Desktop/septena-screenshots/$APPEARANCE"
RESULT="/tmp/septena-shots.xcresult"

cd "$(dirname "$0")/.."

SIM=$(xcrun simctl list devices available | grep "$SIM_NAME (" | head -1 \
      | grep -oE '\([0-9A-F-]{36}\)' | tr -d '()')
[ -z "$SIM" ] && { echo "No '$SIM_NAME' simulator found"; exit 1; }
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl ui "$SIM" appearance "$APPEARANCE" 2>/dev/null || true

rm -rf "$RESULT"
xcodebuild test -scheme Septena \
  -destination "platform=iOS Simulator,id=$SIM" \
  -resultBundlePath "$RESULT" \
  -only-testing:SeptenaUITests/ScreenshotTests \
  -configuration Debug

rm -rf "$OUT" && mkdir -p "$OUT"
xcrun xcresulttool export attachments --path "$RESULT" --output-path "$OUT" >/dev/null
python3 - "$OUT" <<'PY'
import json, os, sys
d = sys.argv[1]
for a in json.load(open(os.path.join(d, "manifest.json")))[0]["attachments"]:
    src = os.path.join(d, a["exportedFileName"])
    if not os.path.exists(src):
        continue
    base = a["suggestedHumanReadableName"].split("_0_")[0]
    if base.startswith("00-"):          # drop the diagnostic hierarchy dump
        os.remove(src); continue
    if not base.endswith((".png", ".txt")):
        base += ".png"
    os.rename(src, os.path.join(d, base))
os.remove(os.path.join(d, "manifest.json"))
print("screenshots →", d)
PY
open "$OUT" 2>/dev/null || true
