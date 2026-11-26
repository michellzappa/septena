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
| iPhone, iPad (App Store) | native | web | web | yes | yes | Apple, device |
| Mac (App Store) | native | web | web | yes | yes | Apple, device |
| Mac (Developer ID) | web | web | web | yes | yes | device only (#551) |
| Android | web | native (Credential Manager) | web | yes | yes | device only |
| Web app | web | web | web | yes | yes | device only |
| Claude connector authorize page | web | web | web | yes | yes (today's code) | device only |
| Windows | web | web | web | yes | yes | not built (#136) |
| Apple Watch | through the phone | | | | | through the phone |
| Website | no sign-in; links to the web app and downloads | | | | | |

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
| `GET /v1/auth/methods` | Lists the methods this server has turned on. |
| `POST /v1/auth/email/start`, `/verify` | Email code (#169). |
| `GET /v1/auth/oidc/:provider/start` | Starts a redirect with PKCE and a `state` bound to the client (`return_to` from an allowlist: the web app, each app's claimed redirect, the connector page). |
| `GET /v1/auth/oidc/:provider/callback` | Exchanges the code, verifies the ID token (issuer, audience, nonce, expiry, signature from the provider's JWKS), then signs in or creates the account. Returns to the client with a one-time result code; the client trades it for the session at `POST /v1/auth/oidc/redeem`. |
| `POST /v1/auth/google/native` | Android Credential Manager ID token, verified like the callback. |
| `POST /v1/auth/apple` | Unchanged native Apple flow. Web Apple adds the Services ID to the accepted audiences. |
| `POST /v1/auth/link/*` | Signed-in: add a method (the same flows, ending in "add to this account"); remove one, never the last. |

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
| Connector page creates accounts | Yes: an agent-first account is a real account. *(default)* |
| Order of methods | Platform provider first, then the others, email, device approval. *(default)* |
