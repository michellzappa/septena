# Septask backend — spec

**Status (2026-11-19):** live at `api.septena.app` (Cloudflare account
Centaur-Labs). **Phase 4 done: Septask is backend-only and CloudKit-free**
(§9):
tasks, areas, projects, attachments, conversations, turns and Septask's
synced settings all sync through it. Septena still uses CloudKit for its own
data and freezes the CloudKit task types on a device where Septask runs.
**Owner of decisions:** mz. All open questions answered 2026-11-18 (§12).

## 1. Decisions already made (2026-11-18)

| Question | Decision |
|---|---|
| Where task data lives | Own backend. Cloudflare is the source of truth. SwiftData stays as the local cache. |
| Who Septask is for | mz first. Keep an App Store release possible. |
| Septena (life OS) | Stays. Septena and Septask share one task core. |
| Claude surfaces that must work | Claude.ai / mobile connector, Claude Code / Desktop, scheduled agents while every device sleeps. |

**2026-11-19: Septask becomes a fully separate product** and will probably
be renamed. Backend features (Sign in with Apple, the import, sync) land in
Septask first. **Septena drops tasks** (decided 2026-11-19): the task app
owns them, and Septena's Tasks section is removed after the cutover. The
import runs from Septask (Settings ▸ About ▸ Advanced). Open: the new name.

Earlier default chosen by the agent (overrule if wrong): **tasks move to the backend
for BOTH apps.** Septena's other sections (checklists, intake, body, goals,
wearables, settings) stay on CloudKit. One task store, not two.

## 2. Why

The hosted MCP gateway reads the private CloudKit DB with a
`ckWebAuthToken`. A private-scope token comes only from the idmsa web
sign-in, lives about 8 hours, and Apple gives no server-side refresh
(`SeptenaCore/ClaudeGatewayProvider.swift`). The app renews it only in the
foreground. So Claude loses access whenever no device opened the app in the
last ~8 hours. That is structural; no client fix removes it.

A backend we own removes the token problem: the gateway and the apps talk to
the same server with credentials we control and can refresh.

## 3. Scope

**Moves to the backend:**

- `Task` — including heading rows (`kind == "heading"`) and recurrence fields.
- `Area`, `Project`.
- `TaskAttachment` — metadata in the DB, bytes in R2.
- Task conversation turns (today `TaskEntity.conversationJSON`) — becomes its
  own append-only table (§5.3).

**Stays on CloudKit:** every other record type in `docs/CloudKitSchema.md`.

**Unknown, verify before build:**

- Whether any non-task record references a task, area or project id (goals,
  sections, settings). If yes, that reference crosses stores and needs a rule.
- Whether task-related settings (`SettingsKey.todayGroupByList` and others)
  sync through the CloudKit `Settings` record or stay in local defaults.
- The current state of the gateway — it was not checked out on this machine
  when this spec was written, so the spec did not read its code. Since #83 the
  gateway lives in `backend/` in this repo (the old `../septena-mcp-gateway`
  checkout is frozen).

## 4. Architecture

```
iOS / Mac / Watch apps                 Claude (web, mobile, Code, agents)
  SwiftData cache + op queue                    │
          │  HTTPS + WebSocket                  │ MCP (OAuth)
          ▼                                     ▼
   Worker  api.septena.app  (Hono)  ◄────── Worker  mcp.septena.app (gateway)
          │                                     │
          └──────────► Durable Object per user ◄┘
                        SQLite: tasks, areas, projects,
                        attachments, turns, change log
                        R2: attachment bytes
```

- **One Durable Object per user.** The DO is the authorization boundary and
  the single writer. Its SQLite holds all task data and the change log. Every
  write is serialized by the DO, so the server order is total and simple.
- **The gateway calls the DO directly** (service binding / DO stub). No
  CloudKit Web Services, no `ckWebAuthToken`, no foreground renewal.
- **R2** holds attachment bytes, keyed `u/{userId}/att/{attachmentId}`.
  Uploads and downloads go through the Worker (`PUT`/`GET
  /v1/attachments/:id`), not signed URLs: no S3 credentials to manage, and
  the 25 MB limit is under the Worker's request-body cap. The client pushes
  the attachment row first, then uploads bytes whose length must equal its
  `byteCount`. An agent adds a file (10 MB at most) with
  `tasks_attachment_add`, in the call or with a one-time signed token on
  `PUT /v1/agent/upload`; it cannot read or delete files
  (`backend/src/shadow/attachments.ts`).
- **Stack:** Workers + Hono + Durable Objects (SQLite) + R2, Zod at every
  boundary. Matches the gateway, which is already a Worker.

## 5. Data model

### 5.1 Rules for every row

- `id` — the existing id, unchanged. Task ids stay bare; area/project ids stay
  the shortids from `docs/IDENTIFIERS.md`. No id rewrite during migration.
- `rev` — server sequence number of the last change to this row. Assigned by
  the DO. Monotonic per user.
- `updatedAt` — server time of the last change.
- `deletedAt` — tombstone. Rows are soft-deleted so a pull can carry the
  deletion. Tombstones are purged after 90 days.
- Field names are the real names, not CloudKit reserved slots:
  `Area.reservedString1` → `emoji`, `reservedInt1` → `position`. Legacy
  encrypted `notes` is dropped; only `notesText` migrates, as `notes`.
  (`Area.reservedString2` / `Project.reservedString1` → `attachment` was
  retired 2026-11-21; the column stays on the wire only so older clients'
  pushes still validate.)
- Dates keep their current shapes (`YYYY-MM-DD` strings for `created`,
  `scheduled`, `deadline`, `deferredDeadline`, `todaySetOn`; the existing `completedAt` string).
  Changing them is a separate decision, not part of the move.

### 5.2 Tables

**tasks:** id, title, status, kind, heading, area, project, created,
scheduled, deadline, deferredDeadline, today, todaySetOn, completedAt, notes, position,
todayPosition, recurrenceUnit, recurrenceInterval, recurrenceAfterCompletion,
recurrencePaused, recurrenceSeriesID, recurrenceAnchorDate, source,
sourceClient, acknowledgedAt, createdAt, rev, updatedAt, deletedAt.

`position` is the manual order inside the task's own list (Inbox, area,
project). `todayPosition` is the manual order on Today, kept apart so
reordering Today never reshuffles the home list, as in Things. It is null
until the row is first ordered on Today; readers fall back to `position`.
The app uses it since #66: `TaskEntity.todayPosition` (local, no CloudKit
field), written by `TaskMutator.reorderToday` and cleared when an open task
leaves Today; every Today surface sorts by `todayPosition ?? position`.

**Fade fields** (docs/TASK_FADE_SPEC.md §3, #117): the `tasks` table has
`touchedAt` (stamp), `deferCount` (int, default 0), `fadedAt` (stamp),
`dropReason` (text 16: `faded` / `user`) and `effort` (text 16: `light` /
`heavy`). The app pushes them (`TaskBackendMapping`) and applies them on pull
(`TaskSyncApply`), so the newest device's fade clock wins. Only the app writes
them: the store refuses an agent write that sets one (`app_only:<field>`), and
`tasks_get` returns them read-only. The Worker went out before the app build
that pushes them, because a push with an unknown column fails validation and
blocks the row.

**areas:** id, title, context, emoji, attachment, position, rev, updatedAt,
deletedAt.

**projects:** id, title, status, area, created, completedAt, notes, context,
githubRepo, attachment, position, rev, updatedAt, deletedAt.

**attachments:** id, taskId, filename, contentType, byteCount, position,
createdAt, r2Key, rev, updatedAt, deletedAt.

**turns:** taskId, seq, role, step, provider, confidence, question, options,
chosen, otherText, inReplyTo, note, ts, plus the per-task fields of
`ConvoTurn`'s parent struct that are not turns (status, assignee, handoff,
artifact, acceptance, endstate) in a `task_convo` row. Exact split follows
`SeptenaCore/TaskConvo.swift` at build time.

**settings** (added 2026-11-19): id (the setting key), value (JSON), rev,
updatedAt, deletedAt. One row per key of `SETTING_VALUES` in the gateway's
`src/store/columns.ts`; each key has its own Zod schema, and unknown keys are
refused. Today: `welcomeName`, `telemetryLevel` (retired, #436: accepted from older builds, read by none), `calendarHiddenTitles`,
`rolledInDismissedOn`, `homeTimezone`. Settings are never deleted (a
tombstone would drop every later write, §6.4); `value: null` clears one.
Why key/value rows and not one row of columns: conflicts stay per key (two
devices changing two settings both win), and a new setting is one schema line
with no table change. A pull carries setting rows only when the client asks
with `settings=1`, because builds before 2026-11-19 decode entities strictly.
The app keeps these values in a blob in Septask's own defaults, NOT in the
shared `SettingsEntity` row, which Septena still syncs through CloudKit
(`SeptenaCore/TaskBackend/TaskSyncSettings.swift`). First run: the blob is
seeded from that row, and a seeded value is pushed only for a key the first
pull did not bring, so a value another device pushed wins. Device-only
preferences stay in local defaults.

**do_sessions** (entity `doSession`, pull flag `doSessions=1`): one row for each
Do. The columns are in `backend/src/store/columns.ts`. The rules, the REST verbs
and what agents may do are in `docs/DO_SPEC.md`.

**changes:** rev, entity, id, op (`upsert` / `delete` / `dropped`), fields (JSON of the
changed field names), clientOpId, actor (`app:<device>` / `mcp:<client>`),
at. This is the sync log and the audit log.

**client_ops:** clientOpId, rev, at — dedupe for retried pushes. Purged after
30 days.

### 5.3 Conversation turns are append-only rows

Today the whole conversation is one JSON string on the task. If Claude
appends a turn while a device appends a turn, last writer wins and one turn is
lost. On the backend, a turn is a row; `seq` is assigned by the DO. Two
appends never overwrite each other.

## 6. Sync protocol

### 6.1 Push

`POST /v1/sync/push` with a batch of ops:

- `{ clientOpId, entity, id, op: "upsert", fields: { … only changed fields … }, base? }`.
  `base: { notes }` (task and project) is the notes the edit started from. The
  DO merges when the row changed meanwhile, and the client pulls the result.
- `{ clientOpId, entity, id, op: "delete" }`
- `{ clientOpId, op: "appendTurn", taskId, turn }`

The DO applies the batch in order inside one transaction, assigns `rev`s,
writes `changes`, and returns `{ appliedThrough: rev, results: [...] }`. A
`clientOpId` already in `client_ops` returns the stored result and does not
apply again. So a retry after a lost response is safe.

### 6.2 Pull

`GET /v1/sync/pull?since=<rev>&limit=<n>` returns the current state of every
row changed after `since`, plus tombstones, plus `nextSince` and `hasMore`.
The client stores `nextSince` only after it saved the batch to SwiftData.

### 6.3 Live nudge

- **Foreground:** the app holds a WebSocket to the DO (hibernation API). On
  any commit, the DO sends `{ rev }`. The client pulls. The socket carries no
  data, only the nudge.
- **Background:** the DO sends a silent APNs push on commit (coalesced). Like
  today's CloudKit rule, push is a hint, not a guarantee: **foreground pull on
  launch and on activate stays the reliable path.**
- **Watch and widgets:** unchanged. They read the snapshots the phone and Mac
  already publish (`TasksWatchSnapshotPublisher`, `TasksWidgetSnapshotStore`).

### 6.4 Conflict rule

**Field-level last-writer-wins by server arrival order.** A push carries only
changed fields, so concurrent edits to different fields of one task both
survive. Concurrent edits to the same field: the later arrival at the DO
wins. Turns never conflict (§5.3). **A deleted row stays deleted:** an update
that arrives after the delete is dropped, and the DO writes it to `changes`
with op `dropped` so the edit is still on record.

**Area and project deletes cascade on the client, not on the server
(2026-11-20).** The device that deletes an area or project first soft-deletes
every task in it (open and done, headings included; an area also deletes its
projects), then deletes the container. So the backend receives ordinary task
`delete` ops plus the area / project `delete`; it does not cascade, and it
never moves tasks to the Inbox. Area and project deletes are held in the
outbox for `deleteGrace`, like task deletes, so ⌘Z can revive the row under
the same id. A device that pulls a container delete before the task deletes
hides those tasks, and moves any that are still live after the full pull to
Recently Deleted (`AreasMutator.sweepDeletedContainerOrphans`). Restoring a
task whose container is gone puts it in the Inbox, never on a dangling id.

Recurrence: the next occurrence keeps its deterministic id (computed from the
series and the completion stamp, as `TasksBackend.complete` / `uncomplete`
do today). Two devices that both spawn it produce one row, because the upsert
is idempotent on id.

### 6.5 Offline

The client queues ops in SwiftData (a persisted op queue — the job
`CKSyncEngine` does today). Local writes apply to SwiftData at once, as now.
The queue drains on reconnect, in order. After a push, the client pulls, and
the pulled server state overwrites local fields that have no pending op.

## 7. Client changes

- **The swap point is the three backends.** Only
  `SeptenaCore/CloudKit/TasksBackend.swift`, `AreasBackend.swift` and
  `ProjectsBackend.swift` call `CKEngine.note…Change` for tasks, areas and
  projects. A new `TaskSyncClient` replaces those calls. Mutators keep their
  public API. Views do not change.
- **CKEngine stops owning task kinds** after cutover. It keeps every other
  record type. The task/area/project/attachment record types stay in the
  CloudKit schema (Prod deploy is additive-only) but receive no writes.
- **Undo** stays as is (`SeptenaCore/TaskUndo.swift`): recorded at the user
  gesture, never in the mutator or the sync apply path.
- **Sign-in:** Sign in with Apple, once per install. The Worker returns a
  long-lived refresh token (Keychain, shared through the app group so
  extensions can read it) and a short access token. **Septena asks for Sign
  in with Apple at first launch**, for every user, same as Septask.
- **In-app MCP server** (`SeptenaCore/MCP/`) keeps working: it reads the
  local cache and writes through the mutators, so its writes sync like any
  app write.
- **Cutover flag:** a `taskStore` setting with values `cloudkit` / `backend`.
  Both paths exist in the code until the cleanup phase.
- **Status (2026-11-19): Septask is CloudKit-free.** Septask never starts
  `CKEngine` (no zone fetch, no push registration, no `CKContainer`), has no
  iCloud or push entitlement, and has no iCloud/backend switch. In Septask
  `TaskStoreMode.current` is always `backend`; Septask writes `backend` into
  the shared `septena.taskStore.mode` key at every launch so Septena keeps its
  freeze. Signed out, Septask edits the local store and queues every change
  in the outbox; the welcome, Today and Settings ▸ Account ask for Sign in
  with Apple. The `.tasks` section color is no longer read in Septask (it
  uses the platform accent).

## 8. MCP gateway

- Tools keep their names and shapes (`tasks_list`, `tasks_create`,
  `tasks_update`, `tasks_thread_append`, …). The gateway changes its data
  source from CloudKit Web Services to the user's DO. Tool changes still land
  in both MCP servers in the same change (`CLAUDE.md`, "Two MCP servers").
- **Auth:** OAuth 2.1 on the gateway, with Sign in with Apple as the identity.
  The OAuth subject maps to the same user id as the app's sign-in, so the
  gateway resolves the same DO. Refresh tokens rotate server-side; no device
  needs to be awake.
- **Scheduled agents:** use the same connector. If an agent runtime cannot do
  OAuth, a per-user API token with a `tasks` scope, created in Settings, is
  the fallback.
- **Dual-era protocol stays** (legacy `initialize` plus stateless
  `2026-07-28`). This spec does not change the protocol layer.
- `ClaudeGatewayProvider` and the reconnect cue retire after cutover.
- **Status (2026-11-21): live.** The connector at `https://api.septena.app/mcp`
  is deployed and is the only task connector (mcp.septena.app was
  decommissioned on 2026-11-20). History below. It started as a read-only test
  connector that served `https://api.septena.app/mcp` from the same Worker
  (`src/shadow/` in the gateway). Its OAuth uses **app pairing** instead of
  web Sign in with Apple (no Services ID needed): the authorize page shows an
  8-character code, and Septask ▸ Settings ▸ About ▸ Advanced ▸ Task backend ▸
  "Connect Claude (preview)" approves it through `POST /v1/pair/approve` with
  the app's own session. Today is ordered by `todayPosition`, then
  `position`. **Read-write since 2026-11-19:** it serves every task tool of the live connector,
  writes included, as TaskStore pushes with actor `mcp:claude`. New pairings
  get `tasks:read tasks:write`; an older read-only pairing must reconnect to
  write.

## 9. Migration

Each phase ends in a working app. Rollback is the cutover flag.

| Phase | What happens | Exit check |
|---|---|---|
| 0. Backend | Worker, DO, R2, auth, push/pull. No app uses it. | Push/pull round trip from a test client. |
| 1. Import | A one-shot "Copy tasks to backend" action in the Mac app reads the local SwiftData mirror and pushes everything, ids unchanged. Attachments upload to R2. | Count and per-row hash match between SwiftData and the DO. |
| 2. Shadow | The gateway reads the DO for `tasks_list` / `tasks_get` in a test connector. The apps still write CloudKit. Import re-runs to refresh. | Claude answers match the app for a few days of real use. |
| 3. Cutover | mz flips `taskStore = backend` on every device. A final import runs first. CloudKit task records freeze (no writes, no deletes). The live connector switches to the DO. | A day of normal use on all devices with no divergence. |
| 4. Cleanup | Remove the CloudKit task path and the token flow from the code. CloudKit task records stay as a frozen backup. | Build green on all schemes. |

**Status (2026-11-19):** phases 0 and 1 are live (2,035 rows imported).
Phase 2 is built and awaits deploy: the read-only connector at
`api.septena.app/mcp`, authorized by pairing a code with the Septask Mac app
(§8).

**Rollback after phase 3:** a one-shot "Copy tasks back to iCloud" writer
must exist **before** cutover, because rows created on the backend after
cutover are not in CloudKit.

**Phase 4 status (2026-11-19), Septask:** done for Septask. The rollback
("Move tasks back to iCloud", `TaskStoreRollback`) and the import ("Copy tasks
to backend", `TaskBackendImporter`, with its CloudKit-pending checks) are
removed from Septask's compile, as are `CloudKitRecordRegistry`,
`SchemaSeedRegistrar` and the CloudKit watch snapshot publisher (project.yml
excludes). No re-upload action replaces the import: the sync engine's
reconcile already sends every local row the backend does not hold. There is
no way back to iCloud from Septask any more. The CloudKit task records stay as
a frozen backup. Septena still compiles the CloudKit task path for its own
records; the files above remain in Septena until Septena drops tasks.

**Phase 4 done (2026-11-19, #42).** No CloudKit task record mapping compiles
into either Septask target. `CloudKit/TaskRecord.swift`, `AreaRecord.swift`,
`ProjectRecord.swift`, `TaskAttachmentRecord.swift` (CKRecord encode/decode)
and `CloudKit/Migration.swift` (the CloudKit `TasksMigrator` and its
snapshots) are excluded from `Septask` and `SeptaskMac`. Their shared halves
moved to their own files, which both apps compile: `TaskRecordNames.swift`
(record type and record-name scheme, plain strings, used by
`TaskStoreMode`'s freeze and the sync engine's ledger),
`TaskAttachments.swift` (`TaskAttachmentEntity`, `TaskAttachmentFiles`,
`TaskAttachmentStore`) and `LaunchMigrators.swift` (`EventTimestamp` and the
launch migrators). `CKEngine` still compiles in Septask because the mutators
take it; it never starts there. `TaskStoreMode` and the frozen-record-types
logic stay for Septena, which reads the device-wide mode so it never writes
tasks through CloudKit.

## 10. Privacy and security

- **The privacy story changes.** Task data leaves the user's iCloud and lives
  on Cloudflare, encrypted at rest by Cloudflare, not end-to-end. Claude needs
  plaintext, so end-to-end encryption is not possible for this data. App
  Store privacy labels and the site's privacy text must change before any
  public release.
- Per-user DO isolation is the authorization boundary. No query crosses users.
- Zod validation on every request body. Unknown fields are rejected. Fail
  closed.
- Secrets live in wrangler secrets only (Apple keys, token signing key).
- Account deletion deletes the DO storage and the R2 prefix.
- **Devices & Access (2026-11-22).** `GET /v1/access` lists every place the
  account is signed in: app sessions (the `devices` and `sessions` tables,
  one row per install, `current` marks the caller) and MCP connections (the
  `connections` table, one row per token family, named from the OAuth client
  registration). `DELETE /v1/access/devices/:sid` ends that device's session
  from the next request and closes its sockets (ADR 0040). It refuses the
  caller's own sid (sign out through `/v1/auth/signout`).
  `DELETE /v1/access/connections/:id` revokes the token family. A connection
  appears on its first token issue or refresh after deploy, and drops out
  after 30 days without a refresh.
- **Sessions (2026-11-25, ADR 0040).** Apps and agents share one session
  model, in `backend/src/store/sessions.ts`. The Durable Object is the only
  authority, every request asks it, and KV holds no live token. A lost
  renewal reply never signs anyone out. A spent token that comes back ends
  the session. A client gives up its session only on a 401 whose body says
  `invalid_grant`.
- **Agents (2026-11-24).** One agent is one MCP connection (one token
  family). The apps show devices and agents as separate lists: Settings ▸
  Account ▸ Devices, and Settings ▸ AI & Agents ▸ Agents. Each agent has a
  name: the user gives it when they approve the code (`name` on
  `POST /v1/pair/approve`), and can change it with
  `PATCH /v1/access/connections/:id {name}` (`null` goes back to the client's
  registered name). Writes and task history use that name. When an agent
  pairs, the client's older families stop working, and so does the agent
  named in `replaces` on the approval, so one agent stays one row.
  `GET /v1/access` returns `agents: {count, limit}`; the plan limit
  `connectedAgents` only logs (`agent_limit_over`), it never blocks.
- **Agent keys (2026-11-26, #86).** For agents that cannot hold an OAuth
  sign-in (scripts, cron, n8n, a CLI). `POST /v1/access/keys
  {name, access: "read"|"write"}` (an app session only; default `write`)
  returns `{id, key, name, scope}` once. The key is
  `sk1.<user id, base64url>.<id>.<secret>`; the store keeps only the hash
  of the secret, as an agent session with client `septena-agent-key` and
  a connection row named `name` (client name "Agent key"). So the key is
  one row in the Agents list, and rename, disconnect
  (`DELETE /v1/access/connections/:id`), Stop, Pause all agents and
  account deletion cover it. It is accepted wherever an `sm2.` token is:
  `Authorization: Bearer sk1.…` on `/mcp` and
  `/v1/agent/events/stream`. A key never expires and stays in the list
  while unused. `POST /oauth/revoke` with the key ends it. It does not
  reach the app routes under `/v1` (the public REST API is #90). Keys
  count toward `connectedAgents` (log-only). Writes and claims use the key's
  name.
- **Waiting (2026-11-26, ADR 0053, #669).** Task fields `waitingOn` (who,
  ≤80 chars) and `waitingSince` (day). A write that sets `waitingOn` without
  `waitingSince` gets today (UTC); clearing `waitingOn` clears both. A
  waiting task never fades (`fadeEnds`, `fadeIsStale`). An agent may set a
  wait but not clear it, nor complete, cancel or delete a waiting task
  (`in_review`). MCP `tasks_set_waiting`, `tasks_list view=waiting`.
- Attachment limits: **25 MB per file, 2 GB per user.** The Worker checks
  both before it mints an upload URL, and the app checks the file size before
  upload so the user sees the error at once.

## 11. Repo split (after cutover)

- A new `septask` repo holds the Septask app targets and the backend Worker.
- The shared task core (models, mutators, `TaskSyncClient`, task UI under
  `Shell/Tasks`) becomes an SPM package that both repos consume.
- Septena pins a version of that package. Shared-code changes then need a
  version bump in Septena; this replaces today's "build all four schemes"
  rule.
- The split happens after cutover so that the migration happens in one repo.

## 12. Decisions on the open questions (2026-11-18)

| Question | Decision |
|---|---|
| Domain | Stay on `septena.app`: keep `mcp.septena.app`, add `api.septena.app`. The live connector does not change. |
| Sign-in in Septena | Septena asks for Sign in with Apple at first launch, for every user. |
| Attachment limits | 25 MB per file, 2 GB per user (§10). |
| Delete vs. late update | A deleted task stays deleted; the late edit is dropped and logged (§6.4). |
| Area / project delete (2026-11-20) | Its tasks go to Recently Deleted, never to the Inbox; the deleting client cascades, the server does not (§6.4). One undo step restores everything. |
| Manual order (2026-11-19) | Today has its own order (`todayPosition`), separate from the home list's `position`, as in Things. The backend column is live; the apps adopt it at cutover. |
| Things-grade pass | Separate work. Needs mz's list of pains. Not part of this spec. |
| Linked projects (2026-11-19) | GitHub Issues and Starlings tasks as project sources, run server-side after cutover. Spec: `docs/LINKED_PROJECTS_SPEC.md`. |
| Septask and CloudKit (2026-11-19) | Septask is CloudKit-free: no engine, no entitlement, no iCloud switch. Settings it syncs move to the backend `setting` entity. Rollback to iCloud is removed. |
| Task-related settings (2026-11-19) | Answers §3's open question. Task view preferences (`todayGroupByList` and the like) are device-local defaults and stay local. The account-wide settings Septask used (name, usage-data level, hidden calendars, rolled-in dismissal, home time zone) synced through the CloudKit `Settings` record; for Septask they now sync as backend `setting` rows (§5.2). |
