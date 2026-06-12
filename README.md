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

| | |
|---|---|
| `GET /.well-known/oauth-authorization-server` | RFC 8414 metadata for client discovery |
| `POST /oauth/register` | RFC 7591 Dynamic Client Registration |
| `GET /oauth/authorize` | claude.ai sends user here → we redirect to Apple |
| `GET /auth/apple/callback` | Apple lands here with `ckWebAuthToken`; we mint a code |
| `POST /oauth/token` | claude.ai exchanges code + PKCE verifier for access token |
| `POST /mcp` | JSON-RPC MCP transport (Authorization: Bearer required) |

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
