# Admin console spec

- Status: building (ADR 0043, ADR 0050). Phase 1 shipped 2026-11-26.
- Page: `https://api.septena.app/admin` (Cloudflare Access, `ADMIN_EMAILS`).
- Code: `backend/src/admin/` (`page.ts`, `metrics.ts`, `plausible.ts`,
  `releases.ts`, `signups.ts`, `accounts.ts`).

## 1. Goal

One page answers, every morning: is Septena growing, where do people come
from, where do they drop out, and do they stay. It must still answer with
millions of accounts. It never shows what a user wrote (ADR 0043).

## 2. Sections and their sources

| Section | Shows | Source |
|---|---|---|
| Growth | Accounts, new accounts (7 d), WAU, MAU, activated, paying, signups, each with the change against 7 days before and a 30-day line. DAU, DAU/MAU, activation %, trial to paid. | Account index + `metric_days` |
| Funnels | Website: visitors → left an email → clicked a download (30 d). Product: accounts → activated → 2+ devices → agent → trial → paying. | Plausible, account index |
| Website | Visitors (7 d with change, 30 d), bounce, visit length, visitors and signups per day, CTA goals with conversion, sources, pages, countries, download clicks by platform, list-keeper CTA by placement. Lists site events with no Plausible goal. | Plausible Stats API v2 |
| Retention by week | Per start week: size, activated, active this week, 2+ devices, paying. | Account index |
| Clients and agents | Devices and versions seen in 30 d, agents per client, sign-in providers, Mac downloads per release. | Account index, GitHub releases |
| Plans and usage | Paid (year/month), granted, Pro, trial, lapsed, tasks, files. | Account index |
| Plan links, Accounts, Signups | As in ADR 0043 and 0045. Signups add counts by page and people vs rows. | AccountStore, D1 `septena-signups` |

## 3. Definitions

- **Active**: a device or agent of the account reached the server in the
  window (`lastSeen`). DAU 1 d, WAU 7 d, MAU 30 d.
- **Activated**: completed at least one task (`closedTasks >= 1`).
- **Paying**: an active App Store, Stripe or Play purchase in Production.
- **Week**: Monday 00:00 UTC.
- **Change**: today's value against the snapshot 7 days before; for daily
  counts, the last 7 days against the 7 before.

## 4. Phases

Each phase is a GitHub issue in the milestone "Admin console".

1. **Growth, funnel, website, retention, clients** (shipped). Daily
   snapshots, Plausible, Mac downloads.
2. **Store numbers.** App Store Connect API: installs, trials, conversions,
   proceeds, renewals, refunds, per country. Google Play when Android ships.
   Needs an ASC API key with Sales and Reports access as a Worker secret.
3. **Revenue.** MRR, ARR, net new MRR, churn, ARPU, LTV by plan, from store
   and Stripe data. Prices come from the store, never typed into the page.
4. **Event stream.** Workers Analytics Engine data points from the API
   (session, task change, agent call), hashed account id, no content. Real
   DAU/WAU/MAU history, the N-day retention curve (D1, D7, D30), feature use
   (Today, Review, agents, shares, imports) per day.
5. **Scale the page.** Server-side paging and search of accounts, aggregates
   from Analytics Engine only, no full index read on load. Target: page under
   1 s at 1,000,000 accounts.
6. **Health.** Worker error rate and latency, sync failures, failing
   webhooks, save failures reported by apps (`StoreHealth`), from Workers
   Observability.
7. **Digest and alerts.** A daily email to mz with the growth tiles and
   anything that crossed a limit (signups drop, error spike, a release with
   low adoption).

## 5. Rules

- A new metric passes the ADR 0043 privacy rule, or it does not ship.
- A third-party source has a read-only key, a timeout, a KV cache and a
  failure line. One failing source never blanks the page.
- The page stays one HTML document with no script (CSP `default-src 'none'`).
  Charts are inline SVG; hover text is the SVG `title`.
- Every count has a definition in §3. A new count adds its definition here.
