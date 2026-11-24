#!/usr/bin/env bash
# Upload a generated App Store set to App Store Connect with fastlane deliver.
#
#   appstore/upload.sh <septask|septena> [ios|osx] [--screenshots-only]
#
# Run it after `cd appstore && npm run all:septask` (or `npm run all`) has
# rendered and validated the set. It never uploads a binary and never submits
# for review (fastlane/Deliverfile). Screenshots replace the ones in App Store
# Connect for every device class in the set (overwrite_screenshots).
# --screenshots-only leaves the listing text alone.
#
# Auth: an App Store Connect API key, read from
# ~/.appstoreconnect/septena.json ({"key_id", "issuer_id", "key"}; key is the
# .p8 contents). It lives outside the repo so every worktree and session finds
# it, and no secret is ever committed. Set it up once with
# appstore/asc-key.sh <key id> <issuer id>.
set -euo pipefail

app="${1:?usage: appstore/upload.sh <septask|septena> [ios|osx] [--screenshots-only]}"
platform="${2:-ios}"
mode="${3:-}"
[ "$platform" = "--screenshots-only" ] && { mode="$platform"; platform=ios; }

key="$HOME/.appstoreconnect/septena.json"
[ -f "$key" ] || { echo "upload: no App Store Connect key at $key. Run appstore/asc-key.sh first." >&2; exit 1; }
command -v fastlane >/dev/null || { echo "upload: fastlane is not installed (brew install fastlane)." >&2; exit 1; }

case "$app/$platform" in
  septask/ios) id=com.septena.tasks; meta=metadata-septask;     shots=screenshots-septask ;;
  septask/osx) id=com.septena.tasks; meta=metadata-septask-mac; shots=screenshots-septask-mac ;;
  septena/ios) id=com.septena.cloud; meta=metadata;             shots=screenshots ;;
  septena/osx) id=com.septena.cloud; meta=metadata-mac;         shots=screenshots-mac ;;
  *) echo "upload: unknown app/platform $app/$platform" >&2; exit 1 ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd)"
[ -d "$root/appstore/$shots" ] || { echo "upload: appstore/$shots is missing. Render the set first." >&2; exit 1; }

args=(deliver --api_key_path "$key" --app_identifier "$id" --platform "$platform"
      --metadata_path "appstore/$meta" --screenshots_path "appstore/$shots")
[ "$mode" = "--screenshots-only" ] && args+=(--skip_metadata true)

cd "$root"
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8   # fastlane needs a UTF-8 locale
exec fastlane "${args[@]}"
