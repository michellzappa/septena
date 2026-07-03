# Ordering, Drag & Drop, and Headings — Plan

Scope: Tasks/Septask (shared `Shell/Tasks` + `Shell/Sidebar`, both apps, all four
schemes). Goal: proper manual ordering, full drag & drop (reorder in-list +
drop into sidebar), and Things-style headings inside projects — using only
standard SwiftUI APIs and the smallest possible delta over what already exists.

## What already exists (verified 2026-07)

Most of the foundation is already built and synced; the UI just stopped using it.

| Piece | Status | Where |
|---|---|---|
| Manual order field | ✅ `TaskEntity.position: Double`, synced, conditional-write (0 = never dragged → falls back to `createdAt`) | `SeptenaCore/Persistence.swift:19` + `docs/CloudKitSchema.md` |
| Order math | ✅ `TaskOrder` (`gap = 1024`, `key()`, `topPosition()`, `bottomPosition()`) | `SeptenaCore/Persistence.swift:~1330` |
| Reorder mutation | ✅ `TaskMutator.reorder(id:toPosition:)` → CK sync (only caller today: Things import) | `SeptenaCore/Outbox.swift:230` |
| Drag payload | ✅ `TaskDragIDs` (`Transferable`, UTType `com.septena.task-drag-ids`, multi-id) | `TaskComponents.swift:7` |
| Drag source | ⚠️ macOS-only `.draggable` on rows | `TaskListView.swift:1768` |
| Sidebar drop | ✅ `.dropDestination(for: TaskDragIDs.self)` on area/project/Today rows → `moveToArea/Project/Today` (not platform-gated) | `SidebarView.swift:1593` |
| In-list reorder | ❌ removed — no drop targets between rows | — |
| Headings | ❌ no concept anywhere in model or schema | — |
| Sidebar area/project order | ⚠️ device-local `@AppStorage` JSON + context-menu move up/down; no drag, not synced | `SidebarView.swift:37` |

Container constraint: task lists render in `SelectableScrollList`
(`ScrollView` + `LazyVStack`, `Shell/UI/SelectableScrollList.swift`), built
deliberately to escape the macOS `List` focus traps. So `.onMove` is not
available; reorder must use the same standard `.draggable`/`.dropDestination`
pair the sidebar already uses. That is the idiomatic API here — no `NSEvent`,
no custom gesture engine.

## Design decisions

### D1 — One canonical manual order per task (reuse `position`)

Keep the existing model: a single `position` Double is the task's manual order
everywhere it appears, `createdAt` is the fallback for never-dragged tasks.
No schema change, no migration, cross-device sync already works.

- Reordering is enabled only where the render order *is* the `TaskOrder.key`
  order (project/area detail lists, heading groups). In tier/date-sorted
  surfaces (Today buckets, Upcoming) rows are not reorder targets — dropping
  there keeps today's filing semantics.
- Things-style *independent* Today ordering is explicitly deferred; if ever
  wanted it's one additive field (`todayPosition`) later, not a redesign now.

### D2 — Reorder = drop between rows, standard transferable API

One new `ViewModifier` (`TaskReorderDrop`) applied to rows in reorderable
lists, symmetric to the existing `SidebarTaskDrop`:

- `.dropDestination(for: TaskDragIDs.self)` on the row; the drop `location.y`
  vs. row-midline decides insert-above vs. insert-below (the row already knows
  its frame — `SelectableScrollList` publishes `rowFrames`).
- `isTargeted` renders a 2pt accent insertion line at the row's top/bottom
  edge (overlay) — the native-feeling cue, ~10 lines.
- On drop: find neighbors in that list's rendered id order, compute the new
  key with a new pure helper `TaskOrder.between(above:below:)` (midpoint;
  `nil` sides use ±`gap`), call `mutator.reorder` per dragged id (sequential
  midpoints for multi-drag, in payload order).
- A trailing "drop at end" zone after the last row (LazyVStack rows off-screen
  don't exist yet, so the end of a long list needs an explicit target).

Degenerate-midpoint guard: when `below − above` is below epsilon, renumber the
visible group at `gap` spacing (one loop over ids → `reorder` calls). Also:
never emit exactly `0` (it's the "never dragged" sentinel) — nudge by epsilon.

### D3 — iOS drag: remove the platform gate

`.draggable` works on iOS (long-press lift). Drop the `#if os(macOS)` around
the row drag source; the sidebar drop modifier is already cross-platform, so
iPad split-view drag-to-sidebar starts working with no new code. iPhone keeps
in-list reorder only (no sidebar visible on the same screen; Move menu already
covers filing there).

### D4 — Headings are tasks (`kind == "heading"`), membership by FK

Model a heading as a `TaskEntity` row, exactly like Things does internally:

- Two new additive Task fields (dev schema auto-registers; prod deploy is
  additive-only compliant; conditional writes so untouched records never sync):
  - `kind: String` — `""`/absent = task, `"heading"` = heading row
  - `heading: String?` — FK to the heading task's id, on member tasks
- Why tasks and not a new record type: the whole pipeline — CKSyncEngine
  wiring, soft delete, `position`/`TaskOrder`, `TaskMutator.reorder`,
  `TaskDragIDs` drag — is inherited for free. A new record type would mean a
  new entity, backend, engine registration, schema table section, and its own
  ordering code: 10× the delta for the same behavior.
- Why FK membership and not "the tasks positionally below me": with an FK,
  **dragging a heading moves only the heading row** — its tasks render under
  it wherever it lands, by construction. No bulk position rewrite, no partial
  failure mid-group. This is the requirement "dragging a heading moves all
  tasks underneath" falling out of the data model instead of being implemented.

Rendering (project detail only): partition open tasks into the un-headed block
(first) then one group per heading, headings ordered by `TaskOrder.key`, tasks
within each group by `TaskOrder.key`. Heading row = title row, no checkbox,
context menu (Rename / Delete / New Task Below). Headings never appear in
Today/Upcoming/Inbox/watch/widgets/counts (see the risk section).

Mutations (thin `TaskMutator` additions, same write-boundary pattern):
- `createHeading(title:project:)` — a create with `kind = "heading"`
- `setHeading(id:heading:)` — file a task under / out of a heading
- delete heading → dissolve: members get `heading = nil`, heading soft-deletes
  (confirmation dialog; tasks are never deleted — section-invariant spirit)
- moving a heading to another project re-homes its members' `project` too
  (one loop in the mutator, single commit path)

Drag semantics reuse D2 unchanged: a heading drags as `TaskDragIDs([id])`;
dropping between rows in the heading band reorders headings; dropping a task
inside a heading group sets `heading` + position; dropping a task above the
first heading clears `heading`.

## Phases (each lands green on `main`, build all four schemes)

**P1 — Order math (pure, tiny). ✅ SHIPPED.** `TaskOrder.positions(count:above:below:)`
+ `between(above:below:)` with zero-sentinel guard (`Persistence.swift`);
renumber-on-collision lives in the drop handler.

**P2 — Drag & drop. ✅ SHIPPED (needs hands-on verification).** `.draggable`
un-gated for iOS; `TaskReorderDrop` modifier (`TaskComponents.swift`) — single
per-row `.dropDestination`, sidebar-style accent wash while targeted,
above/below by drop point vs. row midline (a live insertion line needs
`DropDelegate`; deferred to P4 polish if the midline feel isn't enough).
Enabled on project / area / Inbox lists via `cardedRows(reorderable:)` +
`handleReorderDrop` in `TaskListView.swift`; multi-select drops keep render
order; degenerate midpoints re-space the visible list at `gap` steps. No
end-of-list zone yet — the last row's bottom half covers drop-at-end.

**P3 — Headings.** Model fields + conditional CK writes + `CloudKitSchema.md`
rows; mutator methods; project-view grouped rendering + heading row UI;
heading drag; **exclusion filter everywhere tasks are counted or fed** (Today,
Upcoming, Inbox, badges, Next feed, watch, widgets, Quick Find) via one shared
predicate (e.g. `SeptenaTask.isHeading` used by the existing "live/open"
filters); MCP update **in both servers** (in-app `MCPToolCatalog` + gateway
repo: filter headings out of `tasks_list` or expose them deliberately) + skill
briefs in the same change; Things import maps its native headings (importer
already writes `position`). ~300–400 lines.

**P4 — Optional, later.** Sidebar drag-reorder of areas/projects (replace the
context-menu up/down; needs its own small `Transferable` id type; order could
stay AppStorage-local or be promoted to synced additive fields on
Area/Project); Today "Project — Heading" breadcrumbs; independent Today order.

## Risks & traps

- **Headings leaking into feeds/counts is the P3 failure mode.** Every fetch
  that counts or lists tasks must exclude `kind == "heading"` — do it in one
  shared predicate, not per call site, and grep every `FetchDescriptor<TaskEntity>`.
- **LazyVStack drops**: rows not yet realized can't be targets; the explicit
  end-zone covers the common case (drop at bottom of long list).
- **`position == 0` sentinel** — a computed midpoint must never be exactly 0.
- **Gesture arbitration on macOS rows** is already tuned for `.draggable`
  (see the count-2 tap comment in `SelectableScrollList.swift:146`) — don't
  reorder those modifiers.
- **CloudKit is additive-only in prod**; new fields only, conditional writes,
  document in `docs/CloudKitSchema.md` in the same change.
- **After shared-code changes build all four schemes** (`Septena`,
  `SeptenaMac`, `Septask`, `SeptaskMac`) via `scripts/build.sh`.
- `sortIndex` stays untouched (legacy, slated for separate cleanup).
