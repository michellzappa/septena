# 0018. Run Septena on its own Cloudflare account

- Status: accepted (2026-11-21)
- Date: 2026-11-21
- Deciders: mz

## Context

- The task backend (`api.septena.app`), the community worker
  (`community.septena.app`) and the site (`septena.app`) run on a Cloudflare
  account that also holds unrelated projects and domains.
- That account is on Workers Free. Email Sending, which ADR 0016 needs for
  email codes, requires Workers Paid, and its sending domains belong to one
  account.
- Durable Objects, KV, R2 and D1 data cannot be moved between accounts by
  Cloudflare. A move is a copy done by us. Today the only data is mz's and a
  few testers', so a copy is cheapest now, before launch.
- ADR 0011 makes "one Cloudflare account" the self-host target. Septena
  should run that way itself.

## Decision

Septena moves to a new Cloudflare account named Septena, owned by the same
login that owns the Starlings account. Every Septena worker, store, bucket,
database, secret and the `septena.app` zone move there before launch. Email
Sending is set up on the new account, not the old one. The steps are in
`docs/CLOUDFLARE_ACCOUNT_MOVE.md`.

## Consequences

- Septena gets its own bill, its own API tokens scoped to Septena only, and
  its own email sending reputation.
- A mistake in another project cannot reach Septena's user data.
- The move needs admin export and import routes for the per-user Durable
  Objects, and a short outage while the nameservers change.
- Workers Paid on the new account is a monthly cost.

## Links

- `docs/CLOUDFLARE_ACCOUNT_MOVE.md` · ADR 0011 · ADR 0016 · #169
