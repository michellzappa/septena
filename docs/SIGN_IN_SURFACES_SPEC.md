# Sign-in surfaces spec

**Status:** accepted (2026-11-26). Rests on [ADR 0047](adr/0047-every-way-in-creates-an-account.md),
[ADR 0016](adr/0016-sign-in-beyond-apple.md) and [ADR 0043](adr/0043-plus-links-and-a-counts-only-admin-page.md).
Tracking issue: #137.

## 1. Goal

Every way into Septena lets a new person create an account and lets a
returning person sign in, with every method that surface can offer. The same
methods appear in the same order and with the same words on every surface.

## 2. Surfaces and methods

"native" means the platform's own flow. "web" means a redirect through
`api.septena.app` in the system browser sheet (`ASWebAuthenticationSession`,
Android Custom Tabs, a top-level redirect on the web).

| Surface | Apple | Google | Microsoft | Email code | Device approval | Today |
|---|---|---|---|---|---|---|
| iPhone, iPad (App Store) | native | web | web | yes | yes | Apple, email, device |
| Mac (App Store) | native | web | web | yes | yes | Apple, email, device |
| Mac (Developer ID) | web | web | web | yes | yes | email, device |
| Android | web | native (Credential Manager) | web | yes | yes | email, device |
| Web app | web | web | web | yes | yes | email, device |
| Claude connector authorize page | web | web | web | yes | yes (today's code) | email, device |
| Windows | web | web | web | yes | yes | not built (#136) |
| Apple Watch | through the phone | | | | | through the phone |
| Website | no sign-in; links to the web app and downloads | | | | | |

"email" in the Today column shows only while the server's email switch is
on (`GET /v1/auth/methods`).

Device approval never creates an account: it needs a signed-in device. Every
other method creates one on first use.

## 3. One screen, from the registry

`registry/sign-in.json` (new, generated like the other registries by
`scripts/gen-registries.mjs`):

- `methods`: id (`apple`, `google`, `microsoft`, `email`, `device`), title
  ("Continue with Apple", …), icon, `createsAccount`, and per platform the flow
  (`native`, `web`, `none`).
- `order` per platform: the platform's provider first, then the other
  providers, then email, then device approval ("I use Septena on another
  device").
- Copy for the screen: heading, the line under it, the Terms and Privacy line
  (#564), the error lines, the "This email already has a Septena account"
  step.
- `featureId` rows in `registry/capabilities.json` per method and platform, so
  the site and `docs/FEATURE_MAP.md` show the status.

A method whose backend is off (no keys configured, a self-hosted server
without it) is hidden. The backend says which are on in
`GET /v1/auth/methods`.

## 4. Backend

All flows end in `issueSession()` and an `AccountStore` identity row.

| Route | Does |
|---|---|
| `GET /v1/auth/methods` | Built. `{methods:[{id, web?, native?}]}`: `apple`, `google`/`microsoft` when configured, `email` when on, `device`. |
| `POST /v1/auth/email/start` `{email}` | Built (#169). 202 `{status:"sent", expiresInSeconds, codeLength:6}`, the same for a known and an unknown address. 429 `{error:"too_many_requests", retryAfterSeconds}`, 503 `{error:"email_signin_off" \| "email_send_failed"}`. |
| `POST /v1/auth/email/verify` `{email, code, sessionMode?}` | Built (#169). 200 the session (`sessionMode:"cookie"` from the web app sets the refresh cookie, as device poll does). A new address creates the account and its trial (once per address). 401 `{error:"invalid_code", attemptsLeft}`, 410 `{error:"expired_or_unknown"}`, 429 `{error:"too_many_attempts"}`. |
| `GET /v1/auth/oidc/:provider/start` | Built (#637). Starts a redirect with PKCE and a `state` bound to the client (`return_to` from an allowlist: the web app, each app's claimed redirect, or `/oauth/pair/oidc/:provider` for the connector page). |
| `GET`/`POST /v1/auth/oidc/:provider/callback` | Built (#637). Exchanges the code, verifies the ID token (issuer, audience, nonce, expiry, signature from the provider's JWKS), then returns to the client with a one-time result code (`POST /v1/auth/oidc/redeem`) or approves the connector pairing directly. |
| `POST /v1/auth/google/native` | Built (#637). Android Credential Manager ID token, verified like the callback. |
| `POST /v1/auth/apple` | Built. Native Apple flow plus `APPLE_WEB_CLIENT_ID` audience support and no-silent-linking email collision catch (`409 account_exists` + `linkToken` -> `POST /v1/auth/link/complete`). |
| `GET`/`DELETE /v1/auth/identities`, `POST /v1/auth/link/*` | Built (#171, #643 backend). Signed-in: list linked methods, add email/Apple/Google/OIDC, complete collision link, remove any method except the last (`409 last_method`). |

Rules:

- Provider subject: Apple `sub`, Google `sub`, Microsoft `oid` + `tid`
  (personal and work accounts). Never the email as the subject.
- **No silent linking.** If the provider's email belongs to another account,
  no account is created. The client shows the "already has an account" step
  and sends an email code to that address. A correct code signs in to that
  account and adds the provider (ADR 0047 decision 5).
- Existing Apple users keep their derived id (ADR 0016).
- Rate limits per IP on every start route, as for device start.
- Account deletion deletes every identity row.
- Secrets (client secrets, the Apple key) are Worker secrets only.

Email limits: 3 codes per address per 10 minutes; 5 wrong codes lock the
address until the window ends (a new code does not unlock it); 20 starts and
30 failed verifies per IP per 10 minutes. Codes are stored hashed in
`AccountStore` and spent on first use. The switch is `EMAIL_SIGNIN` in
`backend/wrangler.toml`; it is `"true"` since 2026-11-27 (#564 shipped), and the
`EMAIL` send binding uses Cloudflare Email Service on `septena.app`.

## 5. Clients

Each client renders the registry list and calls the routes above.

- **Apple apps**: one `SeptaskSignIn` screen. Native Apple where the
  entitlement exists (`SeptaskSignIn.appleAvailable`), else web Apple. Google
  and Microsoft through `ASWebAuthenticationSession`. The first-run screen,
  the "Not signed in" notice and Settings ▸ Account all open it.
- **Android**: the sign-in screen gains the providers and email next to
  device approval. Google through Credential Manager.
- **Web app**: the sign-in screen gains the providers and email. The
  "New to Septena? Get the app" link stays.
- **Connector authorize page**: shows the methods above the pairing code. A
  sign-in there approves the connector at once, with no app.
- **Settings ▸ Account ▸ Sign-in methods** on every client: list, add, remove
  (extends #171).

Same behavior on every platform (AGENTS.md). A method a platform cannot offer
is `none` in the registry, with the reason in the registry row.

## 6. Before the first new method opens (mz)

- Email sending for `septena.app`: SPF, DKIM, DMARC (#169).
- Terms of Use and the privacy changes: Septena stores email addresses (#564).
- Provider dashboards: Apple Services ID + Sign in with Apple key; Google Cloud
  OAuth clients (web, Android, iOS); Microsoft Entra app registration (personal
  and work accounts). The agent gives mz each value to paste, one at a time.

## 7. Phases

| Phase | Done when | Depends on |
|---|---|---|
| SI0 Registry (#635) | `registry/sign-in.json` and the capability rows exist and generate for Swift, Kotlin, TS. | — |
| SI1 Email code (#169) | #169 ships on the backend. | mz DNS |
| SI2 Email on every surface (#636) | Apple apps, Android, web and the connector page offer email; a new person creates an account by email on each. | SI0, SI1, #564 |
| SI3 OIDC backend (#637; mz dashboards #638) | Google, Microsoft and web Apple routes ship with tests (token checks, PKCE, state, no silent linking). | SI0, mz dashboards |
| SI4 Providers on every surface (#639 Apple apps, #640 Android, #641 web, #642 connector) | Each surface in §2 offers its providers. | SI3, #564 |
| SI5 Sign-in methods in Settings (#643) | Add and remove on every client (#171 widens). | SI2 |
| SI6 Passkeys | One more row. | SI4 |

## 8. Open questions

| Question | Default |
|---|---|
| Email code or magic link | Code (ADR 0016): works when the mail opens on another device. *(default)* |
| A provider email matches an existing account | Email code to that address, then link. No silent linking. *(default)* |
| Microsoft work accounts | Allowed (`common` tenant). *(default)* |
| Connector page creates accounts | Yes: an agent-first account is a real account (extended to headless agents in [ADR 0056](adr/0056-agents-create-accounts-with-email-confirmation.md)). *(default)* |
| Order of methods | Platform provider first, then the others, email, device approval. *(default)* |
