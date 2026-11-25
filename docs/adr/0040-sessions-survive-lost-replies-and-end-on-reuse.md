# 0040. Sessions survive lost replies and end on reuse

- Status: accepted (2026-11-25)
- Date: 2026-11-25
- Deciders: mz ("super secure and super bullet proof")
- Builds on: [ADR 0002](0002-own-backend-replaces-icloud.md),
  [ADR 0016](0016-sign-in-beyond-apple.md)

## Context

On 2026-11-25 a Mac lost its sign-in. The app quit 160 ms into a token
renewal. The server had already spent the old refresh token, and the new one
died with the reply. The next renewal got 401, and the app signed out.

The same code had more ways to fail. KV, which is eventually consistent,
routed every renewal, and its entry was deleted before the Durable Object
confirmed. An access token outlived a sign-out by up to an hour. A stolen
refresh token was not noticed for apps. Agent tokens lived in KV alone and
outlived account deletion. The clients signed out on any 401, and on a
Keychain that did not answer.

## Decision

Apps and agents share one session model. The user's Durable Object is the only
authority. A refresh token is signed, so it routes to its object with no lookup
table, and only its hash is stored.

A renewal mints a child, and the parent stays good until the child is used, as
a refresh token or through its access token. First use retires everything else
in the session. A retired token that comes back after 30 seconds means two
holders, so the whole session ends. Inside 30 seconds, two holders that raced
from one parent both continue, for one generation. The second must use its
token inside those 30 seconds.

Every request asks the object whether its session is alive. Ending a session
takes effect on the next request and closes its open sockets. A store error
answers 5xx, which never signs anyone out.

A client stores the new token before it uses it, replaces it in place, keeps
it on that device only, and signs out only on a 401 that says
`invalid_grant`.

## Consequences

- No quit, crash, timeout or outage during a renewal signs anyone out, on
  installed versions too: the server change is enough for that.
- A stolen refresh token works until either holder renews past the other.
  Then both are out, and the owner signs in again.
- One extra Durable Object call per request.
- A phone restored from a backup to new hardware asks for sign-in again.
- A copy of an old token, for example in an old backup, ends that session.
- Tokens from before this decision keep working and move over on their next
  renewal. The rollout has two steps (`SIGNED_SESSIONS`): the first version
  reads the new tokens, the second issues them. A rollback by one step signs nobody out. After the
  second step, never roll back to a version from before this decision.
- Account deletion empties the store last, and a repeated deletion answers 204.

## Links

`backend/src/store/sessions.ts`, `backend/test/sessions.test.ts`,
`docs/SEPTASK_BACKEND.md` §10
