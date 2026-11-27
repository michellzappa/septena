# Sync subscription — spec

**Status:** built (proposed 2026-11-19; updated 2026-11-26). §10 says what
ships. The server still runs its limits in log-only mode
(`ENTITLEMENT_ENFORCE=false`). Defaults marked *(default)* stand until mz
overrules them in §11.
**Decisions:** [ADR 0007](adr/0007-septena-is-the-task-app.md),
[ADR 0002](adr/0002-own-backend-replaces-icloud.md),
[ADR 0010](adr/0010-free-server-tier-with-limits.md) (free account with
limits; changes §1, §3, §6, §7 on 2026-11-20),
[ADR 0023](adr/0023-sync-across-devices-is-plus.md) (free account syncs one
device; changes §1, §3, §3.2, §4 on 2026-11-22),
[ADR 0059](adr/0059-pro-sells-like-plus.md) (Pro sells like Plus on 2026-11-26),
[ADR 0060](adr/0060-revenuecat-subscriptions-and-pinned-currencies.md) (RevenueCat across stores and pinned EUR/USD/GBP currencies on 2026-11-26),
[ADR 0061](adr/0061-seven-year-plus-pass.md) (7-Year Plus Pass at half the annual rate on 2026-11-27).
**Builds on:** the backend (`docs/SEPTASK_BACKEND.md`, auth in §7), the
existing tip jar (`Septena/Shell/Settings/SupportStore.swift`,
`SeptenaPlus.swift`, `Config/Septena.storekit`).
**Prices:** set in App Store Connect. The reasoning lives in the private site
repo (`septena-site/docs/PRODUCT_DIRECTION.md`), not here.

## 1. Goal

Septena (the task app) is free and complete on one device. A free account
adds the server with limits for that one device and one agent (ADR 0023,
ADR 0036). One subscription lifts the limits: live sync on every device, 3
agents, a longer history, synced files and sharing (ADR 0010). The rule in one line: **the device is free, the server is free
with limits, paid lifts the limits.**

## 2. What exists and what is missing

**Exists:**

- `SupportStore`: StoreKit 2 store for a tip jar. Products
  `com.septena.cloud.support.{annual,monthly,lifetime}`, local config
  `Config/Septena.storekit`. The App Store Connect products were never
  created, so the ids are still free to drop.
- `SeptenaPlus`: tip-jar copy, tiers and a cosmetic "Supporter" finish. Its
  header rule says no feature may sit behind `plusUnlocked`. ADR 0007 ends
  that rule for the server features in §3.
- Backend auth: Sign in with Apple once per install; the Worker issues a
  refresh token and an access token; one Durable Object per user
  (`docs/SEPTASK_BACKEND.md` §4, §7).
- The in-app MCP server on macOS (`SeptenaCore/MCP/`), which runs on the
  device and needs no server.

**Missing:**

| Gap | Section |
|---|---|
| A rule for what is free and what is paid | §3 |
| Subscription products on the task app's record | §4 |
| A link between a purchase and a backend user | §5 |
| A server-side entitlement that every paid path checks | §6 |
| App behavior with and without the entitlement | §7 |
| A plan for the tip jar | §8 |
| Purchases outside the App Store | §9 |

## 3. Free and paid

Three levels: Free, Plus and Pro (ADR 0010, ADR 0023, ADR 0036, ADR 0045,
ADR 0052, ADR 0059). Pro sells like Plus, one level above it in the same
subscription group (ADR 0059). An account
adds the server; Plus adds more than one. The earlier rule "the server is paid" is
replaced. The public rule: **free on one device, Plus on all of them.** The
paid plan is named **Septena Plus** on every surface.

| Free, no account | Free account | Septena Plus (€7 / €60) |
|---|---|---|
| Every task feature: lists, projects, areas, Today, Next, recurrence, fade, the composer, quick entry, widgets | Everything in the left column | Everything in the left column |
| Watch app paired to the phone (syncs through the phone) | Server sync for 1 device (backup; moving to a new device is free, the old one stops syncing) | Server sync on all devices, including the watch through the server |
| | Live sync of that device | Live sync on every device |
| Import and export (plain JSON) | Change history: 30 days | Full change history, account restore *(pending a Cloudflare check)* |
| Attachments on the device that added them | Recently Deleted: 30 days | Recently Deleted: 30 days (90 when #446 ships) |
| | Attachments stay on the device that added them (no R2) | Attachments synced, 10 GB |
| | 1 connected agent | 3 connected agents |
| | Join shared projects | Create shared projects and invite |

GitHub is in no plan (ADR 0033). `linkedProjects` stays in the plan
table unused and is not a promise.

Exact numbers ("a few", allowances) are set in the plan table (§6) and can
change without a new ADR. Moving a free thing to paid still needs one. The
plan table's values and all plan copy live in `registry/plans.json`: the
backend reads `PLAN_LIMITS`, the app's Septena Plus page and the site's
/pricing page render the copy, and the generator fails when a stated number
differs from its limit.

Rules:

- A free user never needs an account. The app works from first launch with
  no sign-in. The account starts when the user wants a backup, a shared
  project or the connector. A second device needs Plus.
- Nothing free today becomes paid later without a new ADR.
- No limit touches the core task app. Tasks, lists, projects and areas have
  no caps on any level.
- A limit hides; it never deletes user rows. Export is free on every level.
  Upgrading shows everything again.
- New accounts start with a 14-day reverse trial: the full paid plan, then the
  free account.

### 3.1 History windows

| History | Free account | Paid | How the limit works |
|---|---|---|---|
| Change log (`changes`, who changed what) | 30 days | 365 days | Pruned per plan by the daily alarm. A device offline past the window gets a full resync (exists). |
| Logbook (completed tasks) | All | All | No limit on any level (ADR 0036). |
| Recently Deleted | 30 days | 30 days; 90 when #446 ships | User-facing restore window only. 90 matches the tombstone window (decided 2026-11-22). |
| Deleted rows for sync (tombstones) | 90 days | 90 days | Same on every level: it protects sync, not a feature. |
| Conversation turns | Kept | Kept | Not limited. |

Pruning of the change log after a subscription lapses waits for the lapse
period in §7 (12 months). It never runs on the day the subscription ends.

### 3.2 Upsell moments

An upsell appears only when the user meets a limit: once, with one tap, and
it names what the user gets. All copy goes through the humanizer skill.

| Moment | What the user sees |
|---|---|
| Second device signs in | The device works locally; one line says Plus syncs every device. Moving the slot to this device is offered too. |
| History reaches the window edge | A count of older changes, with one tap to Plus. |
| A task with a file opens on another device | On a plan without file sync: "This file is on another device." Plus syncs files to all devices. On Plus or Pro, while the file is on its way: "Files are still syncing between your devices.", with no upsell. |
| An agent past the count pairs | Replace an agent, or Plus. The server counts agents and only logs for now (ADR 0036, #445). |
| A free member shares a project | Joining is free; creating a share is the upsell. |
| Connector write over the abuse cap (500 a day) | The tool returns one neutral line: the agent can make changes again tomorrow. No Plus sell: the cap is an abuse cap, not a plan feature (ADR 0036). |
| Reverse trial ends | One notice listing what changes. No countdown screens. |

Banned: timed nags, badges on paid features, blocked export, modals on
launch.

### 3.3 The funnel

There is no sales team. The funnel is the product, the paywall (§7.1) and
the trial-end notice. Each step has one job:

| Step | What happens | What moves the user on |
|---|---|---|
| 1. Site | /pricing and the home page say "Free on one device. Plus on all of them." The main button is the download, not checkout. | The download. |
| 2. Install | The full app on one device, with no account and no card. | Real use. Nothing asks for money. |
| 3. Account | The app asks for Sign in with Apple only when the user wants an account feature: a backup, the connector, agents, a shared project, or a second device. Every new account starts the 14-day reverse trial. | One quiet entry point per feature (§7). |
| 4. Second device | During the trial the second device syncs like Plus. | The user sees sync everywhere before paying. |
| 5. Trial end | One notice lists what changes (`trial_end` upsell). The account becomes a free account. | The notice's "See Plus" opens the paywall. |
| 6. Limit | At each limit, the moment's upsell (§3.2), once per account. | "See Plus" opens the paywall. |
| 7. Purchase | The paywall (§7.1), in the store of the platform the user is on (ADR 0026). | |
| 8. Lapse | Free limits, data kept, one device syncs (§7). | "Subscribe again" in Settings ▸ Septena Plus. |

**Measure the funnel on our own server, with counts only.** The backend
already knows each step: account created, devices per account, trial
started, entitlement source and product, expiry. A weekly count per step
(accounts, accounts with 2+ devices, trials, trials that converted,
annual vs monthly, renewals, lapses) needs no client analytics and no third
party. No per-user tracking, no SDKs.

## 4. Products

- New subscription group on the `com.septena.tasks` record, two levels
  (ADR 0059):
  - Pro, the higher level: `com.septena.tasks.sync.pro.monthly`,
    `com.septena.tasks.sync.pro.annual`
  - Plus: `com.septena.tasks.sync.monthly`, `com.septena.tasks.sync.annual`
- No StoreKit introductory offer. The trial is the server-side 14-day reverse
  trial (§3), with no card. Two trials would confuse the paywall. *(default,
  2026-11-22)*
- One non-renewing pass for Plus only (ADR 0061):
  - `com.septena.tasks.sync.plus.7year` — Apple **Non-Renewing Subscription** (never a Non-Consumable), Google Play one-time product, Stripe one-time Checkout. Grants 7 years of Plus (`expiresAt = max(now, currentPlusExpiresAt) + 7 years`). No 7-year Pro pass.
- No lifetime product (7-Year Pass replaces open-ended lifetime, ADR 0061).
- *(default)* Family Sharing off at launch (it needs per-member backend
  accounts; revisit after sharing ships).
- One subscription covers Septena Life too, when Septena Life moves to the
  backend.

## 5. Purchase and account link

1. The user taps a paid feature or "Turn on sync". The app asks for Sign in
   with Apple first if the install has no backend account.
2. The app buys with `Product.purchase(options: [.appAccountToken(token)])`.
   This ties the transaction to the account, not to the device. The backend
   user id (`u_…`) is not a UUID, so `token` is a UUIDv5 of the user id in
   the fixed namespace `b85c7060-77c8-4ea3-b8b4-fdee891cc9ef`, lowercase.
   The app reads it from `GET /v1/entitlement` (`appAccountToken`) or
   computes the same value. *(default, P0: mz can overrule before P1 ships;
   after the first real purchase the namespace can never change.)*
3. The app sends the signed transaction (JWS) to `POST /v1/entitlement/apple`.
4. The Worker verifies the JWS with Apple's root certificates (App Store
   Server Library or an equal check in the Worker), checks that
   `appAccountToken` equals the caller's user id, and stores the result.
5. "Restore purchases" repeats step 3 for every item in
   `Transaction.currentEntitlements`.

## 6. Server entitlement

- The user's Durable Object stores one row: `source` (`apple` / `stripe` /
  `grant`), `productId`, `expiresAt`, `originalTransactionId`, `status`.
- App Store Server Notifications V2 go to `POST /v1/webhooks/apple`. The
  Worker verifies each signed payload and updates the row (renewal, expiry,
  refund, grace period, billing retry).
- Every server path checks the user's **plan** in one place: a Hono
  middleware on `/v1` routes, and the same check in the gateway before it
  reaches the DO. The plan is `plus` when any entitlement row is active,
  else `free`. `trial` (the reverse trial) resolves to the Plus limits, and an
  active `pro` row to `pro` (a Pro grant, ADR 0045, or a Pro store product,
  ADR 0059).
- **Plan table (ADR 0010).** One table in `backend/` maps each plan to its
  limits: device count, sync mode (live / poll), connected agents, change-log
  window, Recently Deleted window, R2 attachments on/off and quota, connector
  writes per day (abuse cap), shared-project create, linked-project
  count. There is no hosted AI (decided 2026-11-22: users bring their own). The alarm's pruning, every history read and every
  gate read this table. Apps fetch their limits from the server and never
  hardcode them.
- **Gates read limits, never the plan name.** No code checks `plan == "paid"`.
  Pro (ADR 0045, ADR 0059) is such a row. A later tier (Supporter, Family; see the
  Starlings doc *Free and paid plans*) is then a new row in the plan table and a new product in the same
  subscription group, with no code change at the gates.
- **Fail closed** on a missing or invalid row, with one exception: grace
  period and billing retry count as active (Apple's own rule).
- A `grant` row (no expiry or a set expiry) covers mz, testers, and press.

### 6.1 Implementation (P0, `backend/`)

**Data.** Table `entitlements` in the user's `TaskStore` Durable Object, one
row per source of access: `id` (`apple:<originalTransactionId>` or
`grant:<name>`), `source`, `productId`, `expiresAt` (ms; null = no expiry),
`originalTransactionId`, `status` (`active` / `grace` / `billing_retry` /
`expired` / `revoked`), `environment`, `note`, `signedAt`, `updatedAt`. The
user is on Pro when any active row has `plan` = `pro` (a Pro grant, ADR 0045,
or an App Store row for a Pro product, ADR 0059),
else on Plus when any row is active. An older Apple payload (`signedDate`)
never overwrites a newer one. KV `TOKENS` maps `ent-otx:<originalTransactionId>`
and `ent-aat:<appAccountToken>` to the user, so a webhook finds its user.
Account deletion removes the rows with the rest of the Durable Object.

**Active.** `active` until `expiresAt` + 24 h (a late renewal notification
does not cut sync); `grace` until the grace period end + 24 h;
`billing_retry` until `expiresAt` + 60 days or Apple's `EXPIRED`;
`expired` and `revoked` never. A grant is active until its `expiresAt`.
*(default: the 24 h leeway; mz can overrule.)*

**Routes** (api.septena.app only; mcp.septena.app answers 404 as before):

| Route | Auth | Does |
|---|---|---|
| `GET /v1/entitlement` | bearer | `userId`, `appAccountToken`, `active`, `enforced`, the rows, and (P1.5, §6.3) `plan`, `limits`, `usage`, `device` |
| `POST /v1/entitlement/device` | bearer | moves the sync slot to the calling device (P1.5, §6.3) |
| `POST /v1/entitlement/apple` | bearer | body `{signedTransaction, signedRenewalInfo?}`; verifies, checks `appAccountToken`, bundle, environment, product; writes the row |
| `POST /v1/webhooks/apple` | Apple JWS | App Store Server Notifications V2 `{signedPayload}`; 200 for any verified payload |
| `POST /v1/admin/grants` | `X-Admin-Token` | body `{userId, name, plan?, note?, expiresAt?}`; writes `grant:<name>` |
| `DELETE /v1/admin/grants/:userId/:name` | `X-Admin-Token` | removes a grant |

The admin page `https://api.septena.app/admin` gives plans (ADR 0043, ADR
0045). A link's claim writes a `grant:link-…` row; Give on an account writes
`grant:admin`. The
`X-Admin-Token` routes stay for scripts.

The admin routes answer 404 while the `ADMIN_TOKEN` secret is unset.

**Verification.** No library: `backend/src/entitlement/appleJws.ts` does
the App Store Server Library's check with WebCrypto. ES256 header, `x5c` of
three certificates; the intermediate must be signed by Apple Root CA - G3,
which is pinned in the code (SHA-256
`63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179`), never
the chain's own root; the leaf must be signed by the intermediate; the leaf
must carry OID 1.2.840.113635.100.6.11.1 and the intermediate
1.2.840.113635.100.6.2.1; every certificate must be valid at the payload's
`signedDate`; the leaf key verifies the JWS. Xcode StoreKit-testing
transactions are signed locally and fail this check by design.

**Counts as a purchase:** bundle id in `APPLE_IAP_BUNDLE_IDS`
(`com.septena.tasks`), environment in `APPLE_IAP_ENVIRONMENTS`
(`Production,Sandbox`), product id starting `com.septena.tasks.sync.`.
*(default: Sandbox counts until public launch, so TestFlight and P1 testing
work; remove it from the var at launch.)*

**Status mapping (webhook).** `data.status` decides (1 active, 2 expired,
3 billing retry, 4 grace, 5 revoked). Without it: `REFUND` / `REVOKE` →
revoked, `EXPIRED` → expired, `DID_FAIL_TO_RENEW` → grace (subtype
`GRACE_PERIOD`) or billing retry, `GRACE_PERIOD_EXPIRED` → billing retry,
anything else → by `expiresDate`. A transaction with `revocationDate` is
revoked. A transaction the app posts never moves a `grace` or
`billing_retry` row to `expired`; only Apple's notifications do.

**Enforcement.** P1.5 replaced the yes/no check with the plan table; see
§6.3. Worker var `ENTITLEMENT_ENFORCE`:

- `"false"` (the default in `wrangler.toml`): every gate runs and logs
  `entitlement_would_block` with the user id, the plan and the limit.
  Nothing is refused, and reads show everything. A failed plan check lets
  the call through with no limits.
- `"true"`: a call past a limit is refused (§6.3). A failed plan check
  logs `plan_check_failed`: sync paths fail open so a store hiccup never
  stops sync, while writes that cost money (attachments, connector writes
  and agent claims) fail closed (503 `plan_check_failed` on `/v1`, a tool
  error on the connector).

The live connector on mcp.septena.app (CloudKit) is not gated.

**App Store Connect (mz, P1).** Set the Production and Sandbox server
notification URLs to `https://api.septena.app/v1/webhooks/apple`, version 2.

### 6.2 Grant yourself (mz, one time)

Run from `~/Dev/septena/backend` after this code is deployed.

1. Make an admin token and store it as a Worker secret. Keep the value in
   your password manager.

   ```
   openssl rand -base64 32 | tee /dev/tty | ./node_modules/.bin/wrangler secret put ADMIN_TOKEN
   ```

2. Find your user id. Start the tail, then open Septena on a device that
   syncs. Copy `userId` from the first `entitlement_free_account` line.

   ```
   ./node_modules/.bin/wrangler tail septena-mcp-gateway --search entitlement_free_account
   ```

3. Write the grant (put your token and user id in):

   ```
   curl -sS -X POST https://api.septena.app/v1/admin/grants -H "X-Admin-Token: TOKEN" -H "Content-Type: application/json" -d '{"userId":"u_YOURID","name":"mz","note":"owner"}'
   ```

   The answer shows `"active": true`. The `entitlement_free_account` lines
   for your user id stop.

4. Only then set `ENTITLEMENT_ENFORCE = "true"` in `backend/wrangler.toml`
   and deploy. A tester gets the same grant with their own `name`; give an
   `expiresAt` (ISO 8601) for a time-limited grant. Remove one with
   `curl -X DELETE https://api.septena.app/v1/admin/grants/u_ID/NAME -H "X-Admin-Token: TOKEN"`.

### 6.3 Plan table and free-account limits (P1.5, `backend/`)

**Plan table.** `PLAN_TABLE` in `backend/src/entitlement/entitlement.ts`
maps `free` → `PLAN_LIMITS.account`, `plus` → `PLAN_LIMITS.plus` and `pro` →
`PLAN_LIMITS.pro`
(generated from `registry/plans.json` `limits`; null = no cap).
`resolvePlan` gives `plus` when any entitlement row is active, else `free`.
`planFor` reads the rows and the usage counters a gate needs in one call to
the user's Durable Object. Every gate reads a limit through `decide`, never
the plan name. Refusals quote the registry's upsell copy (`PLAN_UPSELLS`,
generated from `plans.json` `upsells`), so the words match the app.

**Device.** A device is a session: one sign-in on one install. The access
token carries the session id (`sid`), which survives refresh-token rotation.
Table `devices` in the DO records each session that called a sync route and
its `slotAt`. The slot holders are the `devices` count of live sessions with
the newest `slotAt` within the last 14 days.

- A device that may sync refreshes its `slotAt`. On Plus (no cap) every
  device does, so after a lapse the device used last keeps the slot (§7).
- A device takes a free slot by itself on its first sync. A slot holder
  that has not synced for 14 days loses its slot to the next device that
  syncs, with no prompt (reinstall, restored or new phone; §6.4 finding 1).
  It never pushes out an active holder: the second device stays local and
  gets the `second_device` upsell. *(default 2026-11-22: §3.2's "the device
  works locally; moving the slot is offered" wins over ADR 0023's "the new
  device takes the slot". mz can overrule; then sign-in would call the
  claim.)*
- `POST /v1/entitlement/device` moves the slot to the calling device; the
  old device stops syncing and keeps its local data. Free on every plan,
  limited to one manual move per 24 hours on a capped plan (§6.4 finding 2).
  A second manual move within 24 hours returns 402
  `device_move_rate_limited` with the `second_device` upsell words. Taking
  an open or 14-day-expired slot automatically does not count as a move.
- Signing out (`/v1/auth/signout`) or an expired session frees its slot.
- A device past the count gets 402 `device_not_syncing` on `/v1/sync/*`,
  `/v1/attachments/*` and `/v1/changes`. A token from before session ids
  (at most one hour after deploy) names no device and is let through.

**Reverse trial.** First sign-in writes a 14-day `trial` row in
`entitlements` (resolving to `plus`) and records a KV marker
`trial-used:<userId>` in `TOKENS`. `DELETE /v1/account` does not remove
this marker (and writes it first if the store held a `trial` row), so
deleting and re-signing up with the same Apple id never starts a second
trial (§6.4 finding 4).

**Plan read failure.** Any failure reading the user's plan is logged as
`plan_check_failed`. Sync paths (`/v1/sync/*`, `/v1/changes`, `/v1/tasks*`)
and `POST /v1/entitlement/device` fail open so a Durable Object hiccup
never stops sync for paying users (§6.4 finding 6). Writes that cost money
(`/v1/attachments/*`, MCP connector writes and `tasks_claim`) stay fail
closed in enforce mode (503 `plan_check_failed` on `/v1`, a tool error on
the connector).

**Other limits.**

| Limit | Where | Over the limit (enforce mode) |
|---|---|---|
| `liveSync` | `GET /v1/sync/ws` | 402 `live_sync_not_in_plan`; the app polls `/v1/sync/pull` |
| `changeLogDays` | `GET /v1/changes`, `tasks_history`, `tasks_activity` | Older rows are not shown. `/v1/changes` adds `windowDays` and `hiddenOlder` (count, or null while more pages follow) for the `history_edge` upsell |
| `attachmentsGB` | `PUT /v1/attachments/:id` | 402 `attachments_not_in_plan` (free: 0) or `attachment_quota` (Plus: 10 GB of live uploaded bytes). Downloads of bytes already stored still work |
| `connectorWritesPerDay` | connector write tools and notes writes | Tool error with the `connector_cap` words. Reads always work |
| `connectedAgents` | OAuth code exchange (a new agent pairs) | **Log-only, in both modes.** Logs `agent_limit_over` with the count and the limit; the pairing still works. `GET /v1/access` returns `agents: {count, limit}`. An agent is one MCP connection used in the last 30 days |
| `recentlyDeletedDays`, `createShares`, `linkedProjects` | Apps (read from `GET /v1/entitlement`) | The server has no Recently Deleted, sharing or linked-project surface yet |

Every 402 body is `{error, limit, upsell, message}`: `upsell` is the
moment id from `plans.json` (null for live sync), `message` its words.

**Counters.** Table `usage` in the DO: `cw:YYYY-MM-DD` (connector writes,
UTC day) and `ar:YYYY-MM` (agent runs, UTC month). A call counts after it
ran. The daily alarm drops counters older than 62 days and `devices` rows
whose session is gone.

**`GET /v1/entitlement` adds:** `plan` (`free` / `plus`), `limits` (the
plan table row), `usage` (`connectorWritesToday`, `agentRunsThisMonth`),
`device` (`syncing` for the caller, `syncingDevices`, `knownDevices`).

**Not built in P1.5:**

- The reverse trial (§3). It needs an account start date that the server
  does not record for existing accounts; existing testers would all get a
  trial from deploy day. Next step: record the first sign-in, resolve
  `trial` for 14 days, give it the Plus limits.
- Per-plan pruning of the change log. The alarm still prunes every account
  at 365 days; the free window only hides. This follows "a limit hides" and
  the 12-month lapse rule; the cost is a few MB per free account.
- App work: the second-device upsell and the "sync this device" button,
  poll-only sync on free, the 402 bodies. The app reads all of it from
  `GET /v1/entitlement` and the 402 body.

### 6.4 Limit logic review (2026-11-22)

A review of §6.3 before `ENTITLEMENT_ENFORCE` turns on. Each finding has
a default; mz can overrule it. Nothing here is built yet unless it says so.

**1. A reinstall looks like a second device.** A device is a session. A
reinstall, a restored phone or a new phone signs in as a new session while
the old session still holds the slot until it expires. The user then sees
the `second_device` upsell on the phone they always used, which breaks
"replacing a phone never needs Plus" (ADR 0023).
*Default:* a slot holder that has not synced for 14 days loses the slot to
the next device that syncs, with no prompt. The move button stays for the
case inside 14 days.

**2. The free move can stand in for Plus.** `POST /v1/entitlement/device`
is free and instant, so a free user with a phone and a Mac can move the
slot back and forth and get two-device sync by hand.
*Default:* one move per 24 hours. A second move inside that window returns
402 with the `second_device` words. Finding 1's automatic take does not
count as a move.

**3. "Delete lapsed data after 12 months" contradicts the free account.**
§7 says the server keeps a lapsed user's data 12 months, then deletes it.
But a lapsed account is a free account, and a free account keeps one
device syncing to the server. Deleting its data would delete a free
account's backup.
*Default:* lapsing never deletes tasks. After 12 months lapsed, the server
deletes only what the free plan does not hold: attachment bytes in R2 and
change-log rows past the free window, after a warning mail. An account with
no sign-in for 24 months is deleted after a warning mail, on every plan.

**4. The trial can repeat.** The user id comes from the Apple `sub`, so
deleting the account and signing in again gives the same user id with an
empty Durable Object, and `startTrialOnce` starts a new trial.
*Default:* keep a KV marker `trial-used:<userId>` that account deletion does
not remove. It holds no personal data beyond the id the server already
derives.

**5. Old app builds meet 402.** Builds from before P1 do not know the 402
bodies. Once enforcement is on, a free account on such a build sees a sync
error instead of the upsell.
*Default:* enforcement turns on only after a build that handles every 402
body is the only build on TestFlight and the App Store, and after a week of
`entitlement_would_block` logs shows what would block.

**6. A plan check failure blocks paying users too.** In enforce mode a
failed plan read returns 503 on sync for everyone. That is fail closed, as
§6 says, but a Durable Object hiccup then stops sync for Plus accounts.
*Default:* keep fail closed for writes that cost money (attachments,
agent claims), and let sync through on a failed plan read, logged as
`plan_check_failed`. Sync of one device is free anyway; the device check
needs the plan only to block a second device.

**7. A purchase on the wrong account is silent.** An Apple ID that bought
Plus while signed in to Septena account A, then used with account B, gets
403 `account_mismatch`; the app finishes the transaction and shows
"failed".
*Default:* the Plus sheet says "This Apple ID's Plus belongs to another
Septena account" when `Transaction.currentEntitlements` holds a Plus
transaction whose `appAccountToken` is not this account's.

**8. Live sync on one device.** With one syncing device, `liveSync: false`
mostly delays agent and connector edits reaching the app, which is the
moment the free account should feel agents work.
*Decided 2026-11-24 (ADR 0036):* live sync on every account.

**9. What already holds.** The trial and a lapse leave the device used
last syncing (newest `slotAt`). Grace and billing retry stay active. A
refund revokes at once. History past the free window hides and comes back
on upgrade. Downloads of stored files keep working on free. Counters use
UTC days and months, and a renewal of a claim is not a new agent run.

**Issues:** #262 (findings 1, 2, 4, 6 — built in `backend/`), #263 (finding 3), #264 (402
bodies, findings 5 and 8), #265 (finding 7), #267 (turn enforcement on).

**Order to turn enforcement on:** findings 1, 2, 4 and 6 in the backend;
the app handles every 402 body (the upsell moments, issue list in §10);
grants for testers; a week of `entitlement_would_block` logs; then
`ENTITLEMENT_ENFORCE=true`.

## 7. App behavior

- **Active:** sync runs, the connector works, agents run.
- **No account:** the app is the full free app on one device. Server
  features show one quiet entry point each, never a modal on launch.
- **Free account:** sync runs within the free limits (§3). At a limit the app
  shows the upsell for that moment (§3.2) and nothing else.
- **Lapsed:** the account falls back to the free limits. The most recently
  used device keeps syncing; the others keep their local data and stop
  syncing (ADR 0023). Local data stays on every device and stays fully editable. Lapsing never deletes tasks: after 12 months the server
  deletes only attachment bytes and change-log rows past the free window,
  after a warning mail (§6.4, finding 3). Re-subscribing resumes sync with the server
  copy as the base and pushes local edits on top (the normal op queue).
- The app never deletes local data because a subscription ended.
- Agents and links stop at expiry. Open agent claims return to the user.

### 7.1 The paywall

One sheet, **the plan sheet** (`SeptaskPlusSheet`), is the only place that
sells Plus and Pro in the app (ADR 0059). It opens only from a tap, never on
launch and never on a timer.

**Where it opens from:**

- "See Plus" or "See Pro" on an upsell moment (§3.2), including the full
  agent list in Settings ▸ AI & Agents ▸ Agents (`agents_full`,
  `agents_full_plus`).
- Settings ▸ Septena Plus (`SeptaskPlusPane`): "See Plus" before a plan,
  "See Pro" on Plus, "Manage Subscription" on Pro or a store subscription
  with nothing above it.
- "See Plus" on the trial-end notice.

**Each upsell moment shows once per account.** The "shown" mark syncs with
the account's other settings, so a second device does not repeat it. After
that the moment stays as a quiet line where the limit is (the device row,
the history edge, the file row, the agent list), never as a new prompt.

**How it sells (in the order a reader decides):**

1. **Why it opened.** The moment's title and detail come first. With no
   moment, the plan name and the ladder headline.
2. **Which plan.** A Plus / Pro picker. The sheet opens on the plan that
   answers the moment (`upsells[].plan` in `plans.json`). An account on
   Plus sees only Pro, as an upgrade.
3. **What changes.** The plan's card line, then its card rows (devices,
   agents, files, history). A value that differs from the account's plan
   today is bold in the accent; one that stays the same is quiet. A trial
   compares with Free, because the trial ends in a free account.
4. **The price.** StoreKit lists the picked plan's two products, annual
   first. Under it: cancel at any time, the no-hostage promise, Restore,
   Terms, Privacy.

```text
┌───────────────────────────────────────┐
│ Not Now                Septena Plus   │
│                                       │
│  All three agent slots are in use     │  ← the moment: title
│  Plus connects three agents. Pro …    │    and detail
│                                       │
│  [   Plus   |▐  Pro  ▌]               │  ← opens on the moment's plan
│                                       │
│  ◉ With Pro                           │
│    For people who run many agents …   │
│  Devices        All your devices      │  ← quiet: same as today
│  Agents                 No limit      │  ← bold accent: what changes
│  Files              50 GB synced      │
│  History                365 days      │
│                                       │
│  ┌─────────────────────────────────┐  │
│  │ ● €120 a year                   │  │  ← StoreKit, the picked plan
│  │ ○ €14 a month                   │  │
│  └─────────────────────────────────┘  │
│  [            Subscribe            ]  │
│  Cancel at any time in Settings.      │
│  We never hold your data back         │
│  Restore Purchases · Terms · Privacy  │
└───────────────────────────────────────┘
```

**How it is built (standard StoreKit, no custom store UI):**

- `SubscriptionStoreView(productIDs:)` for the picked plan, with the pitch
  as its marketing header, rebuilt when the plan changes. Plus and Pro are
  two levels of one subscription group (Pro level 1, Plus level 2), so the
  App Store handles upgrade, downgrade and proration.
- `.subscriptionStoreControlStyle(.picker)`. Every purchase carries
  `appAccountToken` (§5). Every word comes from `registry/plans.json`
  (`paywall`, `upsells`, `cards`, `cardRows`), so the site and every app
  say the same words. Copy goes through the humanizer skill.
- The Mac App Store build sells with the same sheet. The Mac download build
  (Developer ID, Sparkle) has no App Store receipt: it never shows the
  store, it says to buy in the App Store version and that the plan turns
  on at sign-in (`PlusStore.isDirectDownload`, #683).
- The sheet reads `PlanStatus` and the entitlement source. It never decides
  the plan itself.

**The sheet by plan state:**

| State | Main action | Notes |
|---|---|---|
| No account | "Try Plus free for 14 days" (Sign in) | The pitch and the picked plan's prices show as information. Signing in starts the reverse trial. |
| Trial | Subscribe | "Plus is on until {date}"; a purchase now starts billing today, and the sheet says so. |
| Free account | Subscribe | The standard sheet. |
| Lapsed (was Plus) | Subscribe | The title reads "Welcome back". |
| Plus through Apple or a grant | Subscribe to Pro | Only Pro. Through Apple, one line says Pro starts at once and the App Store refunds the unused Plus. |
| Plus through Google Play or the web | None | The owned line, and "change your plan in the store where you bought Plus" (ADR 0026: never two purchases). |
| Pro | Manage Subscription | No prices. |

**After the purchase:**

1. `.success` with a verified transaction: the app posts the JWS to
   `POST /v1/entitlement/apple`, refreshes `PlanStatus`, then finishes the
   transaction. The sheet shows "Plus is on. Your other devices start
   syncing." and a Done button.
2. `.pending` (Ask to Buy, Strong Customer Authentication): "Waiting for
   approval." The `Transaction.updates` listener completes it later.
3. `.userCancelled`: the sheet stays as it was, with no message.
4. The server cannot be reached: the transaction stays unfinished, and the
   sheet says "Purchase received. Plus turns on when Septena reaches the
   server." The `Transaction.updates` listener that starts at launch retries
   until the server accepts it. The user never pays twice.

**Other platforms** render the same registry copy. Android: the same sheet
in Compose, buying through Play Billing. Web and Windows: the Plus page on
septena.app for the signed-in account, which opens Stripe Checkout and
returns to a thank-you page. The Windows app opens that page in the browser
(ADR 0026).

## 8. The tip jar

*(default)* Remove the tip jar from the task app. One way to pay, not two.
Keep the cosmetic supporter finish only if a subscriber gets it. The
`com.septena.cloud.support.*` products were never created in App Store
Connect, so nothing breaks. Septena Life may keep the tip jar until it moves
to the backend.

## 9. Other platforms, RevenueCat and currencies

Decided in ADR 0026 (2026-11-22) and amended in ADR 0060 (2026-11-26). One
account, one subscription (Plus or Pro, ADR 0059), bought on any store, valid
on every device.

- **Subscription backend (ADR 0060):** Standardize on **RevenueCat** (free up
  to $2,500 USD MTR, 1% above) across Apple App Store, Google Play and
  Web/Windows (Stripe / RevenueCat Web Billing). Every purchase maps to the
  Septena backend user id (`u_…`) as `app_user_id`. RevenueCat webhooks sync
  entitlement rows into the user's Durable Object `entitlements` table so the
  plan table and every server gate stay unchanged; the P0 direct Apple JWS
  verifier (`backend/src/entitlement/appleJws.ts`) is superseded once
  RevenueCat integration ships. Task data and sync traffic never touch
  RevenueCat.
- **Currencies (ADR 0060, amended 2026-11-27):** EUR is the single baseline
  (`€7 / €60 / €210 (7 yrs)` Plus, `€14 / €120` Pro; 7-Year Pass decided in
  ADR 0061). No manual currency pinning across stores: App Store Connect and
  Google Play auto-equalize every storefront from the EUR base.
  - **Web & Windows:** EUR baseline via RevenueCat / Stripe; Stripe Tax
    calculates VAT and Envisioning Technology files EU VAT through the One Stop
    Shop.
  - **Pricing page (`/pricing` and home plan cards):** Quiet inline currency
    dropdown above the plan cards with the Big 3 (`EUR`, `USD`, `GBP`) on top
    and the next 10 major currencies below. Visitors from any other country
    automatically see their own local currency converted from EUR via `/api/geo`
    (`CF-IPCountry` + daily edge-cached EUR FX rates), with an approximate-price
    footnote.
  - **Annual price lock:** Locked in purchase currency within the same store;
    protects Septena's subscription price tier, excluding statutory tax changes.
- **No double payment:** an account on Plus or Pro from any source sees no buy
  button for the same tier anywhere, only where to manage it.
- **No checkout link out of a store app** at launch, on iOS or Android.

## 10. Phases

| Phase | Work | Exit |
|---|---|---|
| P0 | Entitlement row, Apple JWS verify, webhook, `grant` rows, middleware on `/v1` and the gateway. mz has a `grant`. | A user without a row gets 402 on sync; mz syncs. |
| P1 | Products in App Store Connect, StoreKit purchase + restore in the task app, account link, the Plus sheet (§7.1) with its registry `paywall` copy, the reverse trial, lapsed state. Remove the tip jar from the task app. | A sandbox purchase turns on sync; a sandbox expiry stops it, and local data stays. |
| P1.5 | Server side built 2026-11-22 (§6.3), except the reverse trial. Plan table and free-account limits (ADR 0010): device count, poll-only sync, history windows, local-only attachments, connector and agent caps, reverse trial, upsell moments (§3.2). | A free account syncs 1 device; a second device stays local and shows the upsell; a paid account lifts every limit. |
| P2 | Free-mode audit: every free feature works with no account and no network. | Fresh install, airplane mode, every free feature works. |
| P3 | Stripe for the web client and Windows (ADR 0026): Checkout, customer portal, webhooks, Stripe Tax. | A web purchase turns on sync on iPhone. |
| P4 | Google Play Billing with the Android app (ADR 0026): `google` source, Play Developer API, real-time developer notifications. | A Play purchase turns on sync on Mac. |

**P1 status (2026-11-22).** Built in code: the reverse trial on the server
(a `trial` entitlement row written once at the first sign-in, `trialEndsAt`
on `GET /v1/entitlement`), `PlusStore` (purchase with `appAccountToken`,
the `Transaction.updates` listener from launch, Restore Purchases, finish
only after the server answered), the Plus sheet (`Septask/SeptaskPlusSheet.swift`)
with its registry `paywall` copy, the plan states in `PlanStatus` (trial,
lapsed, source), and a local StoreKit file (`Config/Septena.storekit`) on
the `Septask` and `SeptaskMac` schemes. Upsell moments built in the app
(2026-11-22): `second_device` and `trial_end` as Today notices (at most one
at a time, trial_end first), `history_edge` as a quiet last line under a
task's history (`/v1/changes` sends `upsell: "history_edge"` only on the
free plan with hidden rows). The sheet adds "Sync This Device" for
`second_device` (`POST /v1/entitlement/device`), and Settings ▸ Septena
Plus keeps that line after the notice is gone. "Once per account" is the
synced setting `upsellsSeen`. `file_elsewhere` shows in a task's
attachments on a plan without file sync; on Plus or Pro the same row shows a
neutral syncing line. `share_create` is the 402 line when a free account
creates a shared project. `connector_cap` is the MCP tool's neutral line at
the abuse cap. The connected-agent count only logs on the server for now (#445).
The App Store Connect products do
not exist yet; `checkout.open` stays false until they do. The Mac sells
once its release moves to the Mac App Store (ADR 0026).

P0 can start after roadmap M1 phase 0 (backend auth exists). P1 must ship
before any public release that uses the backend.

## 11. Open questions for mz

| Question | Default |
|---|---|
| Monthly and annual price | Decided 2026-11-19: €5 / €40. Raised 2026-11-22 to €7 / €60. Pro added 2026-11-26 at €14 / €120 (ADR 0059). Currencies pinned 2026-11-26: EUR €7/€60, USD $7/$60, GBP £6/£50 (Pro 2×), rest auto-equalized from EUR (ADR 0060) |
| Web payment provider & subscription backend | Decided 2026-11-22: Stripe, not a merchant of record (ADR 0026). Amended 2026-11-26: standardize on RevenueCat across Apple, Google Play and Web/Stripe, with fixed EUR/USD/GBP on web (ADR 0060) |
| Subscribing during the trial | Default 2026-11-22: billing starts on the day of purchase; the sheet says so (§7.1) |
| Terms of Use | Default: Apple's standard EULA, linked from the paywall and the App Store listing |
| Trial length | Decided 2026-11-19: 14 days |
| Does the watch need the subscription? | No, it syncs through the paired phone |
| Is the hosted Claude connector paid? | Yes, it runs on our server |
| Lifetime / one-time product | No lifetime product. 7-Year Plus Pass at €210 / $210 / £175 / R$ 840 (50% off annual × 7, Plus only; Apple Non-Renewing Subscription, Play/Stripe one-time), paired with free Cloudflare self-hosting (ADR 0011, ADR 0061, decided 2026-11-27) |
| Family Sharing | Off at launch |
| How long the server keeps a lapsed user's data | Tasks: always (it is a free account). Attachment bytes and old history: 12 months, with a warning mail first (§6.4) |
| Tip jar in the task app | Removed |
| Early TestFlight access as a subscriber perk | Yes |
| Does the code stay open source? | Yes; the paid product is the hosted service |
| Free server tier | Decided 2026-11-20: yes, a free account with limits (ADR 0010) |
| Attachments on the free account | Decided 2026-11-20: none on the server; files stay on the device that added them |
| Recently Deleted on Plus vs the 90-day tombstone window (§3.1) | Decided 2026-11-22: Plus keeps Recently Deleted 90 days |
| A free account's second device: take the slot at sign-in (ADR 0023) or stay local and offer the move (§3.2) | Default 2026-11-22: stay local, offer the move (§6.3) |
| Limit values ("a few" connector writes, agent runs, hosted-AI allowance) | Decided 2026-11-24 (ADR 0036): 1 connected agent on a free account, 3 on Plus, and a 500-writes-a-day abuse cap on a free account. No hosted AI (decided 2026-11-22: users bring their own Claude). The values live in `registry/plans.json` `limits` (generated to `PLAN_LIMITS` for the backend) |
