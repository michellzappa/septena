# 0011. Keep the backend self-hostable on the user's own Cloudflare account

- Status: proposed
- Date: 2026-11-21
- Deciders: mz

## Context

- ADR 0002 moved task data from the user's iCloud to `api.septena.app`. The
  promise "your data lives only in your iCloud" is gone.
- The backend is in this public repo under the MIT license (`backend/`): one
  Cloudflare Worker, one Durable Object per user (`TaskStore`), a
  `PairingStore` Durable Object and one R2 bucket. A person with a Cloudflare
  account can already run `wrangler deploy` on it.
- The apps cannot use such a deploy. `TaskBackendClient.baseURL` and the
  Septask connector URL hard-code `https://api.septena.app`.
- Sign in with Apple identity tokens carry the app's bundle id as audience.
  A self-hosted server can check them against Apple's public keys without its
  own Apple developer account. Not tested yet.
- ADR 0010 estimates server cost at about $0.015 a month per active user.
  Self-hosting does not save a user money. Its value is control and trust.
- Some features need secrets that only Septena holds: APNs push (our key),
  hosted AI (ADR 0009), and server-side integration keys (ADR 0003).
- Durable Objects with SQLite storage are Cloudflare-specific. Whether
  standalone `workerd` runs them well enough for production is unknown.

## Decision

The backend stays self-hostable as a goal, and self-hosting stays
unsupported. The supported target is the user's own Cloudflare account. We do
not port the backend to Docker, Postgres or another platform.

We keep the path open with these rules, built after the backend cutover is
stable:

1. The app takes its server URL from one setting (Advanced), default
   `api.septena.app`. The MCP connector URL derives from it.
2. The plan table (ADR 0010) has an unlimited mode. A server in that mode
   enforces no limits, and the apps show no upsell.
3. The HTTP API carries a version. The server states the versions it
   accepts, and an app refuses an unknown server version with a clear
   message instead of corrupting data.
4. A feature that needs a Septena-held secret turns off cleanly on a server
   without it. Sync never depends on it (foreground fetch stays the reliable
   path).
5. `backend/SELF_HOSTING.md` documents the deploy steps and lists what does
   not work there.

We do not advertise self-hosting until rule 3 is in place.

## Consequences

- Users who distrust our server get a real alternative, which replaces part
  of the trust that ADR 0002 gave up.
- App and server can no longer change their contract together. Released apps
  must work with servers that never update, within the versions rule 3
  defines. This is the main cost.
- Push, hosted AI and server-side integrations do not work on a self-hosted
  server unless the operator adds their own keys where that is possible.
- Shared projects (ADR 0004) work only between accounts on one server. No
  federation.
- A self-hosted user pays us nothing for the server. We accept this. The
  audience is small and technical.
- Support requests from setups we cannot see. "Unsupported" sets that
  expectation; we answer what we choose to.
- If we ever need a Cloudflare-only feature that a single-account deploy
  cannot copy, this ADR constrains it. A new ADR is needed to drop the goal.

## Links

- ADR 0002, ADR 0003, ADR 0004, ADR 0009, ADR 0010
- `docs/SEPTASK_BACKEND.md`
- `SeptenaCore/TaskBackend/TaskBackendClient.swift`,
  `Septask/SeptaskBackendSettingsPane.swift`, `backend/wrangler.toml`
