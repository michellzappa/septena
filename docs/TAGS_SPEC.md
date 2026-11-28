# Tags and simple in-list filtering — spec

**Status:** proposal (2026-11-21). Defaults in §9 stand unless mz overrules.
**Decisions:** [ADR 0002](adr/0002-own-backend-replaces-icloud.md), [ADR 0007](adr/0007-septena-is-the-task-app.md), [ADR 0008](adr/0008-agent-loop-rules-live-in-the-store.md), [ADR 0015](adr/0015-shared-registries-for-cross-platform-clients.md).
**Builds on:** `registry/entities.json`, `backend/src/store/TaskStore.ts`, `SeptenaCore/Models.swift`, `SeptenaCore/Persistence.swift`, `SeptenaCore/Outbox.swift`, `Septask/SeptaskKitComposer.swift`, `Septask/SeptaskKitRowViews.swift`, `Septask/SeptaskKitTaskList.swift`, `Septena/Shell/Tasks/TaskListView.swift`.
**Tracking issue:** [#96](https://github.com/septena/septena/issues/96).
**Owner of decisions:** mz. Defaults chosen by the author are marked *(default)*.

## 1. Goal

Add lightweight **tags** to tasks for cross-cutting context (`@errands`, `@waiting`, `@5min`, `@work`) and **fast visual in-list filtering** across Today, Upcoming, Anytime, Projects, Areas, and Logbook — superseding the old `docs/BACKLOG.md` exclusion.

**UX / IA ideal (mz, 2026-11-21):**
- **No filter query language.** Filtering is pure visual click/tap on tag pills (and later the Star pill `#127`). Never force users to learn `(@work & !@waiting) | p1` syntax or tag every task.
- **Progressive disclosure:** If a user has created zero tags, no tag bar or tag chrome appears anywhere. Tagging stays tucked behind a subtle Tag pill/shortcut (`⇧⌘T`) in the open composer/inspector/edit sheet, and the filter bar inside a list only appears when the current list has tagged tasks (or when summoned).

## 2. Data model & shared registry (ADR 0015)

### Entity & column design
1. **New `tag` entity (`tags` table) in `registry/entities.json`:**
   - `id`: stable ID (`tag-<uuid>` or normalized slug on import)
   - `name`: `text` (max 64, nullable: false; display name preserved as typed, case-insensitive uniqueness enforced on create/import so `"Errands"` and `"errands"` never duplicate!)
   - `color`: `text` (max 32, nullable: true — optional semantic color token; default neutral pill)
   - `position`: `int` (nullable: true — manual display order)
   - `deletable: true`, `requiredOnInsert: ["name"]`.
2. **New `tags` JSON array column on `task` in `registry/entities.json`:**
   - `tags`: `json` (`string[]` of `tag.id` values, max 20 tags per task, nullable).
   - Why `task.tags` array + `tags` catalog table *(default)*:
     - Renaming a tag updates ONE row in `tags` and immediately reflects on every task referencing that `tag.id` across all devices.
     - Deleting a tag soft-deletes the `tags` row; clients and backend ignore any dangling deleted `tag.id` on read (and lazily prune on next task edit) so deleting a tag never triggers a massive N-task write storm!
     - Re-running an importer (#99) matches existing tags case-insensitively by `name` to avoid duplicate tags.
   - **Flat tags in v1** *(default: no nested parent/child tag trees; Things' nested tags flatten cleanly with path or leaf name and explicit note in #99)*.

## 3. Filtering behavior (simple, visual, zero query language)

- **Inside any task list (Today, Upcoming, Anytime, Project, Area, Logbook):**
  - When at least one visible task in the current list has a tag (or is starred once `#127` ships), a compact horizontal filter strip appears gently at the top of the list (or toggles via `⌘F` / filter button) showing ONLY the tags actually present in that list (plus `Clear` when active).
  - **Multi-tag selection uses AND** *(default: tapping `Errands` + `5min` narrows to tasks with both, matching Things 3; tapping an active pill removes it; `Esc` clears the active filter)*.
  - Filtering never changes a task's area/project membership, sort order, or counts outside the view.
  - **Quick Find (`⇧⌘F` / iOS Search tab):** Typing a tag name also surfaces matching tagged tasks cleanly.

## 4. UX / UI (progressive disclosure)

- **Collapsed task row (`SeptaskKitRowViews.swift`, `TaskComponents.swift`):**
  - Zero chrome when a task has no tags.
  - When tagged: render compact, quiet hairline tag capsules (max 2–3 inline on narrow mobile rows with `+N` overflow) using muted secondary styling so titles remain primary.
- **Assigning tags:**
  - **Mac (`SeptaskKitComposer`, `SeptaskKitInspector`, `SeptaskKitTaskList`):** `⇧⌘T` (or Tag pill in composer) opens a lightweight inline type-to-filter token popover: type a tag name and press Return to toggle an existing tag or create a new one on the fly. Works on multi-selection too.
  - **iPhone & iPad (`TaskComposer`, edit sheet, context menu):** Compact `Tags` row with tap-to-toggle chips + inline `"New tag…"` field.
- **Managing tags:**
  - Lightweight **"Manage Tags"** sheet in Settings ▸ Tasks (and reachable from the tag popover) for rename, merge (merging Tag A into Tag B rewrites tasks referencing A → B and deletes A), color, and delete.
- **Undo:** Assigning/removing tags on tasks records on the shared `TaskUndo` stack at the user gesture.

## 5. Repeating tasks & duplication

- Completing a recurring task (#126) copies its `tags` onto the next generated occurrence (both Swift and backend MCP `tasks_complete`).
- Duplicating a task (`⌘D`) copies its `tags`.

## 6. Agent / MCP surface (`api.septena.app/mcp`)

- `tasks_list` / `tasks_get`: return `tags: string[]` (human-readable tag names for agent ergonomics, plus `tagIds` if needed, or resolve names ↔ IDs transparently in the connector *(default: accept and return tag names in MCP tools, resolving case-insensitively to canonical `tag.id` in `TaskStore` so agents never have to memorize UUIDs!)*).
- `tasks_list`: gains optional `tag` filter parameter (single tag name or array, AND semantics).
- `tasks_create` / `tasks_update`: accept optional `tags: string[]` (auto-creating missing tags only when allowed, respecting `stoppedAt` and `agentsPaused`).
- `tasks_list_tags`: lists existing tags with open task counts so agents reuse the user's vocabulary instead of inventing synonyms.

## 7. Migration & export fidelity

- **Things import (`ThingsImport`):** Read `TMTag` + `TMTaskTag` join table; map task tags directly. Area/project inherited tags: carry onto imported tasks with an explicit toggle/note in `#99` *(default: materialize inherited Things tags only if explicitly enabled in preview, otherwise disclose)*.
- **Apple Reminders / Todoist / TickTick (#99, #100):** Direct 1:1 mapping from Reminders tags, Todoist labels, TickTick tags.
- **Microsoft To Do (#52):** Map Graph `categories` array and inline `#hashtags` if present.
- **Data export (`SeptaskDataTransfer.swift` / `#130`):** Include `"tag"` table and `tags` array on tasks in JSON; render `#tag` tokens in Markdown and comma-separated names in CSV.

## 8. Phases

| Phase | Scope | Depends on |
|---|---|---|
| **TG0 — Registry, backend store, MCP & SwiftData model** | Add `tag` entity and `task.tags` column to `registry/entities.json`, regenerate Swift/TS constants, wire `backend/src/store/columns.ts`, `TaskStore`, recurring-task tag copy, MCP tools (`tasks_list_tags`, `tasks_list` tag filter, `tasks_create`/`tasks_update` tags), `TagEntity` + `TaskEntity.tagIDsJSON` in `Persistence.swift`, `Outbox.swift`, sync mapping/apply, `TaskUndo`, `SeptaskDataTransfer.swift`. | None |
| **TG1 — Mac & iOS tag picker, row pills & visual in-list filter bar** | Implement quiet tag capsules on rows, `⇧⌘T` type-to-assign/create popover on Mac + iOS Tags picker, visual AND filter strip inside lists (hidden when no tags exist), Quick Find tag matching, and Manage Tags (rename/merge/delete) sheet. | TG0 |
| **TG2 — Importer fidelity (Things & Reminders)** | Wire `ThingsImport` (`TMTag`/`TMTaskTag`) and `RemindersBridge` tags into TG0 model. | TG0 |

## 9. Open questions

| Question | Default |
|---|---|
| Tag hierarchy | Flat tags only in v1 (no nested tag trees) *(default)* |
| Multi-tag filter logic | Visual pill selection with AND semantics; no filter query language *(default)* |
| MCP tag representation | Accept/return human tag names, resolved case-insensitively to `tag.id` in `TaskStore` *(default)* |
| Max tags per task | 20 tags *(default)* |
| Inherited Things area/project tags on import | Disclosed in `#99` preview rather than silently duplicating onto every task *(default)* |
