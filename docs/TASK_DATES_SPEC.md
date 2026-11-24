# Task dates spec

**Status:** accepted (2026-11-23) · **ADR:** [0027](adr/0027-task-date-rules-are-core-actions.md),
built on [0025](adr/0025-shared-rust-core.md) · **Issues:** D1 #288, D2 #289, D3 #290, D4 #291, D5 #292

This spec defines what a task's date fields mean, what every user action does
to them, and how each surface reads them. It is the single reference for
When, deadline, Today, overdue, Upcoming and Anytime. Code that disagrees with
it is a bug. Rules marked **(Q)** rest on a decision mz made on 2026-11-23
(§8).

## 1. Goal

- One action gives one result on every platform: iOS, Mac, watch, widgets,
  MCP, REST, Android, web.
- The rules exist once, in the Rust core. Every platform runs the same
  conformance fixtures.
- A user never sees a date stay after they cleared it. A task never shows in
  a list that its fields do not put it in.

## 2. Fields

| Field | Type | Meaning |
|---|---|---|
| `scheduled` | day `YYYY-MM-DD` or nil | **When.** The day the user plans to start. A plan, never a commitment. A past When never turns red. |
| `deadline` | day or nil | **Deadline.** The day the task must be done. The only field that can make a task overdue. |
| `today` | bool | **Today pin.** The user put the task on Today by hand. |
| `todaySetOn` | day or nil | The day the pin was set. Drives days on Today. |
| `todayPosition` | number or nil | Manual order inside Today. |
| `startTime`, `durationMinutes`, `timeZone` | time slot | A time on the task's day. |
| `reminderAt` (+ snooze, dismissed) | instant | A notification. Its own date-time, separate from When. |
| `recurrenceAnchorDate` | day or nil | The logical slot of a fixed repeat. Owned by the recurrence rules. |

Terms used below:

- **T** is the user's current day (§6).
- **active** = `status == open` and not a heading and not deleted and not
  faded.
- **arrived** describes a date that is on or before T.

## 3. Invariants

Every write leaves the fields in a state that meets these invariants. The
core normalises each patch to them. The fixtures check each action against
them. A reader that meets a row that breaks them (old data, a bad sync) still
renders it with the read rules in §5. It does not crash and does not
"repair" the row on read.

- **I1. Pin and When are exclusive.** If `today == true`, then
  `scheduled == nil`. Putting a task on Today replaces its When date, and a
  future When removes the pin. Today a pinned row with a future When shows on
  Today and in Upcoming at the same time.
- **I2. `todaySetOn` follows the pin.** `todaySetOn != nil` exactly when
  `today == true`. It is stamped only on the change false → true. A second pin
  of a pinned row keeps the old stamp. Today the backend and Android re-stamp
  it on every pin, which resets days on Today.
- **I3. Days are valid calendar days.** Every stored day is a valid
  `YYYY-MM-DD` date. Writes reject an invalid day such as `2026-02-30` at the
  boundary. Readers ignore an invalid day as if it were nil (the core's
  `Day::parse`).
- **I4. No empty strings.** A cleared day is stored as nil, never `""`.
- **I5. The deadline is independent of When.** No When action changes the
  deadline. Only the actions that say so in §4 touch it.
- **I6. A time slot needs a day.** If `startTime != nil`, the task has a
  When date or is on Today (pinned or held there by an arrived date). An action
  that removes the day also removes the time slot.
- **I7. Clearing a start time clears the slot.** `startTime == nil` implies
  `durationMinutes == nil` and `timeZone == nil`.

## 4. Actions

These are the only ways a user or an agent changes date fields. Each action
is one core function and one mutator method on every platform. A shell calls
the action, never the field setters. Every action except A10 also clears the
agent cue (`acknowledge`).

| ID | Action | Triggers (all surfaces) | `scheduled` | `deadline` | pin | time slot | reminder |
|---|---|---|---|---|---|---|---|
| A1 | **Put on Today** | When ▸ Today, Move to Today, Toggle Today (on), drop on Today, quick tray, MCP `tasks_move_to_today`, REST `today`, watch `today` | nil (after the recurrence slot is recorded) | unchanged | set (I2) | unchanged | shifts to T if it was on the old When day |
| A2 | **Schedule for a day D** (D > T) | When ▸ date / Tomorrow / This Weekend, drop on Upcoming, defer, MCP `tasks_defer` / `tasks_update scheduled`, REST `tomorrow` / `defer` | D (fixed repeat: mode from the prompt) | unchanged **(Q1)** | removed | unchanged | shifts with When (`shiftReminderOnReschedule`) |
| A3 | **Remove from Today** | Toggle Today (off), swipe, context menu, REST `untoday`, watch `untoday`, MCP `tasks_update today:false` | nil if arrived | nil if arrived **(Q2)** | removed | removed if no day remains (I6) | unchanged |
| A4 | **Toggle Today** | ⌘T, row pill, swipe | A3 if the task is on Today (§5 R2), else A1. Reads `isOnToday`, never the raw pin. | | | | |
| A5 | **Clear the When date** | When ▸ No Date / Clear (Anytime), composer clear, MCP `tasks_update scheduled:null` | nil | unchanged | removed | removed (I6) | unchanged |
| A6 | **Clear When** (`task.clearSchedule`) | context menu ▸ Schedule ▸ Clear When, ⌘⇧., drop on Anytime **(Q6)** | nil | nil | removed | removed **(Q5)** | unchanged |
| A7 | **Set deadline D** | Deadline picker, MCP `deadline`, import | unchanged | D | see rule below | unchanged | unchanged |
| A8 | **Clear deadline** | Deadline ▸ Clear, MCP `deadline:null` | unchanged | nil | see rule below | unchanged | unchanged |
| A9 | **Set a time slot** | time picker, composer, MCP `start_time` | unchanged | unchanged | set if the task has no When date and is not pinned | set (I7 on clear) | unchanged |
| A10 | **Complete / cancel** | checkbox, ⌘K, widget, notification, watch, MCP | unchanged | unchanged | unchanged | unchanged | unchanged. A repeat spawns its next row (below). |
| A11 | **File from the triage band** | move to area / project / list while the row is in the triage band | unchanged | unchanged | set | unchanged | unchanged |
| A12 | **Create** | composer, quick entry, share sheet, Magic Plus, MCP `tasks_create`, REST `POST`, import | as given, then normalised by I1–I7 | as given | as given, stamped (I2) | as given | as given |

**Rules for the actions above:**

- **A day D ≤ T in A2 is A1.** Picking today or a past day in a When picker
  puts the task on Today. It never stores a past When.
- **The deadline keep-on-Today rule (A7, A8).** If the task is on Today only
  because of its old deadline (no pin, no arrived When), and the new deadline
  does not hold it there, the action pins it. A row on Today does not vanish
  because its deadline moved. A6 runs this rule and then removes the pin, so
  Clear When always ends in Anytime.
- **The fixed-repeat prompt.** A2 and A1 on a fixed repeating task ask "this
  occurrence or the whole series". The answer is an input to the action
  (`RecurrenceRescheduleMode`). Every surface that triggers A1 or A2 asks; no
  surface picks a mode silently. Today the Mac composer pill, the Inspector and
  the iOS row actions skip the prompt.
- **The next occurrence (A10).** The new row gets `scheduled = next`,
  `deadline = nil`, no pin, `created = T`, the same time slot, and the
  reminder shifted by `shiftReminderForRecurrence`. Android does not spawn
  today; it must.
- **Undo.** The shell records one snapshot of all date fields before the
  action and one undo entry after it. The mutator never records undo
  (AGENTS.md, "Undo is ONE shared stack").

## 5. Read model

The core's `taskViewMembership(task, T, now)` returns every value below. No
platform derives them itself.

- **R1 active.** `status == open` and not a heading, not deleted, not faded.
- **R2 on Today.** active, and (`today` or `scheduled ≤ T` or
  `deadline ≤ T`).
- **R3 due state.** `overdue` if `deadline < T`; `dueToday` if
  `deadline == T`; else none. Only open tasks have a due state. **(Q4)**
- **R4 red.** The deadline renders red when the due state is `overdue` or
  `dueToday`. A When date never renders red.
- **R5 Upcoming.** active, not on Today, and (`scheduled > T` or
  `deadline > T`). A task is never on Today and in Upcoming at once **(Q3)**.
  Its Upcoming day is the earlier of its future dates.
- **R6 Anytime.** active, no pin, no `scheduled`, no `deadline`.
- **R7 Today view.** on Today, or in the triage band. The Inbox band is the
  triage band plus the Inbox rows that are on Today
  ([Inbox is a band on Today](TRIAGE_BAND_SPEC.md)).
- **R8 arrived on its own.** active, not pinned, created before T, not an
  agent row, and `scheduled == T` or `deadline == T`: the task landed on
  Today this morning by its date, not by hand. One rule for the row's arrived
  dot and the "rolled into Today" notice (decision Q7). It clears itself the
  next day. Before D2, the notice counted `scheduled < T` instead.
- **R9 days on Today.** The earliest of `todaySetOn` (if pinned), an arrived
  `scheduled`, an arrived `deadline`; floored at `created`; T minus that day.
  0 when not on Today or when the agent cue shows.
- **R10 counts.** Every badge and sidebar count is a count of rows that match
  R2, R5, R6 or R7. A count never uses its own predicate.

## 6. The current day (T)

- **Apple.** T comes from one function, the app clock (`DayClock`), which
  honours DEBUG time travel. Today some reads use `SeptenaDate.today` (no time
  travel), some use `DayClock.appToday`, and two row labels use
  `Calendar.isDateInToday` (the wall clock). All of them move to the app clock,
  for reads and writes.
- **Backend.** T comes from one resolver: the request's
  `X-Septena-TimeZone` header, then the account's `homeTimezone`, then UTC.
  MCP, REST and iCal all use it. Today MCP falls back to the grant time zone
  and iCal ignores the header.
- **Android.** The device time zone, through `DayClock`.
- **Core.** The core never reads a clock. The host passes T and now.
- All day comparisons in the core use parsed `Day` values, never string
  compares.

## 7. Audit (2026-11-23)

The drift that the work in §9 removes. File references are from the audit and
can move.

**Writes**

| # | Drift | Where |
|---|---|---|
| W1 | Pick a future When: iOS keeps an overdue deadline; Mac deletes it (`removeFromToday`). | `TaskListView.applyScheduledWhen`, `TaskRowActions.applyWhen` vs `SeptaskKitTaskList` ⌘S popover, pill, Inspector, Upcoming drop |
| W2 | When ▸ Today: Mac pill and Inspector pin without clearing an old When; iOS row actions skip the repeat prompt and the reminder shift. | `SeptaskKitTaskList`, `SeptaskKitInspector`, `TaskRowActions` |
| W3 | When ▸ Clear: iOS keeps the deadline; Mac deletes an overdue one. | iOS `applyWhen(nil)` vs Mac `DatePopover` |
| W4 | Mac ⌘T and the row pill branch on the raw pin. On a row due today the menu says "Remove from Today" and the action pins it. | `SeptaskKitTaskList.toggleTodaySelection` |
| W5 | The composer unpins with `removeFromToday`, so saving a draft can delete an overdue deadline. | `TaskDraft.update` |
| W6 | Remove from Today: REST `untoday` and Apple clear arrived dates; MCP `today:false` and Android do not. | `tasksRest.ts`, `writeTasks.ts`, `TaskMutator.kt` |
| W7 | A future When on a pinned row: `tasks_defer` unpins; MCP `tasks_update scheduled`, Android `schedule` keep the pin (breaks I1). | `writes.ts`, `TaskMutator.kt` |
| W8 | `todaySetOn` re-stamped on every pin (backend, Android); stamped once (Apple). | `writes.ts`, `TaskMutator.kt` |
| W9 | Deadline change auto-pins on Apple only. | `TasksBackend.setDeadline` |
| W10 | Drop on Today: iOS sidebar does not acknowledge; Mac does. | `SidebarView`, `SeptaskKitSidebar` |
| W11 | JSON restore writes fields raw, without normalisation. | `SeptaskDataTransfer` |
| W12 | Android completes a repeating task without spawning the next row. | `TaskMutator.kt` |
| W13 | Reschedule clears reminder snooze and dismissed on backend and Apple, not on Android. | `TaskMutator.kt` |
| W14 | Recurrence spawn uses `DayClock.appToday`; reads use `SeptenaDate.today`. | `TasksBackend` |

**Reads**

| # | Drift | Where |
|---|---|---|
| R-a | Backend "on Today" does not exclude faded tasks; `writes.ts onToday` checks no status at all. | `taskShared.ts`, `writes.ts` |
| R-b | Overdue: app `<=`, watch `<` plus a separate "due today", widget `<` / `==`. Seven copies. | `Models.swift`, `Persistence.swift`, `TasksWatchWire.swift`, `TasksWidgetBuilder.swift`, `TaskComponents.swift`, `SeptaskKitTaskList` ×2 |
| R-c | `isOverdue` has no faded / deleted check; `overdueCount` has one. | `Models.swift`, `Persistence.swift` |
| R-d | Upcoming includes rows that are also on Today. | `Persistence.swift`, `views.rs`, `taskShared.ts` |
| R-e | Rolled in (`scheduled < T`) and arrived today (`scheduled == T` or `deadline == T`) are two different definitions of one idea. | `TaskNotices.swift`, `Models.swift` |
| R-f | Raw pin read as "on Today" in the Mac composer, filing suggestions and QuickFind. | `SeptaskKitComposer`, `TaskFilingSuggestions`, `QuickFindView` |
| R-g | Widget Upcoming subtitle shows a past When date. | `TasksWidgetBuilder.swift` |
| R-h | String compares in TypeScript and `fade.rs`; an invalid day passes TS and fails Rust. | `taskShared.ts`, `recurrence.ts`, `reminders.ts`, `fade.rs` |
| R-i | Five copies of "on Today", none on Apple or the backend calls the core. | — |

**Tests.** Fixtures cover view membership (9 cases), fade, recurrence and
reminders. No fixture covers an action. `task-views.json` has no deadline-only,
`scheduled == T`, deleted, faded, invalid-day or pin-plus-future-When case.

## 8. Decisions

mz answered each question on 2026-11-23. Every answer was the proposed default.

| # | Question | Decision | Why |
|---|---|---|---|
| Q1 | A future When on a task with an overdue deadline: keep the deadline (task stays on Today, red) or delete it? | Keep | A deadline is a commitment. Moving the plan does not move the commitment. This is iOS and Things behaviour. |
| Q2 | Remove from Today on a task with an overdue deadline: delete the deadline, or refuse? | Delete it (current Apple + REST) | Otherwise "Remove from Today" cannot remove the task. The undo entry restores it. |
| Q3 | A task on Today with a future deadline: also show it in Upcoming? | No | One task, one place. |
| Q4 | Due today: red, labelled "Today"; earlier: red, labelled "Overdue"? | Yes | The watch and widget already split the two; the app colours both red. |
| Q5 | Clear When also removes the time slot? | Yes | A time with no day has no meaning (I6). |
| Q6 | Drop on Anytime: Clear When (A6, removes the deadline) or Clear the When date (A5)? | A6 | A drop on Anytime must land in Anytime. The registry already says `clearDates`. |
| Q7 | One "arrived on its own" cue (R8), or keep the rolled-in banner and the arrived dot separate? | One | Two definitions of one idea drift. |

## 9. Phases

**D1 defaults** (recorded 2026-11-23, #288; mz can overrule):

- A heading or a deleted task has no dates to change: every action returns
  an empty patch.
- A11 on a task with a future When date keeps the date. Otherwise A11 is A1.
- A12 does not clear the agent cue: a new agent row is a proposal. The core
  has `normalize_task_dates` for A12 and for restore (W11).
- A1 or A2 on a fixed repeat, "this occurrence": the old When date becomes
  `recurrenceAnchorDate` when none is set. "The whole series": the new day
  becomes the slot. The host still rebases the other open copies.
- R3 gives a due state only to active tasks.
- R8 reads the `created` day. A task without one has not arrived on its own.
- A stored invalid day becomes nil on the next write. A day passed into an
  action that is not valid is an error.

| Phase | Scope | Done when | Depends on |
|---|---|---|---|
| D0 | This spec and ADR 0027. mz answers §8. | Done 2026-11-23. | — |
| D1 Core | `septena-core` gets `task_dates`: the actions of §4 as `(snapshot, action, T) → patch`, the invariants of §3 as a normaliser, R3/R4/R5/R8 added to `taskViewMembership`. New fixtures `registry/conformance/task-dates.json` (every action × every starting state that matters) and the missing `task-views.json` cases. Release a core tag. | Fixtures pass in Rust, Swift, JVM and WASM harnesses. | D0 |
| D2 Apple fixes now | Fix W4 (⌘T), W5, W10 and R-b..R-g in Swift without waiting for the core link, each pinned by a Swift test against the D1 fixtures. | The listed drifts are gone on iOS and Mac. | D0 |
| D3 Apple on the core | `TaskMutator` gets one method per action and calls the core for the patch. Every shell call site (W1–W3) calls the action. `isOnToday`, `isOverdue`, Upcoming and rolled-in copies are deleted in favour of the core's membership. A lint rule fails a shell file that calls `schedule`, `reschedule`, `setDeadline`, `moveToToday` or `removeFromToday` directly. Watch and widgets read the same values. | No date rule left in Swift outside the core bridge. | D1, ADR 0025 C4 |

**D3 status (2026-11-24).** The write half is done: `TaskMutator.apply(_:to:mode:)` asks the core (0.3.0, `applyDateAction`) for the patch and `CloudKitTasksBackend.applyDateAction` (`TasksBackend+DateActions.swift`) writes the changed fields in one save. A whole-series move then rebases the other open copies of a fixed repeat in Swift, because the core sees one row. The lint rule is `date-setter-in-shell`. Still open: the read half (`isOnToday`, `isOverdue`, Upcoming, rolled-in) waits on the C4 list-membership measurement (#250), and T still comes from `SeptenaDate.today` for reads and writes alike until that step moves both to `DayClock`.
| D4 Backend | MCP tools, REST verbs and iCal call the core's actions and membership through WASM (or a TS port that passes the same fixtures, if C3 measures WASM as too heavy). Fixes W6–W8, R-a, R-h, and the T resolver of §6. | `backend/test/conformance.test.ts` runs `task-dates.json`. | D1, ADR 0025 C3 |
| D5 Android | `TaskMutator.kt` calls the core's actions; `TaskViewRules` is deleted. Fixes W12, W13. | `RegistryConformanceTest` runs `task-dates.json`. | D1, ADR 0025 C1 |

MCP tool changes in D4 land in both MCP servers and their skills in the same
change (AGENTS.md, "Two MCP servers").
