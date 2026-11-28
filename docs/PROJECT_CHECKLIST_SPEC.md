# Checklist projects

**Status** · Accepted (#860, 2026-11-28)

A Checklist is a project you can use repeatedly. Checking an item removes it from the active list and keeps it available for next time. The project keeps its place in the sidebar when everything is checked. Groceries, packing, and restocking are the first use cases.

A project Checklist uses project rows. [Task checklist steps](CHECKLISTS_SPEC.md) are the smaller steps inside one task. [Recurrence behavior](RECURRENCE_BEHAVIOR_SPEC.md) covers items that come back on a schedule.

## The rule

**A Checklist is a regular project with three differences:** the check action, the **Checked** group, and add-field suggestions. Everything else (rows, editing, selection, keyboard, context menus, drag, Undo, headings, Delete) is the standard project path, unchanged. No platform has a Checklist-specific list screen, row component, add field, group picker or Delete button.

## Decisions

1. **One Checklist type.** New Checklists write `checklistMode: "plain"`. A client reads `groceries` as a Checklist too. Stored values are never rewritten, and the `groceries` enum value stays: older clients still send it.
2. **Grocery grouping applies to every Checklist.** Hosts always pass `groceries: true` to `projectChecklist` for a Checklist project. Unknown items stay ungrouped, so a packing list is not affected.
3. **Checked is a view, not a heading.** The host builds the **Checked** group from `status == checklistChecked`. No client creates a heading row named Checked, and checking never changes a row's `heading`.
4. **No project subtype, no second renderer, no calendar-repeat changes.**

## Data

- Project field `checklistMode` (`registry/entities.json`): `plain | groceries`, nullable. Null means a regular project.
- Task status `checklistChecked`. A checked row keeps its `id`, `heading` and `position`. Only `status` and the date fields change.
- Sync, export and backup carry both. The sync shape and enum values do not change for this feature.

## Shared core (`core/crates/septena-core/src/project_checklist.rs`)

Clients call these functions through the core. They never re-implement them. Vectors: `registry/conformance/project-checklist.json`.

- **`projectChecklist({ rows, query, groceries })`** returns `ungrouped`, `groups` (active rows per heading; a heading whose rows are all checked is left out, and a heading with no rows at all stays so a new section shows at once), `checked`, `matches` (exact title first, then title prefix or word prefix, case- and accent-insensitive, deleted rows left out) and `suggestedGroup` (a group key such as `dairy`, or null).
- **`checklistCheckPatch({ checked })`.** Checking sets `checklistChecked` and clears every date, Today and reminder field. Reopening sets `open` only, so the row stays undated. There is no completion stamp: no Logbook entry, no project progress, no repeat.
- **`checklistHeading({ projectId, group, title, rows })`** returns `{ heading, create }` for a suggested group. The host passes the project's rows with deleted rows included, and the group's localized title from the registry. The stable heading id is `occurrenceId("checklist:<projectId>", <group>)`, so two offline devices that add bananas create one Produce heading.
  1. A live heading with the stable id, else a live heading with the same title (case- and accent-insensitive): `create: false`, reuse it.
  2. A deleted heading with the stable id or the same title: `heading: null`. The user removed that group, so the row stays ungrouped.
  3. Otherwise `create: true`: create a heading row with the returned id and the title.
- The grocery vocabulary lives in the core. Its group keys equal the registry's `checklistProjects.groups` keys (a core test checks this through `registry::checklist_groups::KEYS`).

## Registry copy

`registry/surfaces.json` `checklistProjects` holds the copy, with keys in `registry/l10n`: **Checklist** (`checklist`), **Project** (`project`), **Project type** (`projectType`), **Checked**, **On list**, **Add item**, **Add "…"** (`addTyped`, placeholder `title`), and the group titles per key (`groups`: Produce, Dairy, Bakery, Meat & Seafood, Pantry, Frozen). **Use as Checklist** is the `project.useAsChecklist` action in `registry/actions.json`, in the `sidebar.project` menu. Clients never hard-code these words.

## Host contract

- **Check action.** On every surface where a project row can be checked (project list, Today, search, quick views), the check control on a row whose project has a non-null `checklistMode` applies `checklistCheckPatch`, not task completion.
- **Undo of a check.** Before the client applies the check patch, it snapshots the row's values for every key in the patch. Undo writes the snapshot back, so the date returns. Record the entry on the platform's shared Undo stack at the user gesture, never a custom toast or a mutator-level record.
- **Checked group.** After the active rows, the client shows one **Checked** group built from `checked`, expanded by default, with the platform's existing collapsible group. A fully checked project stays in the sidebar and opens to the Checked group.
- **Add field.** The standard add field at the bottom of the project. While the user types, show suggestions from `matches`:
  - A checked match shows its title and saved group, for example **Greek yogurt · Dairy**. Choosing it reopens that row.
  - An active match shows **On list** and does nothing.
  - The last choice is always **Add "…"** with the exact typed text.
  - Typing alone never changes the list.
- **Placement of a new item.** The heading the user adds from wins. With none, the client takes `suggestedGroup`, looks up its title in the registry, and calls `checklistHeading`. Otherwise the item stays ungrouped.

## Platforms

- **Web, iOS, iPadOS, macOS, Android:** the full host contract above.
- **watchOS:** the watch reads its lists from the backend REST API, which returns open rows only. It checks through `POST /v1/tasks/:id/complete`, where the backend applies `checklistCheckPatch` to a Checklist row. A checked row never shows as open, and checking uses the checklist check. The watch has no project add field.
- **Windows:** check, reopen, the Checked group and suggested-group placement. The Windows list draws no header for any section without open rows, so a new empty section does not show there yet (#896). Add-field suggestions, New Project → Checklist and Use as Checklist wait for the Windows places UI (#896).

## Create and convert

Offer **Checklist** in the new-project flow. Show **Use as Checklist** in the existing project menu. Conversion sets `checklistMode` only. It keeps the project id, name, area, sidebar position, headings and open rows. Done tasks stay done and stay in the Logbook. There is no "convert back" yet.

## Acceptance checks (per platform)

- Convert a populated project. Compare it with a regular project: the add field, row layout, menus, editing, keyboard and drag are the same. Delete is in the normal row menu for active and checked rows.
- Add Greek yogurt to Dairy and check it. Check every other item. The project stays in the sidebar and opens to Checked. Type `yo`: the suggestion reads **Greek yogurt · Dairy**, and choosing it puts the same row back in Dairy. Type the name of an active item: it shows **On list**, and **Add "…"** still adds a new row.
- Add bananas with no heading open: the row lands in Produce, and the client creates Produce once. Add the same item on a second offline device and sync: there is one Produce heading. Add `zorbo`: it stays ungrouped. Move oat milk to Pantry, check it, and reopen it on another device: it is in Pantry.
- Check a scheduled row from Today: it leaves Today. Undo it: the date returns. Check it again, then reopen it from the project: it is undated and has no Logbook entry.
- Open a legacy `groceries` project: it behaves as a Checklist and its data is unchanged.
