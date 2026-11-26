# 0059. Pro sells like Plus

- Status: accepted (2026-11-26)
- Date: 2026-11-26
- Deciders: mz
- Amends: [ADR 0045](0045-pro-is-a-real-plan-that-is-only-given.md) (Pro is
  never sold), [ADR 0052](0052-the-site-shows-pro-as-a-real-plan.md) (the note
  under the Pro button)

## Context

ADR 0045 kept Pro as a plan that accounts are given and nobody can buy. ADR
0052 showed it on the website with the note "You can't buy Pro yet", and the
pricing page added "If you need it now, write to me". mz rejected that copy
(2026-11-26): a plan with a price that tells the reader to write a personal
note is not a plan. The real gap is the same for every plan: checkout is
closed until App Store launch. Pro had one gap more: no store product gave
Pro, so the server could not put a buyer on it.

## Decision

- **Pro sells exactly like Plus.** Same stores (ADR 0026), same server trial,
  same checkout state. While `checkout.open` is false, the Pro card shows the
  same button and the same notice as the Plus card. No plan gets its own
  "not yet" line, and no copy asks the reader to write in for a plan.
- **One subscription group, two levels.** Pro is the higher level, so the App
  Store handles upgrade and downgrade between Plus and Pro. The Pro products
  are `com.septena.tasks.sync.pro.annual` (€120) and
  `com.septena.tasks.sync.pro.monthly` (€14), in `proPrices` in
  `registry/plans.json`.
- **The server maps a product to its plan** from the registry
  (`PLAN_PRODUCT_PLANS`). An App Store row for a Pro product gives Pro. A
  product the registry does not list gives nothing.
- Grants still give Pro (ADR 0045). The admin page is unchanged.

## Consequences

- mz creates the two Pro products in App Store Connect, in the Plus group, one
  level above Plus (issue #45).
- The app paywalls offer the Pro products on every platform; until they do,
  the Pro card keeps `status: "given"`, which keeps it out of the in-app
  purchase list (follow-up issue).
- Stripe (issue #43) and Google Play (issue #176) sell both plans.
