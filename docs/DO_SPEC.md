# Do: one task now

Status: building (2026-11-25; D0 to D2 and the float of §4.2 are on `main`. Open: D3 to D8, see §10).
**Decision:** [ADR 0041](adr/0041-do-is-one-task-now-on-every-screen.md).
**Builds on:** [ADR 0006](adr/0006-tasks-fade-by-default.md) (no guilt, stuck
question), [ADR 0008](adr/0008-agent-loop-rules-live-in-the-store.md) (rules in
the store), [ADR 0025](adr/0025-shared-rust-core.md) (rules in the core),
[ADR 0028](adr/0028-registry-owns-vocabulary-platforms-own-interaction.md)
(registry), `docs/COMPANION_DEVICES_SPEC.md`, `docs/TASK_FADE_SPEC.md`.

Defaults marked *(default)* stand until mz overrules them in §11.

## 1. Goal

The user picks one task and starts. The list goes away on that device. Every
other screen shows, quietly, what the user does. The user leaves when the task
is done or when they stop, and the task remembers where they stopped.

| What the user needs | What Do does |
|---|---|
| A start that does not feel heavy | One tap. No setup. One question if the first step is not clear (§4) |
| A place for a stray thought | Quick Entry works during Do. The thought goes to the Inbox and Do goes on |
| A stop to reorganizing | No list, no timer settings, no cycles |
| Someone who notices | The orb and the notice show the task. They never nag |
| A way back | "Where you stopped" shows first the next time |
| No guilt | Leaving is an exit like any other (§3) |

**Not this:** a Pomodoro app, time tracking for billing, streaks, statistics,
app blocking, a calendar.

## 2. Data

One new synced entity, `doSession` (table `do_sessions`; `sessions` is the
sign-in table). The open row is the current Do. The closed rows are the
history. There is no second record.

| Field | Type | Meaning |
|---|---|---|
| `id` | id | Made by the client that starts it |
| `taskId` | id | The task |
| `startedAt` | stamp | Real time, with zone. Never after the store's clock |
| `plannedMinutes` | int 1 to 240, or nil | nil counts up. Can change during the Do |
| `confirmedAt` | stamp, or nil | The last "Still on it" (§2.2) |
| `endedAt` | stamp, or nil | nil while open. Never before `startedAt` |
| `exit` | `done` / `stopped` / `later` / `replaced` / `closed` | How it ended |
| `lapsed` | bool, default false | The length is unknown. Show no length |
| `note` | text, 500 characters, or nil | Where you stopped |
| `sourceClient` | text | The client that started it |

Contract work, in one change: `registry/entities.json`, `docs/IDENTIFIERS.md`,
the store columns, the pull flag (`doSessions=1`, because older builds decode
pulled entities strictly), and the JSON export and import. A session row is
deleted when its task is purged. Sessions are not the change log, so the plan's
history window does not apply to them *(default)*. They never enter analytics.

### 2.1 Rules

They live in `core/crates/septena-core` as one pure function over the rows, with
vectors in `registry/conformance/do-session.json`. The store runs it in the
same transaction as the write. A client runs it on its own rows, so Do works
offline and without an account. `resolve_do_sessions` takes the task status of
each row. A client that syncs uses the result for display and for its own
gestures, and leaves every other end to the store: in the middle of a pull it
may not have the task yet.

1. **One open.** The row with the latest `startedAt` may stay open (equal
   times: the greater id). Each earlier open row ends with exit `replaced` at
   the `startedAt` of the row that follows it, open or closed. If that is after
   the row was stale, `lapsed` is set. So a Do that was started offline and
   syncs late ends where the next one began.
2. **The earliest end wins.** If a closed row gets another end, the earlier
   `endedAt` stays, with its own exit. So the order in which offline devices
   sync does not change the result.
3. **An end names its row.** No verb means "end whatever is open".
4. **A closed row never opens again.** `note` can still change.
5. **The task decides.** When the task gets status `done`, its open row ends
   with exit `done`. When it is cancelled, deleted or faded, its open row ends
   with exit `closed`. This holds for every route: a checkbox in a list, the
   watch, Accept in Review, an older build that does not know Do.
6. **Undo does not resume.** Undoing the completion opens the task. The Do
   stays ended.
7. **The task must be open.** Headings and closed tasks cannot be done.

### 2.2 Stale

A Do is stale 4 hours *(default, `doStaleHours` in `registry/rules.json`)* after
the later of `startedAt` and `confirmedAt`, or at its planned end when that is
later. Stale is a read rule. Nothing runs when the limit passes.

- A stale Do has no notice, and the orb goes back to Today.
- Interruptions stop waiting (§6).
- The next device that opens asks once, in the notice slot: "Still on
  *title*?" with **Done**, **Stop for now** and **Still on it**. The first two
  set `lapsed`. The third sets `confirmedAt`.
- A new Do ends a stale one as `replaced` and sets `lapsed`.
- A Do that has been stale for 24 hours *(default, `doLapseHours`)* ends at its
  stale limit: exit `stopped`, `lapsed`. The store's daily job applies it.

### 2.3 What it does to the task

- A start stamps `touchedAt` through `TaskMutator.touch`, so it also resets
  `deferCount` (`docs/TASK_FADE_SPEC.md` §3). A faded task is kept. The REST verb
  does the same on the server.
- A start does not move the task, pin it to Today or accept an Inbox row
  *(default)*.
- **Stop for now** changes nothing on the task and counts no defer.
- **Later** opens the one When picker. Only a saved date ends the Do. The normal
  defer rule applies.
- Start and Stop for now are not on the undo stack. Done and Later use the
  existing actions, which are.

## 3. Words

Provisional. They go through `/house/language` and the humanizer before they
ship, and live in the registry.

| Word | Use |
|---|---|
| **Do** | The action, as a verb |
| **Doing** | The state and the notice |
| **Done** | The existing complete action |
| **Stop for now** | End without finishing. "Stop" alone already stops an agent on a task |
| **Later** | Opens When |
| **Do here** | On a notice: make this device the full one |

Do is one letter from Done. So Do has its own icon (never a checkmark), and the
two are never next to each other in a menu or a bar. Never: abandoned, failed,
broken, missed, streak, focus.

## 4. The Do screen

On the device where the user starts it, and on a device where they choose
**Do here**. The choice is local state. It ends with the Do, and it is not
synced.

| Part | Content |
|---|---|
| Last time | "Where you stopped" from the latest row with a note. Hidden if none |
| Title | Large. Not a text field until tapped |
| Checklist, notes, references, attachments | The task page blocks (`taskPage`), same renderers |
| First step | Only if the task has no notes, no checklist and no earlier note: "What is the first step?" It starts Discuss on this task. It never blocks the start |
| Time | Counts up, or down to the planned end. Tap to set: no length, 10, 25, 50 and the task's own duration if it has one |
| Exits | Done, Stop for now, Later |

- **Show the list** (Esc on the Mac, Back on Android) leaves the screen, not the
  Do. The device then shows the notice.
- Quick Entry and Quick Add work.
- The time is drawn from `startedAt` by the device. One minute is the smallest
  step shown *(default)*.
- When a planned length ends: one haptic and a local notification on the device
  with the Do screen, one pulse on the orb, nothing elsewhere. Then the time
  counts on. The time never turns red.
- After **Stop for now**: one optional field, "Where did you stop?". Closing it
  is fine.
- After any exit, if agent requests came in: one line, "N need you", that opens
  Review.

### 4.1 Starting

`task.do` in `registry/actions.json`, one selected open task: the row menu,
the task page, the Task menu, and ⌘J *(default)*. ⌘↩ is not free: on the Mac it
saves and closes the open row. Quick Entry gets **Add and Do** for work that is
not on the list yet. Starting while another Do is open replaces it without a
dialog.

### 4.2 Floating

When the user leaves the app on the device that shows the Do screen, the Do
floats: the title and the time, small, over the other apps. A tap returns to the
Do screen. There is no button and no setting. Other devices keep the notice.

| Platform | How |
|---|---|
| Android | Picture-in-picture, entered when the user leaves the app |
| iPhone, iPad | A local Live Activity (Lock Screen, Dynamic Island). It counts up, also with a length set. System picture-in-picture is for video. An end on another device clears it when the app next runs: the push is D5 |
| Mac | A small panel while Septena is not the active app. A drag moves it, a right click has the Do menu |

Show the list turns it off: the Do is then a notice here too.

## 5. The notice

Every signed-in device that does not show the Do screen.

| Surface | What it shows |
|---|---|
| iPhone, iPad, Android | One line at the top of every list: "Doing *title*" and the time |
| Mac | The same line at the top of every list, and a menu bar item while a Do is open. The menu bar item also shows on the Mac with the Do screen |
| Watch | One row at the top of Today and the complication. No takeover |
| Web, Windows | Built with the client's own first version of Do |
| Locked iPhone (D5) | Live Activity |

A tap offers Done, Stop for now, Later and Do here. The notice uses the notice
slot that exists (`surfaces.json` `notices`), with a kind that does not count as
an explainer. It has no pulse, no color change and no dismissal. The list works
as normal.

A device that is offline or asleep can show an old notice until it next pulls.
That is accepted.

## 6. Agents

- `tasks_orientation` and `tasks_list` show which task is being done
  (`doing: true`). `tasks_get` shows it too. `tasks_agent_events` gets `do_started` and `do_ended`, as
  pointers.
- `tasks_claim` on that task is refused with the new reason `doing`. A start
  ends a live claim, in the same transaction, with the reason "the user does
  this task". The store's other rules do not change.
- An agent write to `doSession` is refused. There is no MCP tool that starts,
  changes or ends a Do.
- Question pushes wait while a Do is open and not stale. The rows and counts
  do not wait. There is no catch-up push: the exit line (§4) and the Review
  count tell the user.
- The user's own timed reminders do not wait. They asked for them.
- **Propose (D7).** `tasks_propose_do` names one open task and one line of
  why. It shows in the notice slot: "Claude suggests *title*" with **Do** and
  **Not now**. One at a time, gone at the end of the day, no push. Refused while
  a Do is open, or while agents are paused.

## 7. Thin clients

`GET /v1/tasks` adds `doing` to every view: `sessionId`, `taskId`, `title`,
`startedAt`, `plannedMinutes`, `confirmedAt`, `staleAt` and the server's `now`, so a
device can correct its clock. No task notes.

| Verb | Effect |
|---|---|
| `POST /v1/tasks/:id/do` with `sessionId` and optional `plannedMinutes` | Start. The client makes the session id, so a retry starts nothing new |
| `POST /v1/tasks/do/:sessionId/stop` with optional `note` | Stop for now |
| `POST /v1/tasks/do/:sessionId/confirm` | Still on it |
| `complete` and the others | As today. They end the Do by rule 5 |
| `defer` with `session` | Later: the Do ends with exit `later` |

These routes are on the companion scope's list when CD2 (#358) builds it. Each
one needs a deliberate gesture on the device (ADR 0034). The watch queues them
offline like its other verbs.

### 7.1 The orb

| | During a Do |
|---|---|
| Face | The title in the middle, the time under it. The ring is the timer: it empties over a planned length, or fills once an hour when counting up *(default)* |
| Hold the middle | Done |
| Tap the middle | Two choices: Stop for now, Keep going |
| BOOT | Today, Week and Review as now. After 20 s it returns to the task, not to Today |
| A hand-off or question | Only the count changes. No pulse, no card |
| A task added or done | No card |
| A planned length ends | One pulse, not at night |
| Night | Dim, as now |
| Start | Tap the middle of an open task. This replaces the local pin |

When the Do ends anywhere, the orb returns to the Today ring. A pin that is
stored at the update is dropped; it does not start a Do.

## 8. History

- The task page `history` block shows each session: day, length, exit, note. A
  lapsed session shows no length.
- Review's done-first week (#56) gets "Worked on, not finished": tasks
  with a session this week that are still open. No minutes and no totals.
- An agent reads a task's sessions through `tasks_history`.

## 9. Plans

Do is in every plan on one device, with no account. Notices on other devices
need sync, so several devices need Plus (ADR 0023). The watch and the orb take
no slot. No new limit.

## 10. Phases

| Phase | What | Needs | Issue |
|---|---|---|---|
| D0 | Core rules, conformance vectors, registry (entity, rule, action, capability) | none | #515 |
| D1 | Store: entity, rules, claim refusal, held pushes, REST verbs, MCP reads, export | D0 | #516 |
| D2 | iPhone, iPad, Mac and Android together: start, Do screen, notice, Mac menu bar, history block, Add and Do | D1 | #517 |
| D3 | Watch: row, complication, verbs | D1 | #518 |
| D4 | Orb: Do replaces the pin | D1 | tinyseptena#18 |
| D5 | Locked iPhone: Live Activity with push updates; Siri and Shortcuts (Do, Stop for now, What am I doing) | D2, the APNs key (#38) | #519 |
| D6 | Review: "Worked on, not finished" | D2, the done-first week (#56) | #520 |
| D7 | An agent proposes a Do | D2 | #521 |
| D8 | Web client | D1, the web client (#21) | #522 |

D2 to D4 can run in parallel after D1. Windows (#136) takes Do from the Android
code.

## 11. Open questions

Decided by mz on 2026-11-25: full on one device and a notice on the others, the
orb takes over, the timer counts up, agents may only propose, the name is Do.

Collected for mz in #523.

| Question | Default |
|---|---|
| Shortcut | ⌘J (⌘↩ is taken in the Mac editor) |
| Name of the exit that does not finish | Stop for now ("Stop" stops an agent) |
| Does a start pin the task to Today? | No |
| When is a Do stale? | After 4 hours |
| When does the store end a forgotten Do? | After 24 hours stale |
| Lengths offered | 10, 25, 50, and the task's own duration |
| Does the length stick to the next Do? | No. Every Do starts by counting up |
| Seconds on the timer? | No |
| Orb ring when counting up | One turn an hour |
| Do timed reminders wait during a Do? | No |
| Ongoing notification on Android | Not in the first version |
| Milestone | M5 Breadth, not labelled `ready-for-agent` |
