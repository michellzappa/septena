# Section system — DRY & consistency audit + refactor plan

Goal: make the implementation of **tasks / sections / manifests / plugins**
incredibly DRY and consistent.

## Headline finding

The section **contract is already clean**. `SectionManifest` (identity, in
SeptenaCore) ↔ `SectionRegistry` (behavior, in app) ↔ `HomepageDomain`
(dashboard tiles) are 1:1 and parity-asserted at launch
(`SectionRegistry.assertManifestParity()`). No "manifest row without a tile"
gaps exist.

The DRY/consistency debt lives in two places:

1. **Consumers that branch on `key`** instead of asking the manifest/plugin —
   re-encoding facts the plugin system already owns (often incompletely).
2. **Per-item patterns that drift** — context menus, edit-sheet callbacks,
   delete keys, mutator method names.

So the work is *routing consumers through the contract* + *normalizing the item
layer*, not rebuilding the contract.

## Tier 1 — Identity de-duplication (high value, low risk) — DONE

- [x] **`CoachContextBuilder`** `sectionLabel()` / `icon()` hand-maintained
  switches (incomplete — omitted symptoms/medications/groceries/activity/github)
  → read `SectionManifest.byKey[key]?.defaultLabel` / `.iconSymbol`. Deletes
  ~40 lines and fixes the missing-section fallbacks.

## Tier 4 — Write boundary (alongside Tier 1) — DONE

- [x] **`SettingsView.updateColor`** wrote `SectionEntity` + `modelContext.save()`
  directly → added `SettingsMirror.setSectionColor(...)` (matching the existing
  `setSectionEnabled` / `setSectionShowInToday` / `setSectionShowInSpotlight`
  shape) and routed the view through it.

## Tier 2 — Per-item normalization (medium value, medium churn) — TODO

- [ ] **Edit-sheet callbacks**: standardize on `(Entity?) -> Void`.
  Mood/Nutrition/Intake use bare `() -> Void` (caller can't tell what saved).
- [x] **Done-Today log Edit/Delete** for mood/nutrition/gut — `NextDoneSection`
  re-resolves the live entity from the `DoneEvent` id and presents the existing
  `Edit*EntrySheet` via `adaptiveDetail`; delete routes through each section
  mutator. `DoneEventRow` gained optional `onEdit`/`onDelete` + a conditional
  context menu. Training (collapsed session) + wake stay read-only. (Note:
  `NutritionEntry.id == file`, so the delete-key "quirk" was a non-issue.)
- [ ] **Delete-key inconsistency**: Training & Nutrition delete by `entry.file`,
  all others by `id`. Likely intentional (blob-keyed storage) — *decide*:
  document `file` as their id-equivalent, or add a uniform `deleteEntry(id:)`
  shim. Not necessarily a code change.

## Tier 3 — Make consumers registry-driven — PARTIALLY DONE

On inspection, only one of these is a clean win; the rest encode genuine
per-section variation that resists a registry slot (documented so we don't
churn against the grain later).

- [x] **HomepageDomain ↔ manifest parity assertion** — added to
  `assertManifestParity()` (DEBUG, launch). Keeps the enum for type-safety +
  ordering but fails loudly on drift from `supportsDashboard`. Clean win.
- [ ] **Quick-add** `WeekDashboardView` switch (11 cases) → **host-coupled,
  large.** Each menu drives `WeekDashboardView`'s own sheet state
  (`presentingMoodCheckin`, `commitHydration(ml:)`, sheet bindings). A clean
  plugin slot means making each section's quick-add self-contained (own sheet
  state, like `TaskRowActions`) — a ~9-section refactor. Real, but the riskiest
  bucket; do deliberately, not big-bang. DEFERRED pending a go-ahead.
- [ ] ~~**Siri intent mapping** switch~~ → **WON'T DO.** App Intents are concrete
  generic types and `SiriTipView` needs the static type; a type-erased plugin
  slot breaks the generic. Already documented in-code as "the switch is
  unavoidable" (`SiriShortcutsSettingsPane.swift:60`). Leave it.
- [ ] **Next feed** `block(for:)` + `isEmpty()` → **over-abstraction risk.**
  Membership is intentionally curated (`NextBlocks` = 4) and the four blocks
  render genuinely different row types (`TodayTaskRow` vs the `CheckableRow`
  trio). A plugin slot would have to thread the full Next render context
  (models, mutators, theme) through a static func for marginal gain. DEFERRED;
  may not be worth it.

## Explicitly NOT debt (do not churn)

- Read-only sections (sleep/body/activity/github) lacking MCP/quick-add/watch —
  by design.
- Next curated to 4 completable sections — intentional.
- **Mutator method-name variety** (`addEntry` / `logEntry` / `logDose`) — a
  blanket rename is high churn across MCP dispatch + call sites for little gain,
  and the names are domain-meaningful. Recommend against.

## Sequencing

Each tier lands green independently — no big-bang edit (the pattern that caused
this repo's past divergence). Tier 1 + Tier 4 first (done), then Tier 2 (incl.
the Done-log resolver), then evaluate Tier 3 per item.
