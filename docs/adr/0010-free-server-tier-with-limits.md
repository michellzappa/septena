# 0010. Offer a free server tier with limits; paid lifts them

- Status: accepted (2026-11-20); free device count amended by [0023](0023-sync-across-devices-is-plus.md) (2026-11-22)
- Date: 2026-11-20
- Deciders: mz

## Context

`docs/SYNC_SUBSCRIPTION_SPEC.md` §3 set one rule: the device is free, the
server is paid. A free user had no account, and nothing free could become
paid without a new ADR.

Facts that changed:

- Server cost per user is small. From the client's sync rhythm and Cloudflare's
  published prices (read 2026-11-20): a user active every day costs about
  $0.015 a month, a dormant user about $0.0007. With 20–30% of users active
  on a given day, €100 a month carries about 20,000 free accounts. These are
  estimates from code, not measured traffic.
- A free user with no account never meets the paid features. The first
  contact with sync, history, sharing or agents is a paywall.
- Shared projects (ADR 0004) need the invitee to have an account. With no free
  account, every invitee must pay before they can join.
- The cost of keeping history is storage only: a 365-day change log is a few
  MB per user.

## Decision

Septena has three levels:

1. **Free, no account.** The full task app on one device, as before. No
   sign-in is needed until the user wants a second device.
2. **Free account.** The server with limits: two devices, slower sync, a short
   history window, no server attachments, small allowances for the Claude
   connector and agents, and joining shared projects.
3. **Paid (€5 a month / €40 a year).** The same server with the limits lifted:
   live sync on all devices, full history, synced attachments, the connector
   and agents without small caps, creating shared projects, linked projects.

The limits live in one plan table on the server. Every limit is enforced on
the server, and apps read their limits from the server. The limit values are
in the spec; this ADR fixes the shape, not the numbers.

Rules for every limit:

- No limit touches the core task app (tasks, lists, projects, areas, the
  composer, fade). They cost us nothing.
- A limit hides; it never deletes user rows. Export is always free. Upgrading
  shows everything again.
- Only logs (the change log) are pruned per plan. Pruning starts only after
  the lapse period, never on the day a subscription ends.
- Limits sit on what costs us money or carries clear value: devices, sync
  speed, history depth, storage, agent runs, hosted AI, creating shares.
- An upsell appears only at the moment a user meets a limit, once, with one
  tap. No timed nags, no badges on paid features, no countdown screens.
- New accounts start with a 14-day reverse trial: the full paid plan, then the
  free account, not nothing.

## Consequences

- More users reach the server, so sync, sharing and agents can sell
  themselves. Invitees join shared projects for free, and each one is a
  candidate for paid.
- We pay for free accounts. At the estimate above, 20,000 free accounts cost
  about €1,200 a year.
- Free sync on two devices may remove the main reason to pay. Live sync, more
  than two devices, the watch through the server, sharing and agents carry
  the paid plan. If conversion is low, the device limit is the first knob.
- The entitlement becomes a plan with limits, not one yes/no check.
  `hasSyncEntitlement` and every gate that calls it change. Both MCP surfaces
  on the backend read the same plan table.
- A lapsed subscriber falls back to the free account, not to no sync. Devices
  past the limit stop syncing; the two most recently used keep syncing.
- Upsell copy is human-facing and goes through the humanizer skill.
- The rule "nothing free today becomes paid later without a new ADR" stays.
  This ADR only adds free things.

## Links

- `docs/SYNC_SUBSCRIPTION_SPEC.md` (limits, upsell moments, history windows)
- ADR 0002, ADR 0004, ADR 0007, ADR 0008, ADR 0009
- Pricing and positioning: Starlings Septena workspace, `/strategy`
