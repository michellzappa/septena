# 0042. Members keep replicas of a shared project

- Status: accepted (2026-11-25)
- Date: 2026-11-25
- Deciders: mz (product), agent (storage)
- Amends: [ADR 0004](0004-shared-projects-own-store.md) (how its rows reach
  members; conversations stay private)

## Context

ADR 0004 puts a shared project in its own Durable Object and keeps personal
fields in each member's store. It left open how a client reads both halves.
The spec's answer was a local `<storeId>:<id>` key in every client, MCP and
the core, and ids minted by the server. Our clients make ids offline, and five
code bases use the bare id as a key. ADR 0004 also listed conversations as
shared; the spec made them private.

## Decision

- **The ProjectStore is the authority; each member's TaskStore holds a full
  replica** of the shared rows in its normal tables, next to the personal
  fields of the same row.
- **Ids are mapped on the server.** A row has one shared id in the
  ProjectStore and a local id in each member's store.
- **The invite is a link** for one person, not an email address.
- **Conversations stay private** to each member.
- **Notes merge; a replica is never deleted with something on it that exists
  nowhere else** (mz, 2026-11-25: never lose data). Spec §5a.

## Consequences

- Clients, MCP, REST, widgets and feeds read a shared project with no change.
  A client needs two new columns (`project.share`, `task.assignedTo`).
- There is more than one copy. The ProjectStore decides every conflict, and a
  replica takes its state; `backend/test/shares.test.ts` holds the rules.
- Every shared write costs one call to the ProjectStore and one per member.
- The same task has different ids in different accounts, so a task link does
  not work between members.
- Ending a share is a local act: drop the replica, or keep it as a private
  project.

## Links

`docs/PROJECT_SHARING_SPEC.md`, ADR 0004, ADR 0011, ADR 0036
