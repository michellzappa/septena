# 0037. Show three plans: Free, Plus and a planned Pro

- Status: accepted (2026-11-24)
- Date: 2026-11-24
- Deciders: mz
- Amends: [ADR 0036](0036-plan-ladder-one-agent-then-three.md) (how the levels
  are shown; the limits stand)

## Context

The pricing page showed "On this device" and "Free account" as two cards at
€0. They look like two plans, and nobody chooses between them. ADR 0036 also
hid Pro, so the page had no third step.

## Decision

- **Public plans are Free, Plus and Pro.** Signing in is a line inside Free:
  it is also free, and it adds a backup and one agent. ADR 0036's limits for
  no account and a free account stay separate in the rules.
- **Pro is shown as planned,** at €120 a year or €14 a month, with no limit on
  agents and 50 GB of files. It has no buy button, store product or server
  plan. It goes on sale under the conditions in ADR 0036.
- **Pro is on the website only.** The apps show Free and Plus, so no app shows
  a plan the store does not sell.
- **Every card has the same lines:** devices, agents, files, history. One note
  says what needs a free account. The Plus limit for Recently Deleted is 30
  days until #446 ships.
- **Pro claims no longer history.** The server keeps 365 days for everyone,
  which is what Plus shows.

## Consequences

- A published Pro price can go down easily, and up only with care.
- `registry/plans.json` has the levels free, plus and pro. The server limits
  keep the keys account and plus.

## Links

`registry/plans.json`, ADR 0023, ADR 0036
