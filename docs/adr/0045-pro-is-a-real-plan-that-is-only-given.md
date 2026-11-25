# 0045. Pro is a real plan that is only given, never sold yet

- Status: accepted (2026-11-25)
- Date: 2026-11-25
- Deciders: mz
- Amends: [ADR 0037](0037-show-free-plus-and-planned-pro.md) (Pro had no server
  plan), [ADR 0043](0043-plus-links-and-a-counts-only-admin-page.md) (the admin
  page's writes)

## Context

mz wants some accounts on Pro for good. The server knew Free and Plus only, so
a grant could give at most three agents once #445 enforces the limit.

## Decision

- **The server has the plan `pro`:** every Plus limit, no limit on connected
  agents, 50 GB of files. Its values are `limits.pro` in `registry/plans.json`.
- **A grant row names its plan.** `entitlements.plan` is `pro` or empty, and
  empty is Plus. No store product gives Pro. The account is on the highest plan
  an active row gives.
- **Pro is still not sold.** The website shows it as planned, with no buy
  button. The apps offer Free and Plus. An app shows "Pro" only on an account
  that has it.
- **In the apps Pro is a Plus account with another name.** Its plan page is
  "Septena Pro" and compares Pro with Plus, without prices. An older build reads
  the same answer and says "Plus".
- **The admin page gives plans.** A link carries Plus or Pro. An account row
  has Give and Take back, which write one row, `grant:admin`. The page still
  shows counts only.

## Consequences

- Selling Pro later needs store products that map to the plan, the price
  decision of ADR 0036 and the paywall. It needs no change at the gates.
- A limit above Plus has a number only for files, and 50 GB stays a working
  value.
