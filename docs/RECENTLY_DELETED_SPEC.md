# Recently Deleted (soft-delete) for tasks

## Why

Task delete was a **hard, unconfirmed, irreversible** operation: the context-menu
"Delete" called `TaskMutator.delete` → `context.delete` + a CKSyncEngine record
deletion, with no confirmation, no undo, and no trash. A single mis-tap (and
"Cancel Task" sits one divider above "Delete" in the same menu) destroyed a task
and propagated the deletion to every device's CloudKit private DB. At least one
real task ("Signals Clients") was lost this way — gone from the private DB, not
merely mis-filed.

The fix makes deletion **reversible by construction** (Apple Reminders model):
delete moves a task to a hidden "Recently Deleted" state that syncs across
devices and is purged only after 30 days.

## Design

**Marker = the existing `deletedAt` field.** `TaskEntity.deletedAt: String?`
already exists (a dormant FastAPI-era tombstone) and is **already filtered out of
the main read paths** (`LocalCache`, Coach, Virtue, Migration). Repurposing it as
the Recently-Deleted timestamp inherits that hiding for free. The legacy `Syncer`
that once purged `deletedAt` rows is dead (comments only) — nothing auto-purges.

**Sync with no schema deploy.** `deletedAt` was local-only (no CloudKit mapping).
It is now mapped onto the **already-deployed reserved field `Task.reservedString1`**
(same trick as Area emoji / GoalMilestone units), so trashing syncs and the
record **survives** in CloudKit instead of being deleted — with zero prod schema
deploy.

### State transitions (CloudKitTasksBackend)

| Op | Effect | CloudKit |
|----|--------|----------|
| `delete(id:)` | set `deletedAt = now`, keep the row | record **update** (push, not delete) |
| `restore(id:)` | clear `deletedAt` | record update |
| `purge(id:)`  | `context.delete` + engine deletion | record **delete** (the old hard path) |

`delete` no longer hard-deletes. `purge` is the old behavior, now reachable only
from "Delete Permanently" and the 30-day auto-purge.

### Read-path coverage (the correctness-critical part)

Every surface that lists tasks must exclude `deletedAt != nil`. Already covered:
`LocalCache` (Persistence), `CoachContextBuilder`, `VirtueSummarizer`,
`Migration`. Patched in Stage 1: `TaskReads` (count loop), `TaskIntents`,
`SpotlightIndexer`, `QuickFindView`, `RhythmSnapshotBuilder`,
`RhythmHomepageView`, `MCPDispatch` (list paths). A trashed task must never leak
into Today, search, Siri, Spotlight, the Rhythm dial, or MCP listings.

## Stages

1. **Data layer (safety core)** — `deletedAt`↔`reservedString1` CK mapping;
   `delete` → soft; add `restore` / `purge`; read-path coverage. After this,
   deletion is non-destructive and recoverable; nothing can be permanently lost
   by a mis-tap.
2. **Recovery UX** — an Undo snackbar after delete; a "Recently Deleted" list in
   the Tasks sidebar (Restore / Delete Permanently / Delete All); 30-day
   auto-purge on launch.

## MCP

In-app reads exclude trashed automatically (shared backend). A `tasks_restore` /
`tasks_purge` tool pair is a later parity item for both servers — tracked, not in
this change. Hard-delete via MCP is still not implemented (see the MCP delete
backlog), so no gateway change is forced here.
