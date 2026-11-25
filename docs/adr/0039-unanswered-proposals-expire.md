# 0039. An unanswered agent proposal expires

- Status: accepted (2026-11-25)
- Date: 2026-11-25
- Deciders: mz
- Builds on: [ADR 0006](0006-tasks-fade-by-default.md),
  [ADR 0038](0038-agents-are-the-integrations.md)

## Context

After 7 days an agent proposal that the user ignored becomes an ordinary task:
with a date it joins Today or Upcoming, without one it stays in Anytime.
Silence counts as acceptance. That was harmless for a few proposals. With
agents that read sources every day (ADR 0038), it fills the lists with tasks
nobody chose. Fade catches some after 14 days, but never one with a deadline
or a future date.

## Decision

A proposal that the user has not touched in 7 days expires: it fades, and goes
to the Faded pile, with or without a date. Silence is never acceptance.
Keeping it from the pile accepts it. Expiry uses the fade pass and the Faded
pile that exist. It adds no pile and no setting, and it drops nothing.

## Consequences

- Nothing an agent proposed enters Today or Upcoming without a user gesture,
  as far as this clock goes. Filed suggestions are #500.
- A useful proposal that the user missed for a week leaves the Inbox. The
  weekly sweep shows it again.
- The expired item is not proposed again (#497).
- The rule lives in the shared core, so every client needs the new core.

## Links

`docs/TASK_FADE_SPEC.md`, `docs/TRIAGE_BAND_SPEC.md`, #499
