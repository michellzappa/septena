# Connector directory submission packet (#85)

**Status:** ready for mz to submit (neither directory has been submitted yet).
**Tracks:** GitHub issue #85 ("Connector: tool annotations, then submit to the Claude and ChatGPT directories").
**Server audited:** `https://api.septena.app/mcp` (`backend/src/shadow/mcp.ts`, `backend/src/tools/taskTools.ts`, `backend/src/shadow/agent.ts`, `backend/src/shadow/notes.ts`, `backend/src/shadow/oauth.ts`, `backend/test/annotations.test.mjs`).

This packet holds the copy-pasteable listing fields, authentication walkthrough, reviewer test-account template, audited tool annotation table, reviewer prompts, and asset checklist for both directories:

1. **Claude Connectors Directory** (`https://claude.com/docs/connectors/building/submission`, submitted at `https://claude.ai/directory/manage`)
2. **OpenAI / ChatGPT Apps & MCP Directory** (`https://developers.openai.com/apps-sdk/app-submission-guidelines`, submitted at `https://platform.openai.com/apps-manage`)

---

## 1. Pre-submission checklist for mz

Complete these checks before clicking Submit in either portal:

- [x] **Tool annotations verified in code and tests.** All 36 live tools on `api.septena.app/mcp` carry top-level `title` and explicit MCP `annotations` (`title`, `readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`), verified 1:1 against every handler by `backend/test/annotations.test.mjs`. (`tasks_update` is marked `idempotentHint: false` because `notes_append` appends on repeat calls without `notes_rev`.)
- [x] **OAuth redirect hosts pinned for both directories.** `backend/src/oauth/redirects.ts` allows `claude.ai`, `claude.com`, `chatgpt.com`, and loopback hosts.
- [ ] **Deploy latest backend to `api.septena.app`.** Ensure the `tasks_update` `idempotentHint: false` fix and `skill.md` update are live in production before triggering portal rescans.
- [ ] **Check canonical web URLs.** Confirm that `https://www.septena.app/privacy`, `https://www.septena.app/support`, and `https://www.septena.app/agents` load cleanly (HTTP 200 or clean redirect to `https://septena.app/...`; paste the final canonical URL in the portal forms).
- [ ] **Prepare reviewer test access (see Section 5).** Both Anthropic and OpenAI reviewers need a frictionless way to authenticate without getting blocked by MFA or an unavailable second device. Because Septena pairs via an 8-character code approved in the signed-in app, fill in Section 5 before submitting.
- [ ] **ChatGPT pairing page wording (small polish before OpenAI submission).** `backend/src/shadow/oauth.ts` currently renders "If you did not start this from Claude, close this page" and "Settings ▸ Connect Claude" on the pairing HTML page even when `clientName` is ChatGPT. Worth generalizing to `opts.clientName` before submitting to OpenAI so reviewers do not see another vendor's name during OAuth.
- [ ] **OpenAI domain verification.** After creating the draft in `platform.openai.com/apps-manage`, serve the portal's verification token at `https://api.septena.app/.well-known/openai-apps-challenge`.
- [ ] **Optional tool-surface decision.** `tasks_list_tags` and `tasks_checklist_*` are currently live in `tools/list` and included in Section 6 below. If you hide them before the app UI renders tags and checklists, update Section 6 and trigger a portal rescan.

---

## 2. Claude Connectors Directory (copy-paste fields)

**Portal:** `https://claude.ai/directory/manage` (requires a paid Claude plan; for Team/Enterprise, Owner or Directory management role).

### Basic listing

- **Connector Name** *(max 100 chars)*:
  ```text
  Septena
  ```
- **Permanent URL Slug** *(cannot be changed after creation)*:
  ```text
  septena
  ```
- **Tagline / Short Description** *(max 55 chars)*:
  ```text
  Tasks that think with you. You decide when it's done.
  ```
- **Detailed Description** *(max 2,000 chars)*:
  ```text
  Septena is a native task app for iPhone, iPad, and Mac built for one person and their agents. Connect Septena to Claude to read your lists, add or update tasks, keep project notes current, and work through tasks together without giving up control of your day.

  What you can do with this connector:
  - Review Today, the Inbox at the top of Today, Upcoming, Anytime, Faded, and your Agent list.
  - Search tasks, look up tasks linked to a specific email, calendar event, GitHub issue, or URL, and inspect project and area briefs before acting.
  - Capture new tasks from a conversation. Tasks you ask for land where you put them; tasks Claude suggests wait as proposals in your Inbox until you accept them.
  - Let Claude claim a task, post short tap-to-answer questions in the app when it needs a decision, attach a draft or summary, and send finished work to Review in your Agent list.

  Built with clear boundaries:
  - Claude never marks an assigned task done. Finished work waits in Review until you tap Accept or Send back.
  - Project and area briefs stay yours. Claude logs decisions under ## Log and proposes brief edits for you to approve.
  - Stop Claude on one task or Pause all agents from the app at any time. The server enforces both immediately.
  ```
- **Categories** *(pick 1 to 5 matching portal labels)*:
  - `Productivity`
  - `Task Management`

### Connection and authentication

- **Remote MCP Server URL**:
  ```text
  https://api.septena.app/mcp
  ```
- **Transport**: Streamable HTTP (`POST /mcp`). Dual-era JSON-RPC 2.0 supporting MCP revisions `2026-07-28` (stateless) and `2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05` (`initialize` handshake). `GET /mcp` and `DELETE /mcp` return `405 Method Not Allowed` with `Allow: POST`.
- **Authentication**: OAuth 2.1 with PKCE (`S256`), Dynamic Client Registration (`POST /oauth/register`), RFC 9728 Protected Resource Metadata (`/.well-known/oauth-protected-resource`), RFC 8414 Authorization Server Metadata (`/.well-known/oauth-authorization-server`), and RFC 7009 Token Revocation (`POST /oauth/revoke`).
- **Scopes**: `tasks:read tasks:write`

### Links and company details

- **Website URL**: `https://www.septena.app`
- **Documentation URL**: `https://www.septena.app/agents`
- **Machine-readable Agent Guide**: `https://api.septena.app/skill.md`
- **Onboarding Guide**: `https://api.septena.app/onboard.md` (also exposed as MCP prompt `onboard_septena`)
- **Privacy Policy URL**: `https://www.septena.app/privacy`
- **Support URL**: `https://www.septena.app/support`
- **Support Contact**: `[mz: fill in support email, e.g. support@septena.app]`
- **Developer / Publisher Name**: `Michell Zappa` (or `Septena`)
- **Open-Source Repository (MIT)**: `https://github.com/michellzappa/septena`

### Data handling and compliance notes (for portal questionnaire)

- **Data accessed**: Only the authenticated user's private Septena store (tasks, checklists, tags, references, areas, projects, notes, task conversations, and change history). No third-party accounts or public web resources are queried by the server (`openWorldHint: false` on all 36 tools).
- **Isolation**: Each user has an isolated Cloudflare Durable Object (`TaskStore`). OAuth access tokens (`sm2.`, 1-hour TTL) are signed and checked against the user's Durable Object on every request. Rotating refresh tokens (`smr2.`, 30-day sliding TTL) are stored hashed (`SHA-256`) there; refresh replay revokes the entire token family at once.
- **No training / no ads**: User task data is never used to train models, sold, or shared with advertisers.
- **User revocation & deletion**: Users can disconnect any agent in Settings (immediately revoking its token family) or delete their entire account in one step.

---

## 3. OpenAI / ChatGPT Apps & MCP Directory (copy-paste fields)

**Portal:** `https://platform.openai.com/apps-manage` (developer verification required).

### Basic listing

- **App / Display Name**:
  ```text
  Septena
  ```
- **Short Description**:
  ```text
  Read, organize, and work your Septena tasks while you decide what gets marked done.
  ```
- **Long Description**:
  ```text
  Septena is a native task app for iPhone, iPad, and Mac built for one person and their agents. Connect Septena to ChatGPT to check your day, capture tasks, update project notes, and collaborate on open work while keeping final approval in your hands.

  What you can do with Septena in ChatGPT:
  - Check Today, the Inbox at the top of Today, Upcoming, Anytime, Faded, and your Agent list.
  - Search open or completed tasks, find tasks linked to an email, calendar event, GitHub issue, or URL, and read project and area briefs for context.
  - Add tasks directly when you ask, or let ChatGPT propose tasks into your Inbox for one-tap review.
  - Work a task step by step: claim a task, post short choices to the task conversation, attach a draft or summary, and send finished work to Review in your Agent list.

  Built with explicit limits:
  - ChatGPT never marks an assigned task done. Finished work waits in Review until you tap Accept or Send back in Septena.
  - Project and area briefs stay yours. ChatGPT appends decisions under ## Log and proposes brief updates for you to accept.
  - Stop an agent on a single task or Pause all agents from Septena at any time. The server enforces both rules on every write.

  Septena is open source under the MIT License, with one private store per account and no ads.
  ```
- **Category**: `Productivity`

### Server, domain verification, and auth

- **Remote MCP Server URL**:
  ```text
  https://api.septena.app/mcp
  ```
- **OAuth Redirect URI Allowed**: `https://chatgpt.com/connector_platform_oauth_redirect` (already pinned in `backend/src/oauth/redirects.ts`).
- **Domain Verification**: Serve OpenAI's challenge token at `https://api.septena.app/.well-known/openai-apps-challenge` once generated in the portal.
- **Privacy Policy URL**: `https://www.septena.app/privacy`
- **Support URL**: `https://www.septena.app/support`
- **Documentation URL**: `https://www.septena.app/agents`

### Tool annotations and safety justification (for OpenAI reviewer notes)

- Every one of the 36 tools returned by `tools/list` defines `title`, `readOnlyHint`, `destructiveHint`, `idempotentHint`, and `openWorldHint` directly on the server.
- All 15 read tools are strictly side-effect-free (`readOnlyHint: true`, `destructiveHint: false`, `idempotentHint: true`, `openWorldHint: false`).
- All 3 tools that can close, overwrite/cancel, or delete user data (`tasks_complete`, `tasks_update`, `tasks_checklist_delete`) declare `destructiveHint: true` so ChatGPT can prompt for confirmation.
- All 36 tools operate strictly on the authenticated user's private Septena store (`openWorldHint: false`).
- Annotations are paired with server-side enforcement in `TaskStore`: agent writes respect per-task `Stop`, global `Pause all agents`, `human_accepts` (agents cannot close assigned or claimed tasks), `brief_is_users` (agents cannot overwrite an existing project or area brief), and optimistic concurrency (`baseNoteRev` / `notes_rev`).

---

## 4. Authentication and app-pairing walkthrough (for reviewers)

Septena uses standard **OAuth 2.1 + PKCE (`S256`) + Dynamic Client Registration**, paired with an in-app approval code (no passwords or web Sign in with Apple login):

1. **Discovery**: The client requests `POST https://api.septena.app/mcp` without a bearer token and receives `401 Unauthorized` with `WWW-Authenticate: Bearer realm="septena-mcp", error="invalid_token", resource_metadata="https://api.septena.app/.well-known/oauth-protected-resource"`.
2. **Metadata**: The client fetches `/.well-known/oauth-protected-resource` and `/.well-known/oauth-authorization-server`, learning `/oauth/register`, `/oauth/authorize`, `/oauth/token`, and `/oauth/revoke`.
3. **Registration**: The client registers via `POST /oauth/register` with its redirect URI (validated against the pinned client allowlist: `claude.ai`, `claude.com`, `chatgpt.com`, or loopback).
4. **Authorization & Pairing Screen**: The client opens `GET /oauth/authorize` with `response_type=code`, `client_id`, `redirect_uri`, `state`, and `code_challenge` (`S256`). Septena renders an HTML page showing a QR code and an 8-character pairing code (for example `ABCD-EFGH`, valid for 10 minutes, max 5 failed guesses per window) and sets an `HttpOnly; Secure; SameSite=Lax` cookie (`septena_pair`). The page refreshes to `GET /oauth/pair/continue` every 3 seconds.
5. **In-App Approval**: The user opens Septena on a signed-in iPhone, iPad, or Mac (`Settings ▸ AI & Agents` / `Connect Claude`), scans the QR code or types the 8-character code. The app calls `POST /v1/pair/inspect` so the user sees the requesting client name before confirming, then `POST /v1/pair/approve` with the app's bearer session token.
   - *Security note*: Scanning the QR code with a phone's system camera lands on `GET /pair/:code`, which approves nothing and instructs the user to scan only inside Septena. Users should only enter a pairing code from a browser window they opened themselves.
6. **Redirect & Token Exchange**: On the next poll of `/oauth/pair/continue`, Septena issues a single-use authorization code (5-minute TTL) and redirects (`302`) to `redirect_uri` with `code`, `state`, and `iss=https://api.septena.app`. The client exchanges the code and PKCE `code_verifier` at `POST /oauth/token` for:
   - `access_token`: prefix `sm2.`, 1-hour lifetime, scope `tasks:read tasks:write`.
   - `refresh_token`: prefix `smr2.`, 30-day sliding lifetime, rotated on every refresh (reusing a spent refresh token revokes the entire token family).
7. **Revocation**: Clients can revoke via `POST /oauth/revoke`, or the user can disconnect the agent at any time in Septena `Settings ▸ AI & Agents`, which deletes the token family immediately.

---

## 5. Test account instructions (template for mz to fill in)

> **Action required before submission:** Replace every `[FILL IN]` placeholder below before pasting into the Claude or OpenAI reviewer notes fields. Both directories reject submissions when reviewers cannot complete OAuth or see populated sample data.

```text
REVIEWER ACCESS INSTRUCTIONS: SEPTENA MCP CONNECTOR

Server URL: https://api.septena.app/mcp
Auth flow: OAuth 2.1 (DCR + PKCE S256) with in-app 8-character pairing code approval.

1. App access for pairing:
   - TestFlight (iOS/iPadOS): [FILL IN: public or reviewer TestFlight link]
   - Direct macOS build (DMG): [FILL IN: signed macOS DMG download URL]
   - Test account sign-in: [FILL IN: reviewer Sign in with Apple / test account details, or pre-approved pairing workflow]
   - Note on MFA / second-device approval: [FILL IN: confirm how reviewer can approve the 8-character pairing code without hitting personal 2FA, e.g., dedicated test account signed in on TestFlight/macOS or pre-issued test bearer / pairing helper if required by portal]

2. How to pair during review:
   a. Start adding https://api.septena.app/mcp in the client; the OAuth window displays an 8-character code (e.g. ABCD-EFGH).
   b. In the signed-in Septena app, open Settings > AI & Agents, enter the 8-character code, verify the client name shown, and tap Approve.
   c. The OAuth browser tab automatically redirects back within ~3 seconds and completes the connection.

3. Pre-populated test data in this account:
   - Areas: [FILL IN: e.g. "Work", "Home", "Studio"] (at least one with a context brief above "## Log")
   - Projects: [FILL IN: e.g. "Website launch", "Q4 planning"] (at least one with notes and an existing "## Log")
   - Tasks:
     - 3-5 open tasks on Today (including 1 unfiled Inbox item and 1 recurring task)
     - 2 Upcoming scheduled tasks and 2 Anytime tasks
     - 1 task with an external reference (URL or GitHub issue) for testing tasks_find_by_ref
     - 1 task assigned to Claude for testing tasks_pending_reasoning and human_accepts refusal
     - 1 task in Review (endState = needs_verify)
   - Reviewers are welcome to create, update, defer, log notes on, or complete sample tasks during testing.

4. Reviewer support contact during review:
   - Email: [FILL IN: support@septena.app or mz's direct review email]
```

---

## 6. Complete audited tool table

Audited directly from `backend/src/shadow/mcp.ts`, `backend/src/tools/taskTools.ts`, `backend/src/shadow/agent.ts`, `backend/src/shadow/notes.ts`, and `backend/test/annotations.test.mjs`.

- **Total tools exposed by `tools/list`:** 36 (15 read-only, 21 write; 3 destructive; 0 open-world).
- **Scopes:** Read tools require `tasks:read`; write tools require `tasks:write` (in addition to `tasks:read` at `/mcp`).
- Every tool sets `openWorldHint: false` and matches top-level `title` to `annotations.title`.

### Read tools (15)

| Tool name | Title | Scope | `readOnly` | `destructive` | `idempotent` | `openWorld` | Purpose |
|---|---|---|---|---|---|---|---|
| `tasks_orientation` | How to work here | `tasks:read` | `true` | `false` | `true` | `false` | Returns the connector guide, tools grouped by family, and which areas have a brief. |
| `tasks_list` | List tasks | `tasks:read` | `true` | `false` | `true` | `false` | Lists tasks for a view (`today`, `inbox`, `review`, `upcoming`, `anytime`, `completed`, `faded`), with optional tag filter and pagination metadata. |
| `tasks_search` | Search tasks | `tasks:read` | `true` | `false` | `true` | `false` | Searches task titles and notes by words (accent/case-insensitive), filterable by area, project, and status. |
| `tasks_find_by_ref` | Find tasks by reference | `tasks:read` | `true` | `false` | `true` | `false` | Finds tasks pointing at an email, thread, calendar event, GitHub issue/PR, web URL, or another task. |
| `tasks_get` | Get task | `tasks:read` | `true` | `false` | `true` | `false` | Inspects one task by id, including checklist, references, backlinks, fade fields, conversation summary, agent state, and optional project/area notes. |
| `tasks_list_projects` | List projects | `tasks:read` | `true` | `false` | `true` | `false` | Lists projects (active, done, cancelled, or all) with their notes and `noteRev`. |
| `tasks_list_areas` | List areas | `tasks:read` | `true` | `false` | `true` | `false` | Lists areas with emoji, notes, and `noteRev`. |
| `tasks_list_tags` | List tags | `tasks:read` | `true` | `false` | `true` | `false` | Lists existing tags with open task counts so agents reuse existing vocabulary. |
| `tasks_thread_get` | Get task conversation | `tasks:read` | `true` | `false` | `true` | `false` | Reads a task's full conversation (`confirmedIntent`, `acceptance`, turns, `artifact`, `handoff`, `endState`, `assignee`). |
| `tasks_pending_reasoning` | List tasks awaiting reasoning | `tasks:read` | `true` | `false` | `true` | `false` | Lists open tasks queued for agent work (respects global pause, stopped tasks, and `your_turn` waits). |
| `tasks_agent_events` | Get agent events | `tasks:read` | `true` | `false` | `true` | `false` | Returns pointer events (task id and kind, no content) since a numeric cursor, plus global pause state. |
| `tasks_activity` | Get task activity | `tasks:read` | `true` | `false` | `true` | `false` | Returns human-readable recent change activity for one task or across all tasks. |
| `tasks_history` | Get task history | `tasks:read` | `true` | `false` | `true` | `false` | Returns field-level before/after change history for a single task. |
| `tasks_project_get` | Get project | `tasks:read` | `true` | `false` | `true` | `false` | Reads one project with its notes, `noteRev`, parent area notes, open tasks, pending proposal, and last 10 changes. |
| `tasks_notes_history` | Get notes history | `tasks:read` | `true` | `false` | `true` | `false` | Lists saved revisions of a project's or area's notes, with optional full revision body. |

### Write tools: tasks and checklists (8)

| Tool name | Title | Scope | `readOnly` | `destructive` | `idempotent` | `openWorld` | Purpose and annotation rationale |
|---|---|---|---|---|---|---|---|
| `tasks_create` | Create task | `tasks:write` | `false` | `false` | `false` | `false` | Creates a new task (committed for `origin: "user_request"`, Inbox proposal by default). Creates a new record each call (`idempotentHint: false`). |
| `tasks_complete` | Complete task | `tasks:write` | `false` | `true` | `true` | `false` | Marks a task done and spawns the next occurrence for recurring tasks. Marked `destructiveHint: true` because it closes a task out of active views; repeat calls return `alreadyComplete: true` (`idempotentHint: true`). Refused with `human_accepts` on agent-assigned or claimed tasks. |
| `tasks_update` | Update task | `tasks:write` | `false` | `true` | `false` | `false` | Updates any subset of fields on an existing task, including notes, references, tags, dates, or `status: "cancelled"`. Marked `destructiveHint: true` because it can cancel a task, overwrite/clear notes, or remove references, and `idempotentHint: false` because `notes_append` appends on repeated calls without `notes_rev`. |
| `tasks_defer` | Defer task | `tasks:write` | `false` | `false` | `true` | `false` | Moves a task's When date to a future day (`YYYY-MM-DD`) and clears Today. |
| `tasks_move_to_today` | Move task to Today | `tasks:write` | `false` | `false` | `true` | `false` | Pins a task to Today and clears a future When date. |
| `tasks_checklist_add` | Add checklist items | `tasks:write` | `false` | `false` | `false` | `false` | Appends 1-level checklist items to a task. Creates new items each call (`idempotentHint: false`). |
| `tasks_checklist_update` | Update checklist item | `tasks:write` | `false` | `false` | `true` | `false` | Renames, checks/unchecks, or reorders a checklist item without auto-completing the parent task. |
| `tasks_checklist_delete` | Delete checklist item | `tasks:write` | `false` | `true` | `true` | `false` | Permanently deletes a checklist item (`destructiveHint: true`). |

### Write tools: task conversations (6)

| Tool name | Title | Scope | `readOnly` | `destructive` | `idempotent` | `openWorld` | Purpose and annotation rationale |
|---|---|---|---|---|---|---|---|
| `tasks_thread_append` | Append to task conversation | `tasks:write` | `false` | `false` | `false` | `false` | Appends one turn (`provider` question + options or `user` choice) to a task's conversation. Appends a new turn each call (`idempotentHint: false`). |
| `tasks_set_acceptance` | Set task acceptance criteria | `tasks:write` | `false` | `false` | `true` | `false` | Sets the agent deliverable bar (`acceptance`) on a task conversation. |
| `tasks_set_endstate` | Set task conversation end state | `tasks:write` | `false` | `false` | `true` | `false` | Sets the conversation end state (for example `needs_verify` to place the task in Review; task remains open). |
| `tasks_set_assignee` | Set task assignee | `tasks:write` | `false` | `false` | `true` | `false` | Routes a task to `me`, `local`, `claude`, or `null` (auto). |
| `tasks_set_artifact` | Set task artifact | `tasks:write` | `false` | `false` | `true` | `false` | Attaches the agent's deliverable (draft, comparison, summary) to a task. |
| `tasks_set_handoff` | Set task handoff | `tasks:write` | `false` | `false` | `true` | `false` | Sets the user's last-mile action button (`open_url`, `compose`, `call`, `none`). |

### Write tools: agent loop (2)

| Tool name | Title | Scope | `readOnly` | `destructive` | `idempotent` | `openWorld` | Purpose and annotation rationale |
|---|---|---|---|---|---|---|---|
| `tasks_claim` | Claim task | `tasks:write` | `false` | `false` | `false` | `false` | Acquires or renews a time-limited lease (default 30 min, max 240 min) and returns project/area notes. Extends lease and counts new runs (`idempotentHint: false`). |
| `tasks_release` | Release task claim | `tasks:write` | `false` | `false` | `true` | `false` | Ends an agent's lease and records a one-line summary in activity. |

### Write tools: areas, projects, and notes (5)

| Tool name | Title | Scope | `readOnly` | `destructive` | `idempotent` | `openWorld` | Purpose and annotation rationale |
|---|---|---|---|---|---|---|---|
| `tasks_notes_log` | Add to notes log | `tasks:write` | `false` | `false` | `false` | `false` | Appends one dated entry under `## Log` using optimistic concurrency (`baseNoteRev`). Appends a new entry each call (`idempotentHint: false`). |
| `tasks_notes_write` | Write notes | `tasks:write` | `false` | `false` | `true` | `false` | Writes notes for a project or area only while its brief is empty (`baseNoteRev` required; server refuses edits to non-empty briefs with `brief_is_users`, so `destructiveHint: false`). |
| `tasks_notes_propose` | Propose notes brief | `tasks:write` | `false` | `false` | `true` | `false` | Saves one pending brief proposal for the user to accept or reject in the app without changing the live brief. |
| `tasks_area_create` | Create area | `tasks:write` | `false` | `false` | `false` | `false` | Creates a new top-level area with optional emoji and notes (`idempotentHint: false`). |
| `tasks_project_create` | Create project | `tasks:write` | `false` | `false` | `false` | `false` | Creates a new project with optional area, notes, and GitHub repo (`idempotentHint: false`). |

### MCP prompts (1)

| Prompt name | Title | Arguments | Purpose |
|---|---|---|---|
| `onboard_septena` | Set up Septena | `focus` (optional string) | Guides the model through populating a new or sparse Septena account with real areas, projects, briefs, and tasks after user confirmation. |

---

## 7. Example reviewer prompts

Use these prompts in portal submission fields and reviewer walkthroughs to exercise read tools, safe writes, confirmation-gated destructive writes, and server-side refusals:

### Read-only checks

1. **Orientation & Today overview:**
   > "What is on my Today list and Inbox in Septena? Flag anything that has been sitting on Today for more than a week."
   *Expected tools:* `tasks_orientation`, `tasks_list(view: "today")`. No writes.
2. **Search & project context:**
   > "Search my Septena tasks for 'website' and show me the project brief for the matching project."
   *Expected tools:* `tasks_search`, `tasks_project_get` (or `tasks_get(include_notes: true)`). No writes.
3. **Reference lookup:**
   > "Do I already have a Septena task linked to `https://github.com/michellzappa/septena/issues/85`?"
   *Expected tool:* `tasks_find_by_ref`. No writes.

### Non-destructive write checks

4. **Explicit user task creation (committed):**
   > "Add a task to Septena called 'Review Q4 budget' for tomorrow."
   *Expected tools:* `tasks_search` (duplicate check), then `tasks_create(title: "Review Q4 budget", scheduled: "<tomorrow>", origin: "user_request")`. Returns `placement: "committed"`.
5. **Proactive agent suggestion (Inbox proposal):**
   > "Propose two follow-up tasks for my Inbox based on this meeting summary, without putting them directly on Today."
   *Expected tool:* `tasks_create` with `origin: "agent_suggestion"` (or omitted). Returns `placement: "inbox_proposal"`.
6. **Agent work loop & Review handoff:**
   > "Check my Septena reasoning queue, claim the first task, attach a short summary artifact, and send it to Review."
   *Expected tools:* `tasks_pending_reasoning`, `tasks_claim`, `tasks_set_artifact`, `tasks_set_endstate(endState: "needs_verify")`. Task stays open and appears in `tasks_list(view: "review")`.
7. **Project notes log:**
   > "Log a note in the Website Launch project saying we decided to ship the English listing first."
   *Expected tools:* `tasks_list_projects` / `tasks_project_get`, then `tasks_notes_log` with the current `baseNoteRev`.

### Confirmation-gated destructive checks

8. **Complete a user task:**
   > "Mark my 'Review Q4 budget' task complete in Septena."
   *Expected tool:* `tasks_complete` (`destructiveHint: true`, client prompts for confirmation before running).
9. **Cancel or overwrite a task:**
   > "Cancel the 'Old draft' task in Septena."
   *Expected tool:* `tasks_update(status: "cancelled")` (`destructiveHint: true`, client prompts for confirmation).

### Safety and negative-case checks

10. **Human-only completion on assigned task (`human_accepts`):**
    Call `tasks_complete` on a task assigned to `claude` (or currently claimed). The server refuses with `reason: "human_accepts"` and instructs the agent to use `tasks_set_endstate(needs_verify)` instead.
11. **Protected user brief (`brief_is_users`):**
    Call `tasks_notes_write` on a project whose brief is already non-empty. The server refuses with `reason: "brief_is_users"` and points to `tasks_notes_log` or `tasks_notes_propose`.
12. **Global pause / per-task stop:**
    Enable `Pause all agents` (or `Stop` on a single task) in Septena and attempt a write tool. The server refuses with `paused` or `stopped`.

---

## 8. Screenshot and visual asset checklist

Prepare these assets before submitting:

- [ ] **Connector / App Icon**
  - Square high-resolution PNG (`1024x1024`, no transparency artifacts, legible at `32x32` and `64x64` on both light and dark portal backgrounds). Source from Septena's canonical app icon assets.
- [ ] **Listing & Reviewer Walkthrough Screenshots** *(3 to 5 clean captures; required as a carousel if submitting an interactive MCP App to Claude, and helpful for reviewer verification in both directories)*:
  1. **Connect & Pair:** The OAuth pairing page (`api.septena.app/oauth/authorize`) alongside Septena's in-app approval confirmation showing the requesting client name.
  2. **Today & Inbox Proposals:** Septena's Today view with an agent-proposed task waiting in the Inbox at the top of Today, clearly marked with its source.
  3. **Task Conversation:** A task showing an agent question with tap-to-answer options (`Discuss`).
  4. **Review (`Accept` / `Send back`):** A finished task with an attached artifact waiting under Review in Septena's Agent list while still open.
  5. **Client Session:** Claude or ChatGPT listing Today's tasks and creating or updating a task via the connector, showing tool-call transparency and confirmation prompts on destructive tools.
- [ ] **Optional Short Walkthrough Recording (OpenAI review):** A 60-to-90-second screen recording showing OAuth pairing, a read query (`tasks_list`), a non-destructive write (`tasks_create`), a confirmation-prompted destructive write (`tasks_complete`), and the resulting instant sync in Septena.
