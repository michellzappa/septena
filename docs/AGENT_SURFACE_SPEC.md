# Agent surface spec

Status: accepted (2026-11-26). Rests on [ADR 0050](adr/0050-septena-publishes-its-agent-contract.md),
ADR 0008 (agent loop) and ADR 0038 (agents are the integrations).

## Why

Agents read septena.app to learn what Septena is, and call `api.septena.app`
to do the work. On 2026-11-26 mz compared this surface with Starlings
(starlingshq.com) and Bipe (bipe.chat). Septena leads on help pages and
comparison pages. It is behind on the items below. This spec puts them in
order. Positioning and copy for the marketing pages are out of scope here:
they live in the Starlings workspace (`AGENTS.md`, "This repo is PUBLIC").

## Where the work lands

| Repo | Owns |
|---|---|
| `michellzappa/septena` (this repo) | The contract: spec source, schema, conformance vectors, error envelope, idempotency, OpenAPI, skills source, the `agent` field in `registry/capabilities.json` |
| `michellzappa/septena-site` | Rendering: Markdown twins, content negotiation, JSON-LD, the pages, the waitlist endpoint |

The site never holds a second copy of a contract. It reads this repo's files
at build time, as it does for `changelog.json`.

## Phases

Each phase is one issue. Phases in one group can run in parallel.

### Group 1: readable site (site repo)

- **AS1 (septena-site#25) Markdown twins everywhere.** Every page in the sitemap answers
  `<path>.md` (home: `/index.md`) and `Accept: text/markdown` (the Worker
  already runs first, `worker/index.js`). The twin is built from the page's
  own content source. `llms.txt` lists a `.md` link next to each entry. A
  build check fails when a sitemap page has no twin.
- **AS2 (septena-site#26) JSON-LD.** `SoftwareApplication` on the home page and the app pages
  (platform, price, offers from `registry/plans.json`), `FAQPage` on Quick
  answers, `BreadcrumbList` on help pages. Built from the same data as the page.

### Group 2: the contract (this repo, then the site)

- **AS3 (#624) Error envelope and idempotency** (ADR 0050 §3, §4). Backend change
  in `backend/src/shadow/`. Both MCP eras. Update `backend/skill.md`,
  `TasksSkill.swift` and the site's `agents.md` in the same change.
  *Shipped.* The code table is `backend/src/errors.ts`; the keys are in
  `backend/src/idempotency.ts` and the TaskStore table `idempotency_keys`.
  MCP: a refusal is `isError` with the old message as the first text and
  the envelope as the second text and `structuredContent`; bad arguments
  are a tool error (`invalid_arguments`), not a JSON-RPC error. `/v1`:
  every app client decodes `error` as a string, so the envelope replaces
  it only when the request sends `X-Septena-Errors: envelope`. The
  default flips when no client in `registry/conformance` reads the string.
- **AS4 (#625) OpenAPI for `/v1`** (ADR 0050 §5). Generated from the Zod
  validators. Served at `api.septena.app/openapi.json`, linked from
  `llms.txt`. CI fails when the generated file is stale. Prepares #90.
  *Shipped.* `backend/src/api/openapi.ts` lists the routes with their own
  validators; `backend/scripts/gen-contract.ts` writes
  `backend/src/generated/openapi.json`. A test fails when a /v1 route is
  neither documented nor listed in `INTERNAL_ROUTES`.
- **AS5 (#626) The agent spec** (ADR 0050 §2). `docs/agent-spec/` holds the spec
  source. The schema is generated from `registry/entities.json`. The site
  publishes `/spec.md`, `/spec/schema.json`, `/spec/conformance/*.json` and
  `/spec/conformance/run.mjs`.
  *Shipped.* Source `docs/agent-spec/spec.src.md`; the same generator
  writes `spec.md` (tables from `registry/entities.json`,
  `registry/rules.json` and `REFUSALS`) and `schema.json`. The runner is
  `docs/agent-spec/conformance/run.mjs`. The site copies them at build time.
- **AS6 (#627) Skills** (ADR 0050 §6). Source in `skills/<name>/SKILL.md` in this
  repo. First set *(default)*: `connect-septena`, `work-a-task`,
  `add-a-task-once` (search, refs, `existing` and `dismissed`),
  `ask-the-person`. The site serves them, and `llms.txt` and `agents.md`
  link them. Feeds #88.
  *Shipped.* `scripts/gen-registries.mjs --check` checks each skill: the
  frontmatter `name` is the folder, a `description` is there, every tool it
  names is registered, and `backend/skill.md` links it. The site copies
  `skills/` at build time (`scripts/sync-registry.mjs`).
- **AS7 (#628) Agent door per capability.** Each entry in
  `registry/capabilities.json` gets an `agent` field: the MCP tools that
  reach it, or `none`. The generator writes it into `docs/FEATURE_MAP.md`.
  The site's parity page and `llms-full.txt` show it as a column.
  *Shipped.* `scripts/lib/mcp-tools.mjs` reads the tool names from the
  backend source; `backend/test/agentErrors.test.ts` checks that list against
  the live `tools/list`. An entry without `agent`, or with a tool the backend
  does not register, fails `gen-registries.mjs --check`.

### Group 3: pages that explain (site repo)

- **AS8 (septena-site#27) Agent waitlist sign-up.** The Web, Android and Windows waitlists get
  `/waitlist.md`, a JSON Schema and `POST /api/waitlist/agent` (existing D1
  `SIGNUPS`, existing rate limit). The person confirms from an email
  before the row counts. (Full agent account creation lives on `api.septena.app`
  per [ADR 0056](adr/0056-agents-create-accounts-with-email-confirmation.md).)
- **AS9 (septena-site#28) Code map.** `llms.txt` gets a "Code map" section that links each
  claim to the source that keeps it: Stop and Pause (`TaskStore`), the claim
  lease, the MCP server, the shared core, the sync engine. The paths come from
  one list in this repo, and the site build checks that each one exists.
  *Shipped.* The list is `registry/code-map.json`; `gen-registries --check`
  checks each path here, and the site build checks it against `main`.
- **AS10 (septena-site#29) How Septena works.** Pages for people and agents:
  architecture (apps, the Worker, the Durable Object store, the core),
  domains (`septena.app`, `api.septena.app`, what each serves) and the
  calls that need no sign-in (`/onboard.md`, `/skill.md`, help, OAuth
  discovery).
- **AS11 (septena-site#30) Security and terms.** A security page: where data is stored, what
  the server keeps, how agents sign in (OAuth with PKCE, device code
  confirmed in the app), Stop and Pause on the server, what is logged.
  Terms of use. Provider-neutral wording about sign-in (sign-in beyond Apple
  is coming). Terms need mz.
- **AS12 (septena-site#31) One page per agent client.** `/integrations` redirects to the
  home page today. It becomes an index, with one page per client that the
  agent guide covers (Claude, Claude Code, any MCP client, and more as the
  guide adds them). Built from one list (`content/agent-logos.json` or a new
  registry entry), never typed by hand. Each page has the setup steps for that
  client and links to the use cases.
- **AS13 (septena-site#32) Use cases.** `help/ask-your-agent` lists sentences. Turn the
  strongest of them into worked use cases: the sentence, what the agent
  reads, what it writes, what lands in Review, what the person does. Plan
  the day, sort the Inbox, a meeting into tasks, take a task, the weekly review.
- **AS14 (septena-site#33) Audience pages and proof.** Audience pages (copy first in the
  Starlings workspace), the maker's own story as the first customer story
  (`docs/MAKER_IDENTITY.md` rules, the journal post), a FAQ page built from
  `content/help-questions.json`, and an agent question in the list-keeper
  quiz rather than a second quiz *(default)*.

All human-facing copy goes through the humanizer skill. No em dashes.

## Order

AS1 first: the other site pages get their twin for free. AS3 before AS5,
because the spec lists the envelope. AS4 and AS6 can run any time. AS7
before AS12 (the client pages show what an agent reaches). Group 3 after AS1.

## Open questions

| Question | Default |
|---|---|
| Idempotency window | 24 hours per account *(default)* |
| Spec version before 1.0 | `v0`, marked unstable *(default)* |
| When the old error fields go away | When no client in `registry/conformance` reads them *(default)* |
| First skills | The four in AS6 *(default)* |
| Quiz | Extend the list-keeper quiz, no second quiz *(default)* |
| Terms of use text | Needs mz (legal) |
| Audience pages | Which audiences: decided in the Starlings workspace first |
