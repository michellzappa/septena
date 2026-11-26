# 0053. Work handed to a person is a Waiting group in Review

- Status: accepted (2026-11-26), revised the same day before any work (mz:
  "yeah rewrite")
- Date: 2026-11-26
- Deciders: mz
- Amends: [ADR 0046](0046-agent-work-is-a-review-group.md) (the group order)
- Spec: [REVIEW_SPEC.md](../REVIEW_SPEC.md) §1, §6
- Study: Starlings `/product/studies/study-a-central-view-of-delegated-work`

## Context

Review shows work handed to an agent (ADR 0046). Work handed to a person has
no place. A shared task records `assignedTo`, but only inside its project. A
task that waits on someone outside Septena (an investor, a candidate, a
lawyer) has nothing. Founders name "hand work off and know it came back" as a
top job, and "dropping something that matters" as the top fear (#167).

mz chose option A of the study on 2026-11-26, with the name "Waiting", and a
task a member completes just closes. A review of that first plan found three
faults: a wait with no follow-up date dropped out of every daily list, an
agent could still end a wait by completing the task, and every shared task
assigned to someone else would count as waiting. A second date beside When
was also more than people use: they chase with a dated task.

## Decision

- **A task can wait on a person.** Two synced fields: `waitingOn` (who, free
  text) and `waitingSince` (the day it was set, by the store).
- **The When date is the day to chase.** There is no follow-up field. A
  waiting task shows where any task shows: on Today when its date comes, in
  Upcoming, in Anytime, in its project, with a "Waiting on Anna" label.
- **Waiting is a Review group,** not a new place (ADR 0044, ADR 0046). The
  order becomes: Questions, Finished work, **Waiting**, Working, Queued,
  Stopped, Faded, Projects. It does not count in the badge: the When date
  does that job.
- **A waiting task never fades.**
- **Only the user ends a wait,** as for every Review group: Got It Back,
  Complete or cancel. An agent may set a wait and its When date, but may not
  clear, complete, cancel or delete a waiting task. It asks "they replied?"
  as a Question.
- **Shared projects:** a task waits on a member only when this user assigned
  it to that member. When the member completes it, it closes for everyone.
- **The agent part comes first.** A wait starts in mail or chat, so the agent
  that makes a waiting task from a sent message, and asks when a reply comes,
  ships in the first phase.
- **The rule is in the core** (ADR 0025). Every platform ships the group in
  the same change.

## Consequences

- One place still holds everything that waits: on the user, on an agent, on a
  person.
- Two new synced task fields (`registry/entities.json`), no new date and no
  new badge rule.
- The agent closes the loop with no connector (ADR 0038): it reads the thread
  the task points at and asks.
- A wait with no When date shows in Anytime and in Review ▸ Waiting, and the
  weekly review shows it.

## Links

`docs/REVIEW_SPEC.md`, `docs/PROJECT_SHARING_SPEC.md`, ADR 0038, ADR 0044,
ADR 0046, #167, #669
