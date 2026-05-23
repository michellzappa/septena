# Septena Migration Handoff

Last updated: 2026-05-23

This handoff is for the next agent taking over the FastAPI -> CloudKit
migration in the iOS app and the matching MCP gateway work.

## Repos

- iOS app: `/Users/mz/Dev/septena-cloud`
- Active MCP gateway sibling: `/Users/mz/Dev/septena-mcp-gateway`
- Deprecated MCP repo is not the target. Use `septena-mcp-gateway`.

## Current Migration Status

CloudKit-backed and already wired through the app:

- tasks
- areas
- projects
- settings
- sections

Partially started, app-side only, not yet CloudKit-native:

- habits
- supplements
- chores

Still mostly FastAPI-backed:

- goals
- groceries
- nutrition
- caffeine
- cannabis
- gut
- training
- remaining history/aggregate views

## What Was Already Finished Before This Handoff

### Tasks / Areas / Projects

These are already migrated with:

- SwiftData mirror entities in
  [Persistence.swift](/Users/mz/Dev/septena-cloud/SeptenaCore/Persistence.swift)
- CloudKit record mappers in
  [TaskRecord.swift](/Users/mz/Dev/septena-cloud/SeptenaCore/CloudKit/TaskRecord.swift),
  [AreaRecord.swift](/Users/mz/Dev/septena-cloud/SeptenaCore/CloudKit/AreaRecord.swift),
  [ProjectRecord.swift](/Users/mz/Dev/septena-cloud/SeptenaCore/CloudKit/ProjectRecord.swift)
- sync engine wiring in
  [CKEngine.swift](/Users/mz/Dev/septena-cloud/SeptenaCore/CloudKit/CKEngine.swift) and
  [SeptenaServices.swift](/Users/mz/Dev/septena-cloud/SeptenaCore/SeptenaServices.swift)

Parity fixes already made and expected to remain true:

- task ids use the short base32 format
- `created` dates use `YYYY-MM-DD`
- empty string reads from CloudKit Web Services normalize to nil
- completing a task clears `today` and `todaySetOn`
- project/area assignment remains mutually exclusive

### Settings / Sections

These are now CloudKit-first in the app, with FastAPI only as fallback when
the local mirror is empty.

Key files:

- [SettingsMirror.swift](/Users/mz/Dev/septena-cloud/SeptenaCore/SettingsMirror.swift)
- [SettingsRecord.swift](/Users/mz/Dev/septena-cloud/SeptenaCore/CloudKit/SettingsRecord.swift)
- [SectionRecord.swift](/Users/mz/Dev/septena-cloud/SeptenaCore/CloudKit/SectionRecord.swift)
- [SettingsView.swift](/Users/mz/Dev/septena-cloud/Septena/Shell/Settings/SettingsView.swift)
- [SectionTheme.swift](/Users/mz/Dev/septena-cloud/SeptenaCore/SectionTheme.swift)
- [Migration.swift](/Users/mz/Dev/septena-cloud/SeptenaCore/CloudKit/Migration.swift)

Important known fix:

- mirrored section ordering had been wrong once; it was fixed in
  [SettingsMirror.swift](/Users/mz/Dev/septena-cloud/SeptenaCore/SettingsMirror.swift)
  so `settings.section_order` wins over alphabetical fallback

### MCP Gateway State

In `/Users/mz/Dev/septena-mcp-gateway`, the gateway already has CloudKit
tools for the migrated domains above.

Important naming constraint from the user:

- `tasks_list_projects` stays
- `tasks_list_areas` stays
- `sections_list` is the correct sections tool name
- `tasks_list_sections` was intentionally removed

Do not reintroduce legacy aliases unless the user explicitly asks.

## Work Started This Turn

Follow-up on 2026-05-23:

- habits definitions + day events are now wired into the app's CloudKit
  engine path
- supplements definitions + day events are now wired into the app's
  CloudKit engine path
- chores definitions + events now have a canonical app-side SwiftData +
  CloudKit model as well
- app startup now does a one-time FastAPI `range` backfill for habits and
  supplements when this install has not yet round-tripped those domains
  through CloudKit
- that backfill seeds the full local history window and immediately queues
  those records for CloudKit upload

Chores are only partially bootstrapped:

- the app can now ingest a canonical `definitions + events` export and derive
  current due state locally
- startup will auto-import chores too once FastAPI exposes that export

Still missing on the backend side:

- a raw chore export endpoint, e.g. `/api/chores/export?days=N`
- it must return:
  - all current definitions
  - raw events with a stable per-file `record_id`

Important backend detail:

- current chore event JSON `id` values are not unique for multiple same-day
  defers; the export must not use that field as CloudKit identity
- use the underlying filename or another stable unique event key instead

This turn only started safe groundwork for `habits + supplements + chores`.
It did not finish their CloudKit migration.

### New Local Mirror Entities

Added in
[Persistence.swift](/Users/mz/Dev/septena-cloud/SeptenaCore/Persistence.swift):

- `HabitDefinitionEntity`
- `HabitDayStateEntity`
- `SupplementDefinitionEntity`
- `SupplementDayStateEntity`
- `ChoreSnapshotEntity`

These are local mirror/cache entities only. They do not yet carry
`cloudKitSystemFields`, and they are not yet part of `CKEngine`.

### New Mirror Helper

Added:

- [ChecklistMirror.swift](/Users/mz/Dev/septena-cloud/SeptenaCore/ChecklistMirror.swift)

What it does:

- reconstructs `HabitsDayResponse` from the local mirror
- reconstructs `SupplementsDayResponse` from the local mirror
- reconstructs `[ChoreItem]` from the local mirror
- replaces mirrored rows using current FastAPI responses

Current shape:

- habits are stored as definitions plus date-scoped state
- supplements are stored as definitions plus date-scoped state
- chores are stored as a snapshot list

This is intentionally transitional. It improves cold-start/cache behavior
without committing yet to the final CloudKit event model.

### Dashboard / Next Screen Wiring

Updated:

- [NextItemsSection.swift](/Users/mz/Dev/septena-cloud/Septena/Shell/Dashboard/NextItemsSection.swift)

Current behavior:

- `paintFromCache()` reads `habits`, `supplements`, and `chores` from
  `ChecklistMirror` first
- it falls back to `ResponseCache` when the mirror is empty
- `load(client:)` still fetches from FastAPI
- successful FastAPI responses now seed the mirror via `ChecklistMirror`

What did not change:

- mutations still go through `HTTPOutbox`
- no CloudKit writes for these domains yet
- no CK record types yet
- no MCP tool work yet for these domains

## Current Build State

Verified on 2026-05-23:

- `xcodebuild -project Septena.xcodeproj -scheme Septena -destination 'generic/platform=iOS Simulator' build`
- Result: `BUILD SUCCEEDED`

Known warnings remain, unrelated to this migration slice:

- several existing `ModelContext` non-Sendable warnings
- one existing `try?` warning in `SuggestionEngine.swift`

## Working Tree Notes

The tree includes earlier migration files plus this turn's groundwork.
Notable modified/untracked files:

- [MIGRATION_PLAN.md](/Users/mz/Dev/septena-cloud/MIGRATION_PLAN.md)
- [ChecklistMirror.swift](/Users/mz/Dev/septena-cloud/SeptenaCore/ChecklistMirror.swift)
- [Persistence.swift](/Users/mz/Dev/septena-cloud/SeptenaCore/Persistence.swift)
- [NextItemsSection.swift](/Users/mz/Dev/septena-cloud/Septena/Shell/Dashboard/NextItemsSection.swift)
- [SettingsMirror.swift](/Users/mz/Dev/septena-cloud/SeptenaCore/SettingsMirror.swift)
- [SettingsRecord.swift](/Users/mz/Dev/septena-cloud/SeptenaCore/CloudKit/SettingsRecord.swift)
- [SectionRecord.swift](/Users/mz/Dev/septena-cloud/SeptenaCore/CloudKit/SectionRecord.swift)
- [Migration.swift](/Users/mz/Dev/septena-cloud/SeptenaCore/CloudKit/Migration.swift)

There are also prior task/settings migration edits in the working tree. Do
not assume this is a clean branch.

## Recommended Next Step

Do not jump straight into CloudKit writes for all three checklist domains at
once. The safer next move is:

1. Decide the canonical CloudKit model for each domain.
2. Then replace the transitional snapshot mirror with that model.

Recommended target model:

- habits:
  - `HabitDefinition`
  - `HabitEvent`
- supplements:
  - `SupplementDefinition`
  - `SupplementEvent`
- chores:
  - `ChoreDefinition`
  - `ChoreEvent`

Reason:

- the final system needs history parity
- the old FastAPI API exposes day/history/range views that are derived from
  definitions plus events
- storing only snapshots in CloudKit will paint us into a corner again

## Recommended Implementation Order

### 1. Habits

Start with habits first.

- inspect FastAPI habit config, day, history, toggle, skip, range behavior
- add final SwiftData entities with CloudKit identity metadata
- add `HabitDefinitionRecord.swift` and `HabitEventRecord.swift`
- add typed read derivation for `day` and `history`
- replace habit `HTTPOutbox` writes with a typed CloudKit mutator
- add MCP gateway habit tools in `septena-mcp-gateway`

### 2. Supplements

Then repeat the same pattern for supplements.

### 3. Chores

Do chores after habits/supplements because due/defer semantics are a little
more stateful.

The chore CloudKit model should be event-based, not snapshot-only, so due,
overdue, completion, uncompletion, and defer history can all be derived.

## Rules For The Next Agent

- Keep using the active gateway repo:
  `/Users/mz/Dev/septena-mcp-gateway`
- Do not deploy anything to Cloudflare unless the user explicitly asks
- Do not reintroduce `tasks_list_sections`
- Keep projects/areas under the `tasks_` namespace
- Keep sections outside the tasks namespace
- Do not migrate aggregate `/history` blobs as CloudKit records
- Prefer canonical event records and derived views
- Extend migration snapshot/export before any destructive cutover

## Useful Commands

App build:

```sh
xcodegen generate
xcodebuild -project Septena.xcodeproj -scheme Septena -destination 'generic/platform=iOS Simulator' build
```

Gateway verification:

```sh
cd /Users/mz/Dev/septena-mcp-gateway
npm run typecheck
```

## One-Line Summary

The app is already CloudKit-first for tasks, areas, projects, settings, and
sections. `habits + supplements + chores` have only a new local mirror/cache
layer so far; their actual CloudKit event migration and MCP gateway migration
are still the next real chunk of work.
