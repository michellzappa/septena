# Septena Design Spec

The de-facto design system, written down. Derived from what the app already does — not aspirational. When something here conflicts with code, the code is wrong, not the spec.

## 1. Section model

A **section** is the unit of vertical scope: Tasks, Training, Nutrition, Sleep, Habits, Chores, Supplements, Groceries, Caffeine, Cannabis, Gut, Hydration, Mood, Air, Activity, Body, Goals.

Each section's identity is declared once in [SectionManifest.swift](../SeptenaCore/Sections/SectionManifest.swift):

- `key` — stable string id
- `defaultLabel` — display name (user-overridable via `SectionEntity`)
- `iconSymbol` — **SF Symbol name**, sole source of section iconography
- `accent color` — hex in [SectionTheme.swift](../SeptenaCore/SectionTheme.swift) `defaultPalette`
- `activation`, `onboarding`, `supportsTab`, `supportsDashboard`, `settingsEditor`

New sections register here. Nothing else should encode section identity.

## 2. Iconography

Three tiers. Pick the tier first, then the glyph.

### Tier 1 — Section identity → SF Symbol
Section headers, tab bar, dashboard cards, toolbar glyphs, empty-state hero icon, and any place where "this is the Training section" is the message. Always pulled from `SectionManifest.iconSymbol`. Never emoji.

### Tier 2 — App-shipped taxonomies → SF Symbol or none
Fixed-ish lists of "kinds of thing" the app defines: meal types, training session types, exercise categories. Treat these as structural and use SF Symbols if a glyph is needed at all. If no clean SF Symbol exists for the concept (Push vs. Pull vs. Upper vs. Lower), prefer no glyph over an awkward one. Emoji is not an escape hatch here.

### Tier 3 — User-owned entity instances → emoji from a curated picker, or nothing
The long tail of things users add over time and scan in a list — their specific habits, chores, supplements. Emoji is allowed here because:
- the list is heterogeneous (every row differs),
- users benefit from a glanceable visual key,
- and the user picked it themselves.

Constraints on Tier 3 emoji:
- **From a curated set**, not free-form input. Starter sets in plugin files are the current source of truth.
- **Optional** — rows must render correctly with no emoji. Don't fall back to a placeholder bullet `•` or a "default" emoji.
- **Separate slot, never concatenated** into a title or label string. Use the row's leading glyph slot.

### Rules that apply across all tiers

- **No fallback emoji.** If a value is missing, render the section's SF Symbol or nothing — never a "default" emoji like 💪 or 🏋️.
- **No emoji baked into formatted strings.** `"💧 \(ml) ml"` is wrong; the glyph is a separate view.
- **No emoji in system chrome** — toolbars, headers, empty states, log lines, comments-as-UI.

## 3. List row anatomy

The canonical row (see `HabitRow`, `SupplementRow`, `ChoreRow` in [NextItemsSection.swift](../Septena/Shell/Dashboard/NextItemsSection.swift)):

```
[Leading control] [Optional glyph] [Title] [Spacer] [Trailing accessory]
```

- **Leading control**: `TaskCheckbox` for actionable rows; nothing for log rows.
- **Optional glyph**: Tier 3 emoji or Tier 2 SF Symbol. Omit if absent. Do not fall back to a bullet.
- **Title**: `.septenaTaskTitle`.
- **Trailing accessory**: time, status badge, or overdue indicator in `.septenaMeta` / `StatusBadge`.

Read-only historical entries use `LogRow` ([LogRow.swift](../Septena/Shell/UI/LogRow.swift)): `[Title] [Detail] [Microglyph] [Spacer] [Recency]`.

## 4. Color

All section accents live in [SectionTheme.swift](../SeptenaCore/SectionTheme.swift) `defaultPalette`. Per-section tint is applied with `.tint(theme.color(for: key))`. No hardcoded `Color(...)` literals in views.

Unknown sections fall back to `inkSecondary`. The user's Tasks-section color is the global app accent.

## 5. Typography

Three-family system, mirroring the webapp's editorial identity but keeping SF Pro for native UI feel:

- **SF Pro** (system) — all UI body, controls, labels, sidebar rows, task titles, buttons. Stays the system font so nav bars, alerts, and Dynamic Type behave natively.
- **Fraunces** — editorial headings only (screen titles, section titles, card titles). Stylistic set `ss01` on, matching the webapp.
- **Mono (JetBrains Mono or equivalent)** — numerics, units, timestamps, tags. Tabular figures (`.monospacedDigit()`) where columns of numbers need to align.

The serif + mono pairing is what carries the brand; SF Pro carries the OS feel. Do not replace SF Pro for UI body — it regresses accessibility and creates inconsistency with system chrome.

Use the named styles in [Theme.swift](../Septena/Shell/UI/Theme.swift). No raw `.font(.title)` calls, no fixed point sizes outside of these styles. All styles are built on `Font.custom(_, size:, relativeTo:)` so Dynamic Type still scales.

- `.septenaScreenTitle` — destination header (Fraunces, `largeTitle.bold`)
- `.septenaSectionTitle` — section header within a screen (Fraunces, `title2.bold`)
- `.septenaCardTitle` — card header (Fraunces, `headline`)
- `.septenaTaskTitle` / `.septenaSidebarRow` / `.septenaNotes` — UI body (SF Pro)
- `.septenaButton` — action labels (SF Pro, `subheadline.semibold`)
- `.septenaLabel` — small labels (SF Pro, `footnote.medium`)
- `.septenaMeta` / `.septenaMetaStrong` — timestamps, metadata (Mono, `footnote`)
- `.septenaMetric` — numeric values, counts, durations (Mono, tabular)
- `.septenaBadge` — status pills (SF Pro, `caption2.semibold`)

## 6. Empty, loading, and error states

`ContentUnavailableView` is the unified empty-state pattern. Required slots: title, `systemImage` (use the section's icon, not a generic placeholder), description.

- Only show after `hasLoaded == true` so the empty state doesn't flash on cold launch.
- No custom loading skeletons.
- Network errors handled upstream by mutators; not surfaced in destination views.

## 7. Edit sheets

Shape shared across `EditCaffeineEntrySheet`, `EditCannabisEntrySheet`, `EditNutritionEntrySheet`:

1. `NavigationStack` wrapper.
2. `Form` with sectioned layout — "When" (`DatePicker`), method/strain/etc. (`Picker`), free-form notes (`TextField(axis: .vertical)`).
3. Save closure + `dismiss`.
4. Cancel via the `dismiss` environment.
5. **No delete in sheet.** Delete lives on the row's context menu.

## 8. Centralization rule

Anything that would otherwise drift across sections — colors, fonts, section identity, glyph choice, row anatomy — has exactly one definition. New plugins consume the central definitions; they don't re-declare them.

When in doubt: if a reviewer can ask "where is this defined?" and get two answers, it's a bug.
