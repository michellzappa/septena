# Task row menu

Status: building (#300). Decided with mz on 2026-11-23.

This spec sets which actions the task row context menu shows, in which
order, and where every other task action lives. The registry menu
`task.row` in `registry/actions.json` is the source of truth. Both shells
render it: SwiftUI (`Septena/Shell/Tasks/TaskListContextMenu.swift`) and
AppKit (`Septask/SeptaskKitTaskList.swift`).

## The rule

The row menu holds triage and actions on several tasks. An attribute you
set once per task lives on the task page or inside a picker, not in the
menu.

Corollaries:

1. One flat menu on every platform. Move is the only submenu, because it
   lists destinations.
2. A single task completes from its checkbox. Complete shows in the menu
   only when two or more tasks are selected.
3. Destructive actions sit last, alone, below a divider.
4. An action that leaves the menu keeps its keyboard shortcut and its menu
   bar item.

## The menu

Conditional top group. Each row shows only where it applies:

| Row | Shows when |
|---|---|
| Accept | one task, and it waits for review (`needs_verify`) |
| Send Back… | same as Accept |
| File in &lt;list&gt; | one Inbox task that carries a filing suggestion (the row chip's pick) |

Then, for every open task:

| Group | Rows |
|---|---|
| Triage | When…, Move ▸, Tags…, Deadline…, Star / Remove Star |
| Edit | Open, Duplicate, Share…, Select (iPhone and iPad only) |
| Close | Complete (two or more tasks only) |
| Destructive | Delete |

Move ▸ lists, in order: the sections of the current project (project pages
only), the filing suggestion (only when the top group does not already show
it), Inbox, areas and top-level projects, then Move… for the full picker.
It replaces the two old submenus, Move and Move to Section.

Open opens the task page (ADR 0029, `docs/TASK_PAGE_SPEC.md`), never the
inline editor: a row tap is inline, Open is the page. On the Mac it shows
the inspector pane. On iPhone it pushes the page; on iPad it shows the
docked inspector.

Share… sends the task title, then its notes after a blank line, through the
system share sheet. Several tasks share one title per line, the shape ⌘C
copies. The text comes from `TaskShareText` in `SeptenaCore/Models.swift`.

## Where the removed rows went

| Removed row | Now |
|---|---|
| Edit Details / Rename | Open (the task page). ⌘R still renames the title inline. |
| Show Info (Mac) | View menu and ⌥⌘I. It toggles a pane; it is not a task action. |
| Move to Today / Remove from Today | When picker (Today is its first cell) and ⌘T |
| Clear When | When picker (Clear row) and ⌘⇧. |
| Reminder… | Task page and ⌥⌘R |
| Repeat…, Pause Repeat, Create Next Copy | When picker → Repeat row; menu bar |
| Copy | ⌘C |
| Cancel | Menu bar and ⌥⌘K. On iPhone: Select, then the selection bar's More menu. The task page has no Cancel. |
| Complete (one task) | Checkbox, ⌘K, menu bar |
| Move to Section ▸ | Move ▸, first group |

## The When picker

The When picker answers "when, and how often". It shows the seven-day
strip with Today first, then one list of rows: Tomorrow, Pick another date,
Clear, Repeat and Add time. Every row has the same shape on a platform.
The rows, their order and their words are in `registry/surfaces.json`
`taskDateBoard`. Tomorrow has a strip cell and a row (decided 2026-11-24).
Android has no Repeat row (Repeat is the next row of its task page) and no
time editor yet.

The Repeat row reads "Repeat…", or "Repeat: &lt;rule&gt;" when the task
already repeats. It closes the When picker and opens the Repeat editor,
which also holds Pause.

On iPhone and iPad the Repeat row shows for one task only, because the
Repeat sheet edits one task. The Mac Repeat editor edits a selection, so
the Mac shows the row for several tasks too. The Deadline picker has no
Repeat row.

## The menu bar Task menu

The menu bar Task menu uses the same groups in the same order. It also
keeps every action that has a keyboard shortcut (Today, Clear, Repeat,
Reminder, Rename, Add Checklist Item, Complete, Cancel), because a menu
bar item is how a Mac user finds a shortcut.

## Not in scope

- Android has no row context menu. It gets one when Android task lists
  reach parity; it renders the same registry menu.
- Swipe actions: dropped on 2026-11-23 (`IOS_SWIPE_ACTIONS_SPEC.md`).

## Open questions

| Question | Default |
|---|---|
| Typed repeat ("walk the dog every friday") in quick add and the When field. `SeptenaDateParser.parseRepeatRule` exists with tests, but no screen calls it. | *(default)* Not built. mz chose the When picker only. |
| Create Next Copy has no place on iPhone and iPad after it left the row menu. | *(default)* Menu bar only (iPad keyboard, Mac). Add it to the Repeat sheet if it is missed. |
| Cancel has no place on the task page, and on iPhone it is two steps away (Select → More). | *(default)* Leave it there. Add Cancel to the task page if it is missed. |
