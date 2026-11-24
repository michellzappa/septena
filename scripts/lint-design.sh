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

# ── Haptics (docs/HAPTICS_SPEC.md) ──────────────────────────────────────────
# One vocabulary, one place that maps meaning to feel. A generator built at a
# call site picks a feel by hand and skips the window anchoring and the
# CoreHaptics engine setup in Haptics.swift.
scan haptics-direct-generator error \
  'UI(Impact|Selection|Notification|Canvas)FeedbackGenerator|CHHapticEngine[[:space:]]*\(' \
  'Call a Haptics verb (press/selection/commit/threshold/success/warning/play), or .sensoryFeedback for local view state.' \
  'SeptenaCore/Haptics\.swift'

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

# ── Whole-store task reads (docs/LAUNCH_PERF.md "Interaction performance") ──
# `allTasks` / `liveTasks` build a row object for EVERY live task, logbook
# included, and each one decodes its conversation and recurrence JSON. Calling
# one only to pick tasks by id put the whole table on the tap path (undo
# snapshots, the attribute bar, a Mac move). Fetch the ids instead.
scan whole-store-id-lookup error \
  '(allTasks|liveTasks)\(in: [^)]*\)[[:space:]]*\.(first\(where: \{ *\$0\.id ==|filter \{ *(\$0\.id ==|[A-Za-z_.]+\.contains\(\$0\.id\)))' \
  'Building every task to pick some by id scans the whole store. Use LocalCache.liveTasks(ids:in:).'

# ── Vocabulary (docs/DesignSpec.md §6.6) ────────────────────────────────────
# The thing a person or an agent does is a "task", on every surface. "To-do"
# came from the early Things 3 copy and left the same action with two names
# (the menu said New Task, the shortcuts sheet said New to-do). "To-do" stays
# only in App Store and site search keywords, which this rule does not scan.
scan vocab-task-not-todo error \
  '"[^"]*[Tt]o-?[Dd]os?\b[^"]*"' \
  'Say "task", never "to-do", in user-facing copy and prompts (DesignSpec §6.6).' \
  'Microsoft To Do|[Tt]odoist|TODO|newTodos'

# ── AppKit transient surfaces (docs/SEPTASK_APPKIT_SURFACES.md) ─────────────
# Every popover, floating panel and filter list in the Septask AppKit shell is
# built in Septask/SeptaskKitSurface.swift, so material, corner radius, field
# face and row height have one source of truth. They did not before: the shell
# carried two corner radii, three placements for the same scope of edit, a
# hardcoded systemBlue badge, and eighty lines of panel construction copied
# between Quick Find and the Move picker. Build a surface through KitPopover /
# KitSurfacePanel / KitFilterSurface instead of hand-rolling one.
scan appkit-surface-chrome error \
  '(NSPopover\(\)|material = \.popover|styleMask: \[\.borderless)' \
  'Build transient surfaces via KitPopover / KitSurfacePanel (Septask/SeptaskKitSurface.swift) — do not hand-roll popover or panel chrome.' \
  'Septask/SeptaskKitSurface\.swift'

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

# ── Registry-owned copy (ADR 0020) ──────────────────────────────────────────
# Copy that the registry owns (an action title, a smart-list name, a prompt)
# comes from the generated registry, so it is translated once and the SwiftUI
# and AppKit shells cannot drift. A literal copy of it in a shared shell file is
# how the shells drifted before P2. Known leftovers live in
# scripts/registry-literal-allowlist.json, each with the issue that removes it.
registry_literals=$(python3 scripts/lint-registry-literals.py)
if [ -n "$registry_literals" ]; then
  count=$(printf '%s\n' "$registry_literals" | wc -l | tr -d ' ')
  printf '%s✗ %s%s  (%s)\n' "$RED" "registry-owned-literal" "$OFF" "$count"
  errors=$((errors + 1))
  printf '  %s\n' 'This text is registry copy. Read it from the generated registry (RegistryActions.title, TaskFilter.title, RegistryPrompts, …), not a literal.'
  printf '%s' "$DIM"; printf '%s\n' "$registry_literals" | head -8 | sed 's/^/    /'
  [ "$count" -gt 8 ] && printf '    … and %s more\n' "$((count - 8))"
  printf '%s\n' "$OFF"
fi

# ── Shell copy outside the registry (ADR 0028, #284) ───────────────────────
# A new user-facing label in a shell (Text, Button, Label, NSMenuItem title,
# Compose Text, ...) is copy every other platform types again by hand. Put it
# in the registry and read the generated value. Copy that predates the rule
# lives in scripts/shell-copy-allowlist.json, which only shrinks.
shell_copy=$(python3 scripts/lint-shell-copy.py)
if [ -n "$shell_copy" ]; then
  count=$(printf '%s\n' "$shell_copy" | wc -l | tr -d ' ')
  printf '%s✗ %s%s  (%s)\n' "$RED" "shell-copy-literal" "$OFF" "$count"
  errors=$((errors + 1))
  printf '  %s\n' 'This label is hard-coded in a shell. Add it to registry/*.json and read the generated value, or allowlist it with a reason and issue.'
  printf '%s' "$DIM"; printf '%s\n' "$shell_copy" | head -8 | sed 's/^/    /'
  [ "$count" -gt 8 ] && printf '    … and %s more\n' "$((count - 8))"
  printf '%s\n' "$OFF"
fi

# ── Space must never complete a task ────────────────────────────────────────
# On macOS, Space activates the first button in a selected row — the checkbox —
# so a bare Space silently completed the task the user was only looking at. It
# read as the task vanishing (it went to the Logbook). Both surfaces already
# hold the line: the SwiftUI checkbox is `.focusable(false)`, the AppKit one is
# `refusesFirstResponder = true`. Neither guard is load-bearing anywhere else in
# the file, so a refactor drops it without a compile error and the bug returns
# silently. Assert PRESENCE (the inverse of every other rule here), and ban
# binding Space on the task surfaces at all.
require() {
  local rule="$1" file="$2" pattern="$3" msg="$4"
  grep -qE "$pattern" "$file" 2>/dev/null && return 0
  printf '%s✗ %s%s\n' "$RED" "$rule" "$OFF"
  errors=$((errors + 1))
  printf '  %s\n' "$msg"
  printf '%s    %s  (missing: %s)%s\n\n' "$DIM" "$file" "$pattern" "$OFF"
}

require checkbox-space-guard Septena/Shell/Tasks/TaskCheckbox.swift \
  '\.focusable\(false\)' \
  'TaskCheckbox must stay .focusable(false) — a focusable checkbox in a selected List row is completed by Space.'

require checkbox-space-guard Septask/SeptaskKitRowViews.swift \
  'refusesFirstResponder = true' \
  'KitCheckboxView must keep refusesFirstResponder = true — otherwise Space activates the completion.'

space_bound=$(grep -rnE '(onKeyPress\(\.space|keyboardShortcut\(\.space)' --include="*.swift" \
  Septena/Shell/Tasks Septena/Shell/UI/SelectableScrollList.swift \
  Septena/Shell/UI/ListKeyboardNavigation.swift Septask 2>/dev/null \
  | grep -v 'septena-lint:allow task-space-binding')
if [ -n "$space_bound" ]; then
  printf '%s✗ %s%s\n' "$RED" "task-space-binding" "$OFF"
  errors=$((errors + 1))
  printf '  %s\n' 'Do not bind Space on a task surface — it collides with the row checkbox. Use a modifier shortcut (⌘K completes).'
  printf '%s' "$DIM"; printf '%s\n' "$space_bound" | sed 's/^/    /'
  printf '%s\n' "$OFF"
fi

# ── SwiftData reserved property names ───────────────────────────────────────
# A stored @Model property that shares a name with an NSManagedObject method
# breaks the store at runtime, with no compile error: `entity` made fetch
# predicates throw during SQL generation, and `entityName` made reads trap
# after a save (Core Data's own method shadowed it). Only files that declare a
# @Model are read. Check any other new name with
# `NSManagedObject.instancesRespond(to: NSSelectorFromString("name"))`.
reserved_model=$(grep -rlE --include="*.swift" '@Model' Septena Septask SeptenaCore 2>/dev/null \
  | xargs grep -nHE '^[[:space:]]*(@[A-Za-z]+(\([^)]*\))?[[:space:]]+)*((public|private|fileprivate|internal)[[:space:]]+)?var[[:space:]]+(entity|entityName|objectID|description|isDeleted|managedObjectContext|isFault|hasChanges)\b' 2>/dev/null \
  | grep -v 'septena-lint:allow model-reserved-name')
if [ -n "$reserved_model" ]; then
  printf '%s✗ %s%s\n' "$RED" "model-reserved-name" "$OFF"
  errors=$((errors + 1))
  printf '  %s\n' 'A @Model property must not reuse an NSManagedObject method name (entity, entityName, objectID, description, …). Rename it.'
  printf '%s' "$DIM"; printf '%s\n' "$reserved_model" | head -8 | sed 's/^/    /'
  printf '%s\n' "$OFF"
fi

# ── Shared cross-platform registries (ADR 0015) ──────────────────────────────
# Generated Swift and TypeScript bindings must stay in lockstep with
# `registry/*.json`. Run `node scripts/gen-registries.mjs` after editing any
# registry file.
if [ -f "scripts/gen-registries.mjs" ] && command -v node >/dev/null 2>&1; then
  reg_out=$(node scripts/gen-registries.mjs --check 2>&1)
  if [ $? -ne 0 ]; then
    printf '%s✗ %s%s\n' "$RED" "registry-drift" "$OFF"
    errors=$((errors + 1))
    printf '  %s\n' 'Shared registries failed validation or generated files are out of date. Run: node scripts/gen-registries.mjs'
    printf '%s' "$DIM"; printf '%s\n' "$reg_out" | sed 's/^/    /'
    printf '%s\n' "$OFF"
  fi
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
