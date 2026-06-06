# Septena Design Spec

The de-facto design system, written down. Derived from what the app already does — not aspirational. When something here conflicts with code, the code is wrong, not the spec.

_Last verified against code: 2026-05-30._

## 1. Section model

A **section** is the unit of vertical scope: Tasks, Training, Nutrition, Sleep, Habits, Chores, Supplements, Groceries, Caffeine, Cannabis, Gut, Hydration, Mood, Activity, Body, Goals.

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

Unknown sections fall back to a neutral gray (`SectionTheme.color(for:)`). The user's Tasks-section color is the global app accent (`SectionTheme.accent`).

## 5. Typography

Three families, used by role:

- **SF Pro** (system) — all UI body, controls, labels, buttons, and almost every title (section, card, and tile titles included). Stays the system font so nav bars, alerts, and Dynamic Type behave natively.
- **Fraunces** (serif) — the Dashboard welcome greeting *only* (`septenaWelcomeTitle`). Rare by design: it's the single editorial face in the app, scoped to the front door so arriving at it stays a moment rather than a frame you can't escape. Interior destination headers use SF Pro. Bundled as a variable font and registered via Info.plist (`UIAppFonts` on iOS, `ATSApplicationFontsPath` on Mac); if the file isn't bundled, `Font.custom` falls back to the system font silently, so the app stays buildable either way.
- **SF Mono** (system monospaced, `Font.system(design: .monospaced)`) — numerics, units, timestamps, counts, metrics. Tabular figures (`.monospacedDigit()`) so columns of numbers align.

Fraunces-as-accent plus mono-for-numbers is what carries the brand; SF Pro carries the OS feel. Don't replace SF Pro for UI body — it regresses accessibility and breaks consistency with system chrome. Don't reach for Fraunces beyond the Dashboard welcome.

Use the named styles in [Theme.swift](../Septena/Shell/UI/Theme.swift). No raw `.font(.title)` calls, no fixed point sizes outside these styles. Every style is built on a system text style (or, for Fraunces, `Font.custom(_, size:, relativeTo:)`) so Dynamic Type scales.

- `.septenaWelcomeTitle` — Dashboard welcome greeting (Fraunces SemiBold, ~`largeTitle`). The only Fraunces user.
- `.septenaScreenTitle` — interior destination header (SF Pro semibold, `largeTitle`)
- `.septenaSectionTitle` — section header within a screen (SF Pro semibold, `title2`)
- `.septenaCardTitle` — card header (SF Pro, `headline`)
- `.septenaTileTitle` — dashboard tile header (SF Pro; `title3` on iOS, `headline` on macOS)
- `.septenaTaskTitle` / `.septenaSidebarRow` — UI body (SF Pro, `body`)
- `.septenaNotes` — secondary body (SF Pro, `subheadline`)
- `.septenaButton` — action labels (SF Pro, `subheadline.semibold`)
- `.septenaLabel` — small labels (SF Pro, `footnote.medium`)
- `.septenaBadge` — status pills (SF Pro, `caption2.semibold`)
- `.septenaMeta` / `.septenaMetaStrong` — timestamps, metadata (SF Mono, `footnote`, tabular)
- `.septenaMetric` — numeric values, counts, durations (SF Mono, `body`, tabular)

## 5.5 Materials & depth (Liquid Glass)

Glass is the **chrome material — it floats above content, never replaces it.** Content surfaces stay on system backgrounds (`Theme.paperBackground` = `systemBackground`; grouped backgrounds inside `Form`s). Rows, cards, and Form content are *not* glass — coating content in glass fights legibility and Apple's iOS-26 guidance.

Where glass belongs: floating **interactive controls** — pills, action bars, circular buttons, quick-action toolbars that hover over scrolling content.

- `.glassEffect(.regular, in: <shape>)` — the base. `in:` is the clip shape: `.capsule` for bars/pills, `.circle` for round buttons, `.rect(cornerRadius: Theme.cornerRadius)` for tiles.
- `.interactive()` — add for controls that respond to press (lift/specular). Almost always on, for tappable glass.
- `.tint(accent.opacity(~0.4))` — carries the section accent through the glass when the control is "active"/primary; clear when neutral.
- **Co-animating glass** (adjacent controls that should merge/morph) goes in a `GlassEffectContainer` with `glassEffectID(_:in:)` so they fluidly combine instead of cross-fading.

Established usages: the Goals Discovery flow chrome, the Mood/Insights/Settings floating controls, and edit-sheet save bars. Match them — one translucent layer at a time; don't stack glass on glass.

Modals use a large continuous corner radius (`Theme.cornerRadius`, 22pt) to match the iOS-26 soft-modal shape. Honor Reduce Transparency: the system substitutes an opaque material automatically, but any *custom* translucency must degrade too.

## 6. Empty, loading, and error states

`ContentUnavailableView` is the unified empty-state pattern. Required slots: title, `systemImage` (use the section's icon, not a generic placeholder), description.

- Only show after `hasLoaded == true` so the empty state doesn't flash on cold launch.
- No custom loading skeletons.
- Network errors handled upstream by mutators; not surfaced in destination views.

## 7. Edit sheets

Every create/edit form goes through `AdaptiveEditScaffold` ([SectionDrawer.swift](../Septena/Shell/Sections/SectionDrawer.swift)), presented by `.adaptiveDetail(item:)` / `.adaptiveDetail(isPresented:)`. The scaffold absorbs the cross-surface chrome so no form repeats it:

1. **Adaptive host** — a docked inspector at regular width (iPad / macOS) with an inline Cancel · title · Save header; a `NavigationStack` bottom **sheet** at compact width (iPhone) with a nav-bar toolbar. Forms never wrap their own `NavigationStack`.
2. **Body** — a `Form` (or a custom content view) supplied by the form; sectioned layout — dates (`DatePicker` / `WeekStrip`), relations (`Picker`), free-form notes (`TextField(axis: .vertical)`).
3. **Save** — the form passes an `onSave` closure and a `canSave` flag; the scaffold runs the action then closes. Forms must **not** call `dismiss`/close themselves.
4. **Cancel** — handled by the scaffold (inline header button on inspector, toolbar button on sheet).
5. **Destructive / status actions** — may live **in-sheet** when the editor is the primary surface for them (e.g. `EditTaskSheet` carries Delete, Cancel, and Move-to-Someday so it stays at parity with the row's context menu); they act immediately and close via `\.adaptiveDetailClose` with a `dismiss` fallback. Lighter editors leave delete on the row's context menu. Either is fine — the scaffold supports both.
6. **Detents** — compact-width sheets open at `[.medium, .large]` with a drag indicator; the inspector ignores detents.

## 8. Centralization rule

Anything that would otherwise drift across sections — colors, fonts, section identity, glyph choice, row anatomy — has exactly one definition. New plugins consume the central definitions; they don't re-declare them.

When in doubt: if a reviewer can ask "where is this defined?" and get two answers, it's a bug.

## 9. Spacing & motion

Shape and motion tokens live alongside the type and color tokens — like color, each has exactly one definition. Don't sprinkle magic numbers.

- **Spacing scale** — `Theme.Spacing.xs/sm/md/lg/xl/xxl` (4 / 8 / 12 / 14 / 16 / 28pt). Drawer chrome (`SectionDrawer`, `DrawerSection`, `ChartCard`, `StatStrip`) consumes these; tune one place and the whole drawer system shifts in step.
- **Corner radius** — `Theme.cornerRadius` (22pt, the iOS-26 "soft tile") and `Theme.cornerRadiusSmall` (6pt, chips and pills).
- **Row rhythm** — `Theme.rowVPadding`, `iconTextGap`, `checkboxTap`, and the per-platform row/sidebar heights keep the icon column and text baseline aligned across every row type.

**Motion is gated for accessibility, centrally.** Use the helpers in [Accessibility.swift](../Septena/Shell/UI/Accessibility.swift), not raw `withAnimation`:

- `.a11yAnimation(_:value:)` — declarative; collapses to no animation under Reduce Motion.
- `A11yMotion.run { … }` — the imperative analogue for state toggles.

Any animation a user can trigger repeatedly — and every celebratory flourish (confetti, the mood-commit animation, symbol bounces) — must route through these so Reduce Motion is honored. A screen flash or a `repeatForever` that ignores Reduce Motion is a bug.
