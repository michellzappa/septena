# 0046. Agent work in progress is a group of Review, not its own list

- Status: accepted (2026-11-26)
- Date: 2026-11-26
- Deciders: mz
- Amends: [ADR 0044](0044-review-is-one-place.md) (the separate Agent list)

## Context

ADR 0044 made Review the one place for what waits on the user, and kept an
**Agent** list for work in progress (Working, Queued, Stopped, Done). Both
lists serve one function: the place where the user checks on the agent. One
task moves between them in one run. It is in Agent while it is queued and
worked on, and it jumps to Review when the agent asks or hands it over. Two
sidebar rows for one lifecycle confused the user (mz, 2026-11-26: "review,
for all such things").

## Decision

- **One list: Review.** Its groups, in this order: **Questions**, **Finished
  work**, **Working**, **Queued**, **Stopped**, **Faded** (then Projects,
  #585). A task shows in the first group that fits.
- **The Agent list goes away** on every platform. The `agent` destination
  stays in `registry/destinations.json` as an embedded entry
  (`visibility: "reviewGroup"`, like Faded), so a saved selection, a deep link
  or Quick Find that names it opens Review.
- **The badge counts only Questions and Finished work.** Agent work in
  progress and Faded do not count. The Review row shows while any group has
  an item.
- **The Done stage has no group.** Finished agent work is in the Logbook.
- The rule stays in the shared core: a client takes the core's `reviewGroup`,
  then the core's `agentStage` for Working, Queued and Stopped, then Faded.

## Consequences

- One sidebar row, one place to check on the agent.
- MCP and REST views do not change: `view=review` is still finished work.
- `docs/REVIEW_SPEC.md` §1 and §2 and `docs/TASK_FACTORY_SPEC.md` §3 are
  updated to match.

## Links

`docs/REVIEW_SPEC.md`, `docs/TASK_FACTORY_SPEC.md` §3, ADR 0044.
