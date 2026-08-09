#!/usr/bin/env bash
# Build, sign, notarize, and package the direct-distribution Septask Mac app.
#
# Release inputs:
#   SEPTASK_SIGN_IDENTITY       Developer ID Application identity
#   APPLE_API_KEY_PATH or
#   APPLE_API_KEY               App Store Connect .p8 contents
#   APPLE_API_KEY_ID
#   APPLE_API_ISSUER_ID
#   SPARKLE_PUBLIC_ED_KEY       public Ed25519 key compiled into the app
#   SEPTASK_PROVISION_PROFILE   optional profile for the CloudKit entitlements
#
# The default is a local Release build with ad-hoc signing. CI uses
# --notarize, which fails closed when Developer ID / notarization inputs are
# missing instead of publishing an artifact Gatekeeper will reject.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG=Release
NOTARIZE=0

for arg in "$@"; do
  case "$arg" in
    --notarize) NOTARIZE=1 ;;
    --debug) CONFIG=Debug ;;
    --release) CONFIG=Release ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "error: unknown argument: $arg" >&2; exit 1 ;;
  esac
done

if [[ "$NOTARIZE" -eq 1 && "$CONFIG" != Release ]]; then
  echo "error: --notarize requires --release" >&2
  exit 1
fi
if [[ "$NOTARIZE" -eq 1 && -z "${SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
  echo "error: SPARKLE_PUBLIC_ED_KEY is required for a signed release" >&2
  exit 1
fi

VERSION="$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/project.yml" | head -1)"
BUILD="$(git -C "$ROOT" rev-list --count HEAD)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
  echo "error: project.yml has no valid MARKETING_VERSION" >&2; exit 1;
}
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || { echo "error: invalid git build number: $BUILD" >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "error: Xcode is required" >&2; exit 1; }

DERIVED="$ROOT/.build-macos-release"
DIST="$ROOT/dist"
rm -rf "$DIST"
mkdir -p "$DIST"

echo "Building Septask $VERSION ($BUILD) [$CONFIG]"
xcodebuild \
  -project "$ROOT/Septena.xcodeproj" \
  -scheme SeptaskMac \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}" \
  build

APP="$DERIVED/Build/Products/$CONFIG/Septask.app"
[[ -d "$APP" ]] || { echo "error: Septask.app not found at $APP" >&2; exit 1; }

expanded_entitlements() {
  local out
  out="$(mktemp -t septask-entitlements).plist"
  sed "s/\$(TeamIdentifierPrefix)/${1}./g" \
    "$ROOT/Septask/SeptaskMac.entitlements" > "$out"
  printf '%s' "$out"
}

sign_nested_code() {
  local identity="$1"
  # Sparkle contains helper apps/XPC services inside its framework. Sign those
  # first, then the framework, then the main application. The app entitlements
  # are deliberately applied only to Septask.app.
  while IFS= read -r bundle; do
    codesign --force --options runtime --timestamp --sign "$identity" "$bundle"
  done < <(find "$APP/Contents/Frameworks" -type d \
    \( -name '*.app' -o -name '*.xpc' \) -print | sort -r)
  while IFS= read -r framework; do
    codesign --force --options runtime --timestamp --sign "$identity" "$framework"
  done < <(find "$APP/Contents/Frameworks" -type d -name '*.framework' -print | sort -r)
}

sign_release() {
  local identity="${SEPTASK_SIGN_IDENTITY:-}"
  [[ -n "$identity" ]] || {
    echo "error: SEPTASK_SIGN_IDENTITY is required for --notarize" >&2; exit 1;
  }

  local entitlements
  entitlements="$(expanded_entitlements "${SEPTASK_TEAM_ID:-}")"
  if [[ -n "${SEPTASK_PROVISION_PROFILE:-}" ]]; then
    [[ -f "$SEPTASK_PROVISION_PROFILE" ]] || {
      echo "error: SEPTASK_PROVISION_PROFILE does not exist" >&2; exit 1;
    }
    cp "$SEPTASK_PROVISION_PROFILE" "$APP/Contents/embedded.provisionprofile"
  else
    echo "warning: no SEPTASK_PROVISION_PROFILE; CloudKit may be unavailable" >&2
  fi

  sign_nested_code "$identity"
  codesign --force --options runtime --timestamp \
    --sign "$identity" --entitlements "$entitlements" "$APP"
  rm -f "$entitlements"
  codesign --verify --deep --strict --verbose=2 "$APP"
}

if [[ "$NOTARIZE" -eq 1 ]]; then
  sign_release
else
  codesign --force --deep --sign - "$APP"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/Septask-macOS.zip"
cat > "$DIST/version.txt" <<EOF
version=$VERSION
build=$BUILD
config=$CONFIG
notarized=$NOTARIZE
EOF

if [[ "$NOTARIZE" -eq 1 ]]; then
  KEY_PATH="${APPLE_API_KEY_PATH:-}"
  TEMP_KEY=""
  if [[ -z "$KEY_PATH" ]]; then
    [[ -n "${APPLE_API_KEY:-}" ]] || { echo "error: APPLE_API_KEY(_PATH) is required" >&2; exit 1; }
    TEMP_KEY="$(mktemp -t septask-auth-key).p8"
    printf '%s\n' "$APPLE_API_KEY" > "$TEMP_KEY"
    chmod 600 "$TEMP_KEY"
    KEY_PATH="$TEMP_KEY"
  fi
  [[ -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER_ID:-}" ]] || {
    echo "error: APPLE_API_KEY_ID and APPLE_API_ISSUER_ID are required" >&2; exit 1;
  }
  xcrun notarytool submit "$DIST/Septask-macOS.zip" \
    --key "$KEY_PATH" --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER_ID" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  rm -f "$TEMP_KEY"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/Septask-macOS.zip"
fi

echo "Built $DIST/Septask-macOS.zip ($VERSION+$BUILD)"
