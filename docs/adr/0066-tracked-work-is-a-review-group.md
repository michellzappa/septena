# 0066. Work that goes on elsewhere is a Review group: Tracked

- Status: accepted (2026-11-28)
- Date: 2026-11-28
- Deciders: mz (asked for the best fit), agent (the rule)
- Amends: [ADR 0044](0044-review-is-one-place.md) (the groups),
  [ADR 0046](0046-agent-work-is-a-review-group.md) (the group order)
- Spec: [REVIEW_SPEC.md](../REVIEW_SPEC.md) §1, §2
- Issue: #858

## Context

An agent sets `endState = decomposed` when the work on a task goes on
elsewhere: in a GitHub issue, another tracker, or smaller tasks. ADR 0044
says such a task "comes back with `needs_verify`". Until then the task stayed
in Today, Upcoming, Anytime and its area and project like any open task. The
user cannot act on it, so the working lists filled with noise. Completing the
task instead breaks the loop that brings it back for the user to check.

## Decision

- **A new group of Review: Tracked.** An open task with
  `endState = decomposed` shows in Review ▸ Tracked. The group sits after
  Stopped and before Faded. It does not count in the Review badge and it
  starts collapsed, like Faded.
- **A tracked task leaves the working lists:** Today, Upcoming, Anytime, and
  its area and project lists. Search and Quick Find still find it.
- **The user's deadline wins.** A tracked task with a deadline that is due
  today or past still shows on Today. A When date or a Today pin does not
  bring it back.
- **It comes back as Finished work.** When the work elsewhere ends, the agent
  hands the task over with `needs_verify` and a note. The task moves to
  Finished work, as for every hand-off.
- **The user can bring it back.** The row menu has Bring Back (sets
  `endState` to `open`, the user only), Complete and Delete. The row shows the
  title, the end-state note as its context line, and the issue link from the
  task's references, which opens in the browser.
- **A tracked task does not fade.** It is in no list.
- **The rule is in the shared core.** `conversationState` returns the
  `tracked` group after `finished` and `questions`, and `taskViewMembership`
  returns `isTracked` and keeps the task out of the lists. Clients take the
  core's group first, as ADR 0046 says, so a tracked task that also waits on
  a person shows in Tracked.

## Consequences

- The working lists hold only what the user can act on. Any agent and any
  tracker get the same behavior, not only the Septena factory.
- MCP and REST views follow the same list rule. `view=review` stays finished
  work only.
- A stale `decomposed` (the issue closed and no agent handed over) waits in a
  collapsed group. The user sees it there and brings it back or completes it.

## Links

`docs/REVIEW_SPEC.md`, ADR 0044, ADR 0046, ADR 0053, #858
