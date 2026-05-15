# Septena Backlog

Tracked work, not urgent. Ordered loosely by appeal, not priority.

## Interactions

- **Swipe gestures on task rows** — left-to-complete, right-to-schedule (spec in [interactions.md](things-reference/interactions.md)). Blocked: the custom `TaskRow` component currently fights with `DragGesture`; needs investigation into whether to drop down to a `UIViewRepresentable` wrapper or restructure the row's gesture stack.
- **Magic Plus drag-to-file** — drag the floating button onto Today / Upcoming targets to schedule on creation. Tap-to-create is enough for now.
- **Multi-select mode** — long-press a row → enter selection state, radio circles replace checkboxes, bottom action bar for batch move/schedule/delete/complete.

## Search & Navigation

- **Quick Find wiring** — the search bar UI in [SidebarView.swift](../Septena/Views/SidebarView.swift) is not connected. Wire it to filter tasks across all lists by title/notes.

## Lists

- **Logbook grouped by completion date** — Today / Yesterday / This Week / Earlier headers in the Logbook view.
- **Project headings** — manual section dividers inside a project (not a sort; preserves manual order). Requires a `Heading` model alongside tasks in the project's ordered children. Defer until a real project asks for it.

## Data model (deferred)

- **Checklists / subtasks** — nested checkable items on a task. Not yet, but likely needed.

## Multi-platform (separate epic)

- **iPad** — `NavigationSplitView` 3-column when `horizontalSizeClass == .regular`, pointer hover, cross-list drag-and-drop, keyboard shortcuts.
- **macOS** — `.commands` menu, native toolbar, context menus replacing swipes, multiple windows, Settings scene, ⌘ shortcuts.

## Explicitly out of scope

- Tags
- "This Evening" bucket
- Calendar / EventKit integration
- Manual sort controls (rely on opinionated defaults + manual drag-reorder)
