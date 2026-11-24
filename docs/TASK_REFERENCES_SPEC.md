# Task references — spec

**Status:** building (R0, 2026-11-24). mz accepted the defaults of #296.
**First release = R0 + R1:** add a link or an email to a task, see it, open it. R2 to R4 come later and do not block it.
Defaults that this doc adds are marked *(new)* in §13.
**Decisions:** [ADR 0031](adr/0031-references-are-keyed-pointers.md),
[ADR 0002](adr/0002-own-backend-replaces-icloud.md),
[ADR 0003](adr/0003-external-links-run-server-side.md),
[ADR 0008](adr/0008-agent-loop-rules-live-in-the-store.md),
[ADR 0015](adr/0015-shared-registries-for-cross-platform-clients.md),
[ADR 0025](adr/0025-shared-rust-core.md),
[ADR 0029](adr/0029-one-task-page-two-depths.md).
**Builds on:** `registry/entities.json`, `registry/surfaces.json` (`taskPage`),
`core/crates/septena-core`, `backend/src/store/TaskStore.ts`,
`backend/src/shadow/mcp.ts`, `SeptenaCore/ConvoDerived.swift`.
**Tracking issue:** [#296](https://github.com/michellzappa/septena/issues/296).
**Owner of decisions:** mz.

## 1. What a reference is

A task can point at the things it is about: an email, a mail thread, a
calendar event, a GitHub issue, a Starlings record, a web page, a file,
another task. Each pointer is a **reference**:

- a canonical **key** that stays the same in every client, and
- a small **snapshot**, so that the reference stays readable when its target
  is gone or cannot be opened on this device.

Each client turns the key into "open it here".

A task without references shows no reference UI.

## 2. References and linked projects

| | `extKey` (`LINKED_PROJECTS_SPEC.md`) | Reference (this spec) |
|---|---|---|
| Meaning | The task **is** the remote item. | The task is **about** the item. |
| Count per task | 0 or 1 | 0 to 20 |
| Sync with the target | Source mode syncs fields both ways. | Never. |
| Owner | A link (`extLinkId`) | The user |

- Both use the key grammar of §3.
- A capture feed (#15) and the forwarding address (#134) write a reference to
  the item they captured.
- The name `links` belongs to linked projects. This entity is `taskRef`.

## 3. Key grammar

A key is `<kind>:<id>`. The kind is lowercase ASCII. The id is normalised per
kind. A key is at most 1,000 characters after normalisation. A longer key is
rejected, never cut.

| Kind | Id | Normal form |
|---|---|---|
| `email` | RFC 5322 Message-ID | Angle brackets and white space removed. The part after the last `@` is lowercased. The part before it is kept. |
| `thread` | Message-ID of the thread root | First entry of `References`, else `In-Reply-To`, else the message's own id. Same normal form as `email`. |
| `event` | iCalendar `UID`, and `\|<RECURRENCE-ID>` for one occurrence | `%` and `\|` in the UID are percent-encoded. RECURRENCE-ID in UTC, `YYYYMMDDTHHMMSSZ`, or `YYYYMMDD` for an all-day event. |
| `issue` | `<owner>/<repo>#<n>` | Owner and repo lowercased. Pull requests use the same kind, because GitHub gives issues and pull requests one number series. |
| `task` | Septena task id, or `<workspace host>/<id>` for a Starlings task | An id without `/` is a Septena task. Host lowercased. |
| `door` | `<workspace host>\|<door>` | Any other Starlings record. Host lowercased. A door that names a GitHub issue becomes `issue:`. A door that names a Starlings task becomes `task:`. |
| `url` | Web URL, `http` or `https` only | Scheme and host lowercased. Default port, fragment and tracking parameters (`utm_*`, `fbclid`, `gclid`) removed. Order of the other parameters kept. |
| `file` | `attachment/<attachment id>` or `icloud/<path>` | iCloud path relative to the user's iCloud Drive, NFC. |

Rules:

- **One item, one key.** A `github.com/…/issues/7` URL becomes an `issue:`
  key, a `message://` URL becomes an `email:` key, a Starlings URL becomes a
  `door:` or `task:` key. `url:` is only the fallback.
- **Details that the vectors fix** (`refs.json`). A kind is
  `[a-z][a-z0-9_-]{0,31}`. The limit counts UTF-16 units. Domains and hosts are
  lowercased in ASCII. A URL with no path gets `/`. A URL with a user name or
  a password, or with white space, is an error. `www.github.com` is GitHub. A
  Starlings URL is a page under `.starlings.work` whose path names one record
  (`/work/<kind>/<id>`, `/docs/document/<id>`, `/calendar/event/<id>`,
  `/team/thread/<id>`); any other page stays `url:`. An iCloud path with `.`,
  `..` or an empty part is an error. Control characters are an error.
- **Unknown kinds are kept.** A client that does not know a kind shows the
  snapshot and never drops the row. The store accepts any kind that matches
  the kind pattern.
- **The raw id is kept too.** Mail apps can match a Message-ID by its exact
  case. The normalised key is for lookup. The resolver uses
  `snapshot.rawId` (§4).
- The grammar lives once, in the core: `parse_ref(input)` (key, URL or
  `message://` link → key + kind), `normalize_ref_key(key)`, and
  `email_ref_keys(headers)` (§6.1). Vectors: `registry/conformance/refs.json`.
- Linked projects use the same functions for `extKey`.

## 4. Data model

New entity `taskRef` in `registry/entities.json`, table `task_refs`. All
platforms get their types from the registry generator.

| Column | Kind | Rule |
|---|---|---|
| `taskId` | id, required | Immutable after insert. |
| `key` | text, max 1,000, required | Normalised. Immutable after insert. |
| `kind` | text, max 32, server-owned | Derived from `key`. |
| `role` | enum `taskRefRole`, default `about` | `about`, `from`, `blocked_by`, `follow_up`. |
| `snapshot` | json, max 2,048 bytes | §4.1. |
| `position` | real, null | Order inside the task. |
| `createdBy` | text, server-owned | The actor of the insert (`app:…`, `mcp:…`, `capture:<feed>`). |
| `lastSeenAt` | stamp, server-owned | The last time a capture path met this key (§6.2). |
| `createdAt` | stamp | |

- Registry limits: `maxRefsPerTask` 20, `refKeyMax` 1,000,
  `refSnapshotMax` 2,048.
- Index on `key` and on `taskId`. At most one live row per `taskId` + `key`.
- **Id:** `ref-` + `fnv1a64(taskId | key | n)`, where `n` is the number of
  deleted rows with the same task and key. Two offline devices that add the
  same reference mint the same id, so the rows converge. A re-added reference
  gets a new id, because a deleted row stays deleted in the store.
- A purged task takes its references with it, as with checklist items. A task
  in Recently Deleted keeps them.
- **Pull is opt-in.** Older clients decode pulled entities strictly, so the
  store sends `taskRef` rows only to a client that asks for them (as
  `includeChecklists` does). The Worker deploys before the first app build
  that pushes references.
- References are on every plan. A snapshot is not an attachment.

### 4.1 Snapshot

Optional fields, all text: `title`, `subtitle` (sender, repo, organiser,
host), `date`, `url` (web address of the item, `http`/`https` only), `rawId`
(the id before normalisation), `account` (the mail account address, for the
Gmail resolver).

- Written when the reference is added. A client that has the source at hand
  can refresh it. Last write wins on the whole field.
- No message body, no attachments, no excerpts.
- Over the cap: the writer shortens `title` and `subtitle`. The store rejects
  a snapshot over the cap.

### 4.2 Repeats, duplicates and roles

- The next occurrence of a repeating task, and a duplicated task, copy the
  `about` references only.
- `from` is the item the task was created from.
- `blocked_by` and `follow_up` are labels in v1. `blocked_by` does not hide
  or lock a task.

## 5. Resolvers: key → "open it here"

The core returns the kind and the parts. Each platform maps them to an open
action. A client that cannot open a kind opens `snapshot.url`. If there is no
URL either, the row shows the snapshot and has no open action.

| Kind | Mac, iPhone, iPad | Web, Android, Windows |
|---|---|---|
| `email`, `thread` | `message://%3C<rawId>%3E` (Apple Mail) | Gmail account: Gmail search on `rfc822msgid:<rawId>` for `snapshot.account`. Other providers: snapshot only. |
| `event` | EventKit lookup by UID | `snapshot.url` |
| `issue`, `door`, `url` | Web URL, built from the key | Same |
| `task` (Septena) | The task page | The task page |
| `task` (Starlings) | Web URL | Same |
| `file` | The attachment; an iCloud path opens in Finder or Files | The attachment |

- A URL opens only when its scheme is `http`, `https` or `message`. A client
  never opens another scheme from a key or a snapshot.
- Every value is percent-encoded when it goes into a URL.
- The root of a thread is often not in the local mailbox. A `thread` row opens
  the task's newest `email` reference of the same thread first, then the root.

## 6. Behaviours

### 6.1 Attach on capture

The forwarding address, capture feeds, the iOS Share extension and agents
write a `from` reference when they create a task.

**A forwarded mail is a new message with its own Message-ID.** That id must
never become the key of the original. `email_ref_keys(headers)` decides:

| What arrives | `email` key | `thread` key |
|---|---|---|
| Forward as attachment (`message/rfc822` part) | Message-ID of the attached message | Root of the attached message |
| Redirect, or an automatic forwarding rule (no new message; `From` is not the account owner) | Message-ID of the message | Root of the message |
| Forward inline (a new message by the owner) | Last entry of `References`, else `In-Reply-To`, else none | First entry of `References`, else none |
| Gmail feed (#15), agents with mail access | Message-ID from the headers | Root from the headers |

With no key, the capture creates a task without a reference. Mail clients
differ in the headers they write on an inline forward. This is unknown until
R2 tests real `.eml` fixtures from Apple Mail, Gmail, Outlook and Fastmail.

The Share extension gets a URL and no mail headers, so it writes a `url` key
(or `issue`, `door`, … when the URL parses).

### 6.2 No duplicates

Before a capture path creates a task, the store looks up the keys in the same
single-writer transaction as the insert.

- **An active task has the same `email` key:** no new task. The store stamps
  `lastSeenAt`. The stamp shows in the task history as "captured again".
- **An active task has the same `thread` key, and the mail is new:** no new
  task. The store adds the `email` reference to that task (up to the limit)
  and sets the reply mark (§6.3).
- **Only closed tasks have the key** (done, cancelled, faded or deleted): the
  store stamps `lastSeenAt` on the closed task's reference and creates a new
  task. The new task has a `follow_up` reference to the closed task. A deleted
  task gets no stamp and no `follow_up`.
- Several active tasks have the key: the most recently touched one.

The same check covers agents. `tasks_create` with a `from` reference whose key
is on an active task returns that task and `placement: "existing"`. With
`allow_duplicate: true` it creates the task. Duplicate checks apply to `from`
references only. A user who adds an `about` reference by hand is never blocked.

### 6.3 Thread activity

When a capture path receives a mail and the root of its thread is a `thread`
key on an active task, the store stamps `replyAt` on the task.

- `replyAt` is a new nullable stamp on `task`. Only the store sets it.
- The core's membership function puts an active task with `replyAt` in the
  Inbox band on Today, filed or not. The task keeps its area, project, dates
  and order. Today the band holds unfiled tasks only, so this is a new rule in
  `views.rs` with vectors in `task-views.json`. `tasks_list view="inbox"`
  follows from it.
- The row shows a "New reply" mark (copy in the registry).
- Any of these clears `replyAt`: the user opens the task page, opens the
  reference, edits or moves the task, or completes it. An agent cannot clear
  it.
- A reply from the account owner does not set it.
- Only mail that Septena receives counts: the forwarding address, a feed, or
  an agent that calls `tasks_ref_seen` (§7). Septena never reads a mailbox on
  its own.
- A sender address can be forged. The mark never completes, edits, files or
  schedules a task, so a forged mail can only bring a task to the Inbox. The
  daily cap of the forwarding address also counts mails that match a task.

### 6.4 Back-links

"Which tasks point at this?" is one indexed lookup. The task page of a Septena
task shows the tasks that point at it. The Share extension and agents use the
same lookup to show that an item already has a task.

### 6.5 Completion hints

An agent can read a referenced item and propose completion with
`tasks_set_endstate(needs_verify)`. A reference never completes a task. The
`human_accepts` rule stays.

### 6.6 GitHub issue links become references

Today the apps and MCP read an issue link out of conversation text, with two
parsers (`ConvoIssueLink` in Swift, `issueLink` in TypeScript). ADR 0033 folds
them into references. Septena never contacts GitHub.

- **Backfill, once per account (R0):** every task whose conversation text gives
  an issue link today gets one `about` reference of kind `issue`. Same search
  order as `TaskConvo.linkedIssue`. A task that already has the key is skipped.
  It runs again without effect.
- **New writes (R0):** when an agent writes a GitHub issue or pull request URL
  into an artifact, a handoff, an end-state note or a turn, the store adds the
  `issue` reference, up to the limit. The core parses it. A user's own removal
  wins: the store does not add a key again that a user removed from the task.
- **MCP `issue` (R0):** the field stays on task rows and reads the newest
  `issue` reference, where the newest is the last one added. The TypeScript
  text parser goes. Pull requests give `kind: "pr"` when `snapshot.url` says so.
- **Apps (R1):** the References block and the conversation's "Open" link read
  references. The row chip and `ConvoIssueLink` go. Old app builds keep their
  own parser, and the text stays, so nothing changes for them.
- **No live state.** A private, closed, renamed or deleted issue looks the
  same. The row shows `owner/repo#n` when there is no title.
- Agents that know the title write it into `snapshot.title`.

## 7. MCP and REST

There is one MCP server, `backend/src/shadow/mcp.ts`. The REST surface for
thin clients (`backend/src/api/tasksRest.ts`) gets the same fields.
`backend/skill.md` and the skill briefs change with it.

- `tasks_create`: `refs: [{key, role?, snapshot?}]`, `allow_duplicate?`.
- `tasks_update`: `refs` adds or updates by key. `refs_remove: [key]` removes.
- `tasks_get`: `refs` (key, kind, role, snapshot) and `backlinks` (id, title,
  status).
- `tasks_list`, `tasks_search`: `refCount`, and `replyAt` when set. Not the
  full references, to keep lists small.
- New `tasks_find_by_ref(key)`: the tasks that point at a key, active first.
  Accepts a key, a URL or a `message://` link.
- New `tasks_ref_seen(key, email_key?, date?)`: an agent that reads mail
  reports a new message on a thread (§6.2, §6.3). It changes nothing else.
- `artifact.refs` keeps its shape. A string that parses as a key renders as a
  reference.
- Keys are normalised by the core at the boundary. Zod validates every row.
  An invalid key is an error, not a silent drop.
- ADR 0008 holds: a stopped task and a paused account refuse agent reference
  writes. `agentRefusal` in `TaskStore` must cover `taskRef`.

## 8. App surfaces

- **Task page:** a new block kind `references` in `registry/surfaces.json`
  (`taskPage.references`, depth `page`, `editOnly`), after attachments. One
  row per reference: kind icon, title, subtitle. A tap opens it. The context
  menu has Open, Copy Link, Remove. The block is absent on a task with no
  references, except through "Add Reference" in the task's menu.
- An `email` and a `thread` reference to the same conversation show as one
  row.
- **Task row:** one quiet icon when the task has a `from` reference, and the
  "New reply" mark. No chips in v1.
- **Add:** paste a URL or a `message://` link into "Add Reference". The panel
  first offers the links that are already in the task's title and notes, one
  tap each. Septena never turns a link in the notes into a reference on its
  own, and adding one leaves the notes as they are. On the Mac (R4), drag a
  mail from Apple Mail, or a link from a browser, onto a task row or the page.
- **Row title:** `snapshot.title`. Without one: `owner/repo#n` for an issue,
  host and path for a URL, the kind's label for the rest. The client never
  fetches a title from the network.
- **Wrong input:** text that does not parse shows one line under the field and
  adds nothing. A key that the task has already only highlights its row.
- **Watch and widgets:** nothing in v1.
- Undo: add and remove register on `TaskUndo` at the gesture.
- New capability `task.references` in `registry/capabilities.json`, per
  platform. Labels come from the registry.

## 9. Export and import

- JSON export gets the table `task_ref` (`DATA_EXPORT_SPEC.md` §3.1).
- Markdown export writes one indented line per reference: title, then the URL
  if there is one.
- CSV export gets a `references` column with the keys, separated by a space.
- The import engine (`MOVING_IN_SPEC.md`) accepts `refs` in its bundle.
  Adapters that have a source URL write a `from` reference.

## 10. Privacy

- A snapshot holds a mail subject and a sender. That is user content, as
  notes are: same store, same encryption at rest, same export, same deletion.
- Keys and snapshots go to no third party on their own. They leave the store
  to the user's own devices, to the agents the user connected, and to the
  service the user opens when they tap a reference (a Gmail search, GitHub).
- Logs and telemetry never hold a key or a snapshot.
- The backend privacy text gets one line before R2 ships: forwarded mail keeps
  its message id, subject and sender with the task.

## 11. Phases

| Phase | What | Depends on | Exit check |
|---|---|---|---|
| R0 (#386) | Core key grammar and vectors; registry entity, limits and enum; store, index, opt-in pull, permissions; MCP and REST fields, `tasks_find_by_ref`; issue links become references (§6.6); JSON export. | None | An agent creates a task with an `email` reference, and `tasks_find_by_ref` on the raw `message://` link returns it. |
| R1 (#387) | Apple apps: sync, the References block on Mac, iPhone and iPad, resolvers, paste to add, undo, Markdown and CSV export; the row chip and the Swift parser go (§6.6). | R0 (#386) | A tap on an `email` reference opens the mail in Apple Mail on Mac and iPhone. |
| R2 (#388) | Forwarding address writes references; duplicate check in the store and in `tasks_create`; privacy line. | R0, #134 (EM0) | The same mail forwarded twice as an attachment creates one task. The `.eml` fixtures give the results of §6.1. |
| R3 (#389) | `replyAt`, the Inbox-band rule in the core, the "New reply" mark, `tasks_ref_seen`. The Gmail feed writes references when it ships (#15). | R1, R2 | A reply on a referenced thread marks the active task and shows it in the Inbox band. Opening the task clears it. |
| R4 (#390) | Back-links: the task page list and the iOS Share extension. Drag a mail onto a task on the Mac. Android and web blocks and resolvers. | R1; web waits for #21 | Sharing a URL that already has a task shows that task. |

Every phase: registry generator check, core vectors, backend typecheck and
tests, and one app build where app code changes. mz tests the apps by hand.

## 12. Not in this spec

- Two-way sync with an email (archive, label, reply).
- Reading a mailbox. Septena sees only what it receives.
- Blocking behaviour for `blocked_by`.
- References on projects and areas. The key grammar allows it later.

## 13. Open questions

mz accepted the first six on 2026-11-24. The *(new)* ones came up while this
doc was written. They stand until mz overrules them.

| Question | Default |
|---|---|
| Table or JSON field on the task? | Table. The reverse lookup needs an index. |
| Max references per task? | 20. |
| Does thread activity move a task to the Inbox band, or only mark it? | Mark it and show it in the Inbox band. |
| Does the duplicate check match closed tasks? | No. The closed task gets a log entry, and a new task is created. |
| Snapshot size cap? | 2 KB. |
| Milestone? | M3, next to #134. |
| Does a task in the band for a new reply leave its project? *(new)* | No. It keeps its place and also shows in the band. |
| Does a faded task count as open for the duplicate check? *(new)* | No. It counts as closed. |
| Inline forward with no usable headers? *(new)* | Create the task without a reference. Never use the forward's own id. |
| What does a repeating task copy? *(new)* | `about` references only. |
| Does `tasks_create` by an agent stop on a duplicate? *(new)* | Yes, it returns the existing task. `allow_duplicate: true` overrides. |
| Old issue links? | Decided by mz, 2026-11-24: backfill them and delete the parsers (ADR 0033). |
