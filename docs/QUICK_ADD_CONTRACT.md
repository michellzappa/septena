# Quick-add contract

Every section that can be logged from the dashboard has two quick-add surfaces.
They play distinct roles, and both must stay *useful, never overwhelming, and
consistent across the app's variety*.

## The two surfaces

1. **Tile context-menu** — long-press / trailing-circle on a dashboard tile
   (`Septena/Sections/<Name>/<Name>QuickAddMenu.swift`, wired in
   `WeekDashboardView.quickAddMenu(for:)`). This surface carries the dual
   pattern.
2. **In-section "+"** — the one prominent accent button in `SectionDrawer`
   (`DrawerQuickAdd`). This opens the **full editor/composer directly**.

## The rule (tile context-menu)

A tile menu is, in order:

1. **Quick suggestions** — up to ~5 context-aware one/two-tap actions for *right
   now* (due items, recent/common logs, container choices). Capped; never a wall.
2. `Divider()`
3. **Exactly one escape row** to the full surface — so the menu is *never a
   dead end*, even when nothing is due.

How the escape resolves, by section type:

- **Event-log sections** (Mood, Symptoms, Gut, Nutrition, Intake, Medications,
  Hydration) — escape reaches the full editor. Either directly (`New entry…` /
  `New meal…` / `Full check-in…`) or by opening the section (`<Section>…` /
  `More…`), where the "+" is the editor.
- **Toggle/checklist sections** (Habits, Supplements, Chores, Groceries) —
  escape is `<Section>…`, opening the section drawer where you add / manage.

Escape rows that open the section use the `ellipsis` glyph and a `<Section>…`
label; rows that open an editor directly use an editor glyph
(`square.and.pencil`, `plus.circle`) and a `New …` label.

## The rule (in-section "+")

`DrawerQuickAdd` opens the full editor/composer directly. Sections with several
quick options instead point it at a chooser **sheet** (not a Menu —
`.glassProminent` only fills a Button) that leads with suggestions and **ends
with a `New entry…` row** to the full editor (see `IntakeQuickLogSheet`,
`MealRelogSearchView`).

## Adding a section

A new loggable section must wire **both**: a tile menu that follows the rule
above (suggestions + one escape), and a `DrawerQuickAdd` that reaches the full
editor. See `docs/ADDING_A_SECTION.md` for the rest of the surface checklist.

This is a UI contract only — it adds no MCP tools or wire fields.
