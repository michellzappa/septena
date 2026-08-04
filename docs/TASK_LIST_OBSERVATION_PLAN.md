# Task list: from snapshot arrays to store observation

Status: proposed, not started. Written after the August 2026 task-surface audit.

## The problem

`TaskListView` renders from `@State` arrays of `SeptenaTask` **value structs**,
projected out of `TaskEntity` by `LocalCache`. Nothing in the view observes
SwiftData, so "the row on screen matches the store" is maintained entirely by
hand. The machinery that exists only to paper over that:

- `.septenaTasksChanged` → relevance filter (`taskChangeMayAffectCurrentList`)
  → 0.3 s debounce → defer-while-editing (`reloadOrDeferWhileEditing`) →
  generation counter + 75 ms sleep (`load()`) → `performLoad()`.
- Optimistic hand-patchers that must be kept in step with every mutation:
  `patchLocally`, `flipStatus`, `removeLocally`, plus an inline copy in
  `applyRemoveFromToday`.
- Merge passes that reconcile the snapshot against a fresh read:
  `preservingSettling`, `ghostCheckRemoteCompletions`, `remoteArrivingIDs`,
  `assignMerged`.
- 32 call sites of `Task { await load() }` — nearly every mutation manually
  re-drives the whole list.

The cost is not just size. Every one of those is a place a row can go stale,
and they interact: a deferred reload can be swallowed while a second editor is
open, and a patcher that covers only some fields leaves the rest stale until the
next reload lands.

## Why not just `@Query`

`@Query` would give observation for free, but the list can't adopt it as-is:

1. **Ordering is computed, not stored.** Render order comes from
   `TaskOrder.key(position:createdAt:)` — an explicit position when dragged,
   otherwise the creation instant. Not expressible as a `SortDescriptor`.
2. **Grouping is view logic.** `groupedOpenItems` partitions by area/project and
   `projectGroupedRows` by heading, both against `StructureCache` order.
3. **Membership is not a simple predicate.** Today folds in the triage band,
   settling rows, and session-visible completions.
4. **The animation beats are stateful.** Settle (linger-then-fade),
   remote-arrival expand, and promote-flash all need the *previous* rendering to
   diff against — that's what `preservingSettling` and
   `ghostCheckRemoteCompletions` do.

So the target is not "drop `@Query` in the view". It is: **one observable object
owns the rows, and it is the only thing that rebuilds them.**

## Proposed shape

Introduce `TaskListModel` — `@Observable`, `@MainActor`, one per mounted list,
keyed by `TaskFilter`:

```
@Observable @MainActor
final class TaskListModel {
  private(set) var rows: [SeptenaTask]
  private(set) var triage: [SeptenaTask]
  // …the derived snapshots the view reads today
}
```

It owns, in one place:

- the `LocalCache` reads (`localTasks`, structure, progress, suggestions);
- the notification subscription and its debounce;
- the merge passes (settle preservation, ghost completions, arrivals);
- the optimistic patch API, replacing the four hand-patchers with a single
  `apply(_ change:)` that both mutates the visible rows and records what the
  next rebuild must preserve.

The view then holds `@State private var model: TaskListModel` and reads
`model.rows`. Observation propagates changes; the view keeps only genuinely
view-local state (selection, `expandedEditId`, sheet routing).

`NextView` already has this shape (`tasksModel.load(...)`), so this is
convergence on an existing in-repo pattern rather than a new invention.

## Sequencing

Each step compiles and ships on its own; none requires the next.

1. **Extract reads.** Move `localTasks` / structure / progress / suggestions
   into the model. The view still calls `load()`; behavior unchanged.
2. **Move the merge passes.** `preservingSettling`,
   `ghostCheckRemoteCompletions`, `remoteArrivingIDs`, `assignMerged` become
   model internals. `SettleStore` moves with them.
3. **Collapse the patchers** into one `apply(_:)`. This is where the
   stale-field class of bug dies: a single patch path can't cover title but
   miss deadline.
4. **Move the subscription.** The model subscribes to `.septenaTasksChanged`
   itself and owns the debounce. `reloadOrDeferWhileEditing` becomes a
   `model.holdRefresh(while:)` the view sets from `listInputActive`.
5. **Delete `load()` call sites.** Once mutations go through the mutator and the
   model observes the notification, most of the 32 `Task { await load() }` calls
   are redundant. Remove them in batches, watching for the ones that were
   secretly load-bearing for focus sequencing (`startCreateUnderHeading`
   sequences focus *after* the 75 ms sleep — that coupling has to be broken
   explicitly, not inherited).

## Known traps to carry across

- **Never reassign rows while a field is focused.** The array swap re-diffs the
  `LazyVStack` and drops first responder mid-keystroke. Whatever replaces
  `pendingReloadWhileEditing` must preserve this hold.
- **Do not call `ckEngine.fetchChanges()` from a refresh.** It re-enters the
  CKSyncEngine delegate inside `applyDidFinishBatch` and asserts. Fetches stay
  owned by launch / foreground / push / manual re-sync.
- **`items` currently has a synchronous-fallback getter** (it reads
  `LocalCache` when `storageFilter != filter`) so a filter swap renders correct
  data on the first frame. The model must keep that first-frame guarantee —
  `paintFromCache()`-style seeding, as `NextView` does.
- **Keyboard order must equal render order.** `keyboardOrderedTaskIds` and
  `groupedOpenItems` are two hand-synchronized computations today; the model
  should expose ONE ordered id list that both the renderer and arrow-nav read,
  which retires the drift risk.

## What this does not change

The write boundary stays exactly as it is: `TaskMutator` →
`CloudKitTasksBackend` → SwiftData + `CKSyncEngine`, posting
`.septenaTasksChanged`. This plan is only about how the read side learns.
