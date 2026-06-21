#!/usr/bin/env bash
#
# changelog-stamp.sh — keep one human-readable "Unreleased" entry at the top of
# the canonical changelog current, carrying the live build (commit) number, and
# stamp that same number into Config/Base.xcconfig. The committer-cron calls this
# after it lands real work, so the in-app "What's New" history and the public
# /changelog page always reflect what's shipped-but-unreleased, with an
# always-current commit count.
#
#     scripts/changelog-stamp.sh             # refresh + stamp + commit (cron path)
#     DRY_RUN=1 scripts/changelog-stamp.sh   # print the entry it would write, touch nothing
#
# Design notes (why this is safe to run hourly):
#   • The build number IS the commit count (`git rev-list --count HEAD`). Writing
#     it into a commit would change the count it just recorded, so we stamp the
#     PREDICTED count (current + 1, the single refresh commit we make) — exact at
#     HEAD afterwards. No drift, no hand-bumping.
#   • A guard skips entirely when HEAD is already a refresh commit, so the cron
#     only acts when real work has landed since the last refresh — no hourly
#     churn on a quiet tree.
#   • Released entries are never touched: only the single sentinel-version
#     "Unreleased" entry is rewritten. Cutting a release promotes it (see
#     docs/VERSIONING.md).
#   • Highlights are authored by Claude from the commits since the last release;
#     if Claude is unavailable or returns junk, it falls back to the commit
#     subjects so the entry is always populated.
set -euo pipefail

cd "$(dirname "$0")/.."

CHANGELOG="Septena/Resources/changelog.json"
XCCONFIG="Config/Base.xcconfig"
TODAY="$(date +%F)"
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || echo /Users/mz/.local/bin/claude)}"

[ -f "$CHANGELOG" ] || { echo "changelog-stamp: $CHANGELOG not found" >&2; exit 1; }
[ -f "$XCCONFIG" ]  || { echo "changelog-stamp: $XCCONFIG not found"  >&2; exit 1; }

# --- guard: skip if HEAD is already our own refresh (nothing new since) -------
HEAD_SUBJECT="$(git log -1 --pretty=%s 2>/dev/null || true)"
case "$HEAD_SUBJECT" in
  "chore(changelog):"*) echo "changelog-stamp: HEAD is a refresh commit — nothing new"; exit 0 ;;
esac

# --- range: everything since the last *released* entry ------------------------
RELEASED_BUILD="$(jq -r 'first(.releases[] | select(.version != "Unreleased") | .build) // 0' "$CHANGELOG")"
RELEASED_VER="$(jq -r 'first(.releases[] | select(.version != "Unreleased") | .version) // "0.0.0"' "$CHANGELOG")"
CURRENT="$(git rev-list --count HEAD)"
DELTA=$(( CURRENT - RELEASED_BUILD ))
if [ "$DELTA" -le 0 ]; then echo "changelog-stamp: no commits since $RELEASED_VER (build $RELEASED_BUILD)"; exit 0; fi

if git rev-parse -q --verify "HEAD~$DELTA" >/dev/null 2>&1; then
  BOUNDARY="HEAD~$DELTA"
else
  BOUNDARY="$(git rev-list --max-parents=0 HEAD | tail -1)"
fi

# Commit subjects in range, minus merges and our own refresh commits.
SUBJECTS="$(git log --no-merges --invert-grep --grep='^chore(changelog)' --pretty='%s' "$BOUNDARY..HEAD")"
if [ -z "$SUBJECTS" ]; then echo "changelog-stamp: only chore commits since release — nothing to announce"; exit 0; fi

PREDICTED=$(( CURRENT + 1 ))   # the one refresh commit we are about to make

# --- author the highlights (Claude, with a deterministic fallback) ------------
SECTION_KEYS="tasks goals habits supplements chores medications symptoms gut nutrition training body sleep mood intake groceries activity github"
HIGHLIGHTS=""
if [ -x "$CLAUDE_BIN" ] || command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
  PROMPT="You write user-facing release notes for Septena, a private life-tracking app for Apple platforms (iOS/macOS/watchOS). Below are git commit subjects since the last release (v$RELEASED_VER). Turn them into a curated JSON array of highlights for end users.

Rules:
- Output ONLY a JSON array. No prose, no markdown, no code fences.
- Each element: {\"title\": string, \"detail\": string|null, \"section\": string|null}.
- title: short, user-facing, sentence case, no trailing period. Describe the benefit, not the implementation.
- detail: one plain sentence of context, or null.
- section: one of [$SECTION_KEYS] if the change clearly belongs to a section, else null.
- Merge related commits. Drop noise (refactors, build fixes, internal chores, version stamps). Aim for 3-8 highlights.

Commits:
$SUBJECTS"
  OUT="$("$CLAUDE_BIN" -p "$PROMPT" 2>/dev/null || true)"
  # Tolerate stray code fences around the array.
  OUT="$(printf '%s' "$OUT" | sed -e 's/^[[:space:]]*```json[[:space:]]*$//' -e 's/^[[:space:]]*```[[:space:]]*$//')"
  if printf '%s' "$OUT" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
    HIGHLIGHTS="$OUT"
  fi
fi
if [ -z "$HIGHLIGHTS" ]; then
  echo "changelog-stamp: using commit-subject fallback (Claude unavailable or invalid output)"
  HIGHLIGHTS="$(printf '%s\n' "$SUBJECTS" | jq -R -s 'split("\n") | map(select(length > 0)) | map({title: ., detail: null, section: null})')"
fi

# --- build the entry ----------------------------------------------------------
SUMMARY="Changes since $RELEASED_VER, refreshed automatically as work lands."
ENTRY="$(jq -n \
  --argjson hl "$HIGHLIGHTS" \
  --argjson build "$PREDICTED" \
  --arg date "$TODAY" \
  --arg summary "$SUMMARY" \
  '{version: "Unreleased", build: $build, date: $date, name: "In development", summary: $summary, highlights: $hl}')"

if [ -n "${DRY_RUN:-}" ]; then
  echo "changelog-stamp: [dry-run] build $PREDICTED, $(printf '%s' "$HIGHLIGHTS" | jq 'length') highlight(s), since $RELEASED_VER"
  printf '%s\n' "$ENTRY" | jq .
  exit 0
fi

# --- write: replace any existing Unreleased entry, pin the new one to the top --
TMP="$(mktemp)"
jq --argjson entry "$ENTRY" \
  '.releases = ([$entry] + (.releases | map(select(.version != "Unreleased"))))' \
  "$CHANGELOG" > "$TMP" && mv "$TMP" "$CHANGELOG"

# Stamp the build number to the predicted count (exact once we commit).
/usr/bin/sed -i '' -E "s/^(CURRENT_PROJECT_VERSION = ).*/\1${PREDICTED}/" "$XCCONFIG"

git add "$CHANGELOG" "$XCCONFIG"
git commit -q -m "chore(changelog): refresh to build $PREDICTED"
echo "changelog-stamp: refreshed → build $PREDICTED, $(printf '%s' "$HIGHLIGHTS" | jq 'length') highlight(s)"
