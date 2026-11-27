# Star / Important marker — spec

**Status:** proposal (2026-11-21). Defaults in §7 stand unless mz overrules.
**Decisions:** [ADR 0002](adr/0002-own-backend-replaces-icloud.md), [ADR 0007](adr/0007-septena-is-the-task-app.md), [ADR 0015](adr/0015-shared-registries-for-cross-platform-clients.md).
**Builds on:** `registry/entities.json`, `backend/src/store/columns.ts`, `SeptenaCore/Models.swift`, `SeptenaCore/Persistence.swift`, `SeptenaCore/Outbox.swift`, `Septask/SeptaskKitRowViews.swift`, `Septena/Shell/Tasks/TaskComponents.swift`.
**Tracking issue:** [#127](https://github.com/michellzappa/septena/issues/127).
**Owner of decisions:** mz. Defaults chosen by the author are marked *(default)*.

## 1. Goal

Provide **one simple boolean Star / Important marker** on tasks — enough to mark high-leverage work and preserve importance when moving in from Microsoft To Do, Apple Reminders, Todoist, and TickTick, without adding P1–P4 multi-level priority clutter.

**UX / IA ideal (progressive disclosure):** Unstarred rows show zero extra chrome. Starring a task adds a quiet star glyph and unlocks a subtle Star filter pill inside lists (pairs with Tags `#96`, no filter query language) and an optional **Starred** smart view that appears in the sidebar only when at least one open task is starred *(default: hide empty Starred list, matching Recently Deleted)*.

## 2. Data model & shared registry (ADR 0015)

Add one column to `entities.task.columns` in `registry/entities.json` and run `node scripts/gen-registries.mjs`:

| Column | Kind | Constraint | Meaning |
|---|---|---|---|
| `starred` | `bool` | `default: 0` | `true` when marked Important / Starred. |

- **SwiftData (`Persistence.swift`):** `var starred: Bool = false` (default value REQUIRED for lightweight SwiftData migration!).
- **Wire / Sync / Export / History / Undo:** Wire through `TaskBackendMapping.swift`, `TaskSyncApply.swift`, `TaskHistory.swift` (`"Starred"` / `"Unstarred"`), `TaskUndo.swift`, `SeptaskDataTransfer.swift`, and `Outbox.swift` (`setStarred(id:starred:)`).
- **Repeating tasks & duplication:** Completing a recurring task preserves `starred` on the next occurrence *(default: recurring important tasks stay starred)*; duplicating a task preserves `starred`.

## 3. UX / UI (progressive disclosure)

- **Task row:** Zero indicator when `starred == false`. When `starred == true`, show a subtle star glyph (`star.fill`, warm accent/gold tint) tucked beside trailing meta (or leading title edge — keep compact so Today's gold badge and Star never clash; *(default: trailing meta beside deadline/repeat)*).
- **Controls:**
  - Mac: `⇧⌘S` or `⌘*` (verify no shortcut collision with existing `SeptaskNavigationCommands` — *(default: `⌥⌘S` or `⌃S`; verify in ST1 against `TaskRowShortcuts`*), composer pill, inspector toggle, context menu (`Star` / `Remove Star`), multi-select bulk star.
  - iOS / iPadOS: context menu, inline composer / task page toggle.
- **Filtering & Smart View:**
  - Inside any list with ≥ 1 starred task, show a single `★` pill in the visual filter bar (`#96`) to filter to starred tasks in one tap.
  - Sidebar smart list **Starred** (open starred tasks, grouped by area/project) shows only when open starred count > 0 *(default, progressive disclosure — same pattern as Recently Deleted)*.

## 4. Agent / MCP & migration mappings

- **MCP (`api.septena.app/mcp`):** `tasks_list` / `tasks_get` include `starred: true` when set; `tasks_list` accepts optional `starred: boolean` filter; `tasks_create` / `tasks_update` accept optional `starred: boolean`.
- **Importers:**
  - Microsoft To Do (`#52`): `importance == "high"` → `starred = true`.
  - Apple Reminders: `flagged == true` or `priority == 1` → `starred = true`.
  - Todoist (`#100`): P1 (highest priority) → `starred = true`; P2/P3 disclosed in migration preview (#99).
  - TickTick (`#100`): High priority (`priority == 5`) → `starred = true`.

## 5. Phases

| Phase | Scope | Depends on |
|---|---|---|
| **ST0 — Registry, backend, MCP & SwiftData model** | Add `starred` to `registry/entities.json`, regenerate constants, update `backend/src/store/columns.ts`, MCP read/write + recurring spawn copy, `Models.swift`, `Persistence.swift`, `Outbox.swift`, `TaskBackendMapping.swift`, `TaskSyncApply.swift`, `TaskHistory.swift`, `TaskUndo.swift`, `SeptaskDataTransfer.swift`. | None |
| **ST1 — Mac & iOS UI (progressive disclosure)** | Quiet row glyph, Mac/iOS toggle controls & context menus, single `★` filter pill in list filter bar, and conditional Starred smart list (hidden when empty). | ST0 |

## 6. Verification

- `node scripts/gen-registries.mjs --check`, `backend` conformance tests, `SeptenaMac` + `SeptaskMac` green builds.

## 7. Open questions

| Question | Default |
|---|---|
| Number of priority levels | Single boolean Star/Important flag only *(default, decided by mz 2026-11-21)* |
| Sidebar Starred list visibility | Hidden when count == 0 (progressive disclosure, like Recently Deleted) *(default)* |
| Repeating tasks | Next occurrence inherits `starred` *(default)* |
