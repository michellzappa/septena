#!/usr/bin/env bash
#
# release-macos.sh — build, sign, notarize and publish the Mac download.
# Guide: docs/RELEASING-MAC.md.
#
#     scripts/release-macos.sh             # build, sign, notarize, check; publish nothing
#     scripts/release-macos.sh --publish   # the same, then tag and publish on GitHub
#
# Runs on a Mac that holds the signing material (mz-mini), so no signing key
# is stored on GitHub. The version is MARKETING_VERSION in project.yml; the
# build number is the git commit count.
#
# Reads (paths can be overridden with the variable of the same name):
#   SEPTENA_SIGN_IDENTITY   Developer ID Application identity in the keychain
#   SEPTENA_PROFILE         Developer ID provisioning profile for com.septena.tasks
#   SEPTENA_SPARKLE_KEY     Sparkle private key (base64 Ed25519 seed)
#   SEPTENA_ASC_ENV         file with ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

die() { echo "error: $*" >&2; exit 1; }

PUBLISH=0
case "${1:-}" in
  "") ;;
  --publish) PUBLISH=1 ;;
  -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
  *) die "unknown argument: $1" ;;
esac

TEAM=992N457T8D
BUNDLE_ID=com.septena.tasks
REPO=michellzappa/septena
# Not secret: installed copies check each update against it. The matching
# private key is SEPTENA_SPARKLE_KEY. Changing it strands installed copies.
SPARKLE_PUBLIC_ED_KEY="Skfl9xBh9KaQJC8CNn9SoBMJw/87UTDTktfatw5OJ5M="
SIGNING="$HOME/.config/signing/centaur-labs"
IDENTITY="${SEPTENA_SIGN_IDENTITY:-Developer ID Application: CENTAUR LABS OU ($TEAM)}"
PROFILE="${SEPTENA_PROFILE:-$SIGNING/profiles/septena-mac-developer-id.provisionprofile}"
SPARKLE_KEY="${SEPTENA_SPARKLE_KEY:-$SIGNING/septena-sparkle-ed25519.key}"
ASC_ENV="${SEPTENA_ASC_ENV:-$SIGNING/asc-centaur.env}"

# --- Checks ---------------------------------------------------------------

[[ -z "$(git status --porcelain)" ]] || die "working tree is dirty"
VERSION="$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\([^"]*\)".*/\1/p' project.yml | head -1)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "project.yml has no valid MARKETING_VERSION"
BUILD="$(git rev-list --count HEAD)"
TAG="v$VERSION"
security find-identity -v -p codesigning | grep -qF "$IDENTITY" || die "identity not in the keychain: $IDENTITY"
for f in "$PROFILE" "$SPARKLE_KEY" "$ASC_ENV"; do [[ -f "$f" ]] || die "missing: $f"; done
command -v xcodegen >/dev/null || die "xcodegen is required"
scripts/check-version-wiring.sh

if [[ "$PUBLISH" -eq 1 ]]; then
  command -v gh >/dev/null || die "gh is required"
  git fetch -q --tags origin
  git merge-base --is-ancestor HEAD origin/main || die "HEAD is not on origin/main"
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    die "$TAG exists; bump MARKETING_VERSION in project.yml"
  fi
fi

# shellcheck disable=SC1090
source "$ASC_ENV"
ASC_KEY="${ASC_KEY_PATH/#\~/$HOME}"
[[ -f "$ASC_KEY" ]] || ASC_KEY="$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8"
[[ -f "$ASC_KEY" ]] || die "App Store Connect key not found: $ASC_KEY"

DERIVED="$ROOT/.build-macos-release"
DIST="$ROOT/dist"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
rm -rf "$DIST"
mkdir -p "$DIST"

notarize() {
  local out
  out="$(xcrun notarytool submit "$1" --key "$ASC_KEY" --key-id "$ASC_KEY_ID" \
    --issuer "$ASC_ISSUER_ID" --wait --output-format json)"
  if [[ "$(plutil -extract status raw - <<<"$out")" != Accepted ]]; then
    xcrun notarytool log "$(plutil -extract id raw - <<<"$out")" --key "$ASC_KEY" \
      --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" >&2 || true
    die "notarization failed for $(basename "$1")"
  fi
}

# --- Build ----------------------------------------------------------------

echo "Building Septena $VERSION ($BUILD)"
xcodegen generate --quiet
xcodebuild -project Septena.xcodeproj -scheme SeptaskMac -configuration Release \
  -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
  clean build > "$DIST/build.log" 2>&1 || { tail -40 "$DIST/build.log" >&2; die "build failed"; }

APP="$WORK/Septena.app"
ditto "$DERIVED/Build/Products/Release/Septena.app" "$APP"
plist() { plutil -extract "$1" raw "$APP/Contents/Info.plist"; }
[[ "$(plist CFBundleShortVersionString)" == "$VERSION" ]] || die "built app has the wrong version"
[[ "$(plist CFBundleVersion)" == "$BUILD" ]] || die "built app has the wrong build number"
[[ "$(plist SUPublicEDKey)" == "$SPARKLE_PUBLIC_ED_KEY" ]] || die "built app has no update key"

# --- Sign, inside out -----------------------------------------------------

# The app's entitlements, without Sign in with Apple (Apple never grants it to
# Developer ID; the app then signs in with a code, SeptaskSignIn.appleAvailable)
# and with the identifiers the data protection keychain needs.
ENTITLEMENTS="$WORK/app.entitlements"
cp Septask/SeptaskMac.entitlements "$ENTITLEMENTS"
/usr/libexec/PlistBuddy \
  -c "Delete :com.apple.developer.applesignin" \
  -c "Add :com.apple.application-identifier string $TEAM.$BUNDLE_ID" \
  -c "Add :com.apple.developer.team-identifier string $TEAM" "$ENTITLEMENTS"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"; }
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SPARKLE/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign --entitlements SeptaskWidgets/SeptaskMacWidgets.entitlements \
  "$APP/Contents/PlugIns/SeptaskMacWidgets.appex"
sign --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"

# --- Notarize and package -------------------------------------------------

ZIP="$DIST/Septena-$VERSION.zip"
DMG="$DIST/Septena.dmg"
zip_app() { rm -f "$ZIP"; ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"; }

zip_app
notarize "$ZIP"
xcrun stapler staple -q "$APP"
zip_app

mkdir "$WORK/dmg"
ditto "$APP" "$WORK/dmg/Septena.app"
ln -s /Applications "$WORK/dmg/Applications"
hdiutil create -quiet -volname Septena -srcfolder "$WORK/dmg" -format UDZO "$DMG"
codesign --timestamp --sign "$IDENTITY" "$DMG"
notarize "$DMG"
xcrun stapler staple -q "$DMG"

spctl --assess --type execute "$APP" || die "Gatekeeper rejects the app"
spctl --assess --type open --context context:primary-signature "$DMG" || die "Gatekeeper rejects the disk image"

# --- Update feed ----------------------------------------------------------

# Installed copies read https://septena.app/mac/appcast.xml, which redirects to
# this asset on the newest GitHub release.
GENERATE_APPCAST="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
[[ -x "$GENERATE_APPCAST" ]] || die "Sparkle generate_appcast not found"
mkdir "$WORK/feed"
cp "$ZIP" "$WORK/feed/"
"$GENERATE_APPCAST" --ed-key-file "$SPARKLE_KEY" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --link "https://septena.app/changelog" \
  --full-release-notes-url "https://septena.app/changelog" \
  --maximum-deltas 0 "$WORK/feed"
cp "$WORK/feed/appcast.xml" "$DIST/appcast.xml"
grep -q 'sparkle:edSignature=' "$DIST/appcast.xml" || die "the appcast is not signed"

echo "Built, notarized and checked: Septena $VERSION ($BUILD)"
[[ "$PUBLISH" -eq 1 ]] || { echo "Nothing published. Files are in $DIST"; exit 0; }

# --- Publish --------------------------------------------------------------

PREVIOUS="$(git describe --tags --match 'v*' --abbrev=0 2>/dev/null || true)"
SINCE=""
[[ -z "$PREVIOUS" ]] || SINCE="$(git log -1 --format=%cs "$PREVIOUS")"
node tools/changelog.mjs --json | SINCE="$SINCE" BUILD="$BUILD" node -e '
  const updates = JSON.parse(require("fs").readFileSync(0, "utf8"))
    .filter((u) => u.platforms.includes("mac") && (!process.env.SINCE || u.date > process.env.SINCE));
  const out = [];
  for (const [kind, title] of [["new", "New"], ["improved", "Improved"], ["fixed", "Fixed"], ["removed", "Removed"]]) {
    const rows = updates.filter((u) => u.kind === kind);
    if (rows.length) out.push(`### ${title}`, ...rows.map((u) => `- ${u.headline}`), "");
  }
  out.push(`Build ${process.env.BUILD}. Needs macOS 26 on Apple silicon. Signed and notarized by Apple.`);
  console.log(out.join("\n"));' > "$WORK/notes.md"

git tag -a "$TAG" -m "Septena $VERSION ($BUILD)"
git push -q origin "$TAG"
# Draft until every asset is up, so the feed never names a missing file.
gh release create "$TAG" "$DMG" "$ZIP" "$DIST/appcast.xml" --repo "$REPO" --verify-tag \
  --draft --title "Septena $VERSION for Mac" --notes-file "$WORK/notes.md"
gh release edit "$TAG" --repo "$REPO" --draft=false --latest

# GitHub takes a moment to move "latest" to the new release.
LIVE=0
for _ in $(seq 24); do
  curl -fsSL "https://septena.app/mac/appcast.xml" 2>/dev/null | cmp -s - "$DIST/appcast.xml" && { LIVE=1; break; }
  sleep 5
done
[[ "$LIVE" -eq 1 ]] || die "the release is public, but https://septena.app/mac/appcast.xml does not match dist/appcast.xml"
echo "Published https://github.com/$REPO/releases/tag/$TAG"
