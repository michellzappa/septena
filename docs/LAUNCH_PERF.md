# Launch performance (Septena task app, iOS)

Status: active. Issues #80 (measure), #81 (draw Today first), #82 (launch
screen, Today snapshot, skeleton rows).

**Target:** under **400 ms** from tap to a real Today list on iPhone Air,
cold launch, Release build.

## Signposts

All launch signposts are always on, in Release too (`LaunchTrace` in
`SeptenaCore/Logging.swift`). Subsystem `com.septena.cloud`, category
`Launch`. Each one also logs one info line with its time since the kernel
created the process.

| Name | Kind | Where | What it marks |
|---|---|---|---|
| `launch.localStoreOpen` | interval | `LocalStore.init` (`Persistence.swift`) | SwiftData `ModelContainer` open |
| `launch.appInit` | event | `SeptaskApp.init` | App struct created (after the store opened) |
| `launch.firstTodayBody` | event | `TaskListView.body` | First Today body evaluation |
| `launch.snapshotUsed` | event | `TodaySnapshotStore.launchRows` (`TodaySnapshot.swift`) | Today read its rows from the launch snapshot (absent: no usable snapshot) |
| `launch.todayLoadDone` | event | `TaskListView.performLoad` | First Today `load()` published its rows |
| `launch.firstFrameDrawn` | event | `LaunchPhase` (`SeptenaServices.swift`) | One frame after the first rows (or the 1.5 s timeout); deferred launch work starts here |
| `start.bindMutators` | interval | `SeptenaServices.bindWriteBoundary()` | Mutator binding, the write boundary; runs before the first frame |
| `launch.servicesStart` | interval | `SeptenaServices.start()` | The whole services start, first caller only |
| `start.backfillSectionOnboarding` | interval | `start()` | Legacy section backfill |
| `start.seedSyncedSettings` | interval | `start()` (Septask) | Synced settings seed |
| `start.taskSyncStart` | interval | `start()` | `TaskSyncEngine.start()` (store open, first sync scheduled) |
| `start.ckEngineStart` | interval | `start()` (Septena Life only) | CKEngine start |
| `launch.deferredWork` | interval | `SeptaskLaunch.run` | Capture import, legacy cleanup, diagnostics, badge |
| `sync.firstPull` | interval | `TaskSyncEngine.runSync` | The first backend pull of the process |

Real-use numbers come from MetricKit (`SeptaskLaunchMetrics` in
`Septask/SeptaskLaunch.swift`, iOS only). The system delivers at most one
payload a day. Each payload logs a line `MetricKit launch: …` (time to first
draw, optimized time to first draw, resume time: count, p50, p90) to the
`Launch` category, and the last summary stays on the device in
`UserDefaults` key `septask.launchMetrics.lastSummary`. It is not sent
anywhere.

## What runs when (iOS cold launch)

Before the first Today frame, only this runs:

1. `LocalStore` open (SwiftData).
2. `SeptenaServices` init (mutators created) and `bindWriteBoundary()`
   (mutators bound, so a tap during the deferred start is safe).
3. `TaskListView` reads its rows from the local store (`LocalCache`).

After `LaunchPhase` reports the first frame (`launch.firstFrameDrawn`):

- `SeptenaServices.start()`: settings seed, `TaskSyncEngine.start()`
  (outbox open, reconcile, push, pull, socket, poll).
- `SeptaskLaunch.activate()`: `TaskSyncEngine.activate()`, fixed-schedule
  catch-up.
- Shared-capture import, legacy Claude cleanup, diagnostics, badge.
- `absorbRemoteChanges()` (utility priority): awaited sync, project graph
  repair, migrators, catch-up, 30-day trash purge.
- The abandoned-draft sweep.
- The Reminders inbox mirror and the calendar agenda on Today.

Every `TaskListView.load()` has two passes: the rows publish first; filing
suggestions and the calendar agenda follow one frame later.

Nothing awaits the network before the first frame, so a signed-out or
offline launch draws as fast as a signed-in one. App Intents still await
`SeptenaServices.start()` before they mutate.

The wait for the first frame is iOS-only. The macOS AppKit shell draws its
list without `TaskListView`, so on macOS the launch work runs as before.
The two-pass `load()`, the deferred Reminders mirror and the deferred
draft sweep apply on both platforms.

## Launch screen

The iOS launch screen (`UILaunchScreen` in `project.yml`, Septask target)
is blank: only the system background, `LaunchBackground` in
`Septask/Assets.xcassets` (white / black). It shows no glyph, so the first
frame replaces an empty screen, not a logo. Decided 2026-11-23; the glyph
launch screen and its render script were removed.

## Today snapshot

A cold launch draws its first Today frame without a SwiftData fetch
(`SeptenaCore/TodaySnapshot.swift`):

- **File:** `Application Support/TodaySnapshot.json`, excluded from
  backup. Versioned JSON: the day, the Today rows, the Inbox rows (full
  row DTOs, notes cut to 80 characters), and the areas and projects in
  sidebar order. At most 150 rows, a size guard only.
- **Writer:** `TodaySnapshotWriter`, iOS task app only, started with the
  deferred launch work. It rewrites the file 2 s after a burst of
  `.septenaTasksChanged` / `.septenaStructureChanged` posts and at day
  rollover. An empty Today removes the file. Signed out: no write.
- **Reader:** `TaskListView` on standalone Today, before its first
  `load()`, and only until `LaunchPhase` reports the first frame. The rows
  feed the same view, so the first `load()` swaps to the live rows with no
  layout change. The list ignores taps while it shows snapshot rows.
- **Invalidation:** sign-out, account switch and account delete remove the
  file (`TaskSyncEngine`). A snapshot from another day than
  `DayClock.today` is never used.
- **Still before the first frame:** the SwiftData store open
  (`launch.localStoreOpen`), Today's notices read, and the view itself.

## Skeleton rows

Today shows placeholder rows (`TaskSkeletonRows`) instead of an empty list
only while it has no rows and the account's first pull has not landed
(signed in, no pull yet, no sync error). Signed out, offline or an empty
account: the normal empty Today. Never a spinner on Today. The rows pulse
slowly; with Reduce Motion on they stay still.

## Record a cold launch

1. Build the `Septask` scheme in **Release** for the device (Product ▸
   Profile, ⌘I, builds Release by default).
2. In Instruments pick the **App Launch** template.
3. Before each run, kill the app and wait about 10 s, so the launch is cold.
4. Record. Stop once the Today list shows rows.
5. Read the `os_signpost` track for subsystem `com.septena.cloud`, category
   `Launch`. Tap to first frame is the App Launch lane; the signposts above
   split it.
6. Do 5 runs, note the median.

Without Instruments: `log stream --predicate 'subsystem ==
"com.septena.cloud" AND category == "Launch"' --level info` on a Mac with
the device attached (or Console.app with the device selected) shows each
signpost with its time since process start.

## Results

| Date | Build | Device | Tap → first frame | `launch.todayLoadDone` | `launch.servicesStart` | `sync.firstPull` | Notes |
|---|---|---|---|---|---|---|---|
| | | iPhone Air | | | | | baseline before #81 |
| | | iPhone Air | | | | | after #81 |

## Interaction performance (after launch)

Target: a tap (complete, move, reschedule, reorder) draws its result in the
next frame, like Things. Each task change posts `.septenaTasksChanged`. Then
the open list, the sidebar, the area page and the Mac shell each read the
store again on the main actor. So the cost of one tap is the sum of those
reads. Before `77c565d2`, most of them built a row object (`SeptenaTask`) for
every live task, logbook included. Each row object decodes the task's
conversation and recurrence JSON. The cost grew with the user's history.

### Rules

- **Pick tasks by id with `LocalCache.liveTasks(ids:in:)`.** Never call
  `allTasks` / `liveTasks(in:)` and then filter by id. Undo snapshots
  (`TaskUndo`, `TaskRowActions`), the attribute bar, a Mac move and a sidebar
  drop run on every gesture. The `whole-store-id-lookup` lint rule enforces
  this.
- **Count from entities, not row objects.** Badges and roll-ups read
  `LocalCache.liveAggregateEntities(in:)` (the same rows as `liveTasks`). Read
  the raw column before a JSON getter: `conversationJSON != nil` before
  `conversation`, `recurrenceUnit != nil` before `recurrence`.
- **Project rings come from `LocalCache.projectCompletionRatios`.**
  `ProjectProgressCache` memoizes the result until the next task, structure
  or data notification. Its observer runs on the posting thread, so the cache
  is stale for no reader. The aggregate fetches three columns only
  (`propertiesToFetch`).
- **Today and its triage band come from `LocalCache.todayAndTriage(in:)`,**
  one fetch of the open rows. The Mac "done today" block reads
  `LocalCache.tasksCompleted(onDay:in:)`, which pages the logbook
  newest-first and stops at the previous day.
- **No store read inside a view `body` or a view `init`.** SwiftUI runs both
  on every parent render. Read in `load()` into `@State`, or through a
  process-wide memo (`StructureCache`, `ProjectProgressCache`,
  `SidebarSeed`).
- **No `DateFormatter()` per call.** Use a static formatter
  (`SeptenaDate.monthDay`, `SeptenaDate.today`, which formats once a day).
- **Decoded conversations are cached by JSON text** (`TaskConvoDecodeCache`).
  An edit is a new key, so the cache never returns a stale decode.

### Not done yet

- Store reads still run on the main actor. A background `ModelContext` that
  builds the rows, with the main actor only applying them, is the next step.
  Measure first: add signposts around `TaskListView.performLoad` and
  `SeptaskKitTaskListController.reload`, then compare one Instruments run on
  real data before and after.
- `TaskReads.dashboardStats` and the sidebar roll-up each scan every live
  entity once per change. They could share one pass.
