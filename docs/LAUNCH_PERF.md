# Launch performance (Septena task app, iOS)

Status: active. Issues #80 (measure), #81 (draw Today first), and the launch
snapshot follow-up.

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
| `launch.todayLoadDone` | event | `TaskListView.performLoad` | First Today `load()` published its rows |
| `launch.servicesStart` | interval | `SeptenaServices.start()` | The whole services start, first caller only |
| `start.backfillSectionOnboarding` | interval | `start()` | Legacy section backfill |
| `start.seedSyncedSettings` | interval | `start()` (Septask) | Synced settings seed |
| `start.taskSyncStart` | interval | `start()` | `TaskSyncEngine.start()` (store open, first sync scheduled) |
| `start.ckEngineStart` | interval | `start()` (Septena Life only) | CKEngine start |
| `sync.firstPull` | interval | `TaskSyncEngine.runSync` | The first backend pull of the process |

Real-use numbers come from MetricKit (`SeptaskLaunchMetrics` in
`Septask/SeptaskLaunch.swift`, iOS only). The system delivers at most one
payload a day. Each payload logs a line `MetricKit launch: …` (time to first
draw, optimized time to first draw, resume time: count, p50, p90) to the
`Launch` category, and the last summary stays on the device in
`UserDefaults` key `septask.launchMetrics.lastSummary`. It is not sent
anywhere.

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
