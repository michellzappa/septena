# 0053. Work handed to a person is a Waiting group in Review

- Status: accepted (2026-11-26)
- Date: 2026-11-26
- Deciders: mz
- Amends: [ADR 0046](0046-agent-work-is-a-review-group.md) (the group order)
- Spec: [REVIEW_SPEC.md](../REVIEW_SPEC.md) §1, §3, §7
- Study: Starlings `/product/studies/study-a-central-view-of-delegated-work`

## Context

Review shows work handed to an agent (ADR 0046). Work handed to a person has
no place. A shared task records `assignedTo`, but only inside its project. A
task that waits on someone outside Septena (an investor, a candidate, a
lawyer) has nothing. Founders name "hand work off and know it came back" as a
top job, and "dropping something that matters" as the top fear (#167).

mz chose on 2026-11-26 (study, options A to D): option A, the name
"Waiting", a passed follow-up date counts in the badge, and a task a member
completes just closes.

## Decision

- **A task can wait on a person.** Three synced fields: `waitingOn` (who, free
  text), `waitingSince` (the day it was set) and `followUpOn` (an optional
  date to chase). A shared task assigned to another member waits on that
  member with no extra step.
- **Waiting is a Review group,** not a new place (ADR 0044, ADR 0046). The
  order becomes: Questions, Finished work, **Waiting**, Working, Queued,
  Stopped, Faded, Projects.
- **The badge counts a waiting task once its follow-up date is today or past.**
  Without a follow-up date, or before it, a waiting task does not count.
- **A waiting task never fades,** like a hand-off.
- **Only the user ends a wait:** Got It Back, Complete, or cancel. An agent
  may set or change a wait (the user asked it to chase someone), but it never
  ends one. It proposes "they replied" as a Question, and the user decides.
- **A task a member completes closes.** It goes to the Logbook. It does not
  come back to the assigner to accept.
- **The rule is in the core** (ADR 0025), with the other groups. Every
  platform ships it in the same change.

## Consequences

- One place still holds everything that waits: on the user, on an agent, on a
  person.
- Three new synced task fields: a schema change on the backend, the core and
  every client (`registry/entities.json`).
- The agent closes the loop with no connector (ADR 0038): it reads the thread
  the task points at and asks.
- A wait with no follow-up date can sit forever without a badge. The Waiting
  group is visible in Review, and the weekly review shows it.

## Links

`docs/REVIEW_SPEC.md`, `docs/PROJECT_SHARING_SPEC.md`, ADR 0038, ADR 0044,
ADR 0046, #167, #669
