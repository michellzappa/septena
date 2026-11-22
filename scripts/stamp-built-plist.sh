#!/bin/sh
#
# stamp-built-plist.sh — Xcode build phase. Writes the git commit count into
# the BUILT bundle's CFBundleVersion, so every build (device, simulator,
# archive) carries a build number that goes up with each commit.
#
# It edits only the copy in the build folder ($TARGET_BUILD_DIR), never a
# tracked file, so parallel sessions get no stamp commits and no conflicts.
# Every bundle target runs it (project.yml postBuildScripts), so the app and
# its extensions always carry the same number. Code signing runs after it.
#
# No git (a source snapshot without .git): the bundle keeps the
# CURRENT_PROJECT_VERSION fallback from Config/Base.xcconfig.
set -eu

plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
[ -f "$plist" ] || exit 0

count="$(git -C "${SRCROOT}" rev-list --count HEAD 2>/dev/null)" || exit 0
[ -n "$count" ] || exit 0

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${count}" "$plist"
echo "stamp-built-plist: ${PRODUCT_NAME} CFBundleVersion = ${count}"
