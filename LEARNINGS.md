# Septena ↔ Claude: integration learnings

Hard-won context on how Claude reads/writes a user's **private** Septena
(CloudKit) data via the MCP gateway. Read this before changing the auth/token
design — several "obvious" approaches are dead ends, proven empirically.

## 2026-11-18 decision: tasks move to our own backend

This **reverses** the "no copy of user data at rest" and "private CloudKit
only" constraints below, **for task data only** (tasks, areas, projects,
task attachments, task conversations). mz decided it on 2026-11-18 because
the ~8h `ckWebAuthToken` makes Claude access fail whenever no device opened
the app recently, and that cannot be fixed on the CloudKit path (see "The
core wall"). Claude must work from claude.ai, mobile, Claude Code and
unattended scheduled agents.

- Task data lives in a per-user `TaskStore` Durable Object (SQLite) in this
  Worker, attachment bytes in R2. Spec: `docs/SEPTASK_BACKEND.md` in the app
  repo.
- Every other Septena section stays on CloudKit and keeps the constraints
  below.
- Do not "restore" the no-data-at-rest rule for tasks. Do not move another
  section to the backend without a new decision from mz.

## Goal & constraints (decided)

- **Who pays / where it runs:** the user's own **Claude subscription**, via an
  MCP connector on claude.ai / Claude mobile (Fork B). The gateway is a
  Cloudflare Worker at `mcp.septena.app`.
- **No copy of user data at rest.** The gateway stores only short-lived
  *credentials*, never life data. (A plaintext mirror was rejected: cost +
  liability + it breaks Septena's "local-first, we never see your data"
  positioning.)
- **Private CloudKit only.** All Septena data lives in the user's CloudKit
  **private** DB (`septena-v1` zone). Nothing is in the public DB.

## The core wall

Apple provides **no silent / server-side way to obtain a PRIVATE-DB
CloudKit Web Services token.**
- `ckWebAuthToken` lasts **~8h** and has **no refresh token**.
- Server-to-server CloudKit keys reach the **public** DB only.
- So a hosted server cannot hold durable access to a user's private DB.

## What we tried and rejected (don't redo these)

1. **Gateway pulls via CloudKit Web Services, holding the browser-minted
   `ckWebAuthToken`.** Works, but the token dies in ~8h with no refresh →
   claude.ai needs a reconnect ~daily. Fragile; this is the thing we moved off.

2. **Native silent mint: `CKFetchWebAuthTokenOperation`.** This is the only
   native API, and its token is **PUBLIC-DB ONLY**. Verified empirically:
   `users/current` on the private path returned **403 `ACCESS_DENIED`** (vs
   `AUTHENTICATION_REQUIRED` when unauth). So the app cannot natively mint a
   private-scoped token. Dead end.

3. **Raw `WKWebView` "silent renewal"** (persistent cookie jar, offscreen
   re-mint). Intended to drop the periodic Apple prompt. **Reverted** because:
   - Silent path unreliable — the offscreen 1×1 web view doesn't reliably run
     idmsa's JS redirect, and the cookie jar didn't hold the Apple session
     across hours → fell back to interactive at ~6h anyway.
   - **Worse interactive UX:** a raw WKWebView gets **no Password AutoFill** and
     **no shared system Safari/Apple session**, so every sign-in was manual
     typing. ASWebAuthenticationSession gets both (the whole reason it's
     tolerable). Net regression.

4. **Device-as-backend tunnel** (app reads CloudKit *natively* — never expires —
   and relays results via a Cloudflare Durable Object; no web token, no copy).
   This is the ONLY design that removes Apple auth entirely. **Not pursued**
   because it needs the app **reachable when Claude queries**, and iOS suspends
   backgrounded apps → realistically requires an **always-on Mac**. Revisit only
   if "zero Apple prompt, works while everything's closed" becomes a hard
   requirement.

## What actually works (current design)

- The **app** drives the idmsa web sign-in with **`ASWebAuthenticationSession`**
  (Safari context → autofill + fast sign-in when the Apple session is alive),
  captures the `ckWebAuthToken` from the gateway's HTTPS callback, and POSTs it
  to `/ingest/ck-token`.
- The **gateway** stores the token **per CloudKit user** (`cktoken:<userRecordName>`),
  and binds each claude.ai **bearer to that identity** at OAuth time. So the
  bearer is durable; it always resolves to the freshest pushed token.
- The app **re-mints on foreground** (throttled ~7h, under the 8h lifetime), so
  the token stays live without claude.ai reconnecting.
- `/ingest/ck-token` is **self-securing**: the pushed token is validated via
  `users/current`; no extra shared secret.

**Accepted tradeoff:** an Apple consent prompt at most ~once per ~8h *when you
open the app* (foreground-only; no background refresh is possible). The
sign-in itself is quick via the live Safari session. True "no prompt ever"
needs design #4.

## Key facts / gotchas (so we don't rediscover them)

- **API token is app-level & shared** (semi-public, ships in the binary, like
  CloudKit JS). Per-user isolation comes from each user's own `ckWebAuthToken`,
  NOT the API token. App's `webServicesAPIToken` **must equal** the gateway's
  `CK_API_TOKEN`; a token is scoped to the API token that minted it.
- **`users/current` signals:** `userRecordName` present → authed OK;
  `403 ACCESS_DENIED` → token is public-only; `AUTHENTICATION_REQUIRED` +
  `redirectURL` → unauthenticated / API-token mismatch.
- **`ASWebAuthenticationSession` `.https` callback (iOS 17.4+)** requires
  Associated Domains **`webcredentials:mcp.septena.app`** (not `applinks`) plus
  an AASA file at `/.well-known/apple-app-site-association` — served `200`,
  `application/json`, **no redirect**, body
  `{"webcredentials":{"apps":["992N457T8D.com.septena.cloud"]}}`.
- **AASA during dev:** real **device only** (not Simulator); association is
  evaluated **at install** (delete + reinstall after entitlement changes). To
  skip Apple's CDN lag, enable **Settings → Developer → Associated Domains
  Development** AND use `webcredentials:mcp.septena.app?mode=developer` in the
  entitlement. Remove `?mode=developer` before shipping (prod relies on the
  CDN-served AASA, which can take hours to propagate).
- **Refresh is foreground-only** — `ASWebAuthenticationSession` / WKWebView need
  UI. No background/suspended refresh. If the app isn't opened for >8h,
  claude.ai's tool calls fail until next open (no reconnect needed — opening the
  app restores it).
- The gateway is **multi-user by construction** (per-`userRecordName` keying),
  no data stored, near-zero marginal cost; each user pays their own inference.

## Production cutover (mandatory before real users)

Tracked as a Septena task too. Before App Store / TestFlight:
- Deploy the CloudKit **schema to production**.
- Flip **both** `ckEnvironment` (app, `ClaudeGatewayProvider`) and
  `CK_ENVIRONMENT` (gateway, `wrangler.toml`) to **`production`**.
- Ensure the **production** API token has the
  `https://mcp.septena.app/auth/apple/callback` sign-in callback URL.
- Remove `?mode=developer` from the entitlement.
- Smoke test: Connect in app → `ingest_ck_token: ok:true` → a private read in
  Claude returns real records.
