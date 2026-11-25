# 0016. Sign in beyond Apple: approve a new device from a signed-in one, or use an email code

- Status: accepted (2026-11-21)
- Date: 2026-11-21
- Deciders: mz
- Amended by: [ADR 0043](0043-plus-links-and-a-counts-only-admin-page.md)
  (every subject except an email address is stored hashed)

## Context

- The only sign-in is Sign in with Apple, native token flow
  (`POST /v1/auth/apple`, `backend/src/api/appleIdentity.ts`). The accepted
  audiences are the four Apple bundle ids (`backend/wrangler.toml`). Web Sign
  in with Apple (a Services ID) is not configured.
- The web client (#21), the Android client (#20) and the Windows client
  (#136, ADR 0013) cannot use the native Apple flow. Many of their users have
  no Apple ID.
- The user id is derived: `u_` + base64url(SHA-256("apple:" + sub))
  (`appleIdentity.ts:97-101`). The derivation was chosen so that a second
  provider cannot collide. There is no account or identity table, so nothing
  links a second sign-in to an existing account.
- After sign-in the backend issues its own session: a stateless `sa1` access
  token (1 hour) and a single-use rotating `sr1` refresh token (180 days)
  (`backend/src/api/session.ts`). Every client already uses this session.
  Only the first step, proving who the person is, is Apple-specific.
- A device-approval flow already exists. The MCP connector shows an
  8-character code (`PairingStore`), the user approves it in a signed-in app
  with `POST /v1/pair/approve`, and the backend issues tokens. The pending
  side keeps a browser-only secret, so the code alone cannot finish the flow.
  Failed approvals are rate limited.
- Bipe links each computer to the phone account: the phone approves the new
  device by QR. People who already use an app on one device rarely want a
  second account system.
- Account recovery must not depend on one device. A person who loses their
  only signed-in device still needs a way back in.

## Decision

Accepted by mz on 2026-11-21 with all defaults below.

1. **Approve a new device from a signed-in one.** A new client (web,
   Android, Windows) shows a QR code and the same 8-character code. A
   signed-in Septena app approves it. The backend then issues an ordinary
   `sa1`/`sr1` session for the existing user id. This reuses `PairingStore`
   with a new purpose (`device`), kept apart from connector pairing so a
   connector code can never mint an app session. *(default)*
2. **Email one-time code** for people with no signed-in device and for
   recovery. The client sends an address. The backend emails a 6-digit code
   that lives 10 minutes, with attempt limits per address and per IP. No
   passwords. The email is sent through Cloudflare Email Service, on the same
   account as the Worker. *(default)*
3. **An identity table** in a new global `AccountStore` Durable Object maps
   `provider:subject` to `userId`. Existing Apple users keep their derived id;
   the table records `apple:<sub>` for them on next sign-in. A new account
   created by email gets a random `u_` id. A signed-in user can add an email
   to their account (verify with a code), which is how an Apple user gets a
   recovery path and a way to sign in on Windows without the phone. Linking
   two existing accounts is out of scope. *(default)*
4. **Not now:** Google sign-in, passkeys and web Sign in with Apple. Each one
   becomes a row in the identity table later without a new ADR, as long as it
   ends in the same session. Passkeys are the first candidate. *(default)*

## Consequences

- An Apple user signs in on Windows or Android by scanning a code with their
  phone. Nothing new to remember.
- An Android-only or Windows-only person can create an account with an email
  address.
- The backend gains `AccountStore`, email sending, two code flows and their
  rate limits. All of them end in `issueSession()`, so sync, entitlements and
  the per-user Durable Object routing do not change.
- Email codes make email the recovery root. Whoever controls the inbox
  controls the account. Device approval stays the safer path and the UI
  offers it first.
- mz must set up the sending domain (SPF, DKIM, DMARC) on `septena.app`.
- A self-hosted server (ADR 0011) needs its own email sending to offer email
  codes. Device approval works without it.
- Account deletion must also delete the account's identity rows.

## The QR code (implemented 2026-11-24)

- Every screen that shows a sign-in code also shows it as a QR code: the
  Claude authorize page and the Android sign-in screen. The QR holds
  `https://api.septena.app/pair/<CODE>`. One encoder lives in the backend
  (`backend/src/shadow/pairQr.ts`): the page draws its SVG, and
  `POST /v1/auth/device/start` returns the module matrix (`qr.size`,
  `qr.modules`) so a client draws it with no QR library.
- The approving app has a Scan Code button next to every code field
  (`Septask/SeptaskSignInCodeScanner.swift`, iPhone, iPad and Mac). A scan
  only fills in the code. The app then shows the same "Sign in on
  <device>?" confirmation as for a typed code.
- The app registers no handler for the `/pair/` URL, on purpose. A link in
  an email or a chat must never open a prefilled approval. A phone's system
  camera opens the URL in a browser, and that page only says where to scan
  it. It looks nothing up and approves nothing.

## Open questions

| Question | Default |
|---|---|
| First-device method on non-Apple clients | Email code *(default)* |
| Approving a new device | QR plus 8-character code, approved in a signed-in app *(default)* |
| Email provider | Cloudflare Email Service *(default)* |
| Google sign-in | Later, not in the first web or Android release *(default)* |
| Passkeys | Later; first candidate after email *(default)* |
| Web Sign in with Apple | Not planned; device approval covers Apple users *(default)* |

## Links

- Issues: #168 S1 identity table · #169 S2 email code · #170 S3 device approval · #171 S4 email on Apple accounts

- #21 web client · #20 Android client · #136 Windows client
- ADR 0002 own backend · ADR 0011 self-hostable backend · ADR 0013 Windows
- `backend/src/api/appleIdentity.ts`, `backend/src/api/session.ts`,
  `backend/src/shadow/PairingStore.ts`, `backend/src/shadow/oauth.ts`
- `docs/ANDROID_CLIENT_SPEC.md`
