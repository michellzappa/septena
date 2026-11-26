---
name: septena-tasks
description: Use the Septena tasks MCP at api.septena.app to read and write the user's tasks, areas, projects and task conversations. Triggers when the user asks about their tasks, today's plan, their inbox, or any Septena data.
---

# Septena tasks MCP

The connector at `https://api.septena.app/mcp` exposes the user's tasks, areas, projects and task conversations, the same data the Septena app shows. The user pairs it from the Septena app. An agent that cannot sign in (a script, cron, n8n) uses an agent key the user creates in the app: send it as `Authorization: Bearer sk1.…`. Changes reach the app within seconds.

## Conventions

- **Dates** are `YYYY-MM-DD` strings in the user's local time.
- **IDs** are short, opaque strings. Always echo back the `id` from a create call before referencing it in an update.

## Guidance

### Start here
- **`tasks_orientation`** returns the server's guide, every tool by family, and which areas have a brief. Call it once when you are new to the account.

### First-time setup (onboarding)
- When helping a user populate a new or sparse Septena account, follow the onboarding guide at `https://api.septena.app/onboard.md` (also exposed as the MCP prompt `onboard_septena`). Draw from what you already know about their ongoing work, projects, and responsibilities — or interview them briefly if starting fresh — to propose real Areas (with context + emoji), Projects (with context briefs), and at least a few concrete Tasks, and confirm before writing.

### How the app works (help)
- When the user asks how to do something in Septena, what a word means, or why something does not work, read `https://septena.app/help.md`. It lists every help page as Markdown, and `https://septena.app/llms-full.txt` has them all in one file. Answer from those pages with the app's own menu names.
- When the pages do not answer it, say so and point to `https://septena.app/support`. Never guess a menu, a shortcut or a feature.
- You cannot press buttons in the app. Tell the user where to tap, or make the change with a tool when one exists.

### Context first: project and area notes
- Every project and area has **notes**: what it is for, who is involved, what was decided, what holds. They are the context for every task inside. Read them before you decide anything about a task. `tasks_claim` returns the task's project and area notes; `tasks_get(id, include_notes: true)` and `tasks_project_get(id)` return them too.
- Notes have two parts. The **brief** is everything above a line `## Log`; it is the user's. The **log** is under it; agents add to it.
- Record each decision or learning with **`tasks_notes_log`** (one entry per call; the tool writes the date and your name). Do it before `tasks_release`.
- Every notes write names the **`baseNoteRev`** you read. A `stale` refusal carries the current notes and noteRev: read them, then write again. Never retry with a guessed rev.
- You may write a whole brief with `tasks_notes_write` only while it is empty (setting up a project with the user). Once it has text, suggest changes with **`tasks_notes_propose`**; the user accepts or rejects them in the app. A `brief_is_users` refusal means exactly this.
- Never invent a brief. Write the user's own words; leave a brief empty when the user said nothing about the project.
- `tasks_project_create` / `tasks_area_create` make containers, with optional notes. Ask first, and list existing ones first so you do not duplicate.
- **`tasks_project_update(id, …)`** renames a project, moves it to another area (`null` for none), sets `githubRepo`, or sets `status` (`active`, `done`, `cancelled`). Done or cancelled moves it to the Logbook; its open tasks stay open. Change the status only when the user asked. **`tasks_area_update(id, …)`** renames an area or sets its emoji. Only the user deletes a project or an area.
- **Headings** split a project into sections. `tasks_project_get` lists `headings` and the `heading` of each open task. **`tasks_heading_create(project, title)`** adds one at the end of the project. Pass `heading` to `tasks_create` or `tasks_update` to file a task under it (the task moves into the heading's project); `heading: null` takes it out. Rename a heading with `tasks_update` on its id.
- `tasks_notes_history` lists every saved version of a note, with who and why.

### Tasks
- Views: `today`, `inbox`, `review`, `upcoming`, `anytime`, `completed`, `faded`. `review` lists open tasks waiting for the user to check and accept (`endState = needs_verify`). `faded` is the Faded pile: open tasks nobody touched for the fade window. No other view shows them, and an agent edit does not bring one back; the user keeps or drops them in the app. `today` is the whole Today page: the **Inbox** section first, then the filed tasks on Today. `inbox` is that Inbox section alone. `anytime` = open tasks with no date that are not on Today, the app's Anytime list (it absorbed the former `someday` bucket). No view returns "all open tasks"; use `tasks_get` to locate a known id.
- **One Inbox.** The app shows a single Inbox at the top of Today. It holds unfiled tasks (no area, no project) and your proposals the user has not accepted. Never describe these as two piles ("triage" vs "unorganized"). `triage` is a retired view name and returns the Inbox.
- Row flags: `inbox: true` = the row sits in the Inbox. `daysOnToday: N` = the row has carried over on Today undone for N days. Mention rows at 7+ as stuck when you summarize Today.
- `tasks_list` returns `{tasks, total, truncated}` — **`truncated: true` means more rows exist beyond `limit`**, so don't conclude a task is missing/deleted from a capped page; raise `limit` or use `tasks_get`.
- **`tasks_get(id)`** — one call for "where is this task, what's its state?": title, status, area, project, scheduled, deadline, today, completedAt, source, notes, plus a compact convo summary. Works regardless of view or status; use this instead of scanning lists to locate a known id.
- **`notes`** — the task's free-text body. Readable on `tasks_get`/`tasks_list` and writable on `tasks_create`/`tasks_update` (pass `notes`; on update, `null`/`""` clears it). This is the plain note field, distinct from the structured `TaskConvo` (artifact/handoff/thread) below.
- **`recurrence`** — the repeat rule, readable on `tasks_get`/`tasks_list` and writable on `tasks_create`/`tasks_update` as `{unit: "day"|"week"|"month", interval: N, after_completion: bool}` (on update, `null` clears it). `after_completion: true` (the default) counts the interval from the day the task is ticked off — use it for "every 3 days" phrasing with no anchor day. `after_completion: false` counts from the previous scheduled date, which is what keeps a named weekday on its weekday ("every Monday"); it REQUIRES the task to have a `scheduled` date and errors without one. Getting this backwards silently converts a fixed weekly task into one that drifts every time the user is late.
- `tasks_complete` on a **recurring** task also creates its next occurrence and returns it as `nextOccurrence` — say when the task comes back, don't send the user to the app. If the result carries a `recurrenceWarning`, the task was still completed but the series didn't advance; relay that rather than claiming the next one is scheduled.
- Resolve `area`/`project` names → ids via `tasks_list_areas` / `tasks_list_projects` before creating/updating.
- **`tasks_search(query)`** finds tasks by words in the title or notes, with near matches. Call it before `tasks_create`.
- **`tasks_defer(id, until)`** moves a task's When to a future day and takes it off Today. **`tasks_move_to_today(id)`** pins it to Today.
- **`tasks_set_waiting(id, waiting_on, scheduled?)`** marks a task as waiting on a person: the user handed it to someone. Use it when the user says they asked someone ("I asked Anna for the deck"), or when you make a task from a message the user sent, with the thread as a reference. Set `scheduled` to the day to chase (a week out unless the user says). `tasks_list view=waiting` lists the waits, oldest first, with `waitingOn` and `waitingSince`. Only the user ends a wait: clearing it, completing, cancelling or deleting a waiting task is refused as `in_review`. When the thread a waiting task points at has a reply, ask with `tasks_thread_append`: a provider turn "Anna replied. Got it back?" with the options "Got It Back" and "Still Waiting". Never send a chase yourself.
- **Tags:** pass tag names in `tags` on `tasks_create` / `tasks_update`; a new name makes a new tag. Call **`tasks_list_tags`** first and reuse the user's names. Only the user renames or recolors a tag.
- **Checklists:** `checklist` on `tasks_create`, then **`tasks_checklist_add(task_id, items)`**, **`tasks_checklist_update(id, …)`** (rename, check, reorder) and **`tasks_checklist_delete(id)`**. `tasks_get` lists the items. Checking every item does not complete the task.
- **`tasks_history(id)`** shows one task's changes with the values before and after.

#### References: what a task points at

A task can point at up to 20 items: an email, a mail thread, a calendar event, a GitHub issue or pull request, a web page, another task. Septena stores a **key** and a small **snapshot** (title, subtitle, date, url) and never syncs with the item.

- Pass `refs: [{key, role?, snapshot?}]` to `tasks_create` and `tasks_update`. `key` is a reference key (`email:<Message-ID>`, `thread:<root Message-ID>`, `event:<iCal UID>`, `issue:<owner>/<repo>#<n>`, `task:<task id>`, `url:<web URL>`), a web URL, or a `message://` link. Septena stores the normal form, so every spelling of one item is one key. An invalid key is an error.
- `role`: `about` (default), `from` (the task was made from it), `blocked_by`, `follow_up`. The last two are labels.
- **One item, one task.** When an active task has the same `from` key, `tasks_create` creates nothing and returns that task with `placement: "existing"` and `matched_keys`. Tell the user it exists; do not create it again. Pass `allow_duplicate: true` only when the user wants a second task. When only a closed task (done, cancelled or faded) has the key, the new task gets a `follow_up` reference to it, returned as `follow_up`. Other roles never block.
- **Turned down stays turned down.** When the user deletes or drops your proposal before accepting it, a new suggestion with the same `from` key creates nothing and returns `placement: "dismissed"`. Do not propose it again, and do not reword it. `tasks_find_by_ref` says `dismissed: true` for such a key. A `user_request` is never blocked, and `allow_duplicate: true` overrides when the user asks.
- Set `snapshot.title` when you know it. Septena never fetches a title. Never put message text in a snapshot.
- `tasks_update`: `refs` adds, or updates by key; `refs_remove: [key]` removes. The other references stay.
- **`tasks_find_by_ref(key)`** answers "which tasks point at this?", open tasks first. Call it before you create a task from an email, an issue or a page.
- `tasks_get` returns `refs` and `backlinks` (the tasks that point at this one). List rows carry `refCount`, and `issue` from the newest GitHub issue or PR reference.
- A GitHub issue or PR URL that you write into an artifact, a handoff, an end-state note or a turn becomes a reference on its own. A reference that the user removed does not come back this way.
- A reference never completes a task.

#### Files on a task

- `tasks_get` lists `attachments` (filename, contentType, byteCount). You cannot read a file's bytes. `uploaded: false` means the bytes are only on the device that added the file.
- **`tasks_attachment_add(task_id, filename, content_type)`** adds a file of up to 10 MB. Pass `text` for text you wrote, or `base64` for a tiny binary. For a file on disk, pass neither and run the returned `command` (one-time token, 15 minutes). The file is attached when that upload answers `attached: true`.
- For a web page or an email, add a reference instead. Only the user can remove a file.

#### Working a task as an agent

- **`tasks_claim(id, agent)`** before you write to a task you work on. The claim is a lease (default 30 minutes): call it again to renew while you work. A refusal names its rule (`paused`, `stopped`, `your_turn`, `held`, `doing`, `budget`): respect it. Only `held` is `retryable` (claim again after `claimUntil`, or pick another task). The claim returns the project and area notes.
- **`tasks_release(id, agent, why)`** when you stop, with one line on what you did. A provider turn with options also ends the claim.
- **`tasks_agent_events(since)`** lists what changed for agents since your cursor (assignments, user answers, stops, pauses). Pass the returned `nextSince` next time. Events are pointers: read the task itself.
- **`tasks_activity(id?)`** shows who changed what and why, for one task or all of them. Read it before you continue work an earlier run started.

#### Task Conversations (agent-driven resolution)

A task can hold a persisted **conversation** that drives it toward a solution. You are the
async reasoning provider: pull the queue, ground the task, and hand the user the smallest
possible choice. The loop is `confirm → ground → (scope if epic) → decide → work → end`.

- **`tasks_pending_reasoning`** — your work queue: tasks marked for you or stuck on a
  low-confidence step. Start here.
- **`tasks_thread_get(id)`** — read the full `TaskConvo` (confirmedIntent, acceptance,
  thread, artifact, handoff, endState, assignee) before acting.
- **`tasks_thread_append(id, turn)`** — append one turn. **Propose and choose are separate
  turns**: a `provider` turn carries `question` + `options` (offer 2–4 + let the user pick);
  a later `user` turn carries `chosen` + `inReplyTo`. **Never invent the user's choice** —
  append the provider turn and stop. A `confirm`-step turn with a `chosen` also sets
  `confirmedIntent` (put the resolved intent sentence in `note`).
- **Confirm first, always.** Don't ground or work until the user has confirmed what the task
  means — append a `confirm` provider turn with readings as options. Don't assume meaning.
- **Don't assume size.** If grounding reveals an epic (e.g. "build a section"), use a `scope`
  step (decompose / MVP / defer) — don't march to `work`.
- **`tasks_set_artifact(id, {title, body, kind?, refs?})`** — attach what you PRODUCED
  (a comparison, a draft, a summary). Renders as a block in the task.
- **`tasks_set_handoff(id, {instruction, actionType, payload?})`** — the human's last-mile
  action, rendered as a tappable button (`open_url`/`compose`/`call`/`none`). Use for
  `agent_assisted`: you did the work, the user does the final step.
- **`tasks_set_acceptance(id, line)`** — the **agent-done** bar (your deliverable). Distinct
  from task completion, which is the **human-done** bar.
- **`tasks_set_endstate(id, "needs_verify", note)`** — your one way to finish. It puts the task
  in the user's **Review**. The note is required: say what to check. Only the user takes a task
  out of Review (Accept or Send back); you may hand over again with a new note. Use
  `decomposed` only when the work goes on as an issue or smaller tasks. Every other end state is
  refused (`human_ends`), and so is done, cancel or delete on agent work (`human_accepts`), also
  after you release the claim. To suggest a cancel, hand over with the reason in the note.
- **`tasks_set_assignee(id, "claude"|"local"|"me"|null)`** — routing. `claude` marks a task
  for your queue; `null` lets the router decide.
- This mirrors the in-app on-device provider exactly (same shape, same verbs). Keep behavior
  identical so the two surfaces never disagree.

#### Provenance & view routing (critical)
**Declare provenance with `origin`** — it decides whether a task lands committed
or as a *proposal*:

- **`origin: "user_request"`** — the user explicitly asked you to create this
  task. It's **committed**: it flows straight into its natural view per the
  fields you set (table below), with no triage step.
- **`origin: "agent_suggestion"` (or omitted)** — you surfaced it yourself,
  proactively (from email, a transcript, your own initiative). It lands as a
  **proposal** in the user's **Inbox** — the section on top of Today
  — awaiting their tap. The gateway defaults to this (secure by default), so if
  you don't set `origin`, you are proposing.

`tasks_create` returns `placement`: `"committed"`, `"inbox_proposal"`, `"existing"`
or `"dismissed"` (the last two created nothing: see References above).

For a **proposal**, the `today` / `scheduled` / `deadline` / `project` you set are
the *proposed disposition* the user accepts with one tap — they do **not** move
the task into `today` / `upcoming` / `anytime` until it's ratified (or until it
ages in after ~7 days unacknowledged). A **committed** task routes immediately:

| Fields you set       | View (committed now / proposal after ratify) |
|----------------------|----------------------------------------------|
| `today: true`        | `today`, `anytime`                           |
| `scheduled: <date>`  | `upcoming`, `anytime`                        |
| `deadline: <date>`   | `anytime` (no route)                         |
| None of the above    | loose capture (stays to-sort)                |

`area` and `project` tag a task for filtering but don't route it on their own.

**Footgun**: a *proposal* is NOT in `today` even when you set `today: true` — it's
in the Inbox, awaiting the user's tap. For proposals, never claim "added to
today"; say you've **proposed** it ("Proposed for today — accept it in your
Inbox"). A **committed** (`user_request`) task you may report as added.

**Verification habit**: check `placement` in the create result, or
`tasks_list(view: "inbox")` for proposals.

```
# "Add X to today" — proposes X for today; user taps to accept
tasks_create(title: "X", today: true)
  → "Proposed for today — accept it in your Inbox."

# "Schedule X for tomorrow"
tasks_create(title: "X", scheduled: "<tomorrow>")

**"remind me to write the newsletter every Monday"**
```
tasks_create(title: "Write newsletter",
             scheduled: "<the next Monday, YYYY-MM-DD>",
             recurrence: {unit: "week", interval: 1, after_completion: false})
```
  → "Proposed for tomorrow — accept it in your Inbox."

# "What haven't I sorted yet?" / "What's in my inbox?"
tasks_list(view: "inbox")

# "Show me unscheduled tasks"
tasks_list(view: "anytime")
```

## Errors to expect

A refused tool call returns `isError: true`. The first text is the message; the second text (and `structuredContent`) is the envelope:

```
{ "error": { "code": "paused", "message": "…", "hint": "…", "retryable": false } }
```

- **`code`** names the rule (`paused`, `stopped`, `your_turn`, `held`, `budget`, `terminal`, `closed`, `not_found`, `human_accepts`, `in_review`, `human_ends`, `note_required`, `human_only:assignee`, `stale`, `brief_is_users`, `rate_limited`, `idempotency_conflict`, …). Codes do not change name.
- **`hint`** says what to do next. Follow it.
- **`retryable: true`** means the same call can work later with nothing from the user (`held`, `rate_limited`, `unavailable`, `plan_check_failed`, `idempotency_in_progress`). Wait, then send the same call with the same `idempotency_key`. `retryable: false`: do not send it again as it is.
- A result that reports a refusal in its own fields (`tasks_claim` with `claimed: false`, `tasks_complete` with `completed: false`, a notes write with `written: false`) keeps those fields and also carries `error`.
- On `/v1`, send `X-Septena-Errors: envelope` to get the same `error` object; without the header `/v1` keeps its old `{ "error": "<code>" }` body.

### Idempotency keys

- Every write tool takes an optional **`idempotency_key`**: a string you make for one write (a UUID). Send the same key when you retry that call after a lost reply or a host error. Septena returns the first result and does not write again. So a retried create never makes a second task, and you do not need to search before you retry.
- A key lives 24 hours. The same key with a different body is refused as `idempotency_conflict`: use a new key for a new write.
- A refused call keeps nothing under its key, so the same call may run again once the rule allows it.
- On `/v1/tasks` writes, send the key as the `Idempotency-Key` header (or an `idempotency_key` body field). A replay answers with `Idempotent-Replayed: true`.

- 401 → the pairing expired or was revoked; the user re-pairs from Septena.
- A write tool that says the connection can only read → the pairing predates write access; the user removes and re-adds the connector.
- `stale` on a notes write → the notes changed since you read them; the reply's `current` has the new text and noteRev.
- `brief_is_users` → you tried to change the user's brief; log under `## Log` or propose instead.
- `recurrenceWarning` on a complete → the task IS done, but its next occurrence wasn't created. Say both parts.

## Don'ts

- Don't poll. Make one call per question.
- Don't fabricate ids. Always list first, then act.
