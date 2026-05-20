# CloudKit Migration — Handoff

Status as of 2026-05-20. Tasks, areas, and projects are on CloudKit
via CKSyncEngine. This document is the brief for the next agent.

> **Identifier model — read first.**
> All label-style entities (areas, projects, and any future chores/habits/
> sections that move to CK or to the MCP surface) use a uniform
> **id + slug + previousSlugs** model. The design rationale, rename
> semantics, and an "adding a new entity type" checklist live in
> [IDENTIFIERS.md](IDENTIFIERS.md). **Apply that checklist whenever you
> add a new entity type — do not invent a fresh id strategy.**

## TL;DR

- **Tasks: on CloudKit.** Writes route through `CKSyncEngine`. Reads
  come from the SwiftData mirror that the engine keeps fresh. Migration
  preserves identity (CKRecord recordName == TaskEntity.id). Tasks are
  content (not labels) and use id-only — no slug.
- **Areas + projects: on CloudKit** (Phase 5b complete). Use the
  id+slug+previousSlugs model from [IDENTIFIERS.md](IDENTIFIERS.md).
  New records get base32-4 shortid ids; legacy records (`septena`,
  `obsidian`) keep their slug-as-id values, which the resolver matches
  uniformly.
- **Other server data (habits, chores, nutrition, etc): unchanged.** When
  they move, follow the IDENTIFIERS.md checklist.
- **Backend selection**: Tasks, areas, and projects are CloudKit-only
  as of the cutover. The `TasksBackendDefaults` flag and the DEBUG
  Settings picker have been removed. FastAPI remains the backend for
  habits, nutrition, training, chores, and supplements.

## Architecture

### Storage layers

1. **Server-side CloudKit zone** `septena-v1` in container
   `iCloud.com.septena.cloud`, Development environment. One record
   type `Task` so far. Schema auto-creates from first write.
2. **CKSyncEngine** (`SeptenaCore/CloudKit/CKEngine.swift`) — owns the
   zone, persists state to `Application Support/CKEngineState.json`,
   handles push subscriptions automatically, exposes pending-changes
   API.
3. **SwiftData mirror** — `TaskEntity` rows in the app-group store.
   Authoritative for reads in CK mode. CKSyncEngine folds incoming
   records via the `applyFetchedRecord` closure; outgoing records are
   materialized by `recordProvider`.
4. **JSON snapshot files** in `Application Support/TaskSnapshots/`.
   Written before every migrate (`pre-migration-*.json`) and on
   demand (`manual-*.json`). Recovery seed.

### Critical settings

- `ModelConfiguration(... cloudKitDatabase: .none)` in
  [Persistence.swift](SeptenaCore/Persistence.swift). Do NOT remove.
  Setting this to `.automatic` (the default) makes SwiftData detect
  the iCloud entitlement and switch to NSPersistentCloudKitContainer
  auto-mirror mode, which has incompatible schema requirements
  (all-optional attributes, no `@Attribute(.unique)`) and will crash
  on launch. We sync via CKSyncEngine explicitly; SwiftData stays
  a local-only store.
- `cloudKitSystemFields: Data?` on `TaskEntity`. Captured every time
  `apply(_:)` runs (which is every time a record round-trips through
  CK). Required so re-saves preserve `recordChangeTag` and don't 409.

### Write path (mutations)

```
View → TaskMutator.<method>
     → if CK flag: CloudKitTasksBackend.<method>
         → mutate TaskEntity in SwiftData
         → engine.noteTaskChange(id:) or noteTaskDeletion(id:)
         → context.save(); post .septenaTasksChanged
       else: existing FastAPI/Outbox path
```

`TaskMutator` is the per-method router. Each method has an `if let
cloudBackend { ...; return }` guard at the top. See
[Outbox.swift](SeptenaCore/Outbox.swift).

### Read path

```
View → TaskReads.list/counts(client:, context:)
     → if CK flag: synthesize TasksListResponse / TasksCounts from
                   LocalCache.tasks(in:, filter:)
       else: client.list / client.counts
```

`TaskReads` ([SeptenaCore/CloudKit/TaskReads.swift](SeptenaCore/CloudKit/TaskReads.swift))
returns the same response shapes as `SeptenaClient`, so call sites
don't branch. 13 call sites have been swapped (see Phase 5 commit).

### Engine plumbing

App.swift, `.task` block, binds three closures and one callback on
`ckEngine` after the @State is alive:

- `recordProvider(recordID)` → builds a CKRecord from the SwiftData
  entity via `entity.toCloudKitRecord()`. Returns nil if entity is
  missing (engine will treat as a transient miss).
- `applyFetchedRecord(record)` → finds-or-inserts a `TaskEntity` and
  calls `entity.apply(record)`. Does NOT save or notify per-record
  — `applyDidFinishBatch` batches that.
- `applyDeletedRecord(recordID)` → deletes the matching TaskEntity.
  Same no-save-per-record pattern.
- `applyDidFinishBatch()` → one `context.save()` + one
  `.septenaTasksChanged` notification per CKEngine event. Critical
  for performance: a 500-row migration fan-out used to take 60+
  seconds before this; now sub-second.

### Reset semantics

`CKEngine.resetZone()` bypasses CKSyncEngine for the delete. Routing
`pendingDatabaseChanges: [.deleteZone(zoneID)]` through the engine
causes it to emit per-record deletion events for everything that was
in the zone, which our `applyDeletedRecord` then cascade-deletes
locally — a 500-row data loss the user definitely didn't ask for.
Direct `CKDatabase.deleteRecordZone(withID:)` + nuke the engine state
file + restart engine + add `saveZone` = clean server slate with
local data intact. `applyingResetCascade` flag is belt-and-suspenders
in case the engine still emits something during reset.

### SidebarView's `.all` apply was a separate latent bug

`syncer.applyTasks(items, scope: .all)` means "this response is the
complete world; delete every local row not in it." But the server's
`view=all` only returns the open subset, not done/cancelled. So
applying with `.all` scope mass-pruned the local store every time the
sidebar refreshed. Now uses `scope: .filter(.upcoming)` (no prune) AND
is skipped entirely in CK mode (where items came from LocalCache
anyway).

## What's done (Phase 0 through Phase 5)

- [x] Entitlements (iCloud + CloudKit + APS) on iOS Septena, SeptenaMac
- [x] `DEVELOPMENT_TEAM` lifted to project.yml base settings
- [x] `SeptenaCore/CloudKit/` directory with `CKEngine`, `TaskRecord`,
      `TasksBackend`, `TaskReads`, `Migration`
- [x] `TaskMutator` thin shim forwarding to `CloudKitTasksBackend`
- [x] `CloudKitTasksBackend` — full create/update/complete/uncomplete/
      cancel/delete/moveToToday/schedule/setDue/setRecurrence/
      moveToArea/moveToProject implementation
- [x] CKSyncEngine wired in App.swift; closures bound; engine starts on
      launch; account status monitored
- [x] FastAPI task-backend toggle removed (cutover complete) — CloudKit
      is now the only path for tasks/areas/projects
- [x] Migration tooling — Export Snapshot, Migrate to iCloud, Restore
      Latest Snapshot (size-based), Reset CloudKit Zone (cascade-safe)
- [x] Silent push registration (`registerForRemoteNotifications`) +
      iOS/macOS AppDelegate handlers route into
      `engine.handleRemoteNotification(_:)`
- [x] Account status monitoring via `.CKAccountChanged` notification;
      surfaced in Settings → Sync → CloudKit (dev) with icon + label;
      Migrate button disabled unless `.available`
- [x] System-fields capture from `sent.savedRecords` (not just
      `fetched.modifications`) — CKSyncEngine doesn't redeliver records
      it just sent, so this was the only path that populated tags
- [x] Batched saves during sent/fetched cascades
- [x] All 13 task-data read sites routed through `TaskReads`
- [x] Diagnostic logging — `[TaskState]` on launch,
      `[Create]/[Edit]/[CK]/[CKEngine]/[TaskMutator]/[TaskList]`
      throughout the flow
- [x] `[TaskState] total=N withCKSystemFields=N` verified on the
      user's device — full bidirectional sync working

## Phase 5b — Areas + Projects on CloudKit

Concrete checklist for the next agent.

### 1. Storage

In [SeptenaCore/Persistence.swift](SeptenaCore/Persistence.swift):

- Add `var cloudKitSystemFields: Data?` to `AreaEntity` (around line 173)
- Add `var cloudKitSystemFields: Data?` to `ProjectEntity` (around line 130)
- Both init signatures get the new defaulted-nil parameter

### 2. Record mapping

Create `SeptenaCore/CloudKit/AreaRecord.swift` and
`SeptenaCore/CloudKit/ProjectRecord.swift` mirroring
[TaskRecord.swift](SeptenaCore/CloudKit/TaskRecord.swift):

- Record types: `"Area"` and `"Project"`
- `decodedCloudKitRecord()`, `captureCloudKitSystemFields(from:)`,
  `toCloudKitRecord()`, `apply(_:)`, `init(cloudKit:)`
- Over-provision reserved fields the same way Task does — production
  schema is rigid

### 3. CKEngine extension

Currently has one set of `recordProvider` / `applyFetchedRecord` /
`applyDeletedRecord` closures, hard-coded for Tasks. Two options:

a) **Three sets of closures, one per record type**. Wiring lives in
   App.swift; engine dispatches by `record.recordType`. Simpler to
   read, more App.swift code.
b) **Single closure pair keyed by record type**. Cleaner if a fourth
   type ever lands. App.swift's bind block becomes a dictionary
   keyed by `"Task"|"Area"|"Project"`.

Pick (a) for now; refactor to (b) if a fourth type appears. Same
deletion-cascade safety guard (`applyingResetCascade`) applies.

### 4. Migrator extension

Either extend [Migration.swift](SeptenaCore/CloudKit/Migration.swift)
to handle all three types in one Migrate button (preferred — user
runs one action), or split into three migrators called sequentially
from the UI.

The snapshot JSON should grow to include `areas: [...]` and
`projects: [...]` alongside `tasks`. Update `TasksSnapshotFile` to
new shape; bump `schemaVersion` to 2. `importFromJSON` reads both
schemas (v1 = tasks only; v2 = all three).

### 5. Backend protocol

Currently `TasksBackend` only has task mutation methods. Decide:

a) Add area/project methods to the same protocol
   (`createArea`, `updateArea`, `deleteArea`, etc.), keeping a single
   monolithic surface.
b) Add `AreasBackend` and `ProjectsBackend` protocols alongside, each
   with their own CloudKit/FastAPI impls.

(b) is cleaner. The view code calls `areasBackend.create(...)` /
`projectsBackend.create(...)`. The current Areas/Projects mutation
paths in views are direct `client.createArea(...)` etc — those need to
be re-routed.

### 6. Read-path swaps

Five call sites still hit FastAPI for area/project data even in CK mode:

- [TaskListView.swift:1675-1676](Septena/Views/TaskListView.swift#L1675) — `client.projects() + client.areas()` in CK branch
- [SidebarView.swift:887-888](Septena/Views/SidebarView.swift#L887) — same
- [AreasProjectsView.swift:220-221](Septena/Views/AreasProjectsView.swift#L220) — same
- [AreasProjectsView.swift:428](Septena/Views/AreasProjectsView.swift#L428) — `client.areas()`
- [AreasProjectsView.swift:437](Septena/Views/AreasProjectsView.swift#L437) — `client.projects()`

Once Areas/Projects are on CK, swap to `LocalCache.areas(in:)` /
`LocalCache.projects(in:)` when the flag is on. Existing
`LocalCache.areas/projects` already work; just gate the call site.

### 7. Capability registration

In CloudKit Dashboard, the new `Area` and `Project` record types
auto-create on first write the same way `Task` did. After the
migration cutover lands and ships, promote schema Development →
Production via Dashboard's "Deploy Schema to Production" button.

## Phase 6 — Cleanup (~30 days post-cutover stability)

The runtime toggle is gone. Remaining cleanup is dead-code removal:

- Delete `OutboxEntity`, `OutboxKind`, task payload structs, `drain()`
  task paths, `executingEntryId`, `pendingCreate`, `enqueue` from
  [Outbox.swift](SeptenaCore/Outbox.swift) — keep habit/nutrition/etc
  outbox functionality intact
- Delete `Syncer` task-related code (FastAPI pull); keep area/project
  pull until those move too (which they have, but the Syncer code is
  still referenced by the migration path)
- Delete `client.list / counts / changes / nextItems / list(view:)`
  client-side
- Server-side: tasks endpoints (`/api/tasks/*`) become read-only or
  go away entirely. Inbox suggestion engine still needs task content
  via some path — either keep tasks endpoints read-only for that, or
  compute embeddings client-side from CK data

## Known non-blocking issues

- **⌘K keyboard shortcut conflict** — UIKeyCommand registry has both
  "Mark as Complete" and "Add Info…" bound to ⌘K. Surfaces in
  console as `Inserted elements conflict with existing elements:
  Keyboard Shortcut (duplicate modifierFlags: command, input: K)`.
  Unrelated to CK; fix by rebinding one of them.
- **`/api/next/items` still fires on every task notification** —
  it's not task data, but SidebarView observes `.septenaTasksChanged`
  and unconditionally refreshes its sidebar including the Next
  badge. Decouple in a follow-up.
- **Areas / projects refresh fires multiple times per task mutation**
  — same root cause. Multiple views observe the notification and
  each re-fetches. Phase 5b's local-read swap makes this free; until
  then, debouncing is the workaround.
- **SwiftData "Unbinding from the main queue" warnings** during
  CKSyncEngine event delivery. The context is correctly @MainActor;
  the warning is from the engine's internal queue handoff. Cosmetic.
- **`-[RTIInputSystemClient remoteTextInputSessionWithID:...]`
  warnings** in the create/edit flow. Internal iOS keyboard
  diagnostics. Not actionable.
- **Reporter disconnected** messages. Same category as above.

## Diagnostic logging surface

Anything prefixed with `[Septena]` and one of these tags is from us
and useful:

- `[TaskState]` — launch dump of TaskEntity counts (status, today,
  scheduled, due, area, project, pendingDeletion, withCKSystemFields)
- `[TaskMutator]` — which backend a mutation routed through
- `[CK]` — CloudKitTasksBackend operations (id + title + op)
- `[CKEngine]` — engine state changes: noteTaskChange, sent.save OK,
  sent.save FAIL with error, fetched.save, fetched.delete (IGNORED
  during reset), resetZone milestones
- `[TaskList]` — load() route taken (cloudKit vs fastAPI) + final
  count
- `[Create]` — + button → shouldStartCreating → startDraft →
  mutator.create returned → editingTaskId set
- `[Edit]` — focus changes, TextField onSubmit, onDisappear,
  commitEdit branches (empty+new delete, empty+existing leave, update
  with title)

To turn logging off in release builds, `SeptenaLog.enabled = false`
at app launch.

## Testing recipes

### Full CK round-trip verification

1. Settings → Sync → confirm iCloud row green.
2. Settings → Sync → Migration → Reset CloudKit Zone. Status:
   `Zone reset (N entities cleared). Now run Migrate…`.
3. Settings → Sync → Migration → Migrate Tasks to iCloud. Status:
   `Migrated N tasks. Snapshot: …`. Picker auto-flips to iCloud.
4. Relaunch. Top of console:
   `[TaskState] total=N ... withCKSystemFields=N`.
5. Create a task (+, type, Enter). Console logs the full
   `[Create]/[Edit]/[CK]/[CKEngine]` chain. Task persists.
6. Edit an existing task. Console: `[CK] update`, `[CKEngine] sent.save
   OK`, no FAIL. CK Dashboard zone query shows updated title.
7. Delete a task. Console: `[CK] delete`, `[CKEngine] sent: deletes=1`.
   Dashboard query shows the record gone.

### Recovery from data loss

If something corrupts local SwiftData:

1. Settings → Sync → Migration → Restore Latest Snapshot. Picks the
   largest snapshot (most data). Status: `Restored N tasks from …`.
   Picker flips to FastAPI.
2. Relaunch. `[TaskState] total=N` with restored count.
3. If you want to retry CK: flip to iCloud, Reset Zone, Migrate.

### Offline → online

1. Airplane mode. Edit a few tasks.
2. Console: `[CKEngine] noteTaskChange ... pending=N` (engine queues
   them).
3. Airplane mode off.
4. Engine drains within seconds: `[CKEngine] sent.save OK` per task.
5. Dashboard reflects.

## File map

- [SeptenaCore/CloudKit/CKEngine.swift](SeptenaCore/CloudKit/CKEngine.swift) — engine wrapper, account status, push, reset, batching
- [SeptenaCore/CloudKit/TaskRecord.swift](SeptenaCore/CloudKit/TaskRecord.swift) — TaskEntity ↔ CKRecord mapping + system fields capture
- [SeptenaCore/CloudKit/TasksBackend.swift](SeptenaCore/CloudKit/TasksBackend.swift) — `TasksBackend` protocol + `CloudKitTasksBackend` (sole implementation)
- [SeptenaCore/CloudKit/TaskReads.swift](SeptenaCore/CloudKit/TaskReads.swift) — read-side routing (list/counts → LocalCache in CK mode)
- [SeptenaCore/CloudKit/Migration.swift](SeptenaCore/CloudKit/Migration.swift) — `TasksMigrator` + snapshot file shapes
- [SeptenaCore/Persistence.swift](SeptenaCore/Persistence.swift) — SwiftData entities + `cloudKitDatabase: .none` + `LocalCache.logTaskStateSummary`
- [SeptenaCore/Outbox.swift](SeptenaCore/Outbox.swift) — `TaskMutator` router + FastAPI/Outbox path (will die in Phase 6)
- [Septena/App.swift](Septena/App.swift) — engine instantiation, closure bind, AppDelegate push routing
- [Septena/Views/SettingsView.swift](Septena/Views/SettingsView.swift) — CK (dev) section + migration buttons + account status row
- [Septena/Views/TaskListView.swift](Septena/Views/TaskListView.swift) — CK-mode read branch, inline editor, commitEdit
- [Septena/Views/TaskComponents.swift](Septena/Views/TaskComponents.swift) — InlineEditTaskRow, focus/blur/submit handlers
- [Septena/Views/SidebarView.swift](Septena/Views/SidebarView.swift) — sidebar aggregate; uses `TaskReads`, skips `.all` prune in CK mode

## Notes for the next agent

- Don't trust "right after import" as a synchronization guarantee
  unless you actively reconciled all sources. CK and FastAPI drift
  the moment one is written to without the other.
- CKSyncEngine's state file (`CKEngineState.json`) and the SwiftData
  store must stay in lockstep. If one is wiped, wipe the other. The
  reset-zone code already does this; if you add other paths that
  wipe local state, do the same.
- `apply(_:)` is unconditional on field values. A CKRecord that
  doesn't have a field will set the local entity's field to nil.
  This is correct (server is authoritative) but watch out when
  building records — if you forget to set a field, you lose data
  on the next fetch.
- Migration always exports a snapshot first. Always. The recovery
  story depends on it.
- The user's data lives on three places in dev (local SwiftData +
  CloudKit Development + FastAPI). Production will collapse to one
  (CK). Don't lose track of which is authoritative for a given
  flag state.
