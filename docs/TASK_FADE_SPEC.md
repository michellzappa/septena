# Task fade — spec

**Status:** accepted. Written and accepted 2026-11-19. Defaults marked *(default)* stand
until mz overrules them in §11.
**Decisions:** [ADR 0006](adr/0006-tasks-fade-by-default.md),
[ADR 0002](adr/0002-own-backend-replaces-icloud.md).
**Builds on:** the triage band (`docs/TRIAGE_BAND_SPEC.md`), the task
conversation loop (`SeptenaCore/TaskConvo.swift`,
`docs/TASK_CONVERSATIONS_PLAN.md`), the Next feed
(`SeptenaCore/NextBlocks.swift`), the on-device suggestion model
(`SeptenaCore/SuggestionEngine.swift`).

## 1. Goal

The task list stays short without effort from the user. Tasks the user does
not care about leave on their own. A task that sticks asks why, and the answer
leads to one action. Opening the app shows a small, fresh Today and what the
user got done.

## 2. What exists and what is missing

**Exists:**

- `TaskEntity`: `created`, `createdAt`, `scheduled`, `deadline`, `today`,
  `todaySetOn`, `completedAt`, status `open` / `done` / `cancelled`,
  recurrence fields, `conversationJSON`, `source`, `acknowledgedAt`.
- The Inbox band over Today (`isInTriageBand`). `.today` excludes band rows.
- Choice cards on a task (`TaskConvo`), and the ball-in-court dot.
- `assignee` (`me` / `local` / `claude`).
- One shared undo stack (`SeptenaCore/TaskUndo.swift`), recorded at the user
  gesture only.

**Missing:**

| Gap | Section |
|---|---|
| A user-touch timestamp (`updatedAt` moves on sync) | §3 |
| A count of how often a task was pushed later | §3 |
| A fade rule and a Faded pile | §4 |
| The weekly sweep | §5 |
| Carry-over prompt at day rollover | §6 |
| The stuck question | §7 |
| A done-first weekly view | §8 |
| An effort estimate and readiness-ordered Next | §9 |

## 3. Data

New fields on the task. All are backend fields (ADR 0002) and wire-contract
fields: add them to `docs/IDENTIFIERS.md` and to both MCP servers in the same
change (`CLAUDE.md`, "Two MCP servers").

| Field | Type | Meaning |
|---|---|---|
| `touchedAt` | `Date?` | Last user gesture on the task. nil on legacy rows: read as `createdAt`. |
| `deferCount` | `Int = 0` | Times the user pushed the task to a later day. Resets to 0 on any non-defer edit. |
| `fadedAt` | `Date?` | Set when the task fades. Cleared when the user keeps it. |
| `dropReason` | `String?` | `"faded"` when the sweep drops it, `"user"` for a manual drop. Set with status `cancelled`. |
| `effort` | `String?` | `"light"` / `"heavy"`. Set by the on-device model at capture or by the user. nil = unknown. |

The SwiftData `TaskEntity` gets the same fields with defaults (a new
non-optional attribute without a default breaks lightweight migration; see
the `recurrencePaused` comment in `Persistence.swift`).

**What stamps `touchedAt`.** Only a user gesture, in `TaskMutator`, at the
same call sites that record undo: open in the inspector, edit title or notes,
schedule, move, set Today, complete, answer a card. **Never** a sync apply,
recurrence spawn, the 30-day purge, an agent write, or the fade itself. A
helper `TaskMutator.touch(id:)` owns the stamp. Add a lint `scan` rule if a
second stamp site appears.

**What counts as a defer.** Setting `scheduled` to a later day than its
current value, removing a task from Today, or answering "not today" on a
carry-over row. Each adds 1 to `deferCount` and also stamps `touchedAt`.

## 4. Fading

A task fades when all of these are true:

- status is `open`, and it is not a heading;
- `now − (touchedAt ?? createdAt)` ≥ the fade window (14 days *(default)*);
- it has no `deadline`;
- its `scheduled` date is nil or in the past;
- it has no recurrence rule;
- its conversation is not on the agent's turn, and `assignee` is not `claude`.

A fading task gets `fadedAt = now`. It leaves every list, every count, Next
and the badge. It shows only in the Faded pile. The fade pass runs once per
day at rollover, on the device that runs first, and on the backend when the
backend owns the job (ADR 0002). It is idempotent: two devices can run it
with the same result.

**The visible fade (decided 2026-11-20).** The countdown shows on the whole
row: the checkbox, title, meta and trailing cluster lose opacity together, by
the same amount, as the task nears its fade, down to `TaskFade.minOpacity`
(0.55, readable), and at the end the task leaves the list. The checkbox never
tints and stays tappable. One
rule for both lists: `SeptenaCore/TaskFade.swift`. Shipped first on the
existing Today tenure clock (`todayTenureFill`, days carried on Today, full
at a week); P2 moves it to `touchedAt` against the fade window in every list.
Touching the task restores full strength.

**The Faded pile.** A sidebar smart list, "Faded", with a count. Rows are
standard task rows. Opening or editing a faded task keeps it (clears
`fadedAt`, stamps `touchedAt`).

The fade is not a user gesture, so it is not on the undo stack. Keeping a
task from the pile is a gesture and is on the undo stack.

## 5. The weekly sweep

Once a week (Sunday *(default)*), the Inbox band shows one row: "N tasks
faded this week. Still want any?". Tapping it opens the sweep sheet.

- The sheet lists the tasks that faded since the last sweep.
- Each row has one control: **Keep**. Kept tasks go back to their list.
- One button at the bottom: **Let the rest go**. It sets status `cancelled`,
  `dropReason = "faded"`, `completedAt = now` on every row not kept. This is
  one undo entry.
- If the user ignores the sweep, nothing is dropped. Faded tasks stay in the
  pile until a sweep passes. AI and timers never drop a task.

Dropped tasks show in the logbook with a "let go" label, distinct from done.

## 6. Carry-over at rollover

At day rollover, each task with `today == true`, `todaySetOn` before today,
and status `open` gets `isInTriageBand = true` with a carry-over label. Today
starts with only ratified tasks.

A carry-over row offers the standard row actions plus one inline pair:
**Today** (ratify, stamps `touchedAt`, no defer) and **Not today** (clears
`today`, counts a defer). Completing it from the band works as today.

This reuses the band. No new container, no second selection style.

## 7. The stuck question

When `deferCount` reaches 3 *(default)*, the task gets one conversation turn,
authored on-device, with the ball on the user's side:

> What is in the way?

| Choice | Action |
|---|---|
| **Unclear** | Starts the existing loop at *confirm*: AI proposes the first physical step, or does the step (ADR 0005 rules apply). |
| **Boring** | AI proposes a 10-minute version as a new title or a first subtask. The user taps to accept. |
| **Not mine** | AI drafts a handoff message (`handoff` field). Nothing is sent: sending is a user action. |
| **Not now** | Date picker for a later `scheduled` date. If the user picks none, the task fades now. |
| **Let it go** | Drops the task (`dropReason = "user"`). |

Answering resets `deferCount` to 0. The question asks once per stuck
episode. It does not ask again until 3 more defers.

The turn uses the existing `question` / `options` / `chosen` shape. The
on-device path runs first, as in `docs/AI_TASKS_EXPLAINER.md`. If AI is off,
the card still shows. "Unclear" and "Boring" then open the composer instead.

## 8. Done first

The weekly view on the Tasks dashboard tile and in the sweep sheet header
leads with two numbers: **done** (status `done`, `completedAt` in the
trailing 7 days) and **let go** (status `cancelled` with a `dropReason`, same
window). "Week" is the trailing 7 days (`sinceDate(daysBack: 6)`). The open
count moves below them.

## 9. AI touches

All are suggestions the user taps. All run on-device first.

- **Capture cleanup.** After capture, the on-device model may propose a
  verb-first title for a vague one ("taxes" → "Download the 2026 annual
  statement"). It shows as a ghost suggestion in the composer. Ignoring it
  costs nothing.
- **Effort.** The same pass sets `effort` (`light` / `heavy`). The user can
  change it in the inspector. It drives §9.1 only.
- **Sweep reasons.** In the sweep sheet, each faded row may carry a one-line
  reason ("untouched since June, no date, no project"). No AI is needed for
  this: it comes from the fields.

### 9.1 Readiness-ordered Next (Septena only)

Septena reads the day's readiness (Oura readiness, else HealthKit sleep). On
a low day, Next lists `light` tasks before `heavy` ones. On a high day,
the first `heavy` task leads. Unknown effort keeps manual order. The user's
manual order breaks ties.

This lives in the Next feed builder behind the runtime profile. Septask runs
`RuntimeProfile.tasksOnly` with no provider stores, so it keeps manual order.
Do not copy the feed file into `Septask/`.

### 9.2 Memory and resurfacing

The list may forget only because something remembers. The memory is the task
store itself, not a separate AI store: a faded or let-go task keeps its notes,
attachments, conversation and change history (the backend keeps the change log
a year).

- **Fade note.** When a task fades, the agent writes one provider turn on it
  (`step = ground`, `note` only, no options): where it stood, why it mattered,
  what it waited on. It is written from the task's own notes, conversation,
  project and source. On-device first; Claude through the runner when the
  conversation needs it. Example: "From the Lisbon trip planning, 12 Oct.
  Waiting on dates from Ana. Passport expires in March."
- **Resurfacing on a signal, never on a timer.** A faded task is proposed back
  when something new connects to it: a new task or note that matches it, a date
  in its notes coming close, its project becoming active again, or the user
  asking ("what did I let go about the house?").
- **It comes back as a proposal.** The task lands in the Inbox band with one
  line on why now, above its fade note. One tap keeps it (clears `fadedAt`,
  stamps `touchedAt`), one tap lets it go. An agent never moves a task to
  Today and never deletes.
- **Quiet by default.** At most 3 resurfaced tasks a week *(default)*. A task
  the user let go in the sweep needs a stronger match than one that only
  faded.
- **Agent surface.** A search over faded and let-go tasks, and a `faded` event
  on `tasks_agent_events` (ADR 0008), on the api.septena.app connector.

## 10. Phases

| Phase | Content | Depends on |
|---|---|---|
| P1 | §3 fields, `TaskMutator.touch`, defer counting. No UI change. | — |
| P2 | §4 fade pass + Faded pile, §5 sweep. | P1 |
| P3 | §6 carry-over at rollover. | P1 |
| P4 | §7 stuck question. | P1 |
| P5 | §8 done-first view. | P2 |
| P6 | §9 capture cleanup + effort, §9.1 readiness Next. | P1 |
| P7 | §9.2 fade note, resurfacing, agent search and `faded` event. | P2 |

P1 must land on the backend schema first if the cutover (M1) has happened,
else on the local model with the backend fields specified for the cutover.

Each phase touches shared task code: build all four schemes (`CLAUDE.md`,
"Septask"). Any new MCP field lands in the in-app server and
`backend/` together.

## 11. Open questions for mz

| Question | Default |
|---|---|
| Fade window | 14 days |
| Do tasks with a `deadline` ever fade? | Never |
| Do tasks inside an active project fade? | Yes, same rule |
| Sweep day | Sunday |
| What a dropped task becomes | status `cancelled` + `dropReason`, shown in the logbook |
| Defers before the stuck question | 3 |
| Carry-over on Saturday and Sunday too | Yes |
| Readiness source when both Oura and HealthKit exist | Oura |
| Fade on by default for new users | Yes, with a Settings toggle to turn it off |
| Resurfaced tasks per week | 3 |
| Does a let-go task ever resurface? | Yes, on a stronger match than a faded one |
