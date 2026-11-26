# Review — spec

**Status:** accepted 2026-11-25 ([ADR 0044](adr/0044-review-is-one-place.md)),
amended 2026-11-26 ([ADR 0046](adr/0046-agent-work-is-a-review-group.md),
[ADR 0053](adr/0053-waiting-on-people-is-a-review-group.md): the Waiting
group). The store rules (§3) are built, except Waiting (§6). §5 says what is
not.

Review is the one list of everything that waits on the user, and of agent
work in progress. Nothing else in the app is called Review. There is no
separate Agent list (ADR 0046).

## 1. The groups

| Group | In when | Out when | If the user ignores it |
|---|---|---|---|
| **Questions** | The last turn is a provider turn with options, on an open task that is not stopped. | The user answers, stops the agent, or closes the task. | It stays. It does not fade. |
| **Finished work** | `endState = needs_verify` on an open task. | The user accepts, sends back, or closes the task. | It stays. It does not fade. |
| **Waiting** | The open task waits on a person (§6): `waitingOn` is set, or the user assigned a shared task to another member. | The user taps Got It Back, completes or cancels it, or the member completes it. | It stays. It does not fade. Its When date brings it to Today to chase. |
| **Working** | An agent holds a live claim on the open task. | The claim ends, the agent asks or hands over, or the user takes the task back. | It stays. It does not fade. |
| **Queued** | Agent work (§3) with no live claim, not stopped and not terminal. | An agent claims it, or the user takes the task back or closes it. | It stays. |
| **Stopped** | The user stopped the agent on this task. | The user resumes the agent, takes the task back or closes it. | It stays. |
| **Faded** | The fade pass set `fadedAt` (`TASK_FADE_SPEC.md` §4), or a proposal expired (ADR 0039). | The user keeps, opens or edits it, or lets it go. A hand-off, a question or a user's deadline also ends the fade. | It stays. A timer never drops a task. |
| **Projects** | The project faded (`TASK_FADE_SPEC.md` §4.2, #585). | Keep, Done or Let go. | It stays, dimmed in the sidebar. |

A task shows in one group: the first that fits. Headings, deleted tasks and
closed tasks show in none.

**Not in Review:** the Inbox band (new captures and proposals are decided on
Today), overdue tasks, and the Today rollover (§6 of the fade spec).

## 2. The list

- Sidebar: right below Today, while it has an item. Go ▸ Review and Quick Find
  always open it.
- Badge: Questions plus Finished work. Waiting, Working, Queued, Stopped,
  Faded and Projects do not count.
- Faded starts collapsed. Its notice opens the keep-or-let-go sheet on any day.
- The weekly prompt on Today opens the same sheet.
- Opening a row in any group but Faded (tap, click, double-click, Return)
  opens the task page, where the conversation is. It never expands the row
  inline. Faded rows expand inline like any other list.
- Agent work that is done has no group: it is in the Logbook.

## 3. Rules the store enforces

An agent is any `mcp:` actor. The rules are in `TaskStore.agentRefusal`; the
refusal carries its rule as text (`AGENT_WRITE_RULES`).

| Rule | Refused as |
|---|---|
| Agent work is ended by the user only: an agent may not mark it done, cancel it or delete it. | `human_accepts` |
| An agent never takes a task out of Review. | `in_review` |
| An agent sets only `needs_verify`, or `decomposed` (the work goes on as an issue or smaller tasks) and back. | `human_ends` |
| A hand-off has a note. | `note_required` |
| A closed task cannot be handed over. | `closed` |
| An agent does not give up a task that is assigned to it. | `human_only:assignee` |

**Agent work** is a task that is assigned to `claude`, in Review, or that an
agent claimed. It stays agent work after the claim ends (`convos.agentWorkAt`,
a store column that does not sync). It ends when the user changes the assignee
or marks the task done.

The store also keeps these true:

- **A hand-off or a question ends the fade.**
- **A revised hand-off is a new hand-off.** When an agent changes the note, the
  artifact or the handoff action in Review, `endStateAt` moves. An Accept that
  names the earlier `reviewAt` is refused as stale.
- **Finishing is leaving.** When the user marks a task in Review done by any
  button, its `endState` becomes `agent_assisted_done`. Reopening it does not
  put it back. A cancelled task keeps its hand-off, so an undo is lossless.

## 4. Accept and Send back

Every client writes the same thing.

- **Accept** completes the task, sets `agent_assisted_done`, acknowledges a
  task an agent added, and stamps `touchedAt`. Undo puts it back in Review with
  its note.
- **Send back** appends a user turn with the note, sets `endState = open`,
  clears `endStateNote` and `stoppedAt`, and assigns `claude`. Undo restores
  the conversation. The note is required.

A plain completion of a task in Review is an Accept.

## 5. Not built

| What | Issue |
|---|---|
| The list of §2 on the clients, and one Accept and Send back (§4) | #590 |
| A push when an agent hands work over | #590 |
| Fading projects in the Projects group | #585 |
| Today rollover (Ask, Clean slate) | #185, #186 |
| The stuck question after a third deferral. It will be a Question. | #55 |
| The Waiting group (§6) | #669 |

## 6. Waiting

Work handed to a person (ADR 0053). Not built: #669.

### Fields

| Field | Type | Set by |
|---|---|---|
| `waitingOn` | text, 1 to 80 characters, or null | The user (Waiting On…), or an agent |
| `waitingSince` | `YYYY-MM-DD` or null | The store, on the day `waitingOn` goes from null to a value. Cleared with it. |

Both sync. There is no follow-up field: **the task's When date is the day to
chase.** Waiting On… offers a When date in the same sheet (*default* a week
out, the user can clear it).

On a shared task the two fields are personal, like When *(default)*.

### Where a waiting task shows

- In Review ▸ Waiting, oldest `waitingSince` first.
- Everywhere else as any task does: on Today when its When date comes, in
  Upcoming before that, in Anytime when it has no date, and in its project or
  area. The row carries a "Waiting on Anna · 5 days" label.
- The weekly review shows the Waiting group *(default)*.

### Actions

Row menu, swipe and task page, from `registry/actions.json`:

| Action | Writes |
|---|---|
| Waiting On… | `waitingOn`, and optionally When |
| Got It Back | clears `waitingOn` (and `waitingSince`); the task stays open in its list |
| Complete | completes the task; the wait ends with it |

To chase later, the user changes When, as for any task.

### Store rules

- A waiting task never fades. Setting a wait ends a fade.
- Only the user ends a wait. On a waiting task, an agent's write that clears
  `waitingOn`, completes, cancels or deletes the task is refused as
  `in_review`, as for every Review group (ADR 0044).
- An agent may set a wait and change its When date: the user asked it to
  chase someone, or it made the task from a message the user sent.
- An agent that sees a reply (it reads the reference the task points at,
  ADR 0038) asks with a provider turn: "Anna replied. Got it back?" with the
  options Got It Back and Still Waiting. The task is then a Question (§1),
  the first group that fits.

### Shared projects

A shared task waits on a member only when **this user** assigned it to that
member: the client shows the member's name, and `waitingSince` is the day of
the assignment. A task someone else assigned, or one assigned to the user,
does not wait. When the member completes it, it closes for everyone, with no
Accept step.

### Wire

- MCP: `tasks_set_waiting {id, waiting_on, scheduled?}` (`waiting_on: null`
  from an agent is refused), `tasks_list view=waiting`, and both fields in the
  task shape. REST mirrors them (#90).
- Core: `reviewGroup` returns `waiting` between `finishedWork` and the agent
  stages. The badge does not change.
