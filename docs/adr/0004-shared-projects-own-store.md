# 0004. A shared project lives in its own store

- Status: accepted (2026-11-19); amended by [0042](0042-members-keep-replicas-of-a-shared-project.md) (replicas; conversations stay private)
- Date: 2026-11-19
- Deciders: mz

## Context

Sharing a project between users was specified on CloudKit shares
(`docs/NATIVE_PROJECT_SHARING_SPEC.md`). ADR 0002 drops iCloud. With the own
backend, each user has one Durable Object. A shared project has several
users, so it cannot live in only one of them without copying.

Linked projects (ADR 0003) also split fields into shared and personal. But a
link copies data from a service we do not control. Copying between two of our
own stores would bring cursors, echo loops and dedupe back for no gain.

## Decision

- A shared project lives in its own Durable Object. It holds the project, its
  tasks, headings and conversation turns, and the member list.
- Shared fields live there: title, notes, status, deadline, heading, order in
  the project, assignee.
- Personal fields stay in each member's own Durable Object, keyed by task id:
  Today, today order, scheduled date, area.
- Each user's Durable Object relays changes from the shared projects it
  belongs to, so a client keeps one sync cursor *(default)*.

## Consequences

- One copy of the truth per shared project. No copy conflicts.
- Each member plans shared work in their own Today.
- Authorization moves from "one user, one store" to "member of this project."
  Every request to a project store checks membership.
- Linked projects and shared projects reuse one field split and one row
  anatomy in the apps.
- A shared project can also be a linked project. The link worker then writes
  into the project store, not into a user store.

## Links

- `docs/PROJECT_SHARING_SPEC.md`
- ADR 0002, ADR 0003
