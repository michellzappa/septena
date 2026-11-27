# List Sort — Spec

> **Status:** building (#779). Decided by mz on 2026-11-27: sort is a view
> setting per list, not a one-time rewrite of the manual order.

A list with a manual order gets a **Sort By** choice. Sorting changes only
how the list shows its tasks. It never writes a task position, so Manual
shows the user's own order again.

## 1. Where it applies

| List | Sort By |
|---|---|
| Today (`today`) | yes |
| Anytime (`anytime`) | yes |
| Every project page | yes |
| Every area page | yes |
| Upcoming, Repeating, Logbook, Review, Starred, Faded, Recently Deleted | no: they have a fixed order |
| The Inbox band on Today | no: it keeps its own order |

The smart lists that take a sort are the destinations with
`supportsManualOrder: true` in `registry/destinations.json`. Read that flag;
never list them by hand.

## 2. Choices

The `listSort` enum in `registry/entities.json`:

| Value | Label | Order | Tasks without the field |
|---|---|---|---|
| `manual` | Manual | the stored manual order (default) | — |
| `when` | When | earliest When date first | at the bottom |
| `deadline` | Deadline | earliest deadline first | at the bottom |
| `title` | Title | A to Z, ignoring case and accents (case folding covers Latin letters) | an empty title at the bottom |
| `created` | Created | newest first (`createdAt`, else the `created` day) | at the bottom |

## 3. The rule (shared core)

`sort_tasks(tasks, sort) -> [id]` in `core/crates/septena-core/src/sort.rs`.
Hosts call it through the JSON entry point:
`invoke_json("sortTasks", {"tasks": [TaskSnapshot…], "sort": "<value>"})`
returns a JSON array of task ids. It has no typed FFI export: that would put
the native slices over their size budget. Vectors:
`registry/conformance/list-sort.json`.

- The host passes the tasks of **one group**, already in manual order.
- The sort is stable: manual order breaks every tie.
- An invalid stored day reads as no date.
- Never re-implement the comparison in Swift, Kotlin or TypeScript.
  `manual` returns the input, so a host can call the core for every sort.

## 4. Groups

A list that shows groups sorts inside each group. Groups keep their order.

- Today with "Group Today by list" on: inside each area or project group.
  Off: the one list.
- A project page: inside each heading, and inside the tasks above the first
  heading. Headings keep their manual order.
- An area page: inside each group the page shows.
- Completed tasks shown at the end of a list keep their place.

## 5. Storage

One synced record setting, `listSort` in `registry/settings.json`:

- Key: the list key. A smart list uses its destination id (`today`,
  `anytime`). A project uses `project:<id>`, an area `area:<id>`.
- Value: a `listSort` value other than `manual`. Manual is the absence of a
  key: picking Manual removes it.
- At most 256 entries. On write, a client drops keys for projects and areas
  that no longer exist.
- Synced, like the sidebar order: every device shows the same sort.
- `ui: false`: the choice lives in the list's own menu, not in Settings.

## 6. Interaction

- **Menu.** Each list that takes a sort has a Sort By menu with the five
  choices and a check on the current one. It sits where the list keeps its
  other list-level commands: the list's toolbar or header menu on iPhone,
  iPad, Android and web, and a Sort By submenu in the Mac View menu for the
  list in focus.
- **Indicator.** When the sort is not Manual, the list header shows one line,
  "Sorted by <label>", so the user knows why the list does not follow their
  drag order.
- **Drag.** In a sorted list, drag-to-reorder between rows is off. Dragging a
  task to the sidebar, to Today or to another project still works. Headings
  still reorder in a sorted project.
- **New and edited tasks.** A task lands in its sorted place. A row in inline
  edit (a new draft or a rename) keeps the place where it appeared until the
  edit ends, then moves. A row never jumps away under the user's cursor.
- **Undo.** Changing the sort is a view change and is not on the undo stack.

## 7. Not in scope

- A sort for Upcoming, Logbook or Review.
- Sort direction (ascending or descending): each choice has one direction.
- A priority sort: Septena has no priority field.
- An MCP or REST parameter. Agents read the manual order.
