# 0052. The website shows Pro as a real plan

- Status: accepted (2026-11-26)
- Date: 2026-11-26
- Deciders: mz
- Amends: [ADR 0045](0045-pro-is-a-real-plan-that-is-only-given.md) (the website line)

## Context

ADR 0045 made Pro a real server plan that accounts are given, and kept the
website showing it as planned. Pro exists and accounts have it, so "planned"
is wrong (mz, 2026-11-26: "pro exists not just planned"). A first fix showed
a "By invitation" badge; mz rejected that too ("pro exists").

## Decision

- The website shows Pro as a plan like Free and Plus: no badge, its price,
  its limits. The note under its button says that you cannot buy it yet.
- The Pro card in `registry/plans.json` has `status: "given"`. It is internal:
  no store product sells Pro yet, so an account gets it as a grant. The
  generator keeps every card with a status out of the in-app purchase list.
- Everything else in ADR 0045 stands. The apps offer Free and Plus to buy,
  and show Pro on an account that has it.

## Consequences

- Selling Pro later removes the status and adds store products (ADR 0045).
- `scripts/gen-registries.mjs` checks that the Pro card is `given`.
