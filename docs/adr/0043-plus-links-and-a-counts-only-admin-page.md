# 0043. Plus is given by link, and the admin page sees counts only

- Status: accepted (2026-11-25)
- Date: 2026-11-25
- Deciders: mz (product), agent (mechanism)
- Amends: [ADR 0016](0016-sign-in-beyond-apple.md) (how a sign-in subject is
  stored). Implements #198, with one change: the page stores a summary per
  account.

## Context

mz wants to give Plus to people and to see accounts, counts and client
status. An account has no email and no name, so a list of accounts cannot say
who is who, and the grant route needs an account id that no app shows. Sign-in
will have more providers than Apple. Each account is its own Durable Object, so
a page cannot read them all on each load. The privacy page says tasks are
stored for the user alone.

## Decision

- **Plus is given by link** (`https://api.septena.app/plus/<token>`). mz names
  the link, sets how long Plus lasts from the claim (default 12 months, or no
  end) and how many accounts may claim it. Two controls, as in the list links
  of Microsoft To Do: *close* stops new people, *take back* ends Plus for one
  account or for everyone. The label is how mz knows who an account is.
- **The claim runs on the web, with the approval code of ADR 0016.** It works
  for every sign-in provider and every app already installed. A "plus" code
  mints no session. No app gets a code field or a link handler: App Review
  forbids unlocking features in the app by anything but an in-app purchase
  (3.1.1).
- **The admin page shows counts, dates, plans and client versions.** It never
  shows a title, a note, a file name or a name the user typed, and it has no
  "view as user". `TaskStore.accountSummary` is the only source; a new field
  there must pass this rule.
- **Its only writes are Plus links.** Deleting data and refunds stay separate.
- **Cloudflare Access protects it and the Worker checks the Access token.**
  Anything missing answers 404.
- **A sign-in subject is stored hashed for every provider, except an email
  address.** A provider's id is opaque, so a hash finds the account as well.
  An email stays readable because codes and recovery mail go to it. The page
  shows the provider, never the subject.
- **One admin page.** The community worker's `/admin/telemetry` is gone.

## Consequences

- `AccountStore` holds an index: one summary per account, at most a day old,
  written by an hourly cron. Account deletion removes it with the account's
  link claims. A link keeps its count, so deleting an account frees no use.
- A lost link cannot be shown again: only its hash is stored. Make a new one.
- mz cannot find an Apple account from an email address. Until the apps show
  an account id, a person deletes their own account in the app.
- Adding a sign-in provider needs no change to links or to the page. It needs
  a change to the privacy page before it opens.
