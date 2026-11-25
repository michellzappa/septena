# Review — spec

**Status:** accepted 2026-11-25 ([ADR 0044](adr/0044-review-is-one-place.md)).
The store rules (§3) are built. §5 says what is not.

Review is the one list of everything that waits on the user. Nothing else in
the app is called Review.

## 1. The groups

| Group | In when | Out when | If the user ignores it |
|---|---|---|---|
| **Questions** | The last turn is a provider turn with options, on an open task that is not stopped. | The user answers, stops the agent, or closes the task. | It stays. It does not fade. |
| **Finished work** | `endState = needs_verify` on an open task. | The user accepts, sends back, or closes the task. | It stays. It does not fade. |
| **Faded** | The fade pass set `fadedAt` (`TASK_FADE_SPEC.md` §4), or a proposal expired (ADR 0039). | The user keeps, opens or edits it, or lets it go. A hand-off, a question or a user's deadline also ends the fade. | It stays. A timer never drops a task. |
| **Projects** | The project faded (`TASK_FADE_SPEC.md` §4.2, #585). | Keep, Done or Let go. | It stays, dimmed in the sidebar. |

A task shows in one group: the first that fits. Headings, deleted tasks and
closed tasks show in none.

**Not in Review:** the Inbox band (new captures and proposals are decided on
Today), overdue tasks, and the Today rollover (§6 of the fade spec).

## 2. The list

- Sidebar: right below Today, while it has an item. Go ▸ Review and Quick Find
  always open it.
- Badge: Questions plus Finished work. Faded and Projects do not count.
- Faded starts collapsed. Its notice opens the keep-or-let-go sheet on any day.
- The weekly prompt on Today opens the same sheet.
- The Agent list shows work in progress: Working, Queued, Stopped, Done.

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
