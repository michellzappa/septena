# 0002. Own backend replaces iCloud

- Status: accepted
- Date: 2026-11-19 (task scope decided 2026-11-18; mz extended it to the whole
  app on 2026-11-19)
- Deciders: mz

## Context

- Claude reads the private CloudKit database through a web token that lives
  about 8 hours. Apple gives no server-side refresh. Claude loses access
  whenever no device opened the app recently
  (`docs/SEPTASK_BACKEND.md` §2).
- CloudKit has no Android or web client, and no server can act on the data
  while every device sleeps.
- The features we want next all need a server that owns the data: linked
  projects, sharing between users, and agents that work tasks unattended.

## Decision

Septena and Septask leave iCloud. The data moves to an own backend at
`api.septena.app`: Cloudflare Workers, one Durable Object per user (SQLite),
R2 for files, Sign in with Apple. SwiftData stays as the local cache. The
migration is its own track, specified in `docs/SEPTASK_BACKEND.md`, and runs
separately from the feature specs that depend on it.

## Consequences

- New specs design for the backend only. No CloudKit path, no "before
  cutover" variant.
- Agents and integrations can run at any time, on the server.
- Android and web clients become ordinary clients of one HTTPS API.
- We give up "your data lives only in your iCloud." Privacy labels, the site
  and in-app copy (`docs/AI_TASKS_EXPLAINER.md`) must change before release.
- We run servers and pay for them per user.
- Docs that rest on iCloud are stale on that point:
  `docs/NATIVE_PROJECT_SHARING_SPEC.md`, `docs/SEPTASK_ANDROID_PLAN.md`,
  `docs/CloudKitSchema.md` after cutover.

## Links

- `docs/SEPTASK_BACKEND.md`
- ADR 0003, 0004, 0005 depend on this ADR.
