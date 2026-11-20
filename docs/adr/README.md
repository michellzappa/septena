# Architecture decision records

One file per decision: `NNNN-short-title.md`, numbered in order. An ADR is
short and does not change after it is accepted. To change a decision, write
a new ADR and set the old one to `superseded by NNNN`.

| # | Decision | Status |
|---|---|---|
| [0001](0001-record-decisions.md) | Record decisions as ADRs; plan with specs, roadmap, issues | accepted |
| [0002](0002-own-backend-replaces-icloud.md) | Own backend replaces iCloud | accepted |
| [0003](0003-external-links-run-server-side.md) | External links run on the server; the remote owns mapped fields | accepted |
| [0004](0004-shared-projects-own-store.md) | A shared project lives in its own store | accepted |
| [0005](0005-tasks-as-factory-intake.md) | Tasks are factory intake; agents ask in the app | accepted |
| [0006](0006-tasks-fade-by-default.md) | Tasks fade by default; the list asks why a task is stuck | accepted |
| [0007](0007-septena-is-the-task-app.md) | Septena is the task app; the life OS becomes Septena Life | accepted |
| [0008](0008-agent-loop-rules-live-in-the-store.md) | Agent loop rules live in the store; the human holds the stop | accepted |
| [0009](0009-trustable-private-ai.md) | Run AI on tasks with checkable privacy guarantees | proposed |

## Template

```markdown
# NNNN. Title in the imperative

- Status: proposed | accepted | superseded by NNNN
- Date: YYYY-MM-DD
- Deciders: mz

## Context
What forces the decision. Facts, not opinions.

## Decision
What we do. One paragraph.

## Consequences
What becomes easier, what becomes harder, what we give up.

## Links
Specs, issues, earlier ADRs.
```
