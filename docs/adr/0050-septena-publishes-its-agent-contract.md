# 0050. Septena publishes its agent contract

- Status: accepted (2026-11-26)
- Date: 2026-11-26
- Deciders: mz
- Spec: [AGENT_SURFACE_SPEC.md](../AGENT_SURFACE_SPEC.md)

## Context

Agents read septena.app and call `api.septena.app`. On 2026-11-26 we compared
the agent surface with two sibling products (Starlings and Bipe). Septena has
the best help set, but:

- Only help pages have a Markdown twin. The home page, features, pricing,
  compare, download, roadmap and changelog are HTML only.
- The rules an agent must follow (IDs, the claim lifecycle, refusal codes)
  live in `docs/IDENTIFIERS.md`, `backend/skill.md` and the agent guide. No
  one document is versioned, and no schema or test vectors are public.
- A refusal says what went wrong, but not whether a retry is safe. A write
  has no idempotency key, so the guide tells an agent to search before it
  retries a create.
- The `/v1` API has no machine-readable description.

These are contracts. Once agents depend on a code, a field or an address, we
cannot change it without breaking them. So we decide their shape once.

## Decision

1. **Every public page has a Markdown twin.** It is served at `<path>.md`
   (the home page at `/index.md`) and when a request sends
   `Accept: text/markdown`. The twin is built from the same source as the
   HTML page, never written by hand.
2. **One versioned agent spec.** `septena.app/spec.md` defines the records
   (task, area, project, reference, turn), their IDs, the claim lifecycle,
   and every refusal code. It has a JSON Schema at `/spec/schema.json`,
   generated from `registry/entities.json`. The language-neutral vectors in
   `registry/conformance/` are published as they are, with a runner that has
   no dependencies. The source is in this repo. The site mirrors it at build
   time. The spec starts at `v0` and stays unstable until the 1.0 launch.
3. **One error envelope.** A refused MCP tool call and a refused `/v1` call
   carry `{ error: { code, message, hint, retryable } }`. Today's codes
   (`paused`, `held`, `budget`, `human_accepts` and the others) become
   `code` values with no change of name. The old fields stay next to the
   envelope until no client in `registry/conformance` reads them. Both MCP
   eras (`backend/src/protocol.ts`) return the same envelope.
4. **Writes take an idempotency key.** Every write tool and every `/v1`
   write accepts an optional `idempotency_key`. The task store keeps the
   key and its result for each account for 24 hours. A repeat returns the
   first result and does not write again.
5. **OpenAPI for `/v1`.** `api.septena.app/openapi.json` (OpenAPI 3.1) is
   generated from the route validators (Zod). It is not written by hand.
6. **Skills are files.** The agent brief is also published as small skills,
   one procedure each, at `septena.app/skills/<name>/SKILL.md`.
   `backend/skill.md` stays the one full brief and links to them.

## Consequences

- An agent can read any page as text and check its own client against the
  schema and the vectors.
- A retry after a lost reply is safe. The "search before you retry" rule in
  the server instructions can go once idempotency ships.
- Every new refusal code, record field or tool must update the spec, the
  schema and the OpenAPI document in the same change. CI checks that the
  generated files are current.
- The spec is a public promise. A breaking change needs a new spec version
  and a deprecation note.

## Links

- Spec: `docs/AGENT_SURFACE_SPEC.md`
- ADR 0008 (agent loop), ADR 0038 (agents are the integrations)
- `docs/IDENTIFIERS.md`, `backend/skill.md`, `registry/conformance/`
- Related issues: #88 (packaged agent installs), #90 (public API with keys)
