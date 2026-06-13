#!/usr/bin/env bash
# Capture raw App Store screenshots for one device class, straight into
# appstore/raw/<device>/<appearance>/. Generalizes the old screenshots.sh.
#
#   appstore/capture.sh <device> [light|dark]
#     device: iphone69 | ipad13 | mac
#     (watch is captured manually: xcrun simctl io <watch-sim> screenshot)
#
# Each device runs the right scheme/destination, then extracts the UI-test
# attachments and renames them to the basenames panels.config.mjs expects.
set -euo pipefail

DEVICE="${1:?usage: capture.sh <iphone69|ipad13|mac> [light|dark]}"
APPEARANCE="${2:-light}"
cd "$(dirname "$0")/.."                      # repo root
OUT="appstore/raw/$DEVICE/$APPEARANCE"
RESULT="/tmp/septena-shots-$DEVICE.xcresult"

case "$DEVICE" in
  iphone69) SCHEME=Septena    SIM="iPhone 16 Pro Max"      ONLY="SeptenaUITests" ;;
  ipad13)   SCHEME=Septena    SIM="iPad Pro 13-inch (M4)"  ONLY="SeptenaUITests" ;;
  mac)      SCHEME=SeptenaMac SIM=""                       ONLY="SeptenaMacUITests" ;;
  *) echo "unknown device: $DEVICE"; exit 1 ;;
esac

rm -rf "$RESULT"
if [ "$DEVICE" = "mac" ]; then
  xcodebuild test -scheme "$SCHEME" -destination 'platform=macOS' \
    -resultBundlePath "$RESULT" -only-testing:"$ONLY" -configuration Debug
else
  SIM_ID=$(xcrun simctl list devices available | grep "$SIM (" | head -1 \
           | grep -oE '\([0-9A-F-]{36}\)' | tr -d '()')
  [ -z "$SIM_ID" ] && { echo "No '$SIM' simulator found"; exit 1; }
  xcrun simctl boot "$SIM_ID" 2>/dev/null || true
  xcrun simctl ui "$SIM_ID" appearance "$APPEARANCE" 2>/dev/null || true
  xcodebuild test -scheme "$SCHEME" -destination "platform=iOS Simulator,id=$SIM_ID" \
    -resultBundlePath "$RESULT" -only-testing:"$ONLY" -configuration Debug
fi

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
    if base.startswith("00-"):            # diagnostic dump, skip
        os.remove(src); continue
    if not base.endswith((".png", ".txt")):
        base += ".png"
    os.rename(src, os.path.join(d, base))
os.remove(os.path.join(d, "manifest.json"))
print("→", d, "::", sorted(f for f in os.listdir(d) if f.endswith(".png")))
PY
echo "✓ $DEVICE/$APPEARANCE captured. Next: cd appstore && npm run all"
