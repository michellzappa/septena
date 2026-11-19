# septena-mcp-gateway

Hosted MCP server that bridges Claude.ai (and any other remote-MCP client) to a user's Septena data in CloudKit. Each user authorizes once via Apple sign-in; their personal `ckWebAuthToken` is stored encrypted in Cloudflare KV and used to query their own private CloudKit DB.

## Status

Scaffold. OAuth + Apple bridge wired end-to-end with KV storage; the initial task, project, and area tools are ported. Untested against a live `wrangler dev` / claude.ai connector — that's the next step.

## Architecture

```
┌──────────────┐    ┌──────────────────────┐    ┌─────────────────────────┐
│  claude.ai   │───►│  mcp.septena.app     │───►│  api.apple-cloudkit.com │
│  user's      │    │  (Cloudflare Worker) │    │  private DB (per user)  │
│  browser     │    │                      │    └─────────────────────────┘
└──────────────┘    │  Workers KV:         │
                    │   STATE / CLIENTS    │
                    │   TOKENS (encrypted) │
                    └──────────────────────┘
```

## Endpoints

The `/v1` routes are the task backend (`src/api/`, `src/store/`), served on `api.septena.app`. Spec and migration phases: `docs/SEPTASK_BACKEND.md` in the app repo.

| | |
|---|---|
| `GET /.well-known/oauth-authorization-server` | RFC 8414 metadata for client discovery |
| `POST /oauth/register` | RFC 7591 Dynamic Client Registration (https-only redirect URIs, pinned to known client hosts) |
| `GET /oauth/authorize` | claude.ai sends user here → we redirect to Apple |
| `GET /auth/apple/callback` | Apple lands here with `ckWebAuthToken`; we mint a code |
| `POST /oauth/token` | code + PKCE → 1h access token + rotating 30d refresh token; also serves the `refresh_token` grant |
| `POST /oauth/revoke` | RFC 7009 revocation (access or refresh token; refresh revokes the pair) |
| `POST /mcp` | JSON-RPC MCP transport (Authorization: Bearer required) |
| `POST /v1/auth/apple` | Task backend: Sign in with Apple identity token + raw nonce → access + refresh token |
| `POST /v1/auth/refresh` · `/v1/auth/signout` | Rotate (single-use) or revoke a task-backend refresh token |
| `POST /v1/sync/push` · `GET /v1/sync/pull` | Task sync: batched field patches in, changes since a `rev` out |
| `GET /v1/sync/ws` | WebSocket nudge `{rev}` on every commit |
| `PUT`/`GET /v1/attachments/:id` | Attachment bytes to/from R2 (25 MB per file, 2 GB per user) |
| `DELETE /v1/account` | Delete all task data and attachment bytes for the user |
| `GET`/`DELETE` `/mcp` | `405` — the GET stream and session-DELETE were removed in MCP `2026-07-28` |
| **api.septena.app only** | Read-only MCP preview over the task backend (phase 2 "shadow", `src/shadow/`). Same paths as above, host-switched in `src/index.ts`; mcp.septena.app is unchanged. |
| `POST /mcp` (api host) | Read-only task tools from the user's TaskStore: `tasks_list`, `tasks_get`, `tasks_list_areas`, `tasks_list_projects`, `tasks_thread_get`, `tasks_pending_reasoning`. Bearer `sm1.` required. |
| `GET /.well-known/oauth-authorization-server` · `/oauth-protected-resource` (api host) | Discovery with issuer `https://api.septena.app`, scope `tasks:read` |
| `POST /oauth/register` (api host) | DCR, same redirect policy as live, clients under KV `v2:client:` |
| `GET /oauth/authorize` (api host) | Shows an 8-character pairing code; the page refreshes itself |
| `GET /oauth/pair/continue` (api host) | The page's poll: once the app approves, 302 to the client with `code`, `state`, `iss` |
| `POST /oauth/token` · `/oauth/revoke` (api host) | PKCE code → `sm1.` access (1h) + rotating `smr1.` refresh (30d); revocation |
| `POST /v1/pair/approve` | App bearer (`sa1.`) + `{code, timeZone?}` binds the user to a pending pairing. 404 wrong code, 409 used, 429 after 5 wrong codes in 10 min |

## Protocol revisions

The gateway is **dual-era** (`src/protocol.ts`), serving both shapes of MCP on
the one `/mcp` endpoint:

- **Modern — `2026-07-28`.** Stateless. No handshake: every request declares
  its protocol version, client identity, and capabilities in `params._meta`,
  mirrored into `MCP-Protocol-Version` / `Mcp-Method` / `Mcp-Name` headers that
  the server validates against the body (mismatch ⇒ `400` + `-32020`). Results
  carry `resultType: "complete"` and `_meta` `serverInfo`; `tools/list` carries
  `ttlMs` + `cacheScope`. `server/discover` is implemented, as the spec
  requires.
- **Legacy — `2025-11-25` and earlier.** The `initialize` /
  `notifications/initialized` handshake, answered as before.

**Do not delete the legacy path.** Claude's connector has not shipped modern
support, so a modern-only gateway would take the live connector offline the day
it deploys. The era is decided per request from how the client opens, which is
what the spec prescribes for a dual-era server.

We never implemented sessions (`Mcp-Session-Id`), the GET stream, SSE
resumability, roots, sampling, or logging — so the removals and deprecations in
`2026-07-28` cost this gateway nothing.

`tools/list` still varies by user (it reflects their enabled sections). That is
explicitly legal: the spec forbids varying by *connection state*, and permits
varying by "the authorization presented on the request". It is served
`cacheScope: "private"` so no shared intermediary can hand one user's manifest
to another.

## Local development

```sh
# 1. Install deps
npm install

# 2. Create KV namespaces — paste returned IDs into wrangler.toml
wrangler kv namespace create STATE
wrangler kv namespace create TOKENS
wrangler kv namespace create CLIENTS

# 3. Set local secrets in .dev.vars (copy from .dev.vars.example)
cp .dev.vars.example .dev.vars
# Fill in CK_API_TOKEN (from CloudKit Dashboard) and TOKEN_ENC_KEY:
openssl rand -base64 32   # paste into .dev.vars as TOKEN_ENC_KEY

# 4. Run locally
npm run dev   # listens on http://localhost:8787
```

Cloudflare Tunnel for public reachability (so claude.ai and Apple's redirect can hit it):

```sh
cloudflared tunnel --url http://localhost:8787
# or, with a stable named hostname (preferred — Apple's redirect URL is fixed):
cloudflared tunnel route dns septena-mcp-dev mcp-dev.septena.app
cloudflared tunnel run septena-mcp-dev
```

Then in **CloudKit Dashboard → Tokens & Keys → API Tokens**, create a token whose URL Redirect is `https://mcp-dev.septena.app/auth/apple/callback`. Use that token's value as `CK_API_TOKEN`.

## Production deploy

```sh
# Set production secrets
wrangler secret put CK_API_TOKEN --env production
wrangler secret put TOKEN_ENC_KEY --env production

# Create production KV namespaces, paste IDs under [env.production] in wrangler.toml
wrangler kv namespace create STATE --env production
wrangler kv namespace create TOKENS --env production
wrangler kv namespace create CLIENTS --env production

wrangler deploy --env production
```

Production CloudKit API token's URL Redirect: `https://mcp.septena.app/auth/apple/callback`.

## End-user flow (once deployed)

1. User clicks "Add Septena to Claude" on septena.app — a deep link that pre-fills `https://mcp.septena.app/mcp` as a custom connector.
2. claude.ai performs DCR, redirects the user to `/oauth/authorize`.
3. Gateway redirects to Apple sign-in.
4. User signs in with their Apple ID.
5. Apple redirects to `/auth/apple/callback` with `ckWebAuthToken`.
6. Gateway issues OAuth code, redirects back to claude.ai.
7. claude.ai exchanges code at `/oauth/token`, gets access token.
8. From now on, every `POST /mcp` from claude.ai is authenticated; tools query the user's private DB.

## Roadmap

- [ ] First live test with `wrangler dev` + tunnel + claude.ai connector
- [x] Initial MCP tools: `tasks_list`, `tasks_create`, `tasks_complete`, `tasks_update`, `tasks_defer`, `tasks_move_to_today`, `tasks_list_projects`, `tasks_list_areas`, `sections_list`
- [ ] Search tools
- [x] Re-auth UX when CloudKit returns 401 (token expired) — user-bound bearers now degrade to an **in-band** tool error (`isError: true`) instead of a hard 401, so Claude's connector stays connected and self-heals on the next call once the app re-mints the token (paired with the app's "Keep Claude connected" nudge). Legacy bootstrap-only bearers still get the discovery 401.
- [ ] `claude://` deep-link button on septena.app
- [ ] Promote CloudKit schema to Production + production API token
- [ ] Additional domains: chores, nutrition, training, groceries, intake, symptoms, medications
- [ ] Streamable HTTP transport with SSE for server-initiated messages
- [ ] Sentry / minimal analytics; "delete my data" endpoint for App Store compliance
