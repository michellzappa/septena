# Septena for Apple Watch

The watch app (`SeptaskWatch` + `SeptaskWatchComplication`, ships as
"Septena") is a **thin client of the task backend**. It has no task store and
compiles no task model: it reads ready-made views and sends verbs.

## Architecture

```
iPhone (Septask)  ──WatchConnectivity──▶  Watch
   │  mints a watch session                │  GET  /v1/tasks?view=today|upcoming|anytime
   │  pushes Today as app context          │  POST /v1/tasks            (create)
   ▼                                       │  POST /v1/tasks/:id/:verb  (complete, today,
api.septena.app  ◀─────────────────────────┘        untoday, tomorrow, defer, cancel)
```

- **Views and verbs run the MCP tools' code** (`backend/src/api/tasksRest.ts`
  → `listTasks`, `runWriteTool`). Today on the wrist, in Claude and on the
  phone use the same rules (`tools/taskShared.ts`, mirrored from
  `SeptenaCore`). Writes are credited `app:septask-watch`, never the agent.
- **Own session.** Refresh tokens are single-use and rotate, so the watch
  can't share the phone's. The phone calls `POST /v1/auth/device` and hands
  the new session over with `transferUserInfo` (`Septask/WatchBridge.swift`).
  This happens when the watch asks (`requestSession`) and once per account
  when a watch app is installed. An unused handoff expires after 7 days, and
  the watch ends the session a new handoff replaces. Sign-out / account switch sends `signedOut`;
  the watch revokes its token and wipes its cache.
- **Instant first frame.** After every task change (2 s debounce) the phone
  pushes Today (`WatchTaskList`) as application context. The watch draws it
  until its own fetch returns.
- **Offline.** Every change applies on screen first, then waits in a
  persisted queue (`WatchStore.queue`, `Application Support/Watch/`).
  Removals wait out a 3.5 s Undo window before they're queued, so Undo
  needs no server call. 404 drops a change; 422 drops it and shows the reason.
- Wire types: `SeptenaCore/TasksWatchWire.swift` (Foundation only).

## UX / IA

- **Today (root).** Inbox section, then the rest of Today, in the phone's
  order. The circle completes (with haptic and an Undo toast); the row opens
  the detail. Swipe right = Complete; swipe left = Tomorrow / Remove from
  Today. Footer: last sync, offline, waiting changes.
- **Detail.** Title, due / scheduled / time / repeat / checklist, notes.
  Complete (big, double-tap gesture), Tomorrow, Remove from Today (or Today,
  from other lists), Cancel Task (confirmed).
- **Capture (+).** `TextFieldLink`: dictation / Scribble opens at once, then
  one tap picks **Inbox** (default, double-tap) · Today · Tomorrow.
- **Lists.** Upcoming (grouped by day) and Anytime (undated backlog; swipe
  left = Today). **Sync** shows connection, last sync, queue, last error,
  Sync Now, and in DEBUG a *Sample data* toggle.
- **Complications.** Circular (count), rectangular (count + next two),
  corner (glyph + "n left"), inline (count + next). They show "All clear" or
  "Open Septena" when there's nothing to show.

Not on the watch, on purpose: areas / projects drill-down, editing titles,
reordering, notes editing, checklists.

## Testing

- Simulator without signing in: the not-connected screen offers *Use
  Sample Data* (DEBUG), also under Lists ▸ Sync. Changes stick locally and
  nothing leaves the watch.
- On device: sign in on the iPhone, open the watch app; it connects within
  a few seconds (Lists ▸ Sync shows "Connected").
- Backend: `cd backend && npm test` (`test/tasksRest.test.ts`). The REST
  surface needs a deploy before the watch can use it.
