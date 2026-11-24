# Checklists (1-level subtasks) — spec

**Status:** proposal (2026-11-21). Defaults in §9 stand unless mz overrules.
**Decisions:** [ADR 0002](adr/0002-own-backend-replaces-icloud.md), [ADR 0007](adr/0007-septena-is-the-task-app.md), [ADR 0008](adr/0008-agent-loop-rules-live-in-the-store.md), [ADR 0015](adr/0015-shared-registries-for-cross-platform-clients.md).
**Builds on:** `registry/entities.json`, `backend/src/store/TaskStore.ts`, `SeptenaCore/Models.swift`, `SeptenaCore/Persistence.swift`, `SeptenaCore/Outbox.swift`, `SeptenaCore/TaskUndo.swift`, `Septask/SeptaskKitComposer.swift`, `Septask/SeptaskKitInspector.swift`, `Septask/SeptaskKitRowViews.swift`, `Septena/Shell/Tasks/TaskComposer.swift`.
**Tracking issue:** [#76](https://github.com/michellzappa/septena/issues/76).
**Owner of decisions:** mz. Defaults chosen by the author are marked *(default)*.

## 1. Goal

Add **1-level flat checklists (subtasks)** inside a task — matching Things 3 checklists and Microsoft To Do steps — without turning tasks into nested project trees.

**UX / IA ideal (mz, 2026-11-21):**
- **1-level flat items only** (no arbitrary nested subtask trees; projects + sections already serve multi-level hierarchy).
- **Progressive disclosure**: tasks without checklist items show zero checklist UI on the row; adding steps stays tucked behind a subtle checklist button/shortcut inside the open composer, inspector, or edit sheet. When a task has steps, its collapsed row shows a quiet progress pill (e.g. `2/5`).

## 2. Data model & shared registry (ADR 0015)

### Separate synced entity vs. JSON blob on `tasks`
**Decision *(default)*: Add a dedicated `checklist_item` entity (`checklist_items` table) in `registry/entities.json`** rather than a JSON array column on `tasks`.

Why:
- Checking off item A on iPhone while renaming or adding item B on Mac (or via an agent over MCP) merges cleanly at row granularity with zero lost updates under `TaskStore`'s field-level LWW push model.
- Keeps `tasks` row payloads small and preserves per-item change history and deterministic IDs for idempotent imports (#99).

### Entity schema (`registry/entities.json`)

Add `checklistItem` to `entities`:

| Column | Kind | Format / Constraint | Meaning |
|---|---|---|---|
| `taskId` | `text` | `format: "id"`, `nullable: false` | Owning `TaskEntity.id`. Required on insert; immutable after insert. |
| `title` | `text` | `max: 2000`, `nullable: false` | Step text (single-line display, wraps cleanly). |
| `checked` | `bool` | `default: 0` | Checked state. |
| `checkedAt` | `text` | `format: "stamp"`, `max: 40`, `nullable: true` | UTC timestamp when checked (preserved on import from To Do `checkedDateTime`). |
| `position` | `real` | `nullable: true` | Fractional manual order inside the parent task (midpoint insert + drag reorder, identical to `tasks.position`). |
| `createdAt` | `text` | `format: "stamp"`, `max: 40`, `nullable: true` | Creation timestamp. |

- `deletable: true`, `requiredOnInsert: ["taskId", "title"]`.
- Limit in `registry/entities.json`: `maxChecklistItemsPerTask: 200` *(default)*.
- **SwiftData (`Persistence.swift`):** New `@Model final class TaskChecklistItemEntity` (id, taskId, title, checked, checkedAt, position, createdAt, updatedAt, deletedAt) + `ChecklistItem` value struct in `SeptenaCore/Models.swift`.
- **Distinct from `convo.subtasks`:** `convo.subtasks` remains agent conversation breakdown metadata; if an agent proposes decomposing a task into checklist steps, it writes real `checklistItem` rows (or the user clicks "Add to checklist" from a conversation proposal).

## 3. Lifecycle rules

1. **Completing the parent task:**
   - Completing a task leaves its checklist items' individual `checked` states intact *(default: matches Things 3 and preserves what was actually done vs. skipped in Logbook)*. Reopening the task restores the exact checklist state.
2. **Soft-deleting & purging the parent task:**
   - Moving a task to Recently Deleted leaves its checklist items attached (hidden from normal queries); restoring the task restores its checklist; permanent delete / 30-day purge cascades deletion to its `checklistItem` rows.
3. **Duplicating a task (`⌘D`):**
   - Copies all checklist items in order, preserving titles and resetting `checked = false` *(default: duplicating a task resets steps to unchecked)*.
4. **Repeating tasks (#126):**
   - When a recurring task spawns its next occurrence (both in Swift and in `backend/` MCP `tasks_complete`), copy the source task's active checklist items in `position` order onto the new occurrence with `checked = false`, `checkedAt = nil`, and deterministic IDs (`fnv1a("<newTaskID>|chk|<index>|<sourceItemID>")`) so phone + agent completions converge without duplicate checklist rows!
5. **Convert checklist item to full task (progressive disclosure):**
   - Optional context menu action on a checklist row: `"Convert to Task"` creates a sibling task in the same project/section/Today state and deletes the checklist item in one undo step *(default: include in CL2 polish)*.

## 4. UX / UI (progressive disclosure)

### Collapsed task row (Mac `SeptaskKitRowViews.swift` & iOS `TaskComponents.swift`)
- Zero extra chrome if `checklistCount == 0`.
- If `checklistCount > 0`: show a quiet trailing/subtitle indicator `✓ 2/5` (or subtle progress glyph + `2/5`) matching `docs/TASK_ROW_LANGUAGE_SPEC.md`.

### Open task (Mac `SeptaskKitComposer.swift` & `SeptaskKitInspector.swift`; iOS `TaskComposer.swift`)
- **Hidden until used:** A subtle checklist icon button in the composer pill bar (or `⇧⌘C` on Mac) inserts the first blank checklist row and focuses it.
- **Keyboard-fast editing (Things-like):**
  - `Return` on a checklist row creates the next checklist item immediately below and focuses it.
  - `Backspace` on an empty checklist row removes it and focuses the previous item (or title/notes).
  - `Tab` / `⇧Tab` / `↑` / `↓` move between items. Focus order in the open task: title → notes → steps → pills.
  - `↓` on the last line of notes enters the first step; `↑` on the first step returns to the end of notes; moving past the last step goes to the first pill. Shipped on Mac (composer and inspector). iOS/iPadOS: Tab works, `↓` from notes not yet (UIKit notes field).
  - `⌘K` toggles the focused step instead of completing the task (Mac and iOS/iPadOS).
  - Each row has a trailing delete button and a context menu: Move Up, Move Down, Delete Step.
  - Drag handle / drag-and-drop reorders items within the checklist.
  - Paste multi-line text inside a checklist row splits into one checklist item per line *(default)*.
- **Undo:** Add, edit, check/uncheck, reorder, and delete checklist items all register on the single shared `TaskUndo` stack at the user gesture (never inside mutators or sync applies).
- **Accessibility:** VoiceOver announces `"<title>, checklist item 2 of 5, unchecked"` and exposes toggle/delete custom actions; Dynamic Type scales checkbox and spacing cleanly.

## 5. Agent / MCP surface (`api.septena.app/mcp`)

- `tasks_get`: returns `checklist: [{ id, title, checked, position }]` ordered by `position` (omitted or empty when none).
- `tasks_list`: returns `checklistCount` and `checklistDoneCount` summary integers (keeps list payloads compact) rather than full item arrays *(default)*.
- `tasks_create`: accepts optional `checklist: string[]` (array of step titles, created in order).
- Dedicated tools (or `tasks_checklist_*` / `tasks_update` sub-operations):
  - `tasks_checklist_add(task_id, items: string[])`
  - `tasks_checklist_update(id, title?, checked?, position?)`
  - `tasks_checklist_delete(id)`
- **Permissions & provenance (ADR 0008):** Respects `stoppedAt` and `agentsPaused`. Checking all checklist items via MCP does **not** automatically complete a Claude-assigned task (human-only completion gate `#87` still holds).

## 6. Migration & export fidelity

- **Things import (`ThingsImport`):** Read `TMChecklistItem` rows ordered by `index` (`status == 3` → `checked = true`, `stopDate` → `checkedAt`).
- **Microsoft To Do (`#52`):** Map Graph `checklistItem` (`displayName`, `isChecked`, `checkedDateTime`, `createdDateTime`).
- **Todoist / TickTick / Apple Reminders (#99, #100):** Map 1-level subtasks/checklist items directly; flatten deeper Todoist/TickTick nesting (depth > 1) with an explicit warning in the migration preview/loss report (#99) rather than dropping them silently.
- **Data export (`SeptaskDataTransfer.swift` / `#130`):** Add `"checklist_item"` table to `septena_export_version: 1` JSON envelope; render `- [ ]` / `- [x]` sub-bullets in Markdown export.

## 7. Phases

| Phase | Scope | Depends on |
|---|---|---|
| **CL0 — Registry, backend store & SwiftData model** | Add `checklistItem` entity to `registry/entities.json`, regenerate Swift/TS constants, wire `backend/src/store/columns.ts`, `TaskStore` cascade delete + recurring-task deterministic copy, MCP tools (`taskShared.ts`, `taskTools.ts`, `writeTasks.ts`), `TaskChecklistItemEntity` in `Persistence.swift`, `TaskMutator` / `Outbox.swift`, `TaskBackendMapping.swift`, `TaskSyncApply.swift`, `TaskUndo.swift`, and `SeptaskDataTransfer.swift`. | None |
| **CL1 — Mac & iOS Checklist UI (progressive disclosure)** | Collapsed row progress pill (`2/5`), keyboard-fast checklist editor in Mac `SeptaskKitComposer` & `SeptaskKitInspector` (`⇧⌘C`, Return-to-add, Backspace-on-empty, drag reorder, paste lines) and iOS/iPadOS `TaskComposer` / edit sheet, VoiceOver & Dynamic Type support. | CL0 |
| **CL2 — Importer fidelity & convert-to-task** | Wire `ThingsImport` (`TMChecklistItem`) and migration engine hooks (#99), plus `"Convert to Task"` context action on checklist items. | CL1 |

## 8. Verification

- `node scripts/gen-registries.mjs --check` passes.
- `backend` typecheck + store/MCP tests (including concurrent check-off + rename merge and recurring task checklist reset/convergence) pass.
- `scripts/build.sh SeptenaMac 'platform=macOS'` and `scripts/build.sh SeptaskMac 'platform=macOS'` both green.
- Manual test by mz: add 3 steps with `⇧⌘C` + Return, reorder by drag, undo with `⌘Z`, complete recurring task and verify next occurrence has 3 unchecked steps, verify Things import preserves checked state.

## 9. Open questions

| Question | Default |
|---|---|
| Storage shape | Dedicated `checklist_items` entity/table (clean per-item LWW sync & history) *(default)* |
| Completing parent task | Keep each checklist item's individual checked state as-is *(default)* |
| Repeating task spawn | Copy all checklist items onto next occurrence, reset to unchecked, deterministic IDs *(default)* |
| Max items per task | 200 items *(default)* |
| Nesting depth from external importers (Todoist/TickTick) | Flatten depth > 1 into 1-level steps with explicit preview/loss notice in `#99` *(default)* |
