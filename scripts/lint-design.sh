#!/bin/bash
# Design-system guardrail.
#
# Greps for the specific conventions that have silently drifted before. Each
# rule below cost a real bug or a cross-session cleanup — the point is that the
# NEXT person can't reintroduce it without the build telling them.
#
#   ERRORS block the build. NOTES are advisory (a drift budget we're paying
#   down); they print but never fail.
#
# Escape hatch, per line, when a violation is genuinely sanctioned:
#     someCall()  // septena-lint:allow <rule-id> — why
# Skip the whole check with SEPTENA_SKIP_LINT=1 (use sparingly).
#
# Run standalone:  scripts/lint-design.sh
# Runs automatically from scripts/build.sh before the build lock is taken.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

[ "${SEPTENA_SKIP_LINT:-0}" = "1" ] && { echo "lint-design: skipped"; exit 0; }

RED=$'\033[31m'; YEL=$'\033[33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
errors=0

# scan <rule-id> <severity> <grep-pattern> <message> [exclude-regex]
scan() {
  local rule="$1" sev="$2" pattern="$3" msg="$4" exclude="${5:-}"
  local hits
  hits=$(grep -rnE "$pattern" --include="*.swift" Septena Septask SeptenaCore 2>/dev/null \
         | grep -v "septena-lint:allow $rule")
  [ -n "$exclude" ] && hits=$(printf '%s\n' "$hits" | grep -vE "$exclude")
  hits=$(printf '%s\n' "$hits" | grep -v '^\s*$')
  [ -z "$hits" ] && return 0

  local count; count=$(printf '%s\n' "$hits" | wc -l | tr -d ' ')
  if [ "$sev" = error ]; then
    printf '%s✗ %s%s  (%s)\n' "$RED" "$rule" "$OFF" "$count"
    errors=$((errors + 1))
  else
    printf '%s• %s%s  (%s)\n' "$YEL" "$rule" "$OFF" "$count"
  fi
  printf '  %s\n' "$msg"
  printf '%s' "$DIM"; printf '%s\n' "$hits" | head -8 | sed 's/^/    /'
  [ "$count" -gt 8 ] && printf '    … and %s more\n' "$((count - 8))"
  printf '%s\n' "$OFF"
}

echo "lint-design: checking design-system conventions…"
echo

# ── Motion (DesignSpec §9) ───────────────────────────────────────────────────
# Bare withAnimation honors nothing; Reduce Motion must collapse every
# user-triggerable animation. LogCommit/CommitMotion gate at the overlay and
# are the documented exceptions.
scan motion-withanimation error \
  '(^|[^.[:alnum:]_])withAnimation[[:space:]]*[({]' \
  'Use a11yAnimate(_:_:) (or A11yMotion.run) — bare withAnimation ignores Reduce Motion.' \
  'Shell/UI/Accessibility\.swift|Shell/UI/LogCommit\.swift|Shell/UI/CommitMotion\.swift|^\s*[0-9]+:\s*//'

scan motion-animation-modifier error \
  '(^|[^[:alnum:]_])\.animation\([^)]*value:' \
  'Use .a11yAnimation(_:value:) — bare .animation(_:value:) ignores Reduce Motion.' \
  'Shell/UI/Accessibility\.swift|a11yAnimation|TimelineView'

# ── Selection language (DesignSpec §4, SelectionLanguage.swift) ──────────────
# The app accent is adaptive ink — WHITE in dark mode. A solid-accent fill with
# white text is invisible there. Selected chips use a tint wash + tint ink.
scan selection-white-on-fill error \
  '[sS]elected [?].*(Color\.white|\.white)' \
  'White ink on a selected fill is invisible in dark mode (the accent is adaptive ink). Use SelectableChip.' \
  'Shell/UI/SelectionLanguage\.swift'

# A hue-tinted row highlight competes with the canonical neutral capsule.
scan selection-accent-fill error \
  '\.(background|fill)\([^)]*[sS]elected[^)]*accentColor' \
  'Row/chip selection uses Theme.listSelectionFill or SelectableChip, never an accent-tinted fill.' \
  'Shell/UI/SelectionLanguage\.swift'

# ── Data-viz primitives (DesignSpec §10) ────────────────────────────────────
scan ring-rerolled error \
  '\.trim\(from:' \
  'Every ring in the app is ProjectProgressIcon. Extend it rather than re-rolling a trimmed circle.' \
  'Shell/Sidebar/SidebarView\.swift'

# ── AppKit batch updates ─────────────────────────────────────────────────────
# `inferringMoves()` reports the move's source in the ORIGINAL array's
# coordinate space, but NSTableView applies a begin/endUpdates batch
# INCREMENTALLY — each call relative to what the preceding ones left behind. So
# `moveRow(at:to:)` fed an inferred offset grabs whatever row slid into that
# slot: moving a task between Today's groups moved the group HEADER instead,
# and the row read as duplicated under the wrong heading. Plain remove+insert
# is what the incremental batch is defined for (verified against a real
# NSTableView over 400 randomized diffs).
scan appkit-inferring-moves error \
  'inferringMoves\(\)' \
  'NSTableView batches apply incrementally — an inferred move offset is stale by the time it runs. Use a plain difference (remove+insert).'

# ── Row tap targets ─────────────────────────────────────────────────────────
# `.plain` (and the plain-derived row styles) opt a Button out of the list
# cell's tap target, so only the DRAWN label is hit-testable — the Spacer and
# the trailing gaps become dead zones and a tap near the right edge of the row
# silently misses. `LogRow` carries `.contentShape(Rectangle())` for exactly
# this reason; every other full-width row Button needs it too. The check reads
# brace structure (label, modifier chain, and button style sit on different
# lines), so it lives in its own script rather than a grep pattern.
row_dead_zone=$(python3 scripts/lint-row-tap-targets.py)
if [ -n "$row_dead_zone" ]; then
  count=$(printf '%s\n' "$row_dead_zone" | wc -l | tr -d ' ')
  printf '%s✗ %s%s  (%s)\n' "$RED" "row-dead-zone" "$OFF" "$count"
  errors=$((errors + 1))
  printf '  %s\n' 'A .plain row Button needs .contentShape(Rectangle()) on its label — without it the Spacer is a dead zone.'
  printf '%s' "$DIM"; printf '%s\n' "$row_dead_zone" | head -8 | sed 's/^/    /'
  [ "$count" -gt 8 ] && printf '    … and %s more\n' "$((count - 8))"
  printf '%s\n' "$OFF"
fi

# ── Typography (DesignSpec §5) — advisory, we are paying this down ───────────
scan type-raw-mono note \
  '\.font\([^)]*(monospacedDigit\(\)|design: \.monospaced)' \
  'Numbers use .septenaMeta / .septenaMetric / .septenaHeroMetric — do not hand-roll a mono font.' \
  'Shell/UI/Theme\.swift|Shell/UI/TextSizeScale\.swift'

scan type-raw-font note \
  '\.font\(\.(caption|caption2|subheadline|footnote|headline|title|title2|title3|body|callout|largeTitle)' \
  'Prefer a named style from Theme.swift (.septenaCaption, .septenaLabel, .septenaBadge, …).' \
  'Shell/UI/Theme\.swift'

echo
if [ "$errors" -gt 0 ]; then
  printf '%slint-design: %s blocking rule(s) violated.%s\n' "$RED" "$errors" "$OFF"
  printf 'Fix them, or annotate the line with  // septena-lint:allow <rule-id> — <why>\n'
  exit 1
fi
printf 'lint-design: OK (notes above are advisory)\n'
exit 0
