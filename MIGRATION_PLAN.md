# Septena CloudKit Migration Plan

Status: Phase 0 inventory, created 2026-05-22.

This plan covers the remaining move from the FastAPI / JSON-file backend to
CloudKit, and the matching move from file/HTTP agent skills to the hosted MCP
gateway at `/Users/mz/Dev/septena-mcp-gateway`.

## Current State

Tasks, areas, and projects are already CloudKit-backed in the iOS app:

- Local SwiftData mirror: `TaskEntity`, `AreaEntity`, `ProjectEntity` in
  `SeptenaCore/Persistence.swift`.
- CK record mappers: `TaskRecord.swift`, `AreaRecord.swift`,
  `ProjectRecord.swift`.
- Mutation facades: `CloudKitTasksBackend`, `CloudKitAreasBackend`,
  `CloudKitProjectsBackend`.
- Sync engine: `CKEngine`, using one custom zone, `septena-v1`.
- Migration / repair: `TasksMigrator`, which now snapshots, pushes, repairs,
  and replaces local mirror state for tasks + areas + projects.
- MCP gateway: `septena-mcp-gateway` already exposes CloudKit task/project/area
  tools over CloudKit Web Services.

FastAPI remains the source of truth for settings, section metadata, habits,
supplements, chores, goals, groceries, nutrition, caffeine, cannabis, gut,
training, and read-only integration views.

## Existing Migration Pattern

Each domain should follow the task migration pattern:

1. Add SwiftData entity or entities with `cloudKitSystemFields: Data?`.
2. Add a `FooRecord.swift` mapper with stable CK field names.
3. Add a typed `FoosBackend` / mutator that writes locally and calls
   `CKEngine.noteFooChange(id:)` or deletion equivalent.
4. Extend `CKEngine` dispatch in `SeptenaServices.start()` for outbound,
   fetched, and deleted records.
5. Add read facades that return existing app DTO shapes from `LocalCache`.
6. Extend the snapshot / migration / repair code before any destructive change.
7. Add matching MCP gateway tools that read/write CloudKit directly.
8. Keep FastAPI as read-only or fallback until the domain has been verified.

History should not be stored as migrated aggregate blobs. Store canonical
events and compute `/history`, `/day`, and dashboard summaries from those
events in both iOS and the MCP gateway.

## Identifier Rules

Use the current `IDENTIFIERS.md` model:

- Content/event records: stable opaque id.
- Label/config records: immutable `id` plus mutable `title` or `name`.
- No new slug or previous-slug fields.
- Tool inputs may accept id or exact title/name; tool outputs must include both
  id and display text.
- Foreign keys store target ids, never titles.

## Parity Issues To Keep Fixed

Before adding more domains, keep iOS and MCP task behavior aligned:

- New task ids use the same base32 alphabet and six-character length.
- `created` is `YYYY-MM-DD`, not full ISO timestamp.
- Empty string fields from CloudKit Web Services are normalized to nil/undefined
  on read.
- Completing a task clears `today` and `todaySetOn`.
- Moving a task to an area clears project; moving to a project clears area.

## Domain Inventory

| Domain | FastAPI endpoints in use | JSON / file source | Proposed CK records | History strategy | MCP gateway tools |
|---|---|---|---|---|---|
| Settings | `/api/settings` | `Settings/settings.json` | `Settings` singleton | None | `settings_get`, `settings_update` |
| Sections | `/api/sections` | settings + manifest merge | `Section` | None | `sections_list`, `sections_update` |
| Habits | `/api/habits/config`, `/day/{date}`, `/history`, `/toggle`, `/skip`, `/new`, `/update`, `/delete/{id}`, `/range` | `Habits/habits-config.json`, `Habits/Log/*.json` | `HabitDefinition`, `HabitEvent` | Derive day/range/history from events | `habits_list`, `habits_log`, `habits_skip`, `habits_update` |
| Supplements | `/api/supplements/config`, `/day/{date}`, `/history`, `/history-by-id`, `/toggle`, `/new`, `/update`, `/delete/{id}`, `/range` | `Supplements/supplements-config.json`, `Supplements/Log/*.json` | `SupplementDefinition`, `SupplementEvent` | Derive day/range/history from events | `supplements_list`, `supplements_log`, `supplements_update` |
| Chores | `/api/chores/list`, `/history`, `/complete`, `/uncomplete`, `/defer`, `/definitions`, `/definitions/{id}` | `Chores/Definitions/*.json`, `Chores/Log/*.json` | `ChoreDefinition`, `ChoreEvent` | Replay events to derive due/overdue/history | `chores_list`, `chores_complete`, `chores_defer`, `chores_update` |
| Goals | `/api/goals`, `/api/goals/{id}` | `Goals/Items/*.json` | `Goal` | None | `goals_list`, `goals_create`, `goals_update`, `goals_delete` |
| Groceries | `/api/groceries`, `/item`, `/item/{id}`, `/categories`, `/category`, `/categories/order`, `/history` | `Groceries/groceries-config.json`, `Groceries/Log/*.json` | `GroceryItem`, `GroceryCategory`, optional `GroceryEvent` | Derive bought/low history from events if kept | `groceries_list`, `groceries_update`, `groceries_categories` |
| Nutrition | `/api/nutrition/entries`, `/events`, `/stats`, `/macros-config` | `Nutrition/nutrition-config.json`, `Nutrition/Log/*.json` | `NutritionEntry`, `NutritionSettings` | Derive macro totals and fasting windows from entries | `nutrition_list`, `nutrition_log`, `nutrition_update`, `nutrition_stats` |
| Caffeine | `/api/caffeine/config`, `/day/{date}`, `/history`, `/entries`, `/entry`, `/beans` | `Caffeine/caffeine-config.json`, `Caffeine/Log/*.json` | `CaffeineEntry`, `CaffeineBean`, `CaffeineSettings` | Derive counts and time series from entries | `caffeine_list`, `caffeine_log`, `caffeine_update` |
| Cannabis | `/api/cannabis/config`, `/day/{date}`, `/history`, `/entries`, `/entry`, `/strains`, `/capsule/*` | `Cannabis/cannabis-config.json`, `Cannabis/Log/*.json`, `_capsules.json` | `CannabisEntry`, `CannabisStrain`, `CannabisCapsuleState` | Derive counts from entries; capsule state as current state | `cannabis_list`, `cannabis_log`, `cannabis_capsule` |
| Gut | `/api/gut/config`, `/day/{date}`, `/history`, `/entry/{id}` | `Gut/gut-config.json`, `Gut/Log/*.json` | `GutEntry`, `GutSettings` | Derive daily movement metrics from entries | `gut_list`, `gut_log`, `gut_update` |
| Training | `/api/training/entries`, `/sessions`, `/last-entries`, `/session-types`, `/summary`, `/progression/{exercise}`, `/cardio-history`, `/suggested-workout` | `Training/training-config.json`, `Training/Log/*.json` | `TrainingEntry`, `TrainingSessionType`, `ExerciseDefinition` | Derive progression, summary, cardio history, suggestions from entries | `training_entries`, `training_log`, `training_last_entries`, `training_summary` |
| Air | `/api/air/summary`, `/history` | `Air/Log/*.json`, cache state | `AirReading` or keep integration-derived | Derive summary/history from readings | Defer unless agent writes air data |
| Sleep | `/api/health/oura`, `/summary`, `/combined`, `/cache` | external Oura + optional cached snapshots | Defer; maybe `SleepNight` snapshots | Derived from imported nights | Read-only later |
| Body | `/api/health/withings` | external Withings + optional body logs | Defer; maybe `BodyMeasurement` snapshots | Derived from measurements | Read-only later |
| Apple Health / Activity | native HealthKit in iOS; FastAPI has `/api/health/apple` | Health Auto Export JSON | Keep device-local unless cloud backup is required | Derived locally | Defer |
| Calendar / Reminders | native EventKit in iOS | external OS data | Keep outside CK except imported tasks | None | Defer |

## Migration Order

### Phase 1: Settings and Sections

Goal: make non-task app configuration CloudKit-native and prove a generic
domain migration path before moving personal history.

- Add `SettingsEntity` and `SectionEntity`.
- Add `SettingsRecord.swift` and `SectionRecord.swift`.
- Extend `CKEngine` with settings/section note methods.
- Replace `SettingsStore.refresh()` and `SectionTheme.refresh()` with local
  CloudKit-backed reads, keeping FastAPI fallback behind a debug/legacy path.
- Add one migration action that snapshots current settings/sections before
  pushing to CloudKit.
- Add MCP gateway tools for get/update/list.

### Phase 2: Recurring Checklists

Move habits, supplements, and chores together because they share the same
definition-plus-event shape.

- Migrate definitions first, then event logs.
- Implement local derived reads for today, range, and history.
- Replace `HTTPOutbox` usage in habit/supplement/chore views with typed CK
  mutators.
- Add MCP tools that accept id or exact name and return canonical ids.

### Phase 3: Simple CRUD Domains

Move goals and groceries.

- Goals are straightforward content records.
- Groceries need current item/category records and optional events if the
  bought/low history remains user-visible.

### Phase 4: Per-Event Logs

Move nutrition, caffeine, cannabis, gut, and training.

- Use one CK record per event.
- Keep config/catalog records separate from event records.
- Make dashboard history and charts pure derivations.
- Add indexes in CloudKit Dashboard for `date`, `recordName`, and any
  high-cardinality query fields used by the gateway.

### Phase 5: Integration Snapshots

Only after user-authored data is moved:

- Decide whether Oura/Withings/Air snapshots should be stored in CK or remain
  integration-backed read-through caches.
- Keep Apple Health primarily on-device unless there is a specific cross-device
  backup requirement.

### Phase 6: FastAPI Retirement

- Remove `HTTPOutbox` after every mutation path has a typed CK mutator.
- Remove FastAPI reads from iOS except explicit legacy import tools.
- Keep the old FastAPI backend read-only for one release window.
- Delete legacy file/HTTP skills after MCP gateway tools cover the same work.

## Settings UI Changes

The Sync pane should become domain-aware:

- Rename `Server URL` to `Legacy FastAPI URL`.
- Show CloudKit account status once.
- Show pending CloudKit records and pending legacy HTTP mutations separately.
- Show per-domain migration status.
- Rename `Re-sync to iCloud` to `Re-sync Migrated Data to iCloud`.
- Expand snapshot copy from "tasks + areas + projects" to "all migrated data".
- Keep dangerous recovery actions in DEBUG until the migration has proven safe.

## MCP Gateway Work

Gateway source: `/Users/mz/Dev/septena-mcp-gateway`.

For every migrated domain:

- Add `src/tools/<domain>*.ts` tool files.
- Add tool registration in `src/mcp.ts`.
- Reuse the same CloudKit field names as iOS record mappers.
- Resolve label references with the id/title rule from `IDENTIFIERS.md`.
- Return JSON with canonical ids, titles/names, and enough context for the
  agent to make the next call unambiguously.
- Keep derived views in lockstep with iOS local-read code.

## Verification Checklist Per Domain

- Migration exports a JSON snapshot before writing CK.
- Local count and CloudKit count match after send/fetch.
- iPhone and Mac show the same data after cold launch.
- Offline mutation queues and drains through CKSyncEngine.
- Gateway can list and mutate the same records the app sees.
- FastAPI/file source can be made read-only without losing app behavior.
- History/dashboard aggregates match pre-migration FastAPI output for a sample
  date window.
