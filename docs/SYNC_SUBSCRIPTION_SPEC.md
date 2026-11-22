# Sync subscription — spec

**Status:** proposed 2026-11-19. Defaults marked *(default)* stand until mz
overrules them in §11.
**Decisions:** [ADR 0007](adr/0007-septena-is-the-task-app.md),
[ADR 0002](adr/0002-own-backend-replaces-icloud.md),
[ADR 0010](adr/0010-free-server-tier-with-limits.md) (free account with
limits; changes §1, §3, §6, §7 on 2026-11-20),
[ADR 0023](adr/0023-sync-across-devices-is-plus.md) (free account syncs one
device; changes §1, §3, §3.2, §4 on 2026-11-22).
**Builds on:** the backend (`docs/SEPTASK_BACKEND.md`, auth in §7), the
existing tip jar (`Septena/Shell/Settings/SupportStore.swift`,
`SeptenaPlus.swift`, `Config/Septena.storekit`).
**Prices:** set in App Store Connect. The reasoning lives in the private site
repo (`septena-site/docs/PRODUCT_DIRECTION.md`), not here.

## 1. Goal

Septena (the task app) is free and complete on one device. A free account
adds the server with limits for that one device (ADR 0023). One subscription lifts the limits: live sync on
every device, full history, synced files, agents, links and sharing
(ADR 0010). The rule in one line: **the device is free, the server is free
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

Three levels (ADR 0010, ADR 0023). The earlier rule "the server is paid" is
replaced. The public rule: **free on one device, Plus on all of them.** The
paid plan is named **Septena Plus** on every surface.

| Free, no account | Free account | Septena Plus (€5 / €40) |
|---|---|---|
| Every task feature: lists, projects, areas, Today, Next, recurrence, fade, the composer, quick entry, widgets | Everything in the left column | Everything in the left column |
| Watch app paired to the phone (syncs through the phone) | Server sync for 1 device (backup; moving to a new device is free, the old one stops syncing) | Server sync on all devices, including the watch through the server |
| The local MCP server on the Mac | Sync every few minutes (no live socket) | Live sync (socket) |
| Import and export (plain JSON) | Change history: 30 days | Full change history, account restore *(pending a Cloudflare check)* |
| Attachments on the device that added them | Recently Deleted: 30 days | Recently Deleted: 1 year |
| | Attachments stay on the device that added them (no R2) | Attachments synced, 10 GB |
| | Claude connector: read, plus a few writes a day | Claude connector without daily caps |
| | Agents: a few runs a month | Agents within the run budget (ADR 0008) |
| | Join shared projects | Create shared projects and invite |
| | 1 linked project | Linked projects without a cap |
| | Hosted AI: small monthly allowance *(if ADR 0009 is accepted)* | Hosted AI: larger allowance *(if ADR 0009 is accepted)* |

Exact numbers ("a few", allowances) are set in the plan table (§6) and can
change without a new ADR. Moving a free thing to paid still needs one.

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
| Logbook (completed tasks) | Last 90 days shown | All | Rows are kept on every level; reads page only within the window. |
| Recently Deleted | 30 days | 1 year | User-facing restore window only. |
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
| A task with a file opens on another device | "1 file on your iPhone." Plus syncs files to all devices. |
| An agent runs out of runs | The task says the agent resumes on the 1st, or now with Plus. The work waits. |
| A free member shares a project | Joining is free; creating a share is the upsell. |
| Connector write over the daily cap | The tool returns one line with the upgrade link. No nagging inside a conversation. |
| Reverse trial ends | One notice listing what changes. No countdown screens. |

Banned: timed nags, badges on paid features, blocked export, modals on
launch.

## 4. Products

- New subscription group on the `com.septena.tasks` record, one level:
  - `com.septena.tasks.sync.monthly`
  - `com.septena.tasks.sync.annual`
- No StoreKit introductory offer. The trial is the server-side 14-day reverse
  trial (§3), with no card. Two trials would confuse the paywall. *(default,
  2026-11-22)*
- *(default)* No lifetime product. A lifetime sale pays once for a server
  that costs money every month.
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
  reaches the DO. The plan is `paid` when any entitlement row is active,
  `trial` during the reverse trial, else `free`.
- **Plan table (ADR 0010).** One table in `backend/` maps each plan to its
  limits: device count, sync mode (live / poll), change-log window, Logbook
  window, Recently Deleted window, R2 attachments on/off and quota, connector
  writes per day, agent runs per month, shared-project create, linked-project
  count, hosted-AI allowance. The alarm's pruning, every history read and every
  gate read this table. Apps fetch their limits from the server and never
  hardcode them.
- **Gates read limits, never the plan name.** No code checks `plan == "paid"`.
  A later tier (Pro, Supporter, Family; see the Starlings doc *Free and paid
  plans*) is then a new row in the plan table and a new product in the same
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
user has sync when any row is active. An older Apple payload (`signedDate`)
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
| `GET /v1/entitlement` | bearer | `userId`, `appAccountToken`, `active`, `enforced`, the rows |
| `POST /v1/entitlement/apple` | bearer | body `{signedTransaction, signedRenewalInfo?}`; verifies, checks `appAccountToken`, bundle, environment, product; writes the row |
| `POST /v1/webhooks/apple` | Apple JWS | App Store Server Notifications V2 `{signedPayload}`; 200 for any verified payload |
| `POST /v1/admin/grants` | `X-Admin-Token` | body `{userId, name, note?, expiresAt?}`; writes `grant:<name>` |
| `DELETE /v1/admin/grants/:userId/:name` | `X-Admin-Token` | removes a grant |

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

**Enforcement.** One check, `hasSyncEntitlement` in
`backend/src/entitlement/entitlement.ts`, used by the `/v1` middleware
(`/sync/*`, `/attachments/*`, `/changes`) and by the api.septena.app
connector's write tools (`tasks_*` writes, `tasks_claim`,
`tasks_release`). Worker var `ENTITLEMENT_ENFORCE`:

- `"false"` (the default in `wrangler.toml`): the check runs and logs
  `entitlement_would_block` with the user id. Nothing is refused. A failed
  check lets the call through.
- `"true"`: no active row → 402 `{"error":"subscription_required"}` on
  sync, a tool error on connector writes. A failed check blocks (fail
  closed).

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
   syncs. Copy `userId` from the first `entitlement_would_block` line.

   ```
   ./node_modules/.bin/wrangler tail septena-mcp-gateway --search entitlement_would_block
   ```

3. Write the grant (put your token and user id in):

   ```
   curl -sS -X POST https://api.septena.app/v1/admin/grants -H "X-Admin-Token: TOKEN" -H "Content-Type: application/json" -d '{"userId":"u_YOURID","name":"mz","note":"owner"}'
   ```

   The answer shows `"active": true`. The `entitlement_would_block` lines
   for your user id stop.

4. Only then set `ENTITLEMENT_ENFORCE = "true"` in `backend/wrangler.toml`
   and deploy. A tester gets the same grant with their own `name`; give an
   `expiresAt` (ISO 8601) for a time-limited grant. Remove one with
   `curl -X DELETE https://api.septena.app/v1/admin/grants/u_ID/NAME -H "X-Admin-Token: TOKEN"`.

## 7. App behavior

- **Active:** sync runs, the connector works, agents run.
- **No account:** the app is the full free app on one device. Server
  features show one quiet entry point each, never a modal on launch.
- **Free account:** sync runs within the free limits (§3). At a limit the app
  shows the upsell for that moment (§3.2) and nothing else.
- **Lapsed:** the account falls back to the free limits. The most recently
  used device keeps syncing; the others keep their local data and stop
  syncing (ADR 0023). Local data stays on every device and stays fully editable. The server keeps the data *(default: 12 months)*, then mails a
  warning before it deletes. Re-subscribing resumes sync with the server
  copy as the base and pushes local edits on top (the normal op queue).
- The app never deletes local data because a subscription ended.
- Agents and links stop at expiry. Open agent claims return to the user.

## 8. The tip jar

*(default)* Remove the tip jar from the task app. One way to pay, not two.
Keep the cosmetic supporter finish only if a subscriber gets it. The
`com.septena.cloud.support.*` products were never created in App Store
Connect, so nothing breaks. Septena Life may keep the tip jar until it moves
to the backend.

## 9. Other platforms

- Web and Android buy through Stripe (web checkout) and Google Play billing.
  Each writes the same entitlement row with its own `source`.
- One account, one entitlement, any store. A user who pays on iPhone gets
  sync on the web client.
- Apple rules: the iOS app does not link to the web checkout unless the
  storefront allows it.

## 10. Phases

| Phase | Work | Exit |
|---|---|---|
| P0 | Entitlement row, Apple JWS verify, webhook, `grant` rows, middleware on `/v1` and the gateway. mz has a `grant`. | A user without a row gets 402 on sync; mz syncs. |
| P1 | Products in App Store Connect, StoreKit purchase + restore in the task app, account link, paywall sheet, lapsed state. Remove the tip jar from the task app. | A sandbox purchase turns on sync; a sandbox expiry stops it, and local data stays. |
| P1.5 | Plan table and free-account limits (ADR 0010): device count, poll-only sync, history windows, local-only attachments, connector and agent caps, reverse trial, upsell moments (§3.2). | A free account syncs 1 device; a second device stays local and shows the upsell; a paid account lifts every limit. |
| P2 | Free-mode audit: every free feature works with no account and no network. | Fresh install, airplane mode, every free feature works. |
| P3 | Stripe for the web client. | A web purchase turns on sync on iPhone. |

P0 can start after roadmap M1 phase 0 (backend auth exists). P1 must ship
before any public release that uses the backend.

## 11. Open questions for mz

| Question | Default |
|---|---|
| Monthly and annual price | Decided 2026-11-19: €5 / €40 (reasoning in the private site repo) |
| Trial length | Decided 2026-11-19: 14 days |
| Does the watch need the subscription? | No, it syncs through the paired phone |
| Is the hosted Claude connector paid? | Yes, it runs on our server |
| Lifetime product | None |
| Family Sharing | Off at launch |
| How long the server keeps a lapsed user's data | 12 months, with a warning mail first |
| Tip jar in the task app | Removed |
| Early TestFlight access as a subscriber perk | Yes |
| Does the code stay open source? | Yes; the paid product is the hosted service |
| Free server tier | Decided 2026-11-20: yes, a free account with limits (ADR 0010) |
| Attachments on the free account | Decided 2026-11-20: none on the server; files stay on the device that added them |
| Limit values ("a few" connector writes, agent runs, hosted-AI allowance) | Open: set in the plan table before P1.5 |
