# 0032. Follow GitHub issues, do not mirror them

- Status: accepted (2026-11-24)
- Date: 2026-11-24
- Deciders: mz
- Amends: [ADR 0003](0003-external-links-run-server-side.md), for GitHub only
- Builds on: [ADR 0031](0031-references-are-keyed-pointers.md) (references)
- Spec: [GITHUB_SPEC.md](../GITHUB_SPEC.md)

## Context

ADR 0003 made every open issue of a linked repository a task, with two-way
sync. A repository that agents work in holds far more issues than a person
plans, so the mirror buries the person's own tasks. Filters do not help there:
agents file under the owner's account and nobody sets an assignee. The gap
that people meet today is a smaller one: the issue closes and the task that
points at it stays open.

## Decision

GitHub owns the work record. Septena owns the person's attention. A task
points at an issue with a reference (ADR 0031) and follows its state: when the
issue closes, the task goes to Review, never to Done. A project can show the
live issues of its repository, but they are not tasks. A person pulls one
issue in as a task, or sends one task out as an issue. Nothing else writes to
GitHub. Issue fields never sync into the task.

## Consequences

- No conflicts, no echo loops and no import of issues in bulk.
- ADR 0003 still holds for the rest: links run on the server, the apps never
  call the provider, and one canonical key identifies an item.
- Follow and browse need read-only issue access. Send needs write access and
  ships last.
- Issues cannot be planned in bulk from Septena. A person pulls them one by one.
- Starlings and Linear keep the design of `docs/LINKED_PROJECTS_SPEC.md`. They
  are not reviewed by this ADR.

## Links

`docs/GITHUB_SPEC.md`, `docs/LINKED_PROJECTS_SPEC.md`,
`docs/TASK_REFERENCES_SPEC.md`, #6, #7, #24
