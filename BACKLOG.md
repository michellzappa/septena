# Backlog

## Move to CloudKit **production** to unlock long-lived (2-week) tokens — without data loss

### Why
The gateway currently runs on `CK_ENVIRONMENT=development`. This caps us at
CloudKit's **30-minute** web-auth tokens:

- Apple's `ckWebAuthToken` is **30 min** by default, **2 weeks** only with the
  "Keep me signed in" / CloudKit.js `persist` path.
- That longer-token path goes through CloudKit **web auth**, which **only works
  on production**. Verified empirically (same API token, `public/users/caller`):
  - `development` → **421 Misdirected Request** (CloudKit web auth refuses dev)
  - `production`  → **401** (reachable; normal "not signed in yet")
- The raw 30-min flow we ship today works on dev only because it uses a
  different endpoint (`private/users/current`). It cannot get a longer token.

So **2-week tokens require production.** No gateway code change gets around this.

### The catch
CloudKit **development and production are separate datastores**. Deploying the
schema to production does **not** copy data. Our data currently lives in
**development** (the iOS app is an Xcode/debug build writing to dev CloudKit).
Naively flipping `CK_ENVIRONMENT=production` would point the gateway at an empty
production database.

### Definition of done
- Gateway runs on `CK_ENVIRONMENT=production`.
- CloudKit.js sign-in works (→ test whether `persist:true` actually yields the
  2-week token — still UNVERIFIED, now testable on prod).
- No personal data lost in the move.

### Plan (no data loss)
1. **Deploy CloudKit schema to Production** (CloudKit Console → Deploy Schema
   Changes to Production). Schema only — safe, no data.
2. **Get data into production.** Two options:
   - **(Preferred, organic)** Ship the iOS app via TestFlight/App Store. A
     production build writes the user's records to production CloudKit going
     forward. Existing dev data still needs step (b) if it must be preserved.
   - **(b) One-time dev→prod migration.** A throwaway migration that reads every
     record from the dev private DB (existing `CK_API_TOKEN`, dev/private) and
     writes them to the prod private DB. Writing to prod private requires a
     **prod** web-auth token (user signs in once via a CloudKit.js prod page).
     Bounded but real work; preserve `recordName`s to keep relations intact.
3. **Switch** `CK_ENVIRONMENT=production` in `wrangler.toml` and redeploy.
4. **Restore the CloudKit.js sign-in path** (removed from the tree while on dev —
   see git history for `src/oauth/signin.ts` + `src/oauth/cloudkitToken.ts`).
   Use `persist:true`. Capture the raw `ckWebAuthToken` by intercepting
   CloudKit.js's own `fetch`/XHR to `api.apple-cloudkit.com` (it does not expose
   the token to a `message` listener).
5. **Verify the lifetime.** Watch the `ck_auth_expired` log's `tokenAgeMinutes`:
   - ~30 min → `persist` did NOT buy the long token; reassess.
   - thousands (≈20160 = 14 days) → success.
6. If tokens still expire too fast, consider a **keepalive cron** (scheduled
   Worker) that carries the rotated token forward to slide the session — only if
   measurement shows rotation actually extends the window.

### Notes / artifacts already in place
- Observability is live: `ck_auth_expired` logs `tokenAgeSeconds` /
  `tokenAgeMinutes`; OAuth endpoints log via `logEvent`. Use these to measure.
- The parked CloudKit.js prototype (sign-in page + token endpoint + fetch/XHR
  token capture) is recoverable from git history if/when we resume.
- An unused Cloudflare secret `CK_WEB_API_TOKEN` (CloudKit.js Post-Message API
  token, no custom URL) may still be set on the Worker — remove with
  `wrangler secret delete CK_WEB_API_TOKEN` or keep for the prod work.

### Reality check
Fully **unattended/permanent** access to a user's **private** CloudKit DB is not
possible — Apple has no server-to-server path to private data. The realistic
target is a **2-week token that slides on use** (effectively permanent for an
active user) plus one-tap re-auth when it lapses.
