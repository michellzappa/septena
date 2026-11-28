# Linked projects — spec

**Status:** not started; rewrite for Starlings only before any work (#12).
**GitHub is out of this spec** since 2026-11-24 (ADR 0033): Septena does not connect to GitHub, and an issue link is a reference ([TASK_REFERENCES_SPEC.md](TASK_REFERENCES_SPEC.md) §6.6). Read every GitHub rule below as historical. **Linear is not planned** (mz, 2026-11-24). **Capture feeds and every provider except Starlings are dropped** (2026-11-25, [ADR 0038](adr/0038-agents-are-the-integrations.md)): an agent reads the source and proposes tasks. The spec still holds for Starlings, which now also builds the shared parts of L0 and L1.
**Decisions:** [ADR 0002](adr/0002-own-backend-replaces-icloud.md),
[ADR 0003](adr/0003-external-links-run-server-side.md).
**Depends on:** the task backend (`docs/SEPTASK_BACKEND.md`). This spec
assumes the backend is the only store; it has no iCloud path.
**Owner of decisions:** mz. Defaults chosen by the agent are marked
*(default)*; overrule them in §11.

## 1. What a linked project is

A linked project is a Septena project whose tasks come from another service.
The other service stays the source of truth for the fields it owns. Septena
adds its own planning on top: Today, scheduled date, manual order, headings,
area, conversation.

First providers:

- **GitHub Issues** — one project per repository.
- **Starlings tasks** — one project per Starlings project (a subject), on one
  or more Starlings workspaces (`hq`, `envisioning`, `bipe`, `uitwijken`, …).

## 2. Why the server, not the device

A link that runs on a device works only while the app runs, as
`RemindersBridge` and `GitHubProvider` do. Every device polls the service
and races the others, and sync stops when every device sleeps.

Each user has one Durable Object that is the single writer
(`docs/SEPTASK_BACKEND.md` §4). A link runs next to it, on the server:

- The Worker holds the provider tokens. No device holds them.
- One process polls or takes webhooks per link. No race between devices.
- Link writes go into the DO like any other write, with actor
  `link:<linkId>` in `changes`. The apps receive them through normal pull.
- Claude sees linked tasks through the same MCP tools, with no extra work.

## 3. Data model

### 3.1 New table `links`

id, provider (`github` / `starlings`), connectionId, remoteScope,
projectId, direction, cursor, lastSyncAt, lastError, rev, updatedAt,
deletedAt.

- `remoteScope` — `owner/repo` for GitHub; `<workspace host>|<subject door>`
  for Starlings (for example `hq.starlings.work|subject:project:abc`).
- `projectId` — the Septena project the link fills. One link per project
  *(default)*. One remote scope per user maps to at most one project.
- `direction` — `read` or `two-way` (§5).
- `cursor` — the provider's change cursor (GitHub `since` timestamp or ETag;
  Starlings update stamp).

### 3.2 New table `connections`

id, provider, account (GitHub login or Starlings workspace host + member
email), tokenRef, scopes, status (`ok` / `expired` / `revoked`), rev,
updatedAt, deletedAt.

- One row per GitHub account and one per Starlings workspace. Several
  Starlings workspaces means several rows. That is the "more than one
  installation" case, and it needs no special code.
- `tokenRef` points at the encrypted token in DO storage. Tokens never sync to
  devices and never appear in `changes` or in pull results.

### 3.3 New fields on `tasks`

- `extKey` — the canonical id of the remote item (§4). Unique per user when
  set.
- `extLinkId` — the link that owns the row.
- `extUrl` — web URL of the remote item, for "Open in GitHub/Starlings".
- `extRemoteUpdatedAt` — the remote's last-change stamp, for conflict checks.

A task with `extKey == null` is an ordinary Septena task, also inside a
linked project (§5.3).

## 4. Identity and dedupe

Every remote item gets one canonical key. Starlings door grammar is the
format:

- GitHub issue: `issue:<owner>/<repo>#<number>`
- Starlings task: `task:<workspace host>/<id>`

The normal form of every key, and the functions that parse it, are in
`docs/TASK_REFERENCES_SPEC.md` §3 (ADR 0031). A task that is **about** a remote
item has a reference, not an `extKey`.

**The same issue can come through two links.** A Starlings project maps a
GitHub repository, and its Work board shows that repo's issues. If mz links
the repo and also the Starlings project, the issue arrives twice. Rule:

- The key of a GitHub issue is the GitHub key, whichever link delivers it.
- When a Starlings link meets an item whose door is `issue:…`, it upserts on
  that key. If a row with that key exists, the existing owner link keeps it
  and the Starlings link does not create a second row.
- The first link that created the row owns it *(default)*. Unlinking the
  owner hands the row to the other link if that link also sees it.

**Task id vs. remote key.** The task id is minted once, when the row is
first imported, as a hash of the `extKey` at that moment. After that the id
never changes. A move to another service (§6.5) changes `extKey`, not the id,
so the task keeps its Today slot, conversation and undo history. Import
upserts on `extKey` (unique per user), never on the id. A replayed import
therefore finds the same row.

## 5. Field ownership

### 5.1 Fields that sync

| Septena | GitHub issue | Starlings task |
|---|---|---|
| title | title | title |
| notes | body | description |
| status `open` | state `open` | open |
| status `done` | closed, reason `completed` | done |
| status `cancelled` | closed, reason `not_planned` | dropped / cancelled |
| deadline | — (milestone due date is not per issue) | due date |

### 5.2 Fields that never leave Septena

today, todaySetOn, todayPosition, scheduled, position, heading, area,
recurrence fields, conversation turns, attachments. These are mz's planning
layer. A remote change never resets them.

### 5.3 Septena-only tasks in a linked project

A task created in a linked project without `extKey` stays local
*(default)*. It does not create a remote issue. A later "Send to GitHub /
Starlings" action can push it, and then it becomes linked. Reason: creating
issues in a shared repo is an outward-facing act. It must be a deliberate
gesture, not a side effect of typing in a list.

### 5.4 Read-only remote data

Labels, milestones, assignees, Starlings pipeline stage, comment count:
stored as one read-only `extMeta` JSON on the task and shown as chips. They
are not editable in Septena in v1. Mapping them both ways is the part that
never converges, so v1 does not try.

## 6. Sync

### 6.1 Inbound (remote → Septena)

- **GitHub:** webhooks for `issues` events when the user installs the GitHub
  App on the repo; else poll `GET /repos/{o}/{r}/issues?state=all&since=` on a
  DO alarm *(default: GitHub App, poll as fallback)*. Pull requests are
  excluded *(default)*.
- **Starlings:** poll the workspace API on a DO alarm, with the update stamp
  as cursor. Starlings is our own product: add a webhook or a change feed
  there if polling is too coarse.
- Each remote change becomes one DO upsert of the mapped fields only, with
  actor `link:<id>`.

### 6.2 Outbound (Septena → remote), `two-way` links only

- The DO sees a commit from `app:` or `mcp:` that changes a mapped field on a
  linked task. It queues an outbound op for that link.
- The link worker sends the change to the provider, then stores the returned
  `extRemoteUpdatedAt`.
- The outbound queue retries with backoff. A permanent failure (403, 404,
  410) sets `lastError` on the link and shows in the app. It never deletes
  the local row.

### 6.3 Conflicts

Field-level last-writer-wins, as in the backend (§6.4 there), with one
addition: for a mapped field, an inbound change whose remote stamp is older
than the last outbound write for that field is skipped. That stops echo
loops (our own write coming back as a webhook).

### 6.4 Deletes and unlinks

| Event | Rule *(all defaults)* |
|---|---|
| Issue deleted or repo access lost | Task goes `cancelled`, keeps its local fields, `extKey` stays. Never hard-delete. |
| Issue transferred to another repo | GitHub redirects the old number; the row updates `extKey` to the new one. If the new repo has no link, the row becomes unlinked (local). |
| Task deleted in Septena | Local delete only. Never deletes or closes the remote item. |
| Task moved out of the linked project | The row becomes local (`extKey` cleared). The remote item is untouched. The next inbound change does not pull it back. Keep a per-link ignore list of keys. |
| Link removed | Rows stay as local tasks *(default)*, or are removed in one undoable step if mz chooses it in the unlink sheet. |

### 6.5 Moving tasks between lists

A move changes the task's home, so it can reach outside Septena. The rule
depends on source and target:

| From → to | What happens |
|---|---|
| Local → local | Same as today. |
| Linked → local | `extKey` cleared, key added to the link's ignore list. Remote item untouched. |
| Local → linked | A sheet asks once: "Create issue in owner/repo?" Yes: the remote item is created and the row becomes linked. No: the row stays local inside that project. |
| Linked → linked, same provider and same connection | The provider's native move: GitHub issue transfer, Starlings subject change. Comments and history stay with the item. |
| Linked → linked, other provider or other connection | No native move exists. Create the item in the target, then close the original with a comment "Moved to <url>". A confirm sheet lists both writes first. |

Rules for every move:

- The task keeps its id and all Septena-owned fields (§4, §5.2).
- Undo is recorded at the gesture (`SeptenaCore/TaskUndo.swift`). For a move
  that wrote to a remote service, undo runs the reverse remote writes where
  possible (transfer back, reopen the original, close the created item). A
  created item usually cannot be deleted. The confirm sheet says so before
  the move.
- A confirm sheet appears only when a remote write happens. Drag and ⌘⇧M stay
  silent for local moves.
- The remote writes go through the outbound queue (§6.2). The row shows a
  pending state until they succeed. On failure the move rolls back locally
  and the row shows the error.

## 6A. Provider adapters

Every provider implements one contract on the backend. The link worker
knows nothing provider-specific.

| Operation | Purpose |
|---|---|
| `authorize` / `refresh` | Get and refresh tokens for a connection. |
| `listScopes(connection)` | Repos, Starlings projects, Linear teams to pick from. |
| `pull(scope, cursor)` | Changed items since the cursor, plus the next cursor. |
| `toKey(item)` | Canonical key (§4). |
| `toFields(item)` | Mapped fields + `extMeta` (§5). |
| `write(key, fields)` | Apply mapped field changes. Returns the new remote stamp. |
| `create(scope, fields)` | Create an item. Returns its key. |
| `move(key, targetScope)` | Native move, when the provider has one; else unsupported. |
| `close(key, reason, comment)` | Close with a reason and an optional comment. |
| `webhook(request)` | Verify and decode an inbound event, when the provider sends them. |

Capabilities differ per provider (no `move` across GitHub orgs, no webhooks
on Starlings yet). The adapter declares them, and the app hides actions a
provider cannot do.

### Link modes

- **Source** (two-way): the full model in this spec. GitHub, Starlings,
  Linear, GitLab.
- **Capture feed** (dropped, ADR 0038; inbound only): the adapter creates a task once per remote
  item, in the Inbox or a chosen project, and never syncs it again. No
  ownership, no write-back, no conflicts. The item's URL goes in `extUrl`, and
  its key in a `from` reference (`docs/TASK_REFERENCES_SPEC.md` §6.1).
  Examples: starred Gmail, Granola action items, Slack "saved for later".

### Provider order

| Provider | Mode | Note |
|---|---|---|
| GitHub Issues | source | First. Proves the model. |
| Starlings tasks | source | Second. Our own product, so its API can adapt. Proves several connections + dedupe. |
| Linear | not planned | Was third. Clean GraphQL and webhooks; strong for selling to developers. |
| Gmail (starred / label) | — | Dropped (ADR 0038). Was the first capture feed. |
| Granola action items | — | Dropped (ADR 0038). |
| GitLab | — | Dropped (ADR 0038). |
| Jira, Asana, Todoist | — | Not planned. Todoist and Asana fit better as a one-shot import. |
| Apple Reminders | — | EventKit runs only on the device. Stays the device inbox bridge (`RemindersBridge`). |

Rejected: a generic "link any MCP server" adapter. MCP tools have no
standard task shape and no change feed, so sync through them is unreliable.

### Linked and shared at once

A shared project (`docs/PROJECT_SHARING_SPEC.md`) can also be linked. The
link then belongs to the project store, not to a user. The connection used
is the one of the member who created the link. If that member leaves, the
link pauses until another member reconnects it.

## 7. Auth

- **GitHub:** a GitHub App (fine-grained, per-repo install, `issues: write`)
  *(default)*, not a PAT. The existing `GitHubProvider` PAT stays on-device for
  the contribution heatmap and is not reused.
- **Starlings:** OAuth 2.1 with dynamic client registration and PKCE, which
  every workspace already serves (`/.well-known/meet`, `/mcp`,
  `/openapi.json`). One authorization per workspace. Septena registers as a
  client on each workspace the first time mz adds it.
- Token refresh runs server-side. A connection whose refresh fails goes to
  `expired`, and the app shows one "Reconnect" row in Settings.

## 8. App surfaces

- **Project header:** provider icon + remote scope + last-sync time + error
  state. "Open in GitHub/Starlings".
- **Row:** a small provider glyph on linked tasks, plus read-only chips from
  `extMeta`. Reuse the existing row anatomy (`docs/TASK_ROW_LANGUAGE_SPEC.md`);
  no new selection or highlight treatment.
- **Settings ▸ Connections:** list of connections, add / reconnect / remove.
- **New project ▸ Link to…:** pick a connection, then a repo or Starlings
  project.
- The apps never call GitHub or Starlings. They only read rows and link status
  from the backend.

## 9. MCP

- Existing task tools work unchanged on linked rows.
- `tasks_get` returns `extKey`, `extUrl` and `extMeta`.
- No new tools in v1. Link management stays in the app.
- There is one MCP server, `backend/src/shadow/mcp.ts` (`AGENTS.md`, "One MCP
  server").

## 10. Phases

| Phase | What | Exit check |
|---|---|---|
| ~~L0~~ | GitHub: dropped (ADR 0033). The tables move to L2. Was: `connections` + `links` tables, GitHub App auth, inbound poll, read-only links. | One repo's open issues show as tasks on every device; closing on GitHub completes them in Septena. |
| ~~L1~~ | GitHub: dropped. Write-back moves to L2. Was: Outbound for complete / reopen / title. Echo suppression. | Completing in Septena closes the issue; no loop in `changes`. |
| L2 | Starlings provider, several workspaces, dedupe by `extKey`. | A repo linked both directly and through a Starlings project shows each issue once. |
| L3 | Notes ↔ body, deadline ↔ due date, "Send to GitHub/Starlings" for local tasks. | Edits round-trip without loss on a real project. |

| L4 | Moves across lists (§6.5), including cross-provider with confirm. | A task moved GitHub → Starlings keeps its id, Today slot and conversation. |
| ~~L5~~ | Capture feeds: dropped (ADR 0038). Was: Gmail first. | A starred mail creates one Inbox task, once. |
| ~~L6~~ | Linear: not planned. Was: | Same exit check as L0–L1, on a Linear team. |

The task factory (`docs/TASK_FACTORY_SPEC.md`) uses the project's
`githubRepo`: it is where the agent works.

## 11. Open questions for mz

| Question | Decision |
|---|---|
| One link per project, or several remote scopes merged into one project? | One. Decided (default, 2026-11-26). |
| Do local tasks in a linked project push to the remote automatically? | No; explicit "Send to…". Decided (default, 2026-11-26). |
| On unlink, keep the rows as local tasks or remove them? | Keep. Decided (default, 2026-11-26). |
| Privacy text: third-party tokens stored on the backend. | Add to the backend privacy text (backend spec §10). Decided (default, 2026-11-26). |
| Build Starlings linked projects, or let the agent read Starlings too (ADR 0038)? | Open (asked 2026-11-25, #24). Default: do not start #12 to #14 until mz answers. |
