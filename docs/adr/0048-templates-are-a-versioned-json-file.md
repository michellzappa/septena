# 0048. A template is a versioned JSON file of structure and briefs, never of private data

- Status: proposed (2026-11-26)
- Date: 2026-11-26
- Deciders: mz (scope, 2026-11-24: "areas and projects with their briefs,
  plus agent recipes", and a public gallery on septena.app); the format
  details below are the author's *(default)*, mz can overrule
- Builds on: [ADR 0021](0021-one-import-engine-with-source-adapters.md) (one
  import engine, the `septena.import` bundle),
  [ADR 0012](0012-project-notes-are-agent-context.md) (notes are agent
  context), [ADR 0015](0015-shared-registries-for-cross-platform-clients.md)
  (shared contracts in `registry/`)

## Context

People will make templates in the app, share them as files, and copy them
from a public gallery on septena.app (#621). Several readers parse one
template: the iPhone, iPad and Mac apps, the Android app, the backend (on
submit), the site (on build), and other people's tools. A format that one
reader changes breaks the others. A template also leaves the user's account
and becomes public, so the format itself must make it hard to leak private
data.

The `septena.import` bundle (ADR 0021) already describes areas, projects and
headings in plain JSON, and the import engine already gives a preview, an
apply through the mutators, a ledger and undo. A bundle has no place for a
template's own metadata (title, description, author name) or for agent
recipes, and it carries tasks, dates and source originals that a template
must not carry.

## Decision

1. **A template is one plain JSON file**: `format: "septena.template"`,
   `version: 1`. A reader refuses a version it does not know. A reader
   ignores a field it does not know, so a field added inside version 1 does
   not break old readers. A change that old readers would misread is a new
   version.
2. **The content reuses the bundle's entity shapes.** `areas`, `projects` and
   `headings` use the field names of the `septena.import` v1 bundle, with a
   smaller field set. A template adds two things: a metadata block and
   `recipes`.
3. **An agent recipe is plain text.** It has a title, a "when" line and a
   Markdown body. It is never code, a script, a tool call or a URL that a
   reader fetches.
4. **Stable ids.** A template has an `id` (base32 shortid, 8 characters,
   `docs/IDENTIFIERS.md` alphabet) that never changes across its revisions,
   and a `revision` integer. Every item has a `key` (shortid, 4 characters),
   unique in the file. Items reference each other by `key`. Keys are not the
   user's store ids.
5. **One copy path.** The app converts a template into a `septena.import`
   bundle with a template adapter. The import engine plans, applies, records
   the ledger and undoes it. Recipes enter the bundle as a section of the
   container's notes. There is no second writer.
6. **Never in a template**: tasks (titles, notes, dates, status), the
   `## Log` part of notes, note history and proposals, references,
   attachments, checklists, tags, reminders, people (assignees, members,
   shares, invites), account and device ids, store ids, timestamps of the
   user's data, `githubRepo`, and source originals. The format has no field
   for any of them, so a reader cannot carry them by mistake.
7. **The schema and its limits live in `registry/`**, with golden validation
   cases. Every reader validates a file at its boundary before it shows or
   stores anything.

## Consequences

- One small schema serves the apps, the backend, the site and outside tools.
- Copying a template gets preview, ledger and undo from the engine, with no
  new write path. A template adapter is the only new import code.
- Template text is public. The exporter strips and the reviewer checks, but
  the format is the first guard: a field that does not exist cannot leak.
- Starter tasks cannot ship in version 1. Adding them later is an additive
  field, so it stays version 1, and old readers drop it.
- Rejected alternative: **a template is a `septena.import` bundle.** It
  reuses one schema, but a bundle carries tasks, dates and originals, has no
  metadata or recipes, and its readers expect a source app.
- Rejected alternative: **recipes as a new synced entity.** It needs new
  columns on every client and the backend. Notes are already the context
  agents read (ADR 0012), with history and the brief rule.

## Links

`docs/TEMPLATES_SPEC.md`, `docs/MOVING_IN_SPEC.md`,
`docs/PROJECT_NOTES_SPEC.md`, #621, #194, #99.
