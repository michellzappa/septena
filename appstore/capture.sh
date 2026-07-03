#!/usr/bin/env bash
# Capture raw App Store screenshots for one device class, straight into
# appstore/<rawRoot>/<device>/<appearance>/. Generalizes the old screenshots.sh.
#
#   appstore/capture.sh <device> [light|dark]
#     device: iphone69 | ipad13 | mac
#     (watch is captured manually: xcrun simctl io <watch-sim> screenshot)
#
#   SEPTENA_APP=septask appstore/capture.sh iphone69 light   # the Septask app
#
# The app (default "septena") picks the scheme, simulator, UI-test target, and
# raw output root — see apps.mjs. Each device runs the right scheme/destination,
# then extracts the UI-test attachments and renames them to the basenames the
# panel config expects.
set -euo pipefail

DEVICE="${1:?usage: capture.sh <iphone69|ipad13|mac> [light|dark]}"
APPEARANCE="${2:-light}"
APP="${SEPTENA_APP:-septena}"
cd "$(dirname "$0")/.."                      # repo root

case "$APP" in
  septena)
    RAWROOT=raw
    case "$DEVICE" in
      iphone69) SCHEME=Septena    SIM="iPhone 16 Pro Max"      ONLY="SeptenaUITests" ;;
      ipad13)   SCHEME=Septena    SIM="iPad Pro 13-inch (M4)"  ONLY="SeptenaUITests" ;;
      mac)      SCHEME=SeptenaMac SIM=""                       ONLY="SeptenaMacUITests" ;;
      *) echo "unknown device: $DEVICE"; exit 1 ;;
    esac ;;
  septask)
    RAWROOT=raw-septask
    case "$DEVICE" in
      iphone69) SCHEME=Septask    SIM="iPhone 16 Pro Max"      ONLY="SeptaskUITests" ;;
      ipad13)   SCHEME=Septask    SIM="iPad Pro 13-inch (M4)"  ONLY="SeptaskUITests" ;;
      mac)      SCHEME=SeptaskMac SIM=""                       ONLY="SeptaskMacUITests" ;;
      *) echo "unknown device: $DEVICE"; exit 1 ;;
    esac ;;
  *) echo "unknown app: $APP (set SEPTENA_APP=septena|septask)"; exit 1 ;;
esac

# Machines vary in which simulators are installed. Override the default with
# SEPTENA_SIM (e.g. SEPTENA_SIM="iPhone 17 Pro Max") when the configured sim
# isn't present — any 6.9" Pro Max / 13" iPad Pro keeps the ASC pixel size.
SIM="${SEPTENA_SIM:-$SIM}"

OUT="appstore/$RAWROOT/$DEVICE/$APPEARANCE"
RESULT="/tmp/septena-shots-$APP-$DEVICE.xcresult"

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
  # Apple's canonical marketing status bar: 9:41, full Wi-Fi, 100% charged,
  # no carrier text. Persists on the booted sim through the UI-test run, so
  # every captured shot shows the same clean bar instead of wall-clock time.
  xcrun simctl status_bar "$SIM_ID" override \
    --time "9:41" \
    --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode notSupported \
    --batteryState charged --batteryLevel 100 2>/dev/null || true
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
