# 0044. Review is the one place for everything that waits on you

- Status: accepted (2026-11-25)
- Date: 2026-11-25
- Deciders: mz
- Amends: [ADR 0006](0006-tasks-fade-by-default.md) (where faded tasks show),
  [ADR 0008](0008-agent-loop-rules-live-in-the-store.md) (what an agent may end)

## Context

"Review" meant two things. `TASK_FACTORY_SPEC.md` kept the word for finished
agent work. The fade prompt's button said Review too. What waits on the user
was spread over a Review list, the Agent list, a Faded list and a Sunday sheet.

The agent half also had holes. An agent could reopen its own hand-off, clear
the assignee and mark the task done. It could take a task out of Review with
`agent_done`, or cancel it. A hand-off on a faded task was in the backend's
Review and hidden in the apps.

## Decision

- **One list.** Review holds four groups, in this order: **Questions**,
  **Finished work**, **Faded**, **Projects**. The contract is
  `docs/REVIEW_SPEC.md`: what puts an item in, what takes it out, and what
  happens when the user ignores it.
- **Faded moves into Review.** The Faded sidebar list goes away. The Faded
  group is the whole pile, collapsed, and it does not count in the badge.
- **Agent shows work in progress only:** Working, Queued, Stopped, Done.
- **Only the user takes an item out of Review.** An agent puts work in, with a
  note. Agent work stays agent work after the claim ends, until the user takes
  the task back or closes it. The store enforces it (`TaskStore.agentRefusal`).
- **A task that waits on the user is never faded.** The store ends the fade on
  a hand-off and on a question.
- **An ignored proposal fades, also with a deadline** (ADR 0039). "A task with
  a deadline never fades" covers tasks that the user made or accepted.
- **Fade is one setting per account,** and so is the state of the weekly
  prompt. The store refuses a fade from a device that did not know the newest
  touch.

## Consequences

- Deterministic items (faded tasks, projects) and agent items share a list,
  row language and undo. A new kind of item is a group, not a new place.
- An agent must ask before it drops agent work. To suggest a cancel it hands
  the task over with the reason in the note.
- `decomposed` stays an agent's to set: the task goes on elsewhere, and it
  comes back with `needs_verify`.
- MCP and REST keep `view=review` (finished work) and `view=faded`.

## Links

`docs/REVIEW_SPEC.md`, `docs/TASK_FACTORY_SPEC.md` §3,
`docs/TASK_FADE_SPEC.md`, #499, #585
