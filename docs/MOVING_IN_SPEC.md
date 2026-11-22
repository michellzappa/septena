# Moving in: one import engine with source adapters

Status: **building** (I0 landed 2026-11-21)

Rests on [ADR 0021](adr/0021-one-import-engine-with-source-adapters.md).
Issues: #98 (coverage tracker), #99 (engine), #52 (Microsoft To Do), #100
(Todoist, TickTick), #101 (Superlist), #102 (Any.do, OmniFocus). Field
evidence per source: Starlings `/strategy/moving-in-data-access-research`.

## 1. Shape

```
source ──► adapter ──► ImportBundle (JSON, v1) ──► engine ──► mutators ──► store
                                                     │
                                         plan · apply · ledger · undo
```

- **Adapter:** reads one source, emits one bundle. Read-only on the source.
- **Bundle:** the internal API. Plain JSON, versioned, self-describing.
- **Engine:** the only code that looks at the user's existing data or writes.

Code: `SeptenaCore/Import/`.

| File | Job |
|---|---|
| `ImportBundle.swift` | The v1 bundle model (Codable, the wire shape). |
| `ImportSource.swift` | The adapter protocol, coverage declaration, source catalog. |
| `ImportPlanner.swift` | Pure planner: bundle + existing data + options → plan + report. |
| `ImportApplier.swift` | Applies a plan through the mutators; undoes a batch. |
| `ImportLedger.swift` | One JSON file per batch: lineage, originals, outcome. |
| `Adapters/ThingsImportSource.swift` | Things database → bundle. |

## 2. The bundle (v1)

Top level:

| Field | Type | Rule |
|---|---|---|
| `format` | `"septena.import"` | Fixed. |
| `version` | `1` | The engine refuses versions it does not know. |
| `source` | object | `app` (catalog id, e.g. `things`), `adapter` (`name@version`), `account` (optional, a label the user can recognise, never a secret), `exportedAt` (ISO time). |
| `areas`, `projects`, `headings`, `tasks` | arrays | See below. Every item has `sourceId`. |
| `unsupported` | array | Adapter-declared losses: `{ entity, field, count, note }` for data the adapter saw but cannot put into the bundle (for example To Do's My Day, which Graph does not expose). |

Every item carries:

- `sourceId`: the source's own stable id. Unique per entity in the bundle.
- `original`: optional, the source record as JSON, kept in the ledger for
  recovery. Capped at 16 KB per item; larger originals are cut and flagged.

Entities:

| Entity | Fields |
|---|---|
| area | `title`, `notes`, `emoji`, `position` |
| project | `title`, `area` (area `sourceId`), `notes`, `status` (`active`/`done`/`cancelled`), `completedAt`, `position` |
| heading | `title`, `project` (project `sourceId`), `position` |
| task | `title`, `notes`, `area`, `project`, `heading` (source ids), `status` (`open`/`done`/`cancelled`), `trashed`, `today`, `scheduled` and `deadline` (`YYYY-MM-DD`), `completedAt`, `createdAt`, `position`, `reminder` (`fireAt`, `mode`), `recurrence` (`unit`, `interval`, `afterCompletion`, `weekdays`, `monthDay`, `ordinalWeekday`), `checklist` (`[{ title, done }]`), `tags` (`[String]`), `starred`, `sourceURL` |

Dates: `scheduled` is the day the user plans to work on the task. `deadline`
is the day it is owed. `reminder.fireAt` is the alert time. An adapter never
puts one into another.

`position` is the source's own order inside the item's list. Only the order
matters; the engine renumbers.

## 3. Adapters

An adapter conforms to `ImportSource`:

- `descriptor`: catalog id, display name, input kind (`file`, `localLibrary`,
  `account`), and **coverage**: for every bundle field, `mapped`,
  `preserved` (kept in originals only) or `unsupported`.
- `read(...) async throws -> ImportBundle`.

The catalog (`ImportSourceCatalog`) lists every known source with its state
(`available`, `planned`, `assisted`). The moving-in UI and the site's
`/moving-in` table read the same list.

Rules:

- Read-only on the source. An adapter never deletes or marks source data.
- No title matching, no dedup, no knowledge of Septena rows. That is the
  engine's job.
- Cloud sources sign in with the provider's OAuth (PKCE, read-only scope) in
  the app. The token stays on the device and is dropped after the read.

## 4. The engine

### 4.1 Plan (dry run)

`ImportPlanner.plan(bundle:existing:options:)` is pure. It reads a snapshot
of the user's areas, projects and prior import lineage, and returns:

- the creates, in order (areas → projects → headings → tasks), each with the
  Septena id it will get;
- the merges: a source area or project whose title matches a live Septena one
  (case- and space-insensitive) maps onto it *(default: merge on)*;
- the skips: items already imported in an earlier batch (lineage match), and
  trashed, completed or cancelled items the options leave out;
- the **report**: per entity, counts of create / merge / skip; per field, the
  disposition (`mapped`, `transformed`, `preserved`, `unsupported`) with a
  count; dangling references (a task whose project is not in the bundle goes
  to its area or the Inbox, and the report says so).

Options *(defaults)*: include completed `false`, include cancelled `false`,
include trashed `false`, merge matching titles `true`, checklist into notes
`false`, tags into notes `false`, re-import deleted `false`.

### 4.2 Field dispositions

| Field | Today | When the feature ships |
|---|---|---|
| checklist | `preserved`; `transformed` into notes only when the user turns the option on | `mapped` (#76) |
| tags | `preserved`; `transformed` into notes on the option | `mapped` (#96) |
| starred | `preserved` | `mapped` (#127) |
| reminder, recurrence, headings, dates, notes, status, order | `mapped` | |
| sourceURL | `transformed`: appended to notes as a link line | |

A `preserved` field is never lost: the batch ledger keeps the item's original
and the bundle values. When the feature ships, a re-run of the batch fills
the field in (I5).

### 4.3 Apply

`ImportApplier.apply(plan:)` runs on the main actor through `TaskMutator`,
`AreasMutator` and `ProjectsMutator`. Each created row carries
`source = "import:<app>"`. The applier:

1. writes the ledger file first with state `applying`;
2. creates in dependency order and records each created id in the ledger as
   it goes;
3. sets the ledger state to `applied` with the reconciled counts (planned vs
   created vs failed);
4. on a thrown error, stops, marks the ledger `partial`, and reports what was
   created. Running the same bundle again resumes: lineage makes the created
   items skips.

### 4.4 Ledger

One JSON file per batch at `Application Support/Septena/Imports/<batchId>.json`:
batch id, source, options, applied time, state, the report, and one entry per
item: entity, source id, Septena id, `created` or `merged`, and the original.
Lineage for later plans is the union of all ledgers in state `applied` or
`partial`.

### 4.5 Undo a batch

`ImportApplier.undo(batchId:)` deletes (to Recently Deleted, never purge)
every row the batch **created** that the user has not changed since. A row
counts as changed when its `updatedAt` is later than the batch's applied
time. Changed rows stay and the result lists them. Merged areas and projects
are never deleted. An imported project or area stays when it still holds a
task the batch did not create. The ledger state becomes `undone`.

## 5. Sources and phases

| Phase | Work | Issue |
|---|---|---|
| **I0** | Bundle v1, adapter protocol, catalog, planner, applier, ledger, undo. Things adapter produces a bundle. No UI change. | #99 |
| I1 | Moving-in UI on the engine: source picker, preview with dispositions, apply with progress, batch list with undo. The Things screen moves onto it; the old Things mapper, apply loop and `ThingsImportMapping` go (their id table is read once into a ledger so earlier imports keep their lineage). | #99 |
| I2 | Reminders adapter (EventKit): lists, sections, notes, dates, alarms, flags, subtasks, recurrence. Source stays untouched. | #99 |
| I3 | Microsoft To Do adapter (Graph v1.0, `Tasks.Read`, personal accounts): lists, tasks, steps, notes, due and reminder times, importance, recurrence, linked resources, attachments up to 25 MB. My Day, list groups, manual order and collaborators are `unsupported` and declared. Then the step-by-step section on `septena.app/moving-in/microsoft-to-do`. | #52 |
| I4 | Todoist (API v1, `data:read`) and TickTick (Open API v1) adapters. | #100 |
| I5 | Re-run a batch to fill fields that became `mapped` (checklists, tags, star). | #99 |
| I6 | Registry fixtures: bundle JSON Schema and planner golden cases in `registry/conformance/import-*.json`, for the TypeScript port the web client needs. | #99, #21 |
| later | Superlist (CSV), OmniFocus (CSV/TaskPaper), Any.do (assisted paste). | #101, #102 |

## 6. Open questions

| Question | Default |
|---|---|
| Where does the engine run? | In the app (ADR 0021). |
| Do cloud-source tokens touch our server? | No. In-app OAuth, dropped after the read. |
| Merge areas and projects with matching titles? | Yes, shown in the preview, per-item override in I1. |
| Checklists before #76 ships | Preserved, not written into notes, unless the user turns that on. |
| Undo across devices | No. The ledger is per device. |
| Import into a paid-only feature (attachments sync) | Attachments import as local attachments; sync follows the plan rules. |
