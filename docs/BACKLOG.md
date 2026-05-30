# Septena Backlog

Tracked work, not urgent. Ordered loosely by appeal, not priority.

## Interactions

- **Magic Plus drag-to-file** — drag the floating button onto Today / Upcoming targets to schedule on creation. Tap-to-create is enough for now.

## Lists

- **Logbook grouped by completion date** — Today / Yesterday / This Week / Earlier headers in the Logbook view.
- **Project headings** — manual section dividers inside a project (not a sort; preserves manual order). Requires a `Heading` model alongside tasks in the project's ordered children. Defer until a real project asks for it.

## Data model (deferred)

- **Checklists / subtasks** — nested checkable items on a task. Not yet, but likely needed.

## Multi-platform

- **iPad** — the open platform gap. `NavigationSplitView` 3-column when `horizontalSizeClass == .regular`, pointer hover, cross-list drag-and-drop, iPad keyboard shortcuts. Today iPad rides incidental size-class branches only — no top-level split view. macOS is already native (`.commands`, menu-bar extra, ⌘ shortcuts, context menus — shipped).

## Explicitly out of scope

- Tags
- "This Evening" bucket
- Manual sort controls (rely on opinionated defaults + manual drag-reorder)
