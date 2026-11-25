# Task app widgets (Today & Upcoming) — spec

**Status:** shipped — historical (2026-11-22, #160 and #161).
**Decisions:** [ADR 0002](adr/0002-own-backend-replaces-icloud.md), [ADR 0007](adr/0007-septena-is-the-task-app.md), [ADR 0015](adr/0015-shared-registries-for-cross-platform-clients.md).
**Builds on:** `SeptenaCore/TasksWidgetBuilder.swift`, `SeptenaCore/TasksWidgetSnapshotStore.swift`, `SeptenaCore/TasksWidgetWire.swift`, `SeptenaCore/SeptenaAppGroup.swift`, `SeptenaCore/Outbox.swift`, `project.yml`.
**Tracking issue:** [#129](https://github.com/michellzappa/septena/issues/129).
**Owner of decisions:** mz. Defaults chosen by the author are marked *(default)*.

## 1. Goal

Bring calm, interactive Home Screen, Lock Screen, and macOS Desktop/Notification Center widgets to Septena (the task app). Today `SeptenaWidgets` ships only in Septena Life; `Septask` and `SeptaskMac` embed no widget extension.

**UX / IA ideal (progressive disclosure):** Zero-config default shows **Today** (clean task list + interactive checkboxes + Quick Add tap target). Long-pressing `"Edit Widget"` reveals an optional list selector (`Today`, `Upcoming`, `Inbox`, `Starred`, or any `Project` / `Area`).

## 2. Data transport (no CloudKit)

- Reuse `TasksWidgetSnapshotStore` + `TasksWidgetWire` inside Septask's App Group container (verify group ID in `Septask.entitlements` / `SeptaskMac.entitlements` — do not share Septena Life's container where bundle boundaries differ).
- Publish a fresh JSON snapshot whenever:
  1. Any `TaskMutator` write commits locally.
  2. `TaskSyncClient` applies a backend pull.
  3. Foreground/midnight rollover runs (`DayClock`).
- Call `WidgetCenter.shared.reloadTimelines(ofKind: "SeptaskTasksWidget")` after writing the snapshot.
- **Interactive completion (`CompleteTaskWidgetIntent`):**
  - AppIntent runs in the extension/app process, awaits `SeptenaServices.shared.start()`, calls `TaskMutator.complete(id:)` (which updates SwiftData + queues the backend outbox op), refreshes the snapshot, and returns immediately so the widget updates in-place without launching the app.
- **Privacy / App Lock:** If App Lock is enabled, render task count only (`"5 tasks today"`) with titles redacted *(default)*.

## 3. Widget families & layout

| Family | Surface | Content |
|---|---|---|
| `systemSmall` | iOS / iPadOS / macOS | List header + open count + top 3 tasks (tap to open) + Quick Add (`septask://quick-add`) |
| `systemMedium` | iOS / iPadOS / macOS | Header + Quick Add button + up to 4 interactive checkable rows |
| `systemLarge` | iOS / iPadOS / macOS | Header + Quick Add button + up to 9 interactive checkable rows (with subtle area/project or deadline meta) |
| `accessoryRectangular` | iOS Lock Screen | Top 2–3 Today tasks |
| `accessoryCircular` / `accessoryInline` | iOS Lock Screen | Today remaining count gauge / `"4 tasks today"` |

## 4. Target & build notes (`project.yml`)

- Add `SeptaskWidgets` (iOS) and `SeptaskMacWidgets` (macOS) extension targets in `project.yml`, embedded into `Septask` and `SeptaskMac` respectively, sharing `CURRENT_PROJECT_VERSION` / `MARKETING_VERSION` from `Config/Base.xcconfig` (`CLAUDE.md` version consistency invariant).
- **Factory build note:** The macOS widget extension builds cleanly under `scripts/build.sh SeptaskMac 'platform=macOS'`; verifying the iOS widget extension requires Xcode.app or a matching watchOS runtime when `Septask` embeds watch.

## 5. Phases

| Phase | Scope | Depends on |
|---|---|---|
| **WG0 — Snapshot publisher & interactive completion intent** | Wire `TasksWidgetSnapshotStore` publishing into `Septask` / `SeptaskMac` mutator & sync paths, add `CompleteTaskWidgetIntent` and `SeptaskWidgetConfigurationIntent` (default Today; optional list/project/area picker), and redact when App Lock is enabled. | None |
| **WG1 — WidgetKit views & XcodeGen targets** | Add `SeptaskWidgets` and `SeptaskMacWidgets` targets in `project.yml` + entitlements, implement Small/Medium/Large/Lock Screen views matching `docs/DesignSpec.md` (light, dark, tinted, Dynamic Type), run `xcodegen generate`, and verify `SeptaskMac` builds green. | WG0 |

## 6. Verification

- `xcodegen generate` clean; `scripts/build.sh SeptaskMac 'platform=macOS'` and `SeptenaMac` green.
- Manual test by mz on Mac and iPhone: add Today widget, check off a task from the widget without opening the app, verify sync to other device, tap Quick Add deep link, verify Lock Screen count updates at midnight.

## 7. Open questions

| Question | Default |
|---|---|
| Default widget list | `Today` *(default)* |
| App Lock behavior | Show count only; hide task titles on Home/Lock Screen when App Lock is on *(default)* |
| Inbox band items in Today widget | Included at top of Today count (matches Today badge semantics) *(default)* |
