# Septena Design Spec

The de-facto design system, written down. Derived from what the app already does — not aspirational. When something here conflicts with code, the code is wrong, not the spec.

_Last verified against code: 2026-06-12._

## 1. Section model

A **section** is the unit of vertical scope: Tasks, Goals, Training, Nutrition, Hydration, Sleep, Habits, Chores, Supplements, Groceries, Intake, Caffeine, Cannabis, Gut, Mood, Symptoms, Medications, Activity, and Body.

Each section's identity is declared once in [SectionManifest.swift](../SeptenaCore/Sections/SectionManifest.swift):

- `key` — stable string id
- `defaultLabel` — display name (user-overridable via `SectionEntity`)
- `iconSymbol` — **SF Symbol name**, sole source of section iconography
- `accent color` — hex in [SectionTheme.swift](../SeptenaCore/SectionTheme.swift) `defaultPalette`
- `activation`, `onboarding`, `supportsDashboard`, `settingsEditor`

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

Read-only historical entries use `LogRow` ([LogRow.swift](../Septena/Shell/UI/LogRow.swift)): `[Optional status dot] [Title] [Detail] [Microglyph] [Spacer] [Recency]`. The leading dot is used by the per-item detail's recent timeline (done / skipped / missed); omit it elsewhere.

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
- **Surface geometry** — the four top-level tabs (Week, Next, Tasks sidebar, Coach) share one page geometry, applied through `septenaSurface()` (PlatformShims.swift), never hand-typed per view:
  - `Theme.pageGutter` (12pt) — screen edge → content, identical on every tab.
  - `Theme.pageTop` (12pt) — nav bar → first content block. Exception: the Next feed passes `top: 0` because its sections pad their own tops with `sectionSpacing` (conditionally hidden sections must not leave gaps).
  - `Theme.pageBottom` (80pt iOS / 24pt macOS) — scroll-past air above the floating tab bar.
  - `Theme.sectionSpacing` (24pt iOS / 16pt macOS) — the one gap between content groups on a surface (Week's banner/timeline/grid, Coach's bands, sidebar grid → area cards).
  - `Theme.tileGap` (12pt) — between tiles in any surface-level grid (Week tiles, Coach bands, Tasks smart lists).
- **Corner radius** — `Theme.cornerRadius` (22pt, the iOS-26 "soft tile") and `Theme.cornerRadiusSmall` (6pt, chips and pills).
- **Row rhythm** — `Theme.rowVPadding`, `iconTextGap`, `checkboxTap`, and the per-platform row/sidebar heights keep the icon column and text baseline aligned across every row type.

**Motion is gated for accessibility, centrally.** Use the helpers in [Accessibility.swift](../Septena/Shell/UI/Accessibility.swift), not raw `withAnimation`:

- `.a11yAnimation(_:value:)` — declarative; collapses to no animation under Reduce Motion.
- `A11yMotion.run { … }` — the imperative analogue for state toggles.

Any animation a user can trigger repeatedly — and every celebratory flourish (confetti, the mood-commit animation, symbol bounces) — must route through these so Reduce Motion is honored. A screen flash or a `repeatForever` that ignores Reduce Motion is a bug.

## 10. Data-viz primitives

The bespoke visualizations. Each kind of chart has **one** definition; a section feeds it data, never re-rolls the drawing. Pick the primitive by the *shape of the question*, not the section.

- **Progress ring** — "how full toward a target / 100%". `ProjectProgressIcon` ([SidebarView.swift](../Septena/Shell/Sidebar/SidebarView.swift)): `progress: Double, tint:, diameter:, lineWidth:`. A faint track at `tint.opacity(0.22)` + a rounded accent arc from 12 o'clock. Used on projects, and (smaller/thicker — 14pt / 2.5pt) as the habit/supplement completion-rate ring (`CompletionRateBadge`). **Centralization debt (§8):** the Rings homepage cell ([RingsHomepageView.swift](../Septena/Shell/Dashboard/RingsHomepageView.swift)) and the Sleep score ring ([SleepDestinationView.swift](../Septena/Sections/Sleep/SleepDestinationView.swift)) currently re-roll their own `trim(from:)` ring. New rings must use `ProjectProgressIcon`; those two should converge onto it.
- **Consistency heatmap** — "density over the past weeks". `ConsistencyHeatmap` ([ConsistencyHeatmap.swift](../Septena/Shell/UI/ConsistencyHeatmap.swift)): GitHub-style Mon→Sun columns, 12pt cells / 3pt gaps, a five-stop accent ramp (level 0–4), optional tappable cells for backfill, and Differentiate-Without-Color dot overlays. Single source — used by the homepage Heatmap mode, section destinations, and per-item detail consistency cards. A binary "did it" log maps done → 4; a graded log (sets/day) buckets into 1–4.
- **24-hour rhythm dial** — "when in the day does this happen". `TimeOfDayWheel` ([TimeOfDayWheel.swift](../Septena/Shell/UI/TimeOfDayWheel.swift)): radial dial of timestamped event dots + duration bands, faded by recency, with a "now" hand. The homepage Rhythm mode overlays sections on one dial.
- **Histograms** — `Histogram` ([ModuleTile.swift](../Septena/Shell/UI/ModuleTile.swift)) for N-bar day strips (optional ceiling/target, two-series stacking, emphasized bar); `CenteredBarChart` (same file) for signed series that pivot on a zero line (weight gain/loss). Multi-series line/area work uses Swift `Charts` directly inside a `ChartCard` (Training, Sleep, Body), not a wrapper.
- **Glyph meters** — tiny inline gauges for a single row: `DifficultyGlyph` (3-step easy/medium/hard) and `LevelGlyph` (ascending bars, 1…10) in [IntensityGlyph.swift](../Septena/Shell/UI/IntensityGlyph.swift).
- **Goal progress** — `GoalMetricProgressView` ([GoalMetricProgressView.swift](../Septena/Shell/Goals/GoalMetricProgressView.swift)): a capsule bar for target goals and a banded track for maintenance ranges. (A range needs the band, so it stays a bar; simple to-target goals are ring candidates.)

Every viz takes the **section accent** as its color (`theme.color(for: key)`), reads `DayClock`/`SeptenaDate.today` for "now", and routes any triggered animation through the §9 a11y helpers.

## 11. Component library

Reusable building blocks. New surfaces compose these; they don't hand-roll equivalents.

**Containers & chrome**
- `SectionDrawer` — the outer shell for every section destination (scroll, grouped background, goals strip, time-travel pill, "+" log button, settings footer). Injects `DrawerSurfaceStyle` (`.solid` on iPad/Mac panes, `.glass` on the iPhone sheet) so cards adapt.
- `DrawerSection(title:, padding:)` — the titled rounded card. `padding`: `.standard` (free-form), `.tight` (charts), `.none` (rows that bring their own insets).
- `DrawerColumns` / `MasonryLayout` — 1-column on compact, balanced 2-column on wide panes.
- `ChartCard(title:, detail:, accessory:)` — editorial header + tight card for one chart.
- `StatGrid` + `StatTile`, and `StatStrip` — the dashboard/destination stat surfaces.
- `ModuleTile` — the Week dashboard tile (header + stats + progress + histogram, accent stripe).

**Per-item detail surface** — `LogDetailScaffold` / `LogDetailBody` + the `LogDetail` model ([LogDetailScaffold.swift](../Septena/Shell/Sections/LogDetailScaffold.swift)). One data-driven surface for a single item's history: masthead, stat tiles, consistency heatmap, key/value cards, and a recent list. `LogDetailBody` is the pure content (used in push hosts like the exercise catalog); `LogDetailScaffold` adds the adaptive Close · title · Edit chrome (sheet/inspector). Habits, supplements, chores, and training exercises all build a `LogDetail` — add a new one rather than a bespoke detail screen.

**Rows** — see §3 for anatomy. The components: `CheckableRow` (the actionable checkbox row behind `TaskRow`/`HabitRow`/`SupplementRow`/`ChoreRow`), `LogRow` (read-only record; optional `leading` status dot + `trailing` recency), `LogEntryRow` (`LogRow` + tap-to-edit + context menu), `TaskCheckbox`, `Hairline`.

**Badges, pills, glyphs**
- `StatusBadge` — muted capsule for a row status word ("Done", "Skipped").
- `CompletionRateBadge` — the 30-day completion ring in a checklist row (see §10).
- `SectionGlyph` / `ColoredGlyph` — the soft / saturated tinted rounded-square section icons; `AreaIcon` is a deliberately flat dot (not a progress shape).
- `AgentCueMarker` — leading accent dot marking an MCP/Claude-authored row; clears on interaction.
- `TimeTravelPill`, `SyncIndicator` — context pill while viewing a past day; idle-hiding sync spinner.

## 12. Commit motion & flourishes

A logging action earns a brief, **data-matched** flourish — motion that echoes what was logged, not generic confetti. One catalog, one dispatcher:

- `CommitMotion` ([CommitMotion.swift](../Septena/Shell/UI/CommitMotion.swift)) — the enum of primitives (`burst`, `snap`, `bloom`, `sink`, `cascade`, `tally`, `settle`, `ripple`, `arc`, `fill`, `streak`), each with a haptic spec.
- `LogCommitCenter` + `LogCommitOverlay` ([LogCommit.swift](../Septena/Shell/UI/LogCommit.swift)) — app-root overlay; a section fires `.flourish(motion:accent:intensity:)` and the overlay renders it. `IgnitionView` is the louder streak-milestone pop (7 / 30 / 100 / 365 days).

Rules: pick the motion that fits the data (a tally grows with count, a cascade scales with how many were taken); scale by `intensity`; always route through the §9 a11y helpers so Reduce Motion collapses it. Don't dilute into one generic celebration.

## 13. Homepage layout modes

The dashboard is one data set (`HomepageDomainData` per section) rendered through interchangeable modes, selected via `HomepageLayoutMode`:

- `WeekDashboardView` — `ModuleTile` grid (stats + trend per section).
- `RingsHomepageView` — one progress ring per section (target % or week activity).
- `HeatmapHomepageView` — one `ConsistencyHeatmap` per section (row on compact, grid on wide).
- `RhythmHomepageView` — all sections overlaid on one `TimeOfDayWheel`.
- `DenseHomepageView` — compact icon + headline rows.

A new mode consumes the same `HomepageDomainData` and reuses the §10 primitives; it must not invent a parallel data path.
