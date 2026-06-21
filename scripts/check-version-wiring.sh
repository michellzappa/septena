#!/usr/bin/env bash
#
# check-version-wiring.sh — assert every target's Info.plist reads the version
# from the build settings, not a hardcoded literal.
#
# The two bundle keys the app surfaces (Settings ▸ About) MUST be wired to the
# project's single source of truth:
#
#   CFBundleShortVersionString → $(MARKETING_VERSION)       (project.yml)
#   CFBundleVersion            → $(CURRENT_PROJECT_VERSION)  (Config/Base.xcconfig)
#
# When a plist hardcodes "1.0" / "1" instead, the whole bundle ships the wrong
# version no matter what the config says — and the embedded targets can drift
# out of sync, which fails App Store validation. This guard catches that.
#
# Run standalone, or let stamp-version.sh call it before an archive:
#
#     scripts/check-version-wiring.sh
#
# Exits non-zero (listing every offending plist) if anything is mis-wired.
set -euo pipefail

cd "$(dirname "$0")/.."

# Every bundle target with a hand-maintained Info.plist. Keep in step with the
# `sources`/`configFiles` targets in project.yml when adding a new target.
PLISTS=(
  Septena/Info.plist
  Septena/Info-Mac.plist
  SeptenaWatch/Info.plist
  SeptenaWatchComplication/Info.plist
  SeptenaWidgets/Info.plist
  SeptenaLiveActivitiesExtension/Info.plist
)

fail=0
for plist in "${PLISTS[@]}"; do
  if [[ ! -f "$plist" ]]; then
    echo "✗ $plist — missing (new target without a plist, or a rename?)" >&2
    fail=1
    continue
  fi

  short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true)"
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || true)"

  if [[ "$short" != '$(MARKETING_VERSION)' ]]; then
    echo "✗ $plist — CFBundleShortVersionString is '$short', expected \$(MARKETING_VERSION)" >&2
    fail=1
  fi
  if [[ "$build" != '$(CURRENT_PROJECT_VERSION)' ]]; then
    echo "✗ $plist — CFBundleVersion is '$build', expected \$(CURRENT_PROJECT_VERSION)" >&2
    fail=1
  fi
done

if [[ "$fail" -ne 0 ]]; then
  echo "" >&2
  echo "Version wiring broken. Point the keys above at the build settings so the" >&2
  echo "bundle reads MARKETING_VERSION / CURRENT_PROJECT_VERSION. See docs/VERSIONING.md." >&2
  exit 1
fi

echo "✓ version wiring OK — all ${#PLISTS[@]} plists read \$(MARKETING_VERSION) / \$(CURRENT_PROJECT_VERSION)"
