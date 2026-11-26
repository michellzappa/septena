# 0056. Agents can create and connect Septena accounts with human email confirmation

- Status: accepted (2026-11-26)
- Date: 2026-11-26
- Deciders: mz
- Extends: [ADR 0047](0047-every-way-in-creates-an-account.md) (every way in creates an account),
  [ADR 0016](0016-sign-in-beyond-apple.md) (email identity and `AccountStore`)
- Spec: [AGENT_ACCOUNT_CREATION_SPEC.md](../AGENT_ACCOUNT_CREATION_SPEC.md)

## Context

- ADR 0047 decided that an agent-first account created on the MCP OAuth
  authorize page is a real Septena account. In practice two gaps kept agents
  from creating accounts end to end:
  1. `POST /oauth/token` refused any account without an active app session
     (`hasAppSession()`), so a brand-new email account created on
     `/oauth/authorize` failed at token exchange.
  2. Headless and terminal agents (Claude Code, Codex, Gemini CLI, OpenClaw,
     scripts) do not run an OAuth browser redirect flow. They had no way to
     set up a new user's Septena account and connect themselves without the
     user first installing an app and creating an agent key by hand.
- Giving an agent the regular `/v1/auth/email/start` + `/verify` app sign-in
  flow would hand it a full `sa1`/`sr2` app session (able to mint keys, revoke
  devices, delete the account, and bypass Stop/Pause). Septena separates human
  app sessions from agent credentials on purpose (`tokens.ts`, ADR 0008).
- Anonymous, unverified agent accounts would invite abuse and leave the user
  with no way to sign in to their tasks later on iPhone, Mac, Android, or the
  web.

## Decision

1. **Agent-first OAuth accounts work without an app session.** When an OAuth
   pairing was approved by email on `/oauth/authorize` (`POST /oauth/pair/email`),
   `POST /oauth/token` verifies that the account still holds an identity in
   `AccountStore` and was not deleted after approval, rather than requiring
   `hasAppSession()`. App-approved pairings keep the `hasAppSession()` check.
2. **Headless agents start account creation and connection with human email
   confirmation.**
   - `POST /v1/agent/signup/start` takes `{ email, agentName, access?, timeZone? }`,
     emails a single-use confirmation link to `email`, and returns
     `{ status: "pending", requestId, pollSecret, expiresInSeconds, intervalSeconds }`.
     The reply is identical whether `email` already has an account or not.
   - `GET /agent/confirm/:token` renders a confirmation card showing the agent's
     name, requested access (`read` or `read and change`), whether this creates
     a new account or connects to an existing one, and links to Terms of Use
     and Privacy Policy. `GET` never mutates state.
   - `POST /agent/confirm/:token` approves (calling the shared email account
     creation + one-time 14-day trial flow) or declines.
   - `POST /v1/agent/signup/poll` takes `{ requestId, pollSecret }`. Once
     approved, it consumes the pending record in one shot and returns **only
     an `sk1.` agent key** (never an `sa1` app session), along with `mcpUrl`,
     `onboardUrl`, and `skillUrl`.
3. **Human ownership and Stop/Pause hold from minute one.** The created account
   is a normal email-backed Septena account. The person signs in later with
   that email on any Septena app or `web.septena.app` and sees the areas,
   projects, notes, and tasks their agent set up, and can pause, rename, or
   disconnect the agent in Settings ▸ AI & Agents.
4. **Same rollout gate as email sign-in.** Both the OAuth email path and
   `/v1/agent/signup/*` are gated by `EMAIL_SIGNIN` (and the `EMAIL` send
   binding), so nothing opens before Terms of Use and privacy copy ship
   (`#564`).

## Consequences

- Browser MCP hosts (Claude, ChatGPT, Cursor) and headless/CLI agents can both
  take a new person from zero to a populated Septena account in one
  conversation, then hand off smoothly when the person opens an app.
- An agent never receives an app session and cannot mint more keys, delete the
  account, or override Stop/Pause.
- Email link confirmation prevents prompt injection from tricking a user into
  pasting a generic sign-in code that silently hands over an existing account.
- Reuses `PairingStore` (under a disjoint `agent-signup:` namespace and storage
  keys) and `AccountStore` rate limits, so no new Durable Object class or
  migration is needed.

## Links

- ADR 0008, ADR 0016, ADR 0047, ADR 0050
- Spec: [AGENT_ACCOUNT_CREATION_SPEC.md](../AGENT_ACCOUNT_CREATION_SPEC.md)
- Code: `backend/src/shadow/agentSignup.ts`, `backend/src/shadow/oauth.ts`,
  `backend/src/shadow/PairingStore.ts`, `backend/src/api/emailSignIn.ts`,
  `backend/src/store/AccountStore.ts`, `backend/skill.md`
