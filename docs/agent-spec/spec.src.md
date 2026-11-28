# Septena agent spec

Version: **v0**. Unstable until Septena 1.0: records, fields and codes can still change. A change that breaks a client gets a note under "Changes" below. From 1.0 on, a breaking change needs a new version.

This spec defines the contract between Septena and an agent: the records, their IDs, the claim lifecycle and every refusal code. It is published at:

- `https://septena.app/spec.md`: this document.
- `https://septena.app/spec/schema.json`: the JSON Schema of the records.
- `https://septena.app/spec/conformance/<suite>.json`: the conformance vectors.
- `https://septena.app/spec/conformance/run.mjs`: a runner for the vectors, with no dependencies.
- `https://api.septena.app/openapi.json`: the OpenAPI 3.1 document for the `/v1` HTTP API.

The source is `docs/agent-spec/` in the public app repository, `github.com/septena/septena`. The tables in this document, the schema and the OpenAPI document are generated from the code and the registry. CI fails when one of them is out of date.

## Where an agent connects

- MCP: `https://api.septena.app/mcp`. Agents work with Septena here. The server speaks the stateless MCP revision `2026-07-28` and the older `initialize` handshake. `https://api.septena.app/skill.md` is the full brief for the tools.
- HTTP: `https://api.septena.app/v1`. It serves the apps and thin clients. `openapi.json` describes every route an outside client may call.
- Sign-in: OAuth with PKCE for MCP hosts, an agent key from the app, or an agent sign-up that the person confirms by email (`POST /v1/agent/signup/start`).

## Records

Each record has an `id` and the fields below. The tables come from `registry/entities.json`, the one source for the columns of the store. In the sync protocol a record travels as `{ entity, row }`, with `entity` the name in the heading.

- A field that is **server-owned** is set by Septena. A write that names it is ignored or refused.
- **Required on create** lists the fields a new record must carry.
- A day is `YYYY-MM-DD` in the person's time zone. A stamp is an ISO 8601 time.

The five records an agent works with most are the **task**, the **area**, the **project**, the **reference** (`taskRef`: what a task points at) and the **turn** (one step of a task's conversation). The task's conversation (`convo`) holds the claim, the assignee and the end state.

{{records}}

### Value sets

{{enums}}

## IDs

- An `id` is an opaque string that matches `{{idPattern}}`. Septena makes it when the record is created. It never changes, also when the title changes.
- A record that points at another stores the other record's `id`, never its title. `task.area` is an area id.
- An id is scoped to its record type. The same string can be an area id and a project id.
- Tools that take an area or a project accept an id or a title. Septena resolves an exact id first, then an exact title (case-insensitive), then a title that contains the text. When more than one record matches a title, the call is refused and names the candidates. Results always carry both `id` and `title`: use the `id` in the next call.
- Tasks are found by id only. Use `tasks_search` or `tasks_find_by_ref` to find one by its words or its link.
- A **reference key** names an outside item: `email:<Message-ID>`, `thread:<root Message-ID>`, `event:<iCal UID>`, `issue:<owner>/<repo>#<n>`, `task:<task id>` or `url:<web URL>`. A web URL or a `message://` link is accepted and stored in its normal form, so every spelling of one item is one key. The vectors in `refs.json` define the grammar.
- An **idempotency key** is not an id. The caller makes it for one write (a UUID works): 1 to 255 printable ASCII characters, no spaces.
- A refusal **code** is a stable name, like an id. It is never renamed.

## The claim lifecycle

An agent that works a task follows these steps. The rules are enforced by the task store on the server, not by the tools, so every client gets the same answer.

1. **Find work.** `tasks_pending_reasoning` lists the tasks waiting for an agent. `tasks_agent_events(since)` returns the events since a cursor; pass back `nextSince`. Events are pointers (`rev`, `kind`, `taskId`, `at`), never task text. The kinds are `assigned`, `user_turn`, `stopped`, `resumed`, `paused`, `unpaused`, `do_started` and `do_ended`. `GET /v1/agent/events/stream` carries the same events. A webhook carries only the kinds that wake an agent (`assigned`, `user_turn`, `resumed`, `unpaused`), retried twice on a network error, 408, 425, 429 or 5xx. Dedupe on `rev`. The poll is the fallback: it carries every event.
2. **Claim.** `tasks_claim(id, agent)` before the first write. A claim is a lease: {{claimDefault}} by default, {{claimMax}} at most. Claim again to renew it while you work. One agent holds a task at a time; another agent gets `held` until `claimUntil`. The claim returns the notes of the task's project and area. Read them before you decide anything.
3. **Work in turns.** Write each step as a turn with `tasks_thread_append`. The steps are `confirm`, `ground`, `scope`, `decide` and `work`. Confirm what the task means before anything else.
4. **Ask.** To ask the person, append a `provider` turn with a `question` and 2 to 4 `options`, then stop. The question ends your claim. The person's answer is a `user` turn with `chosen` and `inReplyTo`; it arrives as a `user_turn` event. Never write the person's choice yourself.
5. **Hand off.** When the work is done, call `tasks_set_endstate(id, "needs_verify", note)`. The note says what to check; a hand-off without one is refused (`note_required`). This releases the claim and puts the task in the person's **Review**. `decomposed` is the only other end state an agent may set: the work goes on as an issue or smaller tasks.
6. **Release.** `tasks_release(id, agent, why)` when you stop without a hand-off, with one line on what you did.
7. **Review.** Only the person takes a task out of Review. **Accept** completes it. **Send back** returns it to the agent with a note. While a task is in Review an agent may hand it over again with a new note, and nothing else (`in_review`).

What only the person does:

- Complete, cancel or delete a task an agent worked on (`human_accepts`), also after the agent released it.
- **Stop** agent work on one task (`stopped`) or **pause** all agents (`paused`). Resume and unpause are the person's too.
- Take a task back from an agent (`human_only:assignee`).
- Start, change or end a Do (`doing`, `human_only_do`). A claim on the task the person is doing is refused.
- Write the brief of a project's or an area's notes once it has text (`brief_is_users`). An agent appends under `## Log` or proposes a new brief.

An agent gets {{runBudget}} runs on a task since the person last wrote on it. Then it must ask (`budget`).

## Errors

A refused call carries one envelope:

```json
{ "error": { "code": "paused", "message": "…", "hint": "…", "retryable": false } }
```

- On MCP a refused tool call has `isError: true`. The first text content is the message, the second text and `structuredContent` are the envelope. Bad arguments are a tool error with `invalid_arguments`, not a JSON-RPC error. A result that reports a refusal in its own fields (`claimed: false`, `completed: false`, `written: false`) keeps those fields and also carries `error`.
- On `/v1` the body is `{ "error": "<code>", … }` by default. Send `X-Septena-Errors: envelope` to get the envelope in `error`, with the old fields next to it.
- `retryable: true` means the same request can succeed later with no action by the person. Wait, then send the same request with the same idempotency key. With `retryable: false`, do not send it again as it is.

### Refusal codes

The table comes from `backend/src/errors.ts`, the one table of codes. A code with a detail after `:` (`immutable:title`) takes the row of the part before the `:` unless the table lists the full code.

{{refusals}}

## Idempotency

Every MCP write tool and every `/v1/tasks` write takes an optional idempotency key: the `idempotency_key` argument, or on `/v1` the `Idempotency-Key` header or body field. Septena keeps the key, a hash of the body and the first result for 24 hours per account. A repeat with the same key and body returns the first result and writes nothing (`/v1` adds `Idempotent-Replayed: true`). The same key with another body is refused as `idempotency_conflict`. A refused call keeps nothing under its key.

## Schema and conformance vectors

`schema.json` is a JSON Schema (draft 2020-12). Each record is under `$defs`, with the entity name as the key.

The conformance vectors are the cases every Septena implementation passes: the apps, the server and the shared core. Each file holds one or more suites. A suite is a list of cases, and each case has a `name` (most do), its inputs and an `expected` result. Fields at the top of a file that are not a list (`today`, `now`) are the context for every case in it.

{{conformance}}

To check your own client, write a module that exports one object per file, with one function per suite you implement. The object's name is the file name without `.json`, in camel case: `task-dates.json` is `taskDates`. Each function takes the case and the file's context and returns what your code computes:

```js
// my-impl.mjs
export const refs = {
  normalizeRefKey: (c) => myNormalize(c.input),
};
```

Then run:

```sh
node run.mjs my-impl.mjs
```

The runner reads the `.json` files next to it, calls each function, and compares its result with `expected` (deep equality, key order ignored). It reports each suite as passed, failed or skipped, and exits with 1 when a case fails. `--dir <path>` reads the vectors from another folder, and `--only <file>` runs one file. It needs Node 20 or newer and nothing else.

## Changes

- **v0** (2026-11-26): first published version.
