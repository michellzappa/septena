# 0012. Project notes are the context agents read first

- Status: accepted (2026-11-21), with the agent defaults
- Date: 2026-11-21
- Deciders: mz (agent proposed)

## Context

ADR 0005 makes tasks the intake for agents, and ADR 0008 gives agents a
claim loop. An agent that claims a task gets the task and its conversation.
It does not get what the project is for, who is involved, what was already
decided, or what constraints hold. A task title alone is rarely enough to
decide well.

Facts in the code today (2026-11-21):

- The `projects` table has two text fields, `notes` and `context`
  (`backend/src/store/columns.ts`). The apps edit only `notes`
  (`AreasProjectsView.swift`). No app surface writes `context`; it arrives
  only through sync and the CloudKit-era record.
- The `areas` table has one text field, `context`. The apps show and edit it
  as "notes".
- The MCP connector reads these fields in `tasks_list_projects` and
  `tasks_list_areas`. No MCP tool writes them, and no tool creates an area or
  a project.
- The change log records project and area edits, but it clips each value to
  4,000 characters (`LOG_TEXT_MAX`) and deletes rows after 365 days
  (`CHANGE_LOG_TTL_MS`). Notes can be 100,000 characters. The log is not a
  history of a note.

## Decision

- **Project notes and area notes are the primary context for agents.** The
  store delivers them; an agent does not have to remember to ask.
  `tasks_claim` returns the task's project notes and area notes in its
  result, with their revision numbers.
- **One notes field per container.** A project has `notes`. An area has
  `context`, shown as "notes" (the wire name stays, so old clients keep
  working). The project `context` field is retired: a one-time migration
  appends any non-empty `context` to `notes` under a heading, then clears
  it. *(default)*
- **Notes have a user-owned brief and an agent log.** *(default)* The brief
  is everything above a `## Log` heading. The log is the section under it.
  An agent appends dated entries to the log. An agent changes the brief only
  through a proposal the user accepts in the app. The store enforces this,
  in the same way as the stop in ADR 0008: an agent write that changes text
  above `## Log` is refused. One exception: an agent may write the brief
  while it is empty, so setup can fill new projects in one pass.
- **Notes writes are guarded by revision.** A write names the revision it
  read. If the notes changed since, the store refuses the write and returns
  the current text, so an agent never overwrites an edit the user made while
  it worked.
- **Notes keep full history.** A `note_revisions` table keeps every saved
  version in full, with actor, time and reason, and never expires. The apps
  can show a version and restore it. The general change log stays as it is.
- **Notes are part of setup.** The connector ships an "onboard Septena"
  skill: it interviews the user by area and project, writes notes first, and
  only then offers to import tasks from Things, Todoist or another app.
- **These tools live on the api.septena.app connector only**, for the same
  reason as ADR 0008: the guards need the Durable Object's single writer.
  The CloudKit gateway and the in-app server keep read-only access.

## Consequences

- An agent that claims a task always has the project's purpose and
  decisions in hand. Context quality now depends on the notes, so setup and
  the template matter.
- The user can trust the brief: only they change it. Agent learnings
  accumulate in the log, where the user can read, keep or delete them.
- A brief/log split is a text convention enforced by the store. A user who
  deletes the `## Log` heading turns the whole note into brief; agent
  appends then add a new `## Log` at the end.
- Long-running projects grow a long log. A later decision may need a
  summarize-and-archive step.
- Retiring project `context` touches the apps, the store, the importer and
  `docs/CloudKitSchema.md`. Old app builds that still write `context` lose
  that write after the migration (no surface writes it today).
- Full revisions cost storage. 100,000 characters per version is the upper
  bound; a cap on versions per note may follow.

## Links

- `docs/PROJECT_NOTES_SPEC.md`
- ADR 0005, ADR 0008
- `backend/src/store/columns.ts`, `backend/src/store/TaskStore.ts`,
  `backend/src/shadow/agent.ts`, `backend/src/shadow/mcp.ts`
- `Septena/Shell/Sidebar/AreasProjectsView.swift`
