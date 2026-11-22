# Web client spec

**Status:** proposal (2026-11-21). Issue #21, milestone M3.

**Rests on:** ADR 0002 (own backend), ADR 0008 (agent loop rules live in the
store), ADR 0015 (shared registries), ADR 0016 (sign-in beyond Apple).

## 1. Goal

A responsive web app at `app.septena.app`, on the same account as the other
apps. It is the first way to use Septena on Windows, Linux and Chromebooks,
and on any computer where the user cannot install apps. It does not replace
the native Windows app (#136, ADR 0013), and the site never presents it as
one.

## 2. Stack and hosting

| Part | Choice |
|---|---|
| App | Next.js App Router, React 19, TypeScript, Tailwind, shadcn/ui, Zod at every boundary *(default)* |
| Output | Static export, no server rendering of task data *(default)* |
| Hosting | Cloudflare Workers static assets at `app.septena.app`, same account as the backend *(default)* |
| Repo | This repo, `web/` (ADR 0015 already names it as a codegen target) *(default)* |
| Package manager | pnpm |

The client never sends task data to any host except `api.septena.app`.

## 3. Shared code

- Generated TypeScript constants from `scripts/gen-registries.mjs` (ADR 0015):
  entity schemas, limits, rules, settings, actions, destinations, icons
  (Lucide column), tokens.
- Pure domain rules (`isOnToday`, `inTriageBand`, `nextScheduledDate`,
  `occurrenceID`, list order) move from `backend/src/tools/taskShared.ts` and
  `backend/src/recurrence.ts` into a small workspace package
  (`packages/task-rules`) that both `backend/` and `web/` import. The
  conformance vectors in `registry/conformance/*.json` run against it.
  *(default)*

## 4. Sign-in and session

Per ADR 0016: "I use Septena on another device" (QR and 8-character code,
approved in a signed-in app) or "Continue with email" (6-digit code).

A browser cannot keep a refresh token safely in script-readable storage, so
the web session differs from the native one:

- The access token (`sa1`, 1 hour) stays in memory only.
- The refresh token lives in an HttpOnly, Secure, `SameSite=Lax` cookie on
  `api.septena.app`, scoped to `/v1/auth/`. `app.septena.app` and
  `api.septena.app` are the same site, so the browser sends it with
  credentialed requests.
- `POST /v1/auth/refresh` accepts the cookie when the request carries an
  allowed `Origin`. It rotates the cookie on every refresh, as it rotates the
  body token today. Requests without an allowed `Origin` are refused.
- Sign-out clears the cookie and revokes the session.
- Requests carry `X-Septena-Client: web <version>`.

## 5. Backend work

| Work | Why |
|---|---|
| CORS for `https://app.septena.app` (credentials, the headers the client sends, preflight caching) | The backend has no CORS today |
| Cookie mode for `/v1/auth/*` with an `Origin` allowlist | §4 |
| `POST /v1/sync/ws-ticket` returns a single-use ticket valid 30 seconds; `/v1/sync/ws?ticket=` accepts it | A browser cannot set `Authorization` on a WebSocket |
| Stripe checkout and webhook write the entitlement row with `source: "stripe"` | #43, `docs/SYNC_SUBSCRIPTION_SPEC.md` §9 |

## 6. Sync and offline

The protocol is `docs/SEPTASK_BACKEND.md` §6, with the same client rules as
the Apple apps and `docs/ANDROID_CLIENT_SPEC.md` §4: mutators as the write
boundary, a persistent coalesced outbox with `clientOpId`, shadows for
changed fields, the 120-second delete grace, pull after push, `nextSince`
saved after the batch, `resetRequired` handling and the Not synced list.

- The local store is IndexedDB (rows, shadows, outbox, cursor). *(default)*
- The app works offline once loaded. A service worker caches the app shell.
  Writes queue in the outbox and drain when the browser is back online.
- Several tabs share one store. One tab holds a Web Lock and runs the sync
  engine; the others read the store and send their writes through it with a
  `BroadcastChannel`.
- Signing out deletes the IndexedDB data and the service worker cache for
  that account.
- The app is installable as a PWA. Installing it does not make it a native
  Windows app, and copy says so.

## 7. First release scope

The same scope as Android A2 and Windows W2:

- Inbox band, Today, Upcoming, Anytime, Repeating, Logbook, Recently Deleted.
- Areas, projects and sections.
- When and Deadline, repeat, notes, Quick Find, one undo history.
- Conversations with option pills; Stop on a task and Pause all agents.
- Keyboard-first: shortcuts from `registry/actions.json`, with Ctrl on
  Windows and Linux and Command on macOS. Shortcuts that browsers reserve
  (Ctrl+T, Ctrl+W, Ctrl+N) are excluded through the registry's OS-collision
  field.
- Responsive layout: sidebar and list on wide screens, one column on phones.

Not in the first release: attachment upload (download works), calendar
events, imports, notifications, agent-first onboarding (#103). Each gets an
issue when the first release ships. Fields added in M2 (tags #96, checklists
#76, timed reminders #97) follow the registries: when a field is in
`registry/entities.json`, the web app shows it.

## 8. Phases

| Phase | Done when | Depends on |
|---|---|---|
| WB0 Backend readiness | CORS, cookie session mode and WebSocket tickets ship with tests. | ADR 0016 sign-in (#168, #170) |
| WB1 Spike | A deployed preview signs in by device approval, pulls one account, creates a task offline and pushes it after reconnect. | WB0, R0 registries |
| WB2 Sync core | The TypeScript sync engine, IndexedDB store and multi-tab lock pass the conformance vectors. Rules and sync decisions come from the shared core's WASM (ADR 0025, C2 #248), not from a `packages/task-rules` copy. | WB1, #246 |
| WB3 First release UI | The scope in §7, judged against the Mac app per `docs/DesignSpec.md`. | WB2, registries R1 to R3 |
| WB4 Billing | Stripe checkout turns on sync on every device (#43). | WB3, entitlements enforced, #108 |
| WB5 Launch | `app.septena.app` is public; the site's web page swaps the waitlist for a link. | WB3 |

Gate: `pnpm build` and the conformance tests in CI. mz tests in a browser.

## 9. Open questions

| Question | Default |
|---|---|
| Stack | Next.js static export on Cloudflare Workers static assets *(default)* |
| Address | `app.septena.app` *(default)* |
| Refresh token on web | HttpOnly cookie on `api.septena.app` *(default)* |
| Offline | Works offline after first load; PWA installable *(default)* |
| Shared rules | `packages/task-rules` used by backend and web *(default)* |
| Billing on web | Stripe, in WB4 *(default)* |
