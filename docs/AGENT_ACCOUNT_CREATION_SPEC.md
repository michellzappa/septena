# Agent account creation spec

**Status:** accepted (2026-11-26). Rests on [ADR 0056](adr/0056-agents-create-accounts-with-email-confirmation.md),
[ADR 0047](adr/0047-every-way-in-creates-an-account.md), [ADR 0016](adr/0016-sign-in-beyond-apple.md),
and [ADR 0050](adr/0050-septena-publishes-its-agent-contract.md).

## 1. Goal

A person can start using Septena through their agent before ever installing an
app. Both browser-based MCP hosts (OAuth) and headless/CLI agents can create a
real Septena account for the user, receive an agent-scoped credential, populate
areas, projects, notes, and tasks via `/onboard.md`, and leave the account
ready for the user to sign in later on iPhone, iPad, Mac, Android, or
`web.septena.app`.

## 2. Two paths, one ownership model

| Agent kind | Path | Human proof | Credential returned |
|---|---|---|---|
| Browser MCP host (Claude, ChatGPT, Cursor) | OAuth 2.1 (`/oauth/authorize` + `/oauth/pair/email` + `/oauth/token`) | Email 6-digit code on the authorize page (later Google / Microsoft / web Apple per ADR 0047) | `sm2.` access + `smr2.` refresh (`tasks:read tasks:write`) |
| Headless / CLI / script agent (Claude Code, Codex, Gemini CLI, OpenClaw) | `POST /v1/agent/signup/start` → email confirmation page → `POST /v1/agent/signup/poll` | Explicit click on the single-use email confirmation link (`/agent/confirm/:token`) | `sk1.` agent key (`tasks:read` or `tasks:read tasks:write`) |

In both paths:
- The account is a normal `email:<normalized>` identity in `AccountStore` with
  the standard one-time 14-day Plus trial per email address.
- The agent never receives an `sa1`/`sr2` app session. It cannot mint keys,
  manage devices, delete the account, or bypass Stop/Pause.
- The agent appears in Settings ▸ AI & Agents under its name and can be
  paused, renamed, or disconnected as soon as the user opens an app.
- Both paths require `EMAIL_SIGNIN = "true"` and the `EMAIL` send binding.

## 3. OAuth agent-first token exchange

When `POST /oauth/pair/email` approves a connector pairing, it records
`approvedVia: "email"` and `approvedAt`. At `POST /oauth/token`:

- App-approved pairings keep the `store.hasAppSession()` guard.
- Email-approved pairings verify that the user still has at least one identity
  in `AccountStore` and that `store.deletedAt() < approvedAt`. No app session
  is required.

`TaskStore.accountSummary()` counts an account with connected agents as live
even before its first app session or task, so agent-first accounts appear on
the admin page.

## 4. Headless agent signup API

All routes live on `api.septena.app` and return `Cache-Control: no-store`.
Refusals on `/v1/agent/signup/*` participate in the ADR 0050 error envelope
when the caller sends `X-Septena-Errors: envelope`.

### `POST /v1/agent/signup/start`

Request body (strict JSON):

```json
{
  "email": "alex@example.com",
  "agentName": "Claude Code",
  "access": "write",
  "timeZone": "Europe/Berlin"
}
```

- `email`: valid email address, trimmed and lowercased (max 254 chars).
- `agentName`: 1 to 40 printable non-control characters (`zAgentName`).
- `access`: `"write"` (default) or `"read"`.
- `timeZone`: optional IANA time zone (`isValidTz`), attached to the issued
  agent key's grant so `today` works before an app syncs `homeTimezone`.

Response `202 Accepted` (identical for new and existing addresses):

```json
{
  "status": "pending",
  "requestId": "as_...",
  "pollSecret": "...",
  "expiresInSeconds": 600,
  "intervalSeconds": 3
}
```

Errors:
- `400 invalid_request` — bad email, name, access, or timeZone.
- `429 too_many_requests` (+ `Retry-After`) — IP or per-email send limit hit,
  or address locked after failed email codes.
- `503 email_signin_off` — `EMAIL_SIGNIN` is off or `EMAIL` binding absent.
- `503 email_send_failed` — Cloudflare Email Service send failed.
- `503 signup_unavailable` — could not allocate a pending record.

### `GET /agent/confirm/:token` and `POST /agent/confirm/:token`

- `:token` is `<requestId>.<emailSecret>`. Only `sha256(emailSecret)` is stored
  in `PairingStore` under `agent-signup:<requestId>`.
- `GET` verifies the token in constant time and renders a confirmation card
  without mutating state (immune to mail scanners and link previews). The page
  states the agent's name, access level, whether this creates a new account or
  connects to an existing one, and links to Terms of Use and Privacy Policy.
- `POST` verifies same-origin (`Origin === API_PUBLIC_URL` when sent) and
  handles `decision=approve` or `decision=decline`. Approval resolves or
  creates the email account (starting the trial once per address) and marks the
  request approved. Both outcomes are one-shot.

### `POST /v1/agent/signup/poll`

Request body (strict JSON):

```json
{
  "requestId": "as_...",
  "pollSecret": "..."
}
```

Responses:
- `202` `{ "status": "pending" }` — waiting for human confirmation.
- `200` (one-shot; consumes and wipes the pending record):

```json
{
  "status": "approved",
  "created": true,
  "userId": "u_...",
  "agentId": "...",
  "agentName": "Claude Code",
  "access": "write",
  "scope": "tasks:read tasks:write",
  "key": "sk1....",
  "mcpUrl": "https://api.septena.app/mcp",
  "onboardUrl": "https://api.septena.app/onboard.md",
  "skillUrl": "https://api.septena.app/skill.md"
}
```

- `410` `{ "error": "denied" }` — human declined the request (one-shot).
- `410` `{ "error": "expired_or_unknown" }` — expired, already claimed, wrong
  secret, or account deleted before claim.
- `429` `{ "error": "too_many_attempts" }` — per-IP failed poll limit hit.

## 5. Rate limits and security

- **Start:** 10 starts per IP per 10-minute window; 3 emails per address per
  10-minute window in `AccountStore` (also refused if the address is locked in
  `email_codes`).
- **Poll:** 5 failed polls per IP per 10-minute window.
- **Expiry:** 10 minutes; `PairingStore` alarm wipes all data at expiry.
- **No enumeration:** `start` returns the same `202` shape for known and
  unknown email addresses. Only the email owner who opens the secret link sees
  whether the address already has an account.
- **Headers on `/agent/confirm/:token`:** `Cache-Control: no-store`,
  `Referrer-Policy: no-referrer`, `X-Robots-Tag: noindex, nofollow`, strict
  CSP (`default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'`).
