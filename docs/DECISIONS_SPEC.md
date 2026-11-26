# Decisions and open questions: spec

**Status:** proposal (2026-11-26, #620).
**Decisions:** [ADR 0047](adr/0047-decisions-and-questions-are-typed-log-entries.md),
[ADR 0012](adr/0012-project-notes-are-agent-context.md),
[ADR 0008](adr/0008-agent-loop-rules-live-in-the-store.md),
[ADR 0044](adr/0044-review-is-one-place.md),
[ADR 0046](adr/0046-agent-work-is-a-review-group.md),
[ADR 0025](adr/0025-shared-rust-core.md).
**Builds on:** `docs/PROJECT_NOTES_SPEC.md` (brief, log, revisions),
`docs/REVIEW_SPEC.md` (groups, badge), `docs/TASK_PAGE_SPEC.md` (blocks),
`backend/src/shadow/notes.ts` (`tasks_notes_log`).
**Related:** #523, #24, #19.
**Owner of decisions:** mz. Defaults chosen by the agent are marked
*(default)*.

## 1. Goal

The user and agents can see what is settled, what is only suggested, and
what is still open, per task and per project. A new agent session starts
from that list. Everything lives in the notes log that exists. There is no
second store.

## 2. Terms

| Term | Meaning |
|---|---|
| **Entry** | One `### <day> · <author>` block under `## Log`. |
| **Decision** | An entry with a `decision` marker. States: `suggested`, `decided`, `declined`. |
| **Suggestion** | A decision in state `suggested`. |
| **Project question** | An entry with a `question` marker, in project or area notes. States: `open`, `closed`. |
| **Task question** | A provider turn with options (ADR 0008). Unchanged. |
| **Open item** | A project question that is `open`, a suggestion, or a task question that waits for the user. |

## 3. Data shape

### 3.1 The entry

```
### 2026-11-26 · claude
<!-- septena:decision id=k3m9qa state=suggested task=jb5e6r answers=p2x7ab -->

Keep decisions in the notes log, not in a new table.

Why: one source of truth, and agents already read the log.
```

- **Heading.** Unchanged from ADR 0012: day and author. The tool writes it.
  The author `user` is reserved for the user. The store refuses it as an
  agent name (`reserved_name`).
- **Marker.** One HTML comment on the line directly under the heading.
  Form: `<!-- septena:<kind> key=value ... -->`. Kinds: `decision`,
  `question`. Values have no spaces.
- **Statement.** The first paragraph after the marker.
- **Reason.** An optional paragraph that starts with `Why: `. Decisions
  only.

### 3.2 Marker keys

| Key | Kinds | Required | Value |
|---|---|---|---|
| `id` | both | yes | 6 characters `[a-z0-9]`, unique in this note. The tool makes it. |
| `state` | both | yes | Decision: `suggested`, `decided`, `declined`. Question: `open`, `closed`. |
| `task` | decision | no | A task id. The task is in this project or area. |
| `answers` | decision | no | The `id` of a question in the same note. |
| `turn` | decision | no | `<seq>` of a user turn on `task`. Only with `task`. |
| `by` | both | when settled | `user`. Who moved the state. |
| `on` | both | when settled | `YYYY-MM-DD`. When the state moved. |

Rules:

- A marker that does not parse, or has no `id` or `state`, makes the entry a
  plain note. *(default: fail soft)*
- Unknown keys are ignored. Writers keep them on a rewrite.
- The tokens are English data. Apps show localized labels from the registry.
- A question has no `task` key. A question about one task is a task question
  (ADR 0047 §4). *(default)*

The grammar goes into `docs/IDENTIFIERS.md` as a wire contract, next to the
`## Log` split rule.

### 3.3 Parsing in the core

New module `core/crates/septena-core/src/notes_log.rs` (ADR 0025):

- `parse_log(notes) -> [Entry]`: day, author, kind, id, state, statement,
  reason, task, answers, turn, by, on, and the byte range of the entry.
- `open_items(notes) -> [Entry]`: open questions and suggestions, newest
  first.
- `set_entry_state(notes, id, state, on) -> notes`: rewrites one marker. The
  apps use it for Confirm, Decline and Close.
- `append_entry(notes, entry) -> notes`: replaces `appendLogEntry` in
  `notes.ts`, so the backend and the apps write the same text.
- `agent_append_check(before, after, verified_turns) -> Ok | reason`: the
  store rule of §4.

Conformance fixtures in `registry/conformance/` cover each kind, each state,
a broken marker, unknown keys and a legacy entry.

## 4. Rules the store enforces

The rules run in `TaskStore.agentNotesRefusal`, after the ADR 0012 checks
(`stale`, `brief_is_users`, append only). They look only at the text that the
agent appends.

| Rule | Refused as |
|---|---|
| A new decision is `suggested`. A new question is `open`. | `human_decides` |
| Exception: `state=decided by=user` with `task` and `turn`, when that turn has `role=user` and an `app:` actor wrote it (change log). | `human_decides` |
| `task` names a task in this project or area. | `task_not_here` |
| `answers` names an open question in this note. | `unknown_entry` |
| `id` is new in this note. | `duplicate_entry` |
| The agent name is not `user`. | `reserved_name` |

Each reason gets a line in `AGENT_WRITE_RULES`. An agent cannot change an
earlier marker, because ADR 0012 lets it append only.

**App writes.** The user may change any marker. App writes use the notes
upsert with `base`, so an agent append that lands at the same time merges
(`mergeText.ts`). Area notes do not carry `base` today (`ops.ts`
`hasNotes`). This spec adds it.

**Event.** When an app actor settles an entry, the store emits an agent event
`note_entry` with `container`, `containerId` and `entryId` (and `taskId` when
the entry has `task`). An agent learns that its suggestion was decided or
declined, or that a question was closed. *(default)*

## 5. Lifecycle

### 5.1 Suggestion to decision

1. An agent calls `tasks_notes_log` with `kind: "decision"`. The entry is a
   suggestion.
2. The user taps **Confirm** or **Decline** (in the notes, the task page or
   Review). The app sets `state`, `by=user` and `on`.
3. When the suggestion has `answers`, Confirm also closes that question
   (`state=closed by=user on=...`). Both changes are one notes write.

The user can also write a decision themselves (**Add decision** in the
notes). It is born `decided by=user`, with the author `user`.

### 5.2 Decision from a task question

The user answers a task question in the app (a user turn). The agent's next
run records the answer with `kind: "decision"` and `from_turn: <seq>`. The
store checks the turn (§4) and writes `state=decided by=user turn=<seq>`. The
app shows "Decided by you, recorded by claude". *(default)*

A decision that the user gave in a chat with the agent, and not in the app,
stays a suggestion. The store cannot check it. One tap confirms it. This is
the same rule as the run budget (ADR 0008). *(default)*

### 5.3 Project question

- **Open.** An agent calls `tasks_notes_log` with `kind: "question"`. The
  user can also add one in the notes (**Add question**). A project question
  does not end a claim and does not block a task.
- **Answer.** The user taps **Answer** and writes a line. The app appends a
  user decision with `answers=<id>` and closes the question, in one write.
  Or an agent appends a suggestion with `answers=<id>`, and the user
  confirms it (§5.1).
- **Close.** The user taps **Close** without an answer. The question becomes
  `closed by=user`, with no linked decision.

An agent cannot withdraw its own question or suggestion. It appends a
suggestion that answers or replaces it, and the user settles both.
*(default)*

### 5.4 Task question

No change. The provider turn with options opens it, a user turn answers it,
and a stop or a close ends it (`REVIEW_SPEC.md` §1).

## 6. MCP (api.septena.app connector only)

**`tasks_notes_log`** gains optional arguments:

| Argument | Meaning |
|---|---|
| `kind` | `note` (default), `decision`, `question`. |
| `reason` | One line. Decisions only. Written as the `Why:` paragraph. |
| `task` | Task id. Decisions only. |
| `answers` | Question entry id. Decisions only. |
| `from_turn` | Seq of the user turn on `task` that holds the user's choice. |

The result gains `entryId` and `state`. Refusals use the shape that exists
(`reason`, `rule`). A decision about a task that has no project and no area
is refused as `no_container`. The agent writes it in the task conversation
instead. *(default)*

**New: `tasks_open_items`** (read only). Arguments: `container` and `id`, or
`task`, or nothing for the whole account. Returns:

- `questions`: open project questions (`container`, `containerId`,
  `entryId`, `text`, `author`, `day`), then task questions that wait for the
  user (`taskId`, `title`, `question`, `options`), from `readOpenQuestions`.
- `suggestions`: suggested decisions, with `task` when set.
- `total` per list. Limit 50 per list.

**Changed:**

- `tasks_claim`: the result gains `open` for the task: the open questions
  and suggestions of its project and area, and every decision (any state)
  with `task` equal to this task. The agent knows what is settled for this
  task before it acts.
- `tasks_project_get`: gains `open` for the project and its area.
- `tasks_agent_events`: the new event kind `note_entry` (§4).
- `tasks_orientation`: says to call `tasks_open_items` first in a new
  session.

**Brief changes.** `backend/skill.md` ("Context first") and
`Septena/Shell/Tasks/TasksSkill.swift` change in the same commit, with the
server `instructions` string in `backend/src/shadow/mcp.ts`:

- Start a session with `tasks_open_items`.
- Record a choice you made as `kind: "decision"` with a `reason`. It is a
  suggestion until the user confirms it. Do not write "the user decided" in
  a note.
- Ask about one task with a provider turn with options. Ask about a whole
  project or area with `kind: "question"`.
- After the user answers a task question, record the answer with
  `from_turn`.
- To answer a project question, log a decision with `answers`.

The dual-era protocol (`backend/src/protocol.ts`) is not affected.

## 7. Apps

Same behavior on iPhone, iPad, Mac (both shells) and Android. Copy lives in
`registry/surfaces.json`, actions in `registry/actions.json`, the Review
group in `registry/destinations.json`. All copy goes through the humanizer
skill. Writes go through `ProjectsMutator` and `AreasMutator` (Android: the
matching repository), and use the core functions of §3.3. Undo is recorded
at the gesture (`TaskUndo`).

### 7.1 Notes log

- A typed entry renders with a label (Suggestion, Decision, Declined,
  Question, Closed), the author and day, the statement, the reason under a
  "Why" label, and a task chip when `task` is set. The marker line is not
  shown.
- A settled entry shows "Decided by you" and the day. A suggestion shows
  **Confirm** and **Decline**. An open question shows **Answer** and
  **Close**.
- Declined decisions and closed questions fold to one line. *(default: keep
  them, do not delete)*
- The entry menu has **Mark as decision** and **Mark as question** on a plain
  entry, and **Undo decision** on a settled one (back to its prior state).
- **Add decision** and **Add question** sit with the log on the project and
  area pages.
- Above the notes, one line counts the open items ("2 open questions, 1
  suggestion"). A tap scrolls to the first one.

### 7.2 Task page

New block kind `decisions` in the `taskPage` block list
(`TASK_PAGE_SPEC.md` §1), page depth only, after `conversation`. It shows:

- the decisions and suggestions with `task` equal to this task, with
  Confirm and Decline;
- one line with the open project questions of the task's project and area,
  which opens the project notes at the first one.

The task's own question stays in the conversation block. The block hides
when it has nothing. The closed set of kinds and the generator check change
with it.

### 7.3 Review

| Group | Change |
|---|---|
| **Questions** | Also holds open project questions. The row shows the question, the project or area, and the author. A tap opens the Answer sheet (answer field, Close, Open notes). |
| **Suggestions** | New group, after Finished work. One row per suggestion: statement, reason, project, linked task. Confirm and Decline on the row and in its menu. |

- Group order: Questions, Finished work, Suggestions, Working, Queued,
  Stopped, Faded, Projects.
- The badge counts Questions (both kinds) and Finished work. Suggestions do
  not count. *(default)*
- Review rows read open items from one store query per refresh, not from a
  parse per row (`docs/LAUNCH_PERF.md`). The clients cache `open_items` per
  note by `noteRev`.
- The watch and the orb show nothing new in v1. *(default)*

## 8. Migration of existing `## Log` text

- No automatic rewrite. Text such as "mz decided" is not parsed. A guess
  that marks a suggestion as decided would be worse than no mark.
  *(default)*
- Legacy entries stay plain notes and render as today.
- The user converts an entry with **Mark as decision** (born `decided
  by=user`) or **Mark as question** (born `open`). The app writes the marker
  under the existing heading and keeps the text.
- The existing `### <day> · <agent>` headings already match §3.1, so no
  heading changes.

## 9. Phases

| Phase | Scope | Needs |
|---|---|---|
| **D0 Contract and core** | §3 grammar in `docs/IDENTIFIERS.md`, `notes_log.rs`, conformance fixtures, core release and pin | ADR 0047 accepted |
| **D1 Store** | §4 rules and refusals, `base` on area notes, `note_entry` event, tests in `backend/test/` | D0 |
| **D2 MCP** | §6 arguments, `tasks_open_items`, claim and project payloads, orientation, the three briefs | D1 |
| **D3 Apps: notes log** | §7.1 and §8 on iPhone, iPad, Mac and Android, registry copy | D0 (D1 for safe merges) |
| **D4 Apps: task page and Review** | §7.2 and §7.3 on every platform, the `decisions` block kind, the Suggestions group | D3 |

D2 and D3 can run in parallel after D1.

## 10. Not in v1

- Decisions in task notes. Task notes stay free text.
- A decision that supersedes an earlier one by id. The user declines the old
  one or logs a new one.
- Decisions and questions in shared projects (ADR 0004), beyond what the
  notes rules give.
- Summarizing or archiving a long log (PROJECT_NOTES_SPEC.md §9).

## 11. Open questions

| # | Question | Default |
|---|---|---|
| Q1 | Marker form: a hidden HTML comment, or visible words in the heading? | Hidden comment under the heading. The heading stays `day · author`. |
| Q2 | A decision the user gave in a chat with the agent: decision or suggestion? | Suggestion. One tap confirms it. |
| Q3 | May an agent record a user's answer to a task question as decided? | Yes, with `from_turn`. The store checks that the user wrote that turn in the app. |
| Q4 | Do suggestions count in the Review badge? | No. Project questions count, as task questions do. |
| Q5 | A decision about a task with no project and no area? | Refused as `no_container`. The agent uses the task conversation. |
| Q6 | May a project question link to one task? | No. A task question is a provider turn with options. |
| Q7 | Parse old "mz decided" text into decisions? | No. The user uses Mark as decision. |
| Q8 | May an agent withdraw its own question or suggestion? | No. It appends a replacement; the user settles both. |
| Q9 | Keep declined decisions and closed questions in the log? | Keep them, folded to one line. |
| Q10 | Event when the user settles an entry? | Yes, `note_entry`. |
| Q11 | Watch and orb? | Nothing new in v1. |
| Q12 | Milestone and track? | M5 Breadth, `track:factory`, as #620. |
