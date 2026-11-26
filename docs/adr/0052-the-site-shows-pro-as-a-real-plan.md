# 0052. The website shows Pro as a real plan, by invitation

- Status: accepted (2026-11-26)
- Date: 2026-11-26
- Deciders: mz
- Amends: [ADR 0045](0045-pro-is-a-real-plan-that-is-only-given.md) (the website line)

## Context

ADR 0045 made Pro a real server plan that accounts are given, and kept the
website showing it as planned. Some accounts have Pro now, so "planned" is
wrong (mz, 2026-11-26: "pro exists not just planned").

## Decision

- The Pro card in `registry/plans.json` has `status: "invite"`: the plan
  exists, accounts get it by invitation, and no store sells it yet.
- The website shows Pro with a "By invitation" badge, not "Planned". Its
  price stays on the card as the price it has once it goes on sale.
- Everything else in ADR 0045 stands. The apps offer Free and Plus, and show
  Pro only on an account that has it. The generator keeps every card with a
  status out of the in-app plan list.

## Consequences

- Selling Pro later removes the status and adds store products (ADR 0045).
- `scripts/gen-registries.mjs` checks that the Pro card is `invite`.
