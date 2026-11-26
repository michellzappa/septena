# 0058. Admin growth comes from daily snapshots now, and from an event stream at scale

- Status: accepted (2026-11-26)
- Date: 2026-11-26
- Deciders: mz (product), agent (mechanism)
- Amends: [ADR 0043](0043-plus-links-and-a-counts-only-admin-page.md) (the
  page also reads third-party aggregates and keeps a daily history)
- Spec: [ADMIN_CONSOLE_SPEC.md](../ADMIN_CONSOLE_SPEC.md)

## Context

mz wants the admin page to be a SaaS console: every signup, every call to
action, website traffic and growth over time, built so it still works with
millions of accounts. ADR 0043 gave the page counts from one summary per
account, refreshed by an hourly cron. That gives "now" only: it cannot say
how many accounts were active last week. It also reads every summary on each
page load, which stops working long before a million accounts.

## Decision

- **The privacy rule of ADR 0043 stays.** The page shows counts, dates,
  plans, client versions and aggregates. No title, note, file name or name the
  user typed, and no "view as user". Every new metric must pass this rule.
- **History is one snapshot per UTC day** in `AccountStore.metric_days`
  (`day`, JSON counts). The hourly cron rewrites today's row after the sweep.
  A series that the data can rebuild (accounts and signups by the day they
  started) is computed from the rows and reaches back to day one.
- **Activated means "completed at least one task".** It is the activation
  step of every funnel and cohort until mz picks another.
- **Third-party numbers are read by the Worker with read-only keys** and
  cached in KV: Plausible Stats API (`PLAUSIBLE_API_KEY`, 10 minutes), GitHub
  release downloads for the Mac (no key, 1 hour). A source that does not answer
  shows a line on the page; the rest of the page stays current.
- **At scale the source changes, the page does not.** When the account index
  passes about 10,000 rows (or a page load passes 1 s), counts move to
  Workers Analytics Engine: the API writes one data point per session request
  and per task change (account id hashed, no content), and the page queries
  daily aggregates with its SQL API. Snapshots stay as the long-term record.
  The account table then pages and searches on the server.

## Consequences

- WAU, MAU, activated and paying get a week-over-week change only seven days
  after the first snapshot (2026-11-26).
- "Active" is the last time a device or agent reached the server. It is not
  "opened the app", and an app that syncs in the background counts.
- Plausible counts a custom event only after mz adds it as a goal. The page
  lists the site events that have no goal yet.
- The Plausible Stats API needs the Business plan; septena.app is on Growth
  (#685). Until mz upgrades, the page embeds a Plausible shared-dashboard link
  (`PLAUSIBLE_SHARED_LINK`, a secret), and the website funnel and goal
  conversion stay empty. The code for the API block is in place and turns on
  with `PLAUSIBLE_API_KEY`.
- Adding App Store Connect, Google Play or Stripe needs a key per source and a
  change to this ADR's list of sources.
