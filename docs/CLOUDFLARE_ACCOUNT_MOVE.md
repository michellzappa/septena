# Cloudflare account move

**Status:** accepted (2026-11-21). Decision: ADR 0018.

Account ids, token values and secret values never go in this file.

## 1. What moves

| Worker (repo path) | Domains | Storage | Secrets |
|---|---|---|---|
| `septena-mcp-gateway` (`backend/`) | `api.septena.app` | KV `STATE`, `TOKENS`, `CLIENTS`; Durable Objects `TaskStore` (one per user), `PairingStore`; R2 `septena-attachments` | `SESSION_SIGNING_KEY`, plus any set only as vars |
| `septena-community` (`community-worker/`) | `community.septena.app` | D1 `septena-community`; KV `ATTEST`, `CHALLENGES`, `RL` | `ADMIN_DASHBOARD_TOKEN`, `TELEMETRY_HASH_SALT`, `USER_HASH_SALT` |
| `septena-site` (`../septena-site`) | `septena.app`, `www.septena.app` | static assets only | none |
| Zone `septena.app` | all of the above | DNS records, including Gandi mail (MX, SPF) | none |

Not moving: `reports-worker/` (template only, not deployed), Starlings
(`septena.starlings.work`, its own account).

## 2. What can be copied and how

| Data | Method | Notes |
|---|---|---|
| `TaskStore` per user | New admin routes: `GET /v1/admin/export/:userId` returns every table as JSON; `POST /v1/admin/import/:userId` writes them into an empty store. `rev`, ids and `changes` keep their values, so client cursors stay valid. | Cloudflare has no Durable Object copy tool. |
| List of user ids | Values of `api-refresh:*` keys in KV `TOKENS`, plus grant rows. | There is no user registry. Pre-launch, every real user has a live session. |
| `PairingStore` | Not copied. Codes live 10 minutes. | |
| KV namespaces | Script: list keys, read each value with its expiration, write to the new namespace. | `TOKENS` holds app refresh tokens and MCP tokens, so copying it keeps sessions and the Claude connector working. |
| R2 `septena-attachments` | Super Slurper (R2 is a supported source) or `rclone`. | Keys `u/{userId}/att/{id}` stay the same. |
| D1 `septena-community` | `wrangler d1 export`, then `wrangler d1 execute --file`. | |
| Secrets | Set again with `wrangler secret put`. | Reuse the old values if mz has them. A new `SESSION_SIGNING_KEY` only expires access tokens (clients refresh). New hash salts would break the community data's user links, so those must be the old values. |
| DNS records | Export a BIND file from the old zone, import into the new one. | Keep the Gandi MX and SPF records, or septena.app mail stops. |

## 3. Steps

Each step names who does it. "Agent" steps run from this repo on mz's laptop
with wrangler logged in as the new account's owner.

1. **mz:** create the Cloudflare account "Septena" under the owner login of
   the Starlings account, and buy Workers Paid on it.
2. **Agent:** build the admin export and import routes in `backend/`, with
   tests, and deploy them to the old account.
3. **Agent:** create the KV namespaces, R2 bucket and D1 database on the new
   account. Put their ids in each `wrangler.toml` on a branch, with the new
   `account_id`.
4. **mz:** give the old secret values, or confirm new ones for
   `SESSION_SIGNING_KEY` and `ADMIN_DASHBOARD_TOKEN`. The two salts must be
   the old values.
5. **Agent:** deploy all three workers to the new account on `workers.dev`
   addresses only (no custom domains yet).
6. **Agent, write freeze:** deploy the old backend with writes answering 503.
   The apps keep their changes in the outbox and retry later.
7. **Agent:** copy KV, every user's `TaskStore`, R2 and D1. Compare row
   counts and object counts per user through both admin routes.
8. **mz:** export the DNS records from the old zone. Add `septena.app` to the
   new account and import the records. Switch the nameservers at Gandi to the
   two the new account shows. Press "Re-check now".
9. **Agent:** when the zone is Active, attach the custom domains to the new
   workers (`api`, `community`, apex, `www`) and check each one.
10. **mz:** sign in on iPhone and Mac and confirm tasks, attachments and the
    Claude connector work.
11. **Agent:** set up Email Sending for `septena.app` on the new account
    (#169).
12. **Agent, after 14 days:** remove the Septena workers, KV, R2 and D1 from
    the old account. The old zone deletes itself.

The outage is the time between step 8 and step 9. While the new zone is
pending, it serves no worker traffic. The old workers stay in freeze until
then.

## 4. Checks before the old account is cleaned

- Every user's task, area, project, convo and turn counts match.
- Attachment counts and byte totals match per user.
- An existing app session refreshes against the new backend.
- The Claude connector lists tasks without re-pairing.
- Mail to an `@septena.app` address still arrives.
- The Apple App Store webhook reaches `/v1/webhooks/apple`.
