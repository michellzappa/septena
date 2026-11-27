# iOS task-row swipe actions — spec

> **Superseded 2026-11-23.** mz dropped every task-row swipe on iPhone and iPad (the hand-built pan gestures fought scrolling, long-press drag and back-swipe, and swipe-left was the only hidden way into multi-select). Touch multi-select now starts from **Select** in the row context menu (`task.select`, capability `edit.multi-select`). The selection mode, bottom bar and multi-task drag below still apply; every swipe section does not. The watch keeps native `List` `.swipeActions`.

**Status:** building (2026-11-21 — SW0 + SW1 implemented on `SelectableScrollList` alongside swipe-left Select in [MULTI_SELECT_SWIPE_AND_DRAG_SPEC.md](MULTI_SELECT_SWIPE_AND_DRAG_SPEC.md)). Defaults in §7 stand unless mz overrules.
**Decisions:** [ADR 0007](adr/0007-septena-is-the-task-app.md), [ADR 0015](adr/0015-shared-registries-for-cross-platform-clients.md).
**Builds on:** `Septena/Shell/Tasks/TaskListView.swift`, `Septena/Shell/Tasks/TaskRowActions.swift`, `Septena/Shell/Tasks/TaskListContextMenu.swift`, `SeptenaCore/TaskUndo.swift`, `SeptenaCore/Haptics.swift`, `SeptenaCore/SettingsKeys.swift` (and later `registry/actions.json` R2 `#143`).
**Tracking issue:** [#132](https://github.com/septena/septena/issues/132).
**Owner of decisions:** mz. Defaults chosen by the author are marked *(default)*.

## 1. Goal

Add fast, native iOS/iPadOS swipe gestures to task rows so everyday triage (Schedule, Today, Move, Delete) works with one thumb swipe instead of requiring a long-press context menu.

**UX / IA ideal (progressive disclosure):**
- Great defaults out of the box with zero configuration required.
- Optional lightweight swipe customization tucked inside **Settings ▸ Tasks** for users who prefer different actions (e.g. Star `#127`, Complete, Defer).
- Never allow accidental destructive deletion on a sloppy full-swipe without immediate undo.

## 2. Default swipe mappings (by surface)

| Direction | Slot | Default action | Full swipe? | Behavior |
|---|---|---|---|---|
| **Leading (swipe right)** | Primary | **Today** (or **Remove from Today** when already pinned on Today) | Yes *(default)* | Toggles Today pin + acknowledges proposal + `Haptics.tick()` + `TaskUndo` + toast |
| **Leading (swipe right)** | Secondary | **Schedule (When…)** | No | Opens `DatePickerSheet` for this task |
| **Trailing (swipe left)** | Primary (outermost) | **Delete** (soft delete → Recently Deleted) | **No** *(default: tap-to-confirm prevents accidental deletes; soft delete still has full `TaskUndo` + toast)* | Moves to Recently Deleted + `TaskUndo` + toast |
| **Trailing (swipe left)** | Secondary | **Move…** | No | Opens `MovePickerSheet` (or accepts `"→ Suggested"` if user customizes) |

### Context-specific overrides
- **Inbox band — unacknowledged agent proposals:** Leading primary = **Accept / Keep** (acknowledges proposal into Today/list); Trailing primary = **Dismiss** (soft delete with undo).
- **Recently Deleted list:** Leading primary = **Restore** (full swipe allowed); Trailing primary = **Delete Permanently** (no full swipe; opens confirmation alert per safety contract).
- **Multi-select / EditMode active:** Swipe actions are disabled while selecting multiple rows.
- **Section headings (`isHeading == true`):** Leading disabled; Trailing offers Rename / Delete section only (never Today/Schedule).

## 3. Optional customization (progressive disclosure)

Stored as two device-local `AppStorage` keys (later registered in `registry/settings.json` R1 `#142` and `registry/actions.json` R2 `#143`):
- `septena.tasks.swipeLeadingAction`: enum `today` *(default)* | `schedule` | `move` | `star` *(shown once #127 ships)* | `complete` | `none`
- `septena.tasks.swipeTrailingAction`: enum `move` *(default)* | `schedule` | `today` | `star` *(once #127 ships)* | `delete` | `none`

Note: Delete remains available as a trailing secondary action unless the user sets trailing to `none`. Customization sits quietly under **Settings ▸ Tasks ▸ Swipe Actions** — never shown during onboarding.

## 4. Architecture & shared-surface discipline

- Implement as a clean `#if os(iOS)` modifier (`.taskRowSwipeActions(...)`) alongside `TaskRowActions` (`Septena/Shell/Tasks/TaskRowActions.swift`), reusing the EXACT same `onMoveToToday`, `onOpenWhen`, `onOpenMove`, `onDelete` callbacks, `TaskUndo` recording, `Haptics`, and `toastStore` as `TaskListRowContextMenu` — zero duplicated business logic!
- Verify `TaskListView` renders rows inside a `List` container (or check where `LazyVStack` is used: SwiftUI `.swipeActions` only attaches inside `List`; if any iOS list surface uses `LazyVStack`, note whether to migrate that container or provide a compact gesture fallback — inspect `TaskListView.swift` in Phase SW0!).
- **Accessibility:** Mirror every swipe action as a VoiceOver `.accessibilityAction(named:)` on the row and respect `@Environment(\.accessibilityReduceMotion)`.

## 5. Phases

| Phase | Scope | Depends on |
|---|---|---|
| **SW0 — Core iOS swipe actions on all task lists** | Audit `TaskListView` container (`List` vs. `LazyVStack`), build `.taskRowSwipeActions` reusing `TaskRowActions` callbacks + `TaskUndo` + `Haptics` + toasts, handle Inbox proposals, Recently Deleted, headings, and multi-select, plus VoiceOver `.accessibilityAction` parity. | None |
| **SW1 — Progressive-disclosure Settings customization** | Add optional `Swipe Actions` row in `TaskSettingsSections.swift` (`septena.tasks.swipeLeadingAction` / `septena.tasks.swipeTrailingAction`) and register slots in `registry/actions.json` once R2 (`#143`) lands. | SW0 |

## 6. Verification

- `scripts/build.sh SeptenaMac 'platform=macOS'` and `scripts/build.sh SeptaskMac 'platform=macOS'` both green (`#if os(iOS)` guards clean on macOS, no broken shared signatures).
- Manual test by mz on iPhone/iPad: swipe right on Inbox/Project/Today tasks, swipe left to Move or Delete, shake/tap Undo, verify multi-select disables swipe, verify Recently Deleted offers Restore.

## 7. Open questions

| Question | Default |
|---|---|
| Full swipe on Delete | Disabled by default (`allowsFullSwipe: false`) to prevent accidental deletes; full swipe enabled on Leading Today *(default)* |
| Customization sync scope | Device-local preference (phone thumb habits differ from iPad) *(default)* |
| Scope on macOS | iOS / iPadOS only (Mac already has keyboard shortcuts, context menus, and inline composer) *(default)* |
