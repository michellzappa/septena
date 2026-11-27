# Checklist projects

**Status** · Product proposal

A Checklist is a project you can use repeatedly. Checking an item removes it from the active list and keeps it available for next time. The project keeps its place in the sidebar when everything is checked. Groceries, packing, and restocking are the first use cases.

A project Checklist uses project rows. [Task checklist steps](CHECKLISTS_SPEC.md) are the smaller steps inside one task. [Recurrence behavior](RECURRENCE_BEHAVIOR_SPEC.md) covers items that come back on a schedule.

## Project and item behavior

- Offer **Checklist** when creating a project and **Use as Checklist** in an existing project’s menu. Conversion keeps the project’s name, area, position, and open tasks. Historical completions remain in the Logbook.
- Show active items first, with **Add item** close at hand. Show one **Checked** group below, expanded by default. A fully checked project opens directly to a list of items the user can bring back.
- Check to move a row to **Checked**. Uncheck to bring the same row back to its saved group and position. Checking does not generate a Logbook completion or advance project progress. Toggle, move, and delete are distinct actions.
- A checklist item appears in Today when the user schedules it there. Checking clears that occurrence’s schedule. When the user brings the row back, it starts undated. Undo restores the preceding state, including the date if checking cleared it.
- Checking and reopening work offline, sync across devices, and use the shared Undo stack for local gestures. Retain the row’s identity through both actions.

## Add and prefill

Search the current project as the user types in **Add item**. A matching checked row shows its full name and group, such as **Greek yogurt · Dairy** for `yo`. Choosing it reopens that row. An active match shows **On list**. Keep an explicit **Add “…”** choice for a genuinely new item, with the typed text intact.

Reuse the name, group, and position. Scheduling and quantity entered for a particular trip should not prefill the next one. Typing alone leaves the list unchanged. Match case-insensitively and rank exact matches ahead of prefixes.

## Groups and Groceries

- **Checklist groups are optional and local to one project.** Packing can have Clothes, Toiletries, and Electronics. A short list can stay flat. Adding within a group assigns it directly. Moving an item changes its saved group. Keep group order stable and show headings in the active list only when they have active items.
- **Groceries is a Checklist preset.** It seeds category headings such as Produce, Dairy, Pantry, and Frozen. For a new item entered from the main Add item field, use a small offline vocabulary to assign a clear match. Leave unknown or ambiguous items ungrouped. Use the same categorization data across clients and sync the assigned group.
- **Explicit placement wins.** The group the user adds into, or moves an item to, takes priority over a grocery suggestion. If they move oat milk to Pantry, it returns to Pantry on every re-add. Show the saved group in autocomplete and provide a **Move to group** action on the row.
- Keep checked items together under **Checked**, with their saved group available when useful. Checking the last item in an aisle collapses that aisle out of the active list without discarding its group.

## First release

The first release includes reusable rows, autocomplete, optional project groups, and the Groceries preset. Bulk reset and automatic categorization for other kinds of checklists can follow when repeated use warrants them.

Use the same row and undo behavior across Apple, Android, and Web. Preserve the project mode, row state, and group assignments through sync and export.

## Acceptance checks

- Finish the first shop. The project stays in the sidebar and all bought items are visible under **Checked**. A week later, type `yo`, reopen the same Greek yogurt row in Dairy, and shop from a list containing only the rows you selected or added.
- An active match is marked **On list**. A truly new item can still be added from the same input.
- A first-time grocery such as bananas lands in Produce. An unknown item stays ungrouped. Move oat milk to Pantry, check it, and reopen it from another device. It returns to Pantry.
- A scheduled item checked from Today disappears from Today. Reopening it from the project leaves it undated. Undoing the original check restores the original date.
- Convert a normal project with open items and historical completions. Its open items become unchecked, and the historical completions stay in the Logbook.
