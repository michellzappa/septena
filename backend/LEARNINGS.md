# Septena ↔ Claude: integration learnings

Hard-won context on how Claude reads/writes a user's **private** Septena
(CloudKit) data via the MCP gateway. Read this before changing the auth/token
design — several "obvious" approaches are dead ends, proven empirically.

## 2026-11-19: Septask settings on the backend (`setting` entity)

Septask is now CloudKit-free, so the few account-wide settings it used to
read from the CloudKit `Settings` record sync through the task backend.

- **Shape:** table `settings`, one row per key, `value` = JSON. Allowed keys
  and their schemas live in `SETTING_VALUES` (`src/store/columns.ts`, the one
  source of truth); `ops.ts` builds one strict upsert schema per key from it,
  so an unknown key or a wrong type is refused at the edge. Today:
  `welcomeName`, `telemetryLevel`, `calendarHiddenTitles`,
  `rolledInDismissedOn`, `homeTimezone`. Adding a setting = one line there,
  plus the app's `SeptaskSyncedSettings.keys` (keep in lockstep).
- **Never deleted.** `delete` is not allowed for `setting`: a tombstone would
  make every later upsert `dropped` (deleted stays deleted). Clear with
  `value: null`.
- **Pull is opt-in: `GET /v1/sync/pull?…&settings=1`.** App builds before
  this change decode entities strictly and would fail a whole pull on an
  unknown `setting` row. Without the flag the DO skips the settings table
  (the cursor still moves past those revs). New app builds always send it and
  re-pull once from rev 0 so settings pushed before they asked arrive.
- **Migration:** nothing to run. `migrate()` already runs
  `CREATE TABLE IF NOT EXISTS` for every entity in `ENTITIES` at DO start, so
  the new table appears on the first request after deploy.
- **The MCP connector reads `homeTimezone`** for "today" (`effectiveTimeZone`
  in `src/shadow/mcp.ts`), falling back to the zone the app sent at pairing,
  then UTC. One extra DO read per tool call.
- **Order of deploy:** the gateway can deploy before or after the app. An app
  that pushes settings to an older gateway gets the op refused, stops sending
  settings for that launch, and tries again next launch.

## 2026-11-19: the api.septena.app connector writes

`https://api.septena.app/mcp` now serves every task tool of the live
connector, writes included, so it can replace mcp.septena.app for tasks once
the devices are on the backend.

- **One push per tool call.** Each write builds its TaskStore ops and sends
  them in one `push(ops, "mcp:claude")`: one transaction, one `{rev}` nudge to
  the user's app sockets (`push` broadcasts whenever an op applied). The
  clientOpIds are random per call, `mcp-<random>-<n>` per op. The ops pass the
  same `zPushBody` schema as `/v1/sync/push` before they reach the store.
- **Shared logic, not copies.** Provenance, update planning, repeat-rule
  parsing, container errors, conversation normalizing and recurrence warnings
  are pure functions in `src/tools/writeTasks.ts`, used by the CloudKit tools
  and by `src/shadow/writes.ts`. The extraction was checked by running the old
  and new CloudKit tool code against a recording mock client on about 25,000
  generated inputs: identical requests and results.
- **Recurrence converges with the app.** Completion uses the app's anchor
  (`recurrenceAnchorDate`, then `scheduled`; `nextScheduledDate` gained the
  optional `logicalScheduled` the Swift calculator has) and `occurrenceID`, so
  Claude and the app derive the same occurrence id. `recurrencePaused`
  suppresses the spawn, as in the app. An occurrence id that was deleted
  before (an undo in the app) stays deleted: the push answers `dropped` and the
  tool returns the `recurrenceWarning`.
- **Order follows the app, not the live gateway.** A new task, a recurring
  occurrence and a re-homed task get `position` = lowest order key − 1024
  (`TaskOrder.topPosition`; `TaskStore.readOrderTop` reads the key the app
  uses). A row that lands on Today gets `todayPosition` = its `position`, the
  app's rule (`TaskBackendMapping`).
- **Scope:** new pairings get `tasks:read tasks:write`. Refresh rotation keeps
  the old scope, so a pre-write pairing stays read-only; its write calls return
  an in-band `isError` result that tells the user to reconnect.
- **Known gap, inherited:** `newTaskId` maps a random byte with `& 31` onto a
  31-character alphabet, so index 31 yields `undefined` and the id is shorter
  than 6 characters in about 17% of creates. Not changed here (live behavior).
  The backend create retries on an id that already exists.

## 2026-11-19: phase 2 preview connector uses app pairing, not web sign-in

The read-only test connector at `https://api.septena.app/mcp` (`src/shadow/`)
reads the user's TaskStore. Its OAuth needs a user id, and web Sign in with
Apple needs a Services ID (developer-portal work we chose not to do). So the
authorize page shows a short code and the signed-in Septask Mac app approves
it (`POST /v1/pair/approve`), like a TV device code.

- **Pairing state lives in a Durable Object (`PairingStore`), one per code,
  not KV.** The page polls the same key every few seconds; KV caches a read at
  the edge for up to a minute, so the approval would show late. The DO also
  makes the approve-once rule atomic.
- **Brute force is limited per user**, in the user's own TaskStore (5 wrong
  codes per 10 minutes). A wrong code maps to no pending pairing, so a
  per-code counter cannot see it.
- **The cookie, not the code, finishes the flow.** The code only binds a
  user; polling and the redirect need the random `pendingId` in the
  browser's HttpOnly cookie.
- **Phishing risk is the device-code one:** someone could get a user to enter
  the attacker's code and so read the user's tasks. The app copy says to
  enter only a code from a browser window you opened yourself.
- **Host split, live untouched:** `byHost` in `src/index.ts` sends api-host
  requests to the preview handlers and every other host (mcp.septena.app,
  localhost) to the live handlers unchanged. The JSON-RPC envelope moved to
  `src/rpc.ts` and the pure task rules to `src/tools/taskShared.ts`; both
  endpoints use them, so the live output did not change.
- **Token prefixes keep kinds apart:** `sa1.`/`sr1.` app session, `sm1.`/`smr1.`
  MCP preview, unprefixed live. KV keys for the preview are under `v2:`.
- **"Today" needs a time zone and the DO has no Settings record.** The app
  sends `TimeZone.current` at approve time; it rides in the grant. Travel
  changes need a re-pair. Fallback is UTC.

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
