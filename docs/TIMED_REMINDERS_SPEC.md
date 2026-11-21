# Timed task reminders — spec

**Status:** proposal (2026-11-21). Defaults in §10 stand unless mz overrules.
**Decisions:** [ADR 0002](adr/0002-own-backend-replaces-icloud.md), [ADR 0007](adr/0007-septena-is-the-task-app.md), [ADR 0008](adr/0008-agent-loop-rules-live-in-the-store.md), [ADR 0015](adr/0015-shared-registries-for-cross-platform-clients.md).
**Builds on:** `registry/entities.json`, `backend/src/store/TaskStore.ts`, `SeptenaCore/Models.swift`, `SeptenaCore/Persistence.swift`, `SeptenaCore/Outbox.swift`, `SeptenaCore/TaskBackend/`, `Septask/SeptaskLaunch.swift`, `Septask/SeptaskKitDatePopover.swift`, `Septena/Shell/Tasks/TaskPickerSheets.swift`.
**Tracking issue:** [#97](https://github.com/michellzappa/septena/issues/97).
**Owner of decisions:** mz. Defaults chosen by the author are marked *(default)*.

## 1. Goal

Let a user attach an actual wall-clock notification to a task — distinct from its `scheduled` (When) date, its `deadline`, and Today membership — so Septena can reliably nudge them at a chosen time on iPhone, iPad, Mac, and future Web/Android/Windows clients without adding visual noise to tasks that don't use alerts.

**UX / IA ideal (progressive disclosure):** Date-only tasks stay completely calm. Reminder controls stay tucked behind an "Add reminder" / bell trigger in the date popover, composer, inspector, and iOS edit sheet, and only show a quiet time badge on a row once a reminder is set.

## 2. Scope & non-goals

**In scope (v1):**
- One timed reminder per task (`reminderAt` + mode/snooze state).
- Quick presets (In 1 hour, Later today, Tomorrow 9:00, Custom date & time) and snooze actions directly from the notification banner (15 min, 1 hour, Tomorrow morning) plus Mark Done.
- Floating-local vs. fixed-instant semantics, DST/timezone travel handling, missed-alert reconciliation, and clean cancellation on completion, cancellation, deletion, or reschedule.
- Repeating-task handoff: completing a recurring task carries the reminder time-of-day onto the next occurrence.
- Backend sync (`api.septena.app`), MCP read/propose access, and lossless migration mapping (Things, Apple Reminders, Microsoft To Do, Todoist, TickTick).

**Explicit non-goals (v1):**
- Multiple reminders per task *(default: single reminder; revisit only if switcher evidence demands it)*.
- Persistent/nagging repeating alarms (Due-style) or Critical Alerts *(default: standard time-sensitive / active OS notification)*.
- Location-based geofence alerts (separate future spec).

## 3. Data model & shared registry (ADR 0015)

Add four nullable columns to the `task` entity in `registry/entities.json` (and regenerate `SeptenaCore/Generated/RegistryConstants.swift` and `backend/src/generated/registries.ts` via `scripts/gen-registries.mjs`):

| Column | Kind | Format / Constraint | Meaning |
|---|---|---|---|
| `reminderAt` | `text` | ISO-8601 local wall-clock (`YYYY-MM-DDTHH:MM`, max 32) OR UTC instant (`YYYY-MM-DDTHH:MM:SSZ`) | The scheduled alert time. Null = no reminder. |
| `reminderMode` | `text` | enum `reminderMode`: `"floating"` \| `"fixed"` (nullable, default `"floating"`) | `"floating"` fires at the wall-clock time in whatever timezone the device is currently in (e.g. "Take pills at 09:00"). `"fixed"` fires at an exact UTC instant (e.g. "Call NYC at 15:00 CET"). *(default: `"floating"`)* |
| `reminderSnoozedUntil` | `text` | `stamp` (UTC ISO-8601 instant, max 40, nullable) | When the user taps Snooze, holds the temporary next fire instant without mutating the task's underlying `reminderAt` (so repeating tasks preserve their original time-of-day). Cleared when fired, completed, or edited. |
| `reminderDismissedAt` | `text` | `stamp` (UTC ISO-8601 instant, max 40, nullable) | Set when the user marks the alert handled or completes/acknowledges it on one device, so other devices cancel/remove the delivered banner on sync instead of firing a duplicate. |

**SwiftData (`TaskEntity` in `SeptenaCore/Persistence.swift`) & `SeptenaTask` (`SeptenaCore/Models.swift`):**
- Add `reminderAt: String?`, `reminderMode: String?`, `reminderSnoozedUntil: String?`, `reminderDismissedAt: String?`.
- Expose a clean value type `TaskReminder: Codable, Hashable` computed property (`fireLocalDateTime`, `mode`, `snoozedUntil`, `dismissedAt`) mirroring how `Recurrence` wraps flat columns.
- Update `TaskBackendMapping.swift`, `TaskSyncApply.swift`, `TaskHistory.swift`, `TaskUndo.swift`, `SeptaskDataTransfer.swift`, and `Outbox.swift` (`setReminder(id:reminder:)`, `snoozeReminder(id:until:)`).

**Relationship to `scheduled` and optional start/end time (#128):**
- A reminder can exist on a task with or without a `scheduled` date or `deadline`.
- Setting a reminder on an unscheduled task does **not** silently set `scheduled` or `deadline` unless the user explicitly sets a date *(default: independent field — matches Things and avoids breaking Inbox/Anytime semantics)*.
- Rescheduling a task's `scheduled` date when `reminderAt` falls on the *same calendar day* as the old `scheduled` date moves the reminder's date along with it while keeping its HH:MM time *(default: keep same-day reminder coupled on reschedule, leave different-day reminders untouched)*.

## 4. Semantics: time zones, DST, snooze, repeats, multi-device

Add golden conformance fixtures in `registry/conformance/reminders.json` tested by both `SeptenaCoreTests` and `backend/test/conformance.test.ts`:

1. **Floating vs. Fixed:**
   - `floating` stores `YYYY-MM-DDTHH:MM` (no offset). Each device resolves it in `TimeZone.current` via `UNCalendarNotificationTrigger(dateMatching:repeats:false)`.
   - `fixed` stores `YYYY-MM-DDTHH:MM:SSZ`. Each device converts to local `Date` and schedules at that exact instant.
   - DST spring-forward nonexistent local time (e.g. 02:30 on spring-forward day): resolve forward to the first valid instant after the gap (03:00). DST fall-back ambiguous time: fire on the first occurrence.
2. **Snooze:**
   - Notification action buttons registered under category `septena.task.reminder`:
     - `Complete` (background, no app switch — calls `TaskMutator.complete` via `SeptenaServices.shared.start()`)
     - `Snooze 15 min` (background — writes `reminderSnoozedUntil = now + 15m`)
     - `Snooze 1 hour` (background — writes `reminderSnoozedUntil = now + 1h`)
     - `Tomorrow 9:00` (background — writes `reminderSnoozedUntil` = tomorrow 09:00 local)
   - Effective fire time = `reminderSnoozedUntil` if present and in the future (or unacknowledged); otherwise resolved `reminderAt`.
3. **Completion, cancellation, deletion:**
   - Completing, cancelling, or soft-deleting a task immediately removes any pending AND delivered `UNUserNotificationCenter` notification for `septask.reminder.<taskID>`.
4. **Repeating tasks (coordinates with #126):**
   - When a recurring task spawns its next occurrence for `nextScheduled`:
     - If the source task had a `reminderAt` on the same day as its `scheduled` (or `logicalScheduled`) date, the spawned occurrence inherits the same `HH:MM` on `nextScheduled` (and `reminderMode`), with `reminderSnoozedUntil = nil` and `reminderDismissedAt = nil`.
     - If the reminder was offset N days before `scheduled` (e.g. 1 day before), preserve that day offset on `nextScheduled`.
     - If `recurrencePaused == true`, no new occurrence or reminder is created.
5. **Missed alerts & OS 64-notification cap (iOS):**
   - `TaskReminderScheduler` (new, in `SeptenaCore` + Apple notification bridge) reconciles the next **50 soonest** open, non-dismissed, future reminders into `UNUserNotificationCenter` (leaving headroom below iOS's 64 pending request limit).
   - Reconcile runs on: app launch, foreground, any `TaskMutator` reminder/schedule/status write, sync apply, and timezone/significant-time-change notification (`NSSystemTimeZoneDidChange`, `UIApplication.significantTimeChangeNotification`).
   - Alerts whose effective time passed while the device was off or muted are not spam-fired retroactively on wake; instead, the task row renders the overdue reminder badge softly so the user sees it in Today/list, and tapping or completing clears it.
6. **Multi-device delivery & deduplication:**
   - Apple devices schedule locally from synced state — works 100% offline with zero push dependency.
   - When Device A completes, snoozes, or dismisses a reminder, syncing `status`/`reminderSnoozedUntil`/`reminderDismissedAt` triggers Device B's reconcile (and silent push `#38` when live) to call `removePendingNotificationRequests` and `removeDeliveredNotifications` for that task ID.
7. **Future Web & Android contract (no claim of shipping yet):**
   - Android (`#20`): identical local scheduling via `AlarmManager` / `WorkManager` from synced fields.
   - Web (`#21`): Web Push via `api.septena.app` alarm/queue for signed-in subscribed browsers, gated on the user granting browser Notification permission.

## 5. UX / UI (progressive disclosure)

- **Mac (`SeptaskKitDatePopover.swift`, `SeptaskKitComposer.swift`, `SeptaskKitInspector.swift`, `SeptaskKitRowViews.swift`):**
  - Inside the When popover (and Inspector), add a compact collapsed row `"Add reminder"` (bell icon). Clicking reveals quick chips (`In 1 hour`, `Tonight 18:00`, `Tomorrow 09:00`) + time input (`9:30am`, `14:00`) + subtle `"Fixed time zone"` toggle only inside a disclosure/popover menu.
  - Keyboard shortcut: `⌥⌘R` (or via When popover `⌘S` → Tab/R) to set/edit reminder; Backspace/Clear button removes it.
  - Task row trailing meta: only when a reminder is active on an open task, show a quiet bell + time (`09:00` if today, `Thu 09:00` if another day; muted amber/red if past due and unacknowledged).
- **iPhone & iPad (`TaskPickerSheets.swift`, `TaskComposer.swift`, `TaskComponents.swift`):**
  - Compact `"Reminder"` row in the schedule sheet / edit sheet; tapping expands presets + native compact date/time picker.
  - Permission prompt: **never ask at launch**. Request `UNUserNotificationCenter.requestAuthorization(options: [.alert, .sound, .badge])` only the first time the user saves a reminder. If denied, still save the reminder data and show a one-line non-blocking banner with a direct `"Open Settings"` link.
- **Undo:** Setting, editing, clearing, or snoozing a reminder from the UI records one `TaskUndo` entry (never inside mutators or sync apply).

## 6. Agent / MCP access (`api.septena.app/mcp`)

- `tasks_list` / `tasks_get` return `reminderAt`, `reminderMode`, `reminderSnoozedUntil` when present.
- `tasks_create` and `tasks_update` accept optional `reminderAt` and `reminderMode`.
- **Human confirmation boundary (ADR 0008):** Agents may propose tasks with a `reminderAt` (landing in the Inbox band as a proposal; **unacknowledged agent proposals do NOT arm local OS notifications until the user accepts/files them** *(default)* so an agent can never wake the user's phone unexpectedly). For an already-accepted task, an agent updating `reminderAt` records provenance in the change log and respects `stoppedAt` / `agentsPaused`.

## 7. Migration & export fidelity

- **Things import (`SeptenaCore/ThingsImport/`):** Read `TMTask.reminderTime` (minutes since midnight on `startDate`) → `reminderAt` (`floating`).
- **Apple Reminders (`RemindersBridge.swift`):** Read `EKAlarm.absoluteDate` → `reminderAt` (`floating` by default unless explicit timezone differs). Relative/location alarms reported in loss summary (#99).
- **Microsoft To Do (`#52`):** Map `isReminderOn == true` + `reminderDateTime` → `reminderAt` (respecting `timeZone`).
- **Todoist (`#100`):** Map explicit timed reminders; report location/relative reminders in loss summary.
- **Data export (`SeptaskDataTransfer.swift` / `#130`):** Include all four reminder fields in JSON and ISO time in CSV/Markdown.

## 8. Phases

| Phase | Scope | Depends on |
|---|---|---|
| **TR0 — Schema, registry & conformance** | Add `reminderAt`, `reminderMode`, `reminderSnoozedUntil`, `reminderDismissedAt` to `registry/entities.json`, regenerate Swift/TS constants, update `backend/src/store/columns.ts`, `TaskStore`, `recurrence` spawn handoff, MCP tools (`taskShared.ts`, `writeTasks.ts`), `SeptenaCore/Models.swift`, `Persistence.swift`, `Outbox.swift`, `TaskBackendMapping.swift`, `TaskSyncApply.swift`, `TaskHistory.swift`, `TaskUndo.swift`, `SeptaskDataTransfer.swift`, and `registry/conformance/reminders.json` tests. | None |
| **TR1 — Local notification scheduler & action handling** | Build `TaskReminderScheduler` (`UNUserNotificationCenter` reconcile with 50-item window, `septena.task.reminder` category, Complete / Snooze 15m / 1h / Tomorrow 9am background handlers, timezone/foreground/sync reconcile, suppress unacknowledged proposals, clean cancel on complete/delete/sync). Wire into `SeptaskLaunch.swift` (iOS + macOS delegates). | TR0 |
| **TR2 — Mac & iOS UI (progressive disclosure)** | Add collapsed "Add reminder" control & presets to Mac (`SeptaskKitDatePopover`, `SeptaskKitComposer`, `SeptaskKitInspector`, `SeptaskKitRowViews`) and iOS/iPadOS (`TaskPickerSheets`, `TaskComposer`, `TaskComponents`), lazy permission prompt + denied-permission banner, and `TaskUndo` wiring. | TR1 |
| **TR3 — Importer fidelity (Things & Reminders)** | Wire `ThingsImport` and `RemindersBridge` to map existing reminder times into `reminderAt` and surface unsupported alarm types cleanly. | TR0 |

## 9. Verification

- `node scripts/gen-registries.mjs --check` passes.
- `backend` typecheck (`tsc --noEmit`) + `conformance.test.ts` (including `reminders.json`) pass.
- `scripts/build.sh SeptenaMac 'platform=macOS'` and `scripts/build.sh SeptaskMac 'platform=macOS'` both green.
- Manual test by mz: set a 1-minute reminder on Mac and iPhone, verify notification fires, test Snooze 15m and Complete from banner, verify completion on one device clears the banner on the other, verify unacknowledged agent proposal does not fire.

## 10. Open questions

| Question | Default |
|---|---|
| Reminders per task in v1 | One reminder per task *(default)* |
| Default timezone mode | `"floating"` wall-clock time; `"fixed"` opt-in behind disclosure *(default)* |
| Coupling with `scheduled` date | Setting a reminder does not auto-set `scheduled`; moving `scheduled` shifts a same-day reminder along with it *(default)* |
| Unacknowledged agent proposals | Never arm OS notifications until the user accepts/files the proposal *(default)* |
| Notification interruption level | `.timeSensitive` on iOS/macOS when user explicitly sets a timed alert, falling back to `.active` if unavailable *(default)* |
| Notification snooze presets | 15 minutes, 1 hour, Tomorrow 9:00 *(default)* |
