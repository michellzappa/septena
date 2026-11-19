# 0003. External links run on the server; the remote owns mapped fields

- Status: accepted (2026-11-19)
- Date: 2026-11-19
- Deciders: mz

## Context

mz wants a Septask project to show tasks from another service: GitHub Issues,
Starlings tasks on several workspaces, later Linear and others. A link that
runs on a device syncs only while the app runs, and several devices race each
other. Planning fields (Today, order, area) have no equivalent on the remote
side.

## Decision

- A link runs on the backend, next to the user's Durable Object. The backend
  holds the provider tokens. The apps never call the provider.
- The remote service owns the fields that map (title, body, open/closed, due
  date). Septask owns the planning fields. A remote change never resets a
  planning field.
- Every remote item has one canonical key in Starlings door format
  (`issue:owner/repo#n`, `task:<host>/<id>`). Dedupe across links uses that key.
- Providers plug in through one adapter contract. Two link modes: two-way
  *source* and inbound-only *capture feed*.

## Consequences

- Linked tasks reach every device and every MCP client through normal sync.
- Writes to a remote service are outward-facing. Moving a task across
  services and creating a remote item need a confirm step in the app.
- The backend stores third-party tokens, which adds to the privacy text.

## Links

- `docs/LINKED_PROJECTS_SPEC.md`
- ADR 0002
