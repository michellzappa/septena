# Project notes — spec

**Status:** building. Accepted 2026-11-21 with every default in §10. N0 (#120) and N1 (#121) built 2026-11-21, not deployed.
**Decisions:** [ADR 0012](adr/0012-project-notes-are-agent-context.md),
[ADR 0008](adr/0008-agent-loop-rules-live-in-the-store.md),
[ADR 0005](adr/0005-tasks-as-factory-intake.md).
**Builds on:** the agent loop on `api.septena.app` (`backend/src/shadow/agent.ts`,
`TaskStore.claim`), the task factory (`docs/TASK_FACTORY_SPEC.md`), the
Things importer (`SeptenaCore/ThingsImport/`).
**Owner of decisions:** mz. Defaults chosen by the agent are marked
*(default)*.

## 1. Goal

A user works on projects together with agents. Every project and area has
notes: what it is for, who is involved, what was decided, what holds. Agents
read those notes before they decide anything about a task, and record what
they learn back into them. The notes are there from the first minute,
because setup starts with them.

Three requirements from mz:

1. Notes are the **default**: every project and area has them, visible first.
2. Notes are **readable and writable through MCP**.
3. Notes **keep history**.

## 2. What exists and what is missing

**Exists:**

- `projects.notes` (edited in the apps) and `projects.context` (no app
  writes it), `areas.context` (shown as notes). All up to 100,000
  characters. `backend/src/store/columns.ts`.
- `tasks_list_projects` and `tasks_list_areas` return those fields.
- The change log records every edit, clipped to 4,000 characters per value
  and kept 365 days.
- `/skill.md` on the connector (`backend/skill.md`), served from
  `backend/src/index.ts`.
- A Things import in the app (`SeptenaCore/ThingsImport/`).

**Missing:**

| Gap | Section |
|---|---|
| One notes field per container | §3 |
| Notes delivered with a claim | §5 |
| MCP tools that write notes, and create areas and projects | §5 |
| A guard against an agent overwriting the user's edit | §4 |
| A rule for who may change what | §4 |
| Full, permanent history with restore | §4, §6 |
| Notes first in the app, with a template | §6 |
| A setup flow that starts with notes | §7 |

## 3. Data

- **Project:** `notes` is the one field. `context` is retired.
- **Area:** `context` is the one field. The wire name stays (old clients and
  the importer use it). Every surface calls it "notes".
- **Migration (one time, in the store):** for each project with non-empty
  `context`, append it to `notes` under `## Context (merged 2026-…)`, then
  set `context` to null. The change log records it with reason
  `merge project context into notes`. *(default: merge, not drop)*
- **New table `note_revisions`:** `container` (`project` | `area`), `id`,
  `rev` (per-note counter, starts at 1), `body` (full text), `actor`, `at`,
  `reason`. One row per saved change. No TTL. *(default: no cap on versions)*
- **`noteRev`** column on `projects` and `areas`: the current revision.
  Every write bumps it. Old rows start at 0.

The revision table is written in the same transaction as the row, in
`TaskStore.push`, for every actor (apps, MCP, importer). So app edits get
history too, not only agent edits.

## 4. Rules (enforced in `TaskStore`)

**Brief and log.** The brief is the text above the first line that is
exactly `## Log`. The log is everything after it. No `## Log` line means the
whole note is brief.

| Actor | Brief | Log |
|---|---|---|
| App (the user) | any change | any change |
| Agent, brief empty | may write it | append |
| Agent, brief not empty | refused (`brief_is_users`); may propose (§5) | append only |

"Append" means the new body equals the old body plus text at the end. An
agent append adds `## Log` first when the note has none. The store checks
the rule on the body, not on the tool, so any future tool is held to it.

**Revision guard.** Every agent notes write carries `baseRev`. If
`baseRev ≠ noteRev`, the store refuses with `stale` and returns the current
body and `noteRev`. The agent re-reads and tries again. Appends also carry
`baseRev`, so two agents that append at once do not interleave silently;
the second one retries on top of the first. *(default: guard appends too)*

**Stop and pause.** A notes write by an agent is refused while
`agentsPaused` is set (ADR 0008). Notes have no per-project stop in v1.

**Log entry shape** *(default)*: `### 2026-11-21 · <agent name>` then the
text. One entry per write. The tool builds the heading, so agents cannot
fake a date or a name.

## 5. MCP (api.septena.app connector only)

**Changed:**

- `tasks_claim` — a successful claim also returns
  `project: { id, title, notes, noteRev }` and
  `area: { id, title, notes, noteRev }` for the task's container (null when
  the task has none). A task with an area but no project returns the area
  only. *(default: full notes, no truncation; 100,000 characters is the
  bound)*
- `tasks_get` — gains `include_notes` (default false) for the same payload,
  for reads without a claim.
- `tasks_list_projects` — drops `context` after the migration. Notes stay.

**New:**

| Tool | Does |
|---|---|
| `tasks_project_get` | One project: notes, `noteRev`, area, open tasks (titles, ids, status), the last 10 activity entries. |
| `tasks_notes_log` | Append one log entry to a project's or an area's notes. Takes `container`, `id`, `baseRev`, `text`, `why`. |
| `tasks_notes_write` | Replace the whole body. Allowed for an agent only while the brief is empty (§4). Takes `baseRev`, `body`, `why`. |
| `tasks_notes_propose` | Propose a new brief. Stores it on the container as `notesProposal { body, agent, at, why }`. One open proposal per note; a new one replaces the old. The user accepts or rejects it in the app. |
| `tasks_notes_history` | A note's revisions, newest first: `rev`, `actor`, `at`, `reason`, and the body when `include_body` is true. |
| `tasks_area_create` | Create an area with optional notes. |
| `tasks_project_create` | Create a project in an area with optional notes and `githubRepo`. |

Refusals use the existing shape (`reason`, `rule`), with the new reasons
`stale` and `brief_is_users`.

**Skill text.** `backend/skill.md` gains a "Context first" section: claim,
read the notes in the claim result, decide, and append one log entry per
decision or learning before release. The in-app MCP server was removed on
2026-11-21 (commit `7b101882`), so the connector is the only MCP surface and
ADR 0012's line about the in-app server no longer applies.

**Server instructions.** The connector's `instructions` string adds one
sentence: project and area notes are the context for every decision; read
them before acting on a task.

## 6. App (Septena and Septask, iOS and Mac)

- **Notes first.** The project and area detail views open with the notes
  field above the task list. Empty notes show the template as placeholder
  text, not as content.
- **Template** *(default)*: `Goal`, `Current state`, `People`, `Decisions`,
  `Constraints`, then `## Log`. A new project created in the app gets the
  headings inserted when the user first focuses the field.
- **Log rendering.** Under `## Log`, entries render with the agent name and
  date as a small header. The user can edit or delete any entry.
- **Proposal card.** When `notesProposal` is set, a card above the notes
  shows the agent, the reason and a diff. Accept replaces the brief and
  clears the proposal; Reject clears it. Both are user actions in the
  change log.
- **History.** A "History" menu item on the notes field lists revisions
  (actor, time, reason). Selecting one shows it read-only, with Restore.
  Restore writes a new revision; nothing is deleted.
- **Retire `context`.** Remove `context` from `ProjectEntity`, the backend
  client, and the CloudKit record mapping once the store migration has run.
  Update `docs/CloudKitSchema.md` (historical note only; ADR 0002).

Hotspot files: `Localizable.xcstrings` for the new strings. All copy goes
through the humanizer skill.

## 7. Setup: the "onboard Septena" skill

**Scope.** First-run onboarding is #103 (the in-app sequence, connection,
preview before bulk writes) and agent setup is #70 (`agents.md`, copy setup
prompt). This section does not add a second flow. It specifies the agent's
script for #103 step 3 so that notes come first, and the MCP tools that
script needs (§5).

**Where it lives** *(default)*: `backend/onboard.md`, served at
`https://api.septena.app/onboard.md` and exposed as an MCP prompt
`onboard_septena` on the connector. `skill.md` and #70's `agents.md` link
to it. Users of Claude Code can install it as a skill from that URL.

**Flow** (the skill text tells Claude to do this, in this order):

1. **Ask how the user thinks about their life and work.** Offer common
   categories (work, clients, home, health, learning, side projects) and let
   the user rename, merge or add. Each becomes an area.
2. **Braindump per area.** For each area: what is going on, which projects
   exist, who is involved. Claude asks follow-up questions one at a time and
   keeps it conversational.
3. **Write notes before tasks.** For each project: create it with
   `tasks_project_create` and a brief in the template headings, written
   from the user's own words. Show the user each brief before writing.
   *(default: confirm per area, not per project)*
4. **Then tasks.** Capture next actions the braindump surfaced, filed into
   their projects.
5. **Optional import.**
   - Things: point the user to the in-app import (Settings), which already
     maps areas, projects, notes and tasks. Claude does not read the Things
     database itself.
   - Todoist, TickTick, Apple Reminders, a CSV or a pasted list: Claude
     reads what the user gives it, maps it to areas and projects, shows the
     mapping, and writes on the user's yes.
   - After any import, Claude walks the imported projects that have empty
     briefs and asks for a few lines each.
6. **Close.** One summary: areas and projects created, projects with an
   empty brief, how to ask an agent to work a task.

The skill never invents a brief. If the user says nothing about a project,
its brief stays empty and the summary lists it.

## 8. Phases

| Phase | Scope | Needs |
|---|---|---|
| **N0 Store** (#120) | §3 migration, `note_revisions`, `noteRev`, §4 rules and refusals, tests in `backend/test/` | — |
| **N1 MCP** (#121) | §5 tools, claim payload, `skill.md` and instructions text | N0 |
| **N2 App: notes first** (#122) | §6 notes-first layout, template, log rendering, retire `context` in the apps | N0 |
| **N3 App: proposals and history** (#123) | §6 proposal card, history and restore | N1 (proposals), N0 (history) |
| **N4 Onboard skill** (#124) | §7 `onboard.md`, MCP prompt, link from `skill.md`; the agent script for #103 step 3 | N1, #70 |

N2 and N1 can run in parallel after N0.

## 9. Not in v1

- Per-task notes as agent context (tasks keep `notes`; the conversation
  already carries task-level context).
- Summarizing or archiving a long log.
- A per-project agent stop.
- Shared projects (ADR 0004): notes in a shared project's own store follow
  the same rules when that store exists; not designed here.

## 10. Open questions

| # | Question | Default |
|---|---|---|
| Q1 | How much may agents change notes? | Brief is the user's; agents append to the log, write an empty brief, or propose. |
| Q2 | Merge project `context` into `notes`, or drop it? | Merge under a heading, then clear. |
| Q3 | Cap on revisions per note? | No cap in v1. |
| Q4 | Truncate notes in the claim result? | No. Full text. |
| Q5 | Guard appends with `baseRev` too? | Yes. |
| Q6 | Where does the onboard skill live? | `onboard.md` on the connector plus an MCP prompt. |
| Q7 | Confirm briefs during onboarding per project or per area? | Per area. |
| Q8 | Milestone? | M2 Agent intake v0, track `track:factory`. |
| Q9 | Does the brief/log rule interact with #87 (agents propose done)? | Same principle, separate rule: agents propose, the human accepts. Both refusals live in `TaskStore`. |
