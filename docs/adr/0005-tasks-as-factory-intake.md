# 0005. Tasks are factory intake; agents ask in the app

- Status: accepted (2026-11-19)
- Date: 2026-11-19
- Deciders: mz

## Context

mz wants to write a note in Septask and have an agent do the work, asking
questions in the app when it needs mz. Most of the conversation layer exists:
the task conversation loop (confirm → ground → decide → work), choice cards,
`assignee = claude`, the `tasks_pending_reasoning` queue, artifacts, handoffs
and end states (`SeptenaCore/TaskConvo.swift`,
`docs/TASK_CONVERSATIONS_PLAN.md`). What is missing:

- No process drains the queue unattended. Today mz must open Claude and ask.
- No claim on a task, so two agents could work the same task.
- No rule for what an agent may do without asking: code in which repos,
  outward actions, money.
- No notification when an agent waits for mz.
- No record of what each run did or cost.

## Decision

- A task with `assignee = claude` is intake for a **runner**: a scheduled agent
  on an always-on host (the Mac mini first). The runner claims tasks with a
  lease, works them through the existing loop, and writes everything back as
  conversation turns.
- Questions stay what they are today: choice cards. The backend sends a push
  notification when a card waits for mz. An answer wakes the runner.
- A **work profile** on the project (or area) says what the agent may do
  without asking. Anything outward-facing or irreversible always ends in an
  approval card or a handoff.
- Code work routes through linked projects: a project linked to a GitHub repo
  is the repo the agent works in. The issue is the work record, the task is
  mz's view of it.
- Each run is logged on the task: start, end, actor, result, cost.

## Consequences

- Septask becomes the one place where mz gives work to agents and answers
  them. Starlings' decision queue stays for Starlings work.
- The backend is a hard dependency: agents work while devices sleep.
- Agent autonomy is set per project, not per task, so mz sets it once.
- The runner is a second consumer of the MCP tools. Tool changes must keep it
  working (the two-servers rule in `CLAUDE.md` applies).

## Links

- `docs/TASK_FACTORY_SPEC.md`
- `docs/TASK_CONVERSATIONS_PLAN.md` (rationale for the loop)
- ADR 0002, ADR 0003
