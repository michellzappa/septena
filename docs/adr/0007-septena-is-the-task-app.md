# 0007. Septena is the task app; the life OS becomes Septena Life

- Status: accepted (2026-11-19)
- Date: 2026-11-19
- Deciders: mz

## Context

- Two apps grew from one repo: the life OS (today called Septena) and the
  task app (working name Septask, `docs/SEPTASK.md`).
- The task app is the product with a clear buyer: a task manager with agents
  that work tasks. The life OS asks too much of most people (food, gut and
  supplement logging) to sell on its own.
- ADR 0002 moves both apps off iCloud to the own backend. A server-owned task
  store makes sync a service we run per user, and it costs money per user.
- Each app already has its own App Store record and bundle IDs:
  - life OS: `com.septena.cloud` (+ `.mac`, `.watchkitapp`, widgets, live
    activities, share)
  - task app: `com.septena.tasks` (+ `.mac`, `.watchkitapp`, `.share`)
- The App Store name "Septena" sits on the `com.septena.cloud` record today.
  App Store names are unique across the store. A US search on 2026-11-19
  found no app called "Septena" (other than ours) and none called "Septena
  Life". Plain "LifeOS" is taken by about 30 apps.

## Decision

The task app takes the name **Septena** and is the primary product. The life
OS becomes **Septena Life**, a secondary product. Both keep their current App
Store records and bundle IDs; only the display names change. "Septask" stays a
working name in code and docs and never ships to users. Septena sells on
several platforms with a small subscription for sync. Septena Life moves to
the own backend too, after the task app; that move is not planned yet.

## Consequences

- mz renames the records by hand in App Store Connect, in one sitting:
  first `com.septena.cloud` → "Septena Life" (this frees the name), then
  `com.septena.tasks` → "Septena". Each rename needs an editable version.
- Bundle IDs, the CloudKit container and the app groups do not change. Users
  never see them.
- New user-facing strings, domains and ids must not say "Septask".
- Existing docs that call the life OS "Septena" are stale on the name. Code
  identifiers (`Septena*`, `Septask*` targets and folders) stay as they are
  until a separate rename spec says otherwise.
- septena.app serves both products. septena.com belongs to someone else
  (registered 2018, expires 2027-01-21).
- Sync becomes a paid feature. A spec must define the paywall (StoreKit and
  the other stores), what stays free, and how the backend checks the
  subscription.
- The life OS stops carrying tasks once the task app has cut over to the
  backend (decided earlier the same day; see `docs/SEPTASK_BACKEND.md`).
- Pricing, positioning and the reasoning behind the business model live in
  the private site repo, not here.

## Links

- ADR 0002 (own backend replaces iCloud)
- `docs/SEPTASK.md`, `docs/SEPTASK_BACKEND.md`, `docs/APPSTORE-SEPTASK.md`
