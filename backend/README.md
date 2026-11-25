# septena-mcp-gateway

Cloudflare Worker for the Septask task backend, at `api.septena.app`:

- `/v1/*` — the task backend API the apps sync with (docs/SEPTASK_BACKEND.md
  in the app repo).
- `/mcp` — the Septena tasks MCP connector (`src/shadow/`). Claude reads and
  writes the user's tasks in their `TaskStore` Durable Object. The user pairs
  it from the Septask app (`/oauth/*`, `/.well-known/*`).
- `/skill.md` — the agent brief for the task tools.

**2026-11-20: the CloudKit connector on `mcp.septena.app` is decommissioned.**
Its code (CloudKit client, Apple web-auth token flow, life-data tools) was
deleted; the history keeps it. Any request that still reaches the Worker under
that host gets `410 Gone`. LEARNINGS.md is mostly about that connector.

## Layout

| Path | What |
|---|---|
| `src/index.ts` | Routes. |
| `src/api/` | `/v1` API, Sign in with Apple, app sessions. |
| `src/store/` | `TaskStore` Durable Object (SQLite), columns, ops. `ProjectStore`: one per shared project. |
| `src/shadow/` | The MCP connector: handler, pairing OAuth, tokens, writes, agent loop. |
| `src/tools/` | Task tool definitions (`taskTools.ts`), view rules (`taskShared.ts`), pure write logic (`writeTasks.ts`). |
| `src/rpc.ts`, `src/protocol.ts` | JSON-RPC envelope, dual-era MCP protocol. |

## Production deploy

`wrangler.toml` has no `[env.production]` block: its top-level config IS
production (custom domain `api.septena.app`, the KV namespaces, the
`TaskStore`, `PairingStore`, `AccountStore` and `ProjectStore` Durable Objects). Deploy with:

```sh
pnpm run deploy
```

`--env production` would deploy a separate, unconfigured Worker. Secrets are
set without `--env` (`wrangler secret put SESSION_SIGNING_KEY`).
To change `SESSION_SIGNING_KEY` without signing anyone out, put the old value
in `SESSION_SIGNING_KEY_PREVIOUS` first, then set the new key. Remove the old
one after 180 days. After a leak, set the new key only: every session ends.
Columns added to `src/store/columns.ts` migrate themselves on the next object
start (`addMissingColumnsSQL`); a new Durable Object class needs a
`[[migrations]]` entry.

## Protocol revisions

The gateway is **dual-era** (`src/protocol.ts`), serving both shapes of MCP on
the one `/mcp` endpoint:

- **Modern — `2026-07-28`.** Stateless. No handshake: every request declares
  its protocol version, client identity, and capabilities in `params._meta`,
  mirrored into `MCP-Protocol-Version` / `Mcp-Method` / `Mcp-Name` headers that
  the server validates against the body (mismatch ⇒ `400` + `-32020`). Results
  carry `resultType: "complete"` and `_meta` `serverInfo`; `tools/list` carries
  `ttlMs` + `cacheScope`. `server/discover` is implemented, as the spec
  requires.
- **Legacy — `2025-11-25` and earlier.** The `initialize` /
  `notifications/initialized` handshake, answered as before.

**Do not delete the legacy path.** Claude's connector has not shipped modern
support, so a modern-only gateway would take the live connector offline the day
it deploys. The era is decided per request from how the client opens, which is
what the spec prescribes for a dual-era server.

We never implemented sessions (`Mcp-Session-Id`), the GET stream, SSE
resumability, roots, sampling, or logging — so the removals and deprecations in
`2026-07-28` cost this gateway nothing.

`tools/list` is served `cacheScope: "private"`.

## Agent loop

The task connector serves five agent-loop tools (`src/shadow/agent.ts`, app repo ADR 0008):

| Tool | Does |
|---|---|
| `tasks_claim(id, agent, ttlMinutes?, why?)` | Takes or renews a lease (30 min default, 240 max). Refusals name the rule: `paused`, `stopped`, `your_turn`, `held`, `budget`, `terminal`, `closed`. |
| `tasks_release(id, agent, why)` | Ends the agent's own claim; `why` goes to the log. |
| `tasks_agent_events(since?, limit?)` | Pointer events with a cursor: `assigned`, `user_turn`, `stopped`, `resumed`, `paused`, `unpaused`. |
| `tasks_activity(id?, limit?)` | The change log in words, with reasons. |
| `tasks_history(id, limit?)` | One task's changes, newest first: who (you or Claude), the op, and each field's before and after. |

The rules are enforced in `TaskStore`, so they hold for every caller:

- A question from the agent (provider turn with options) releases its claim.
- `convo.stoppedAt` and the `agentsPaused` setting are written by app actors
  only. While a task is stopped, every `mcp:` write to it is refused.
- A human turn from the app sets `runsSinceUser` to 0. The 6th fresh claim
  without one is refused (`budget`).
