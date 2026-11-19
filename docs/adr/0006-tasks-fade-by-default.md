# 0006. Tasks fade by default; the list asks why a task is stuck

- Status: accepted (2026-11-19)
- Date: 2026-11-19
- Deciders: mz

## Context

A todo list grows because adding a task costs nothing and removing one costs
guilt. Septena and Septask keep every open task forever, like every other
todo app. After some weeks the list is mostly tasks the user avoids, and
opening the app feels heavy.

Facts from the code today:

- `TaskEntity` has no field that records when the user last touched a task.
  `updatedAt` is server-stamped and moves on every sync write, so it is not a
  user signal.
- Nothing counts how often a task was pushed to a later day.
- Undone `today` tasks carry over to the next day without a prompt.
- The triage band (`docs/TRIAGE_BAND_SPEC.md`) already holds rows the user
  has not ratified, above Today. Agent proposals use it.
- The conversation loop (`SeptenaCore/TaskConvo.swift`) already asks
  tap-to-answer questions on one task.
- Septena (not Septask) has sleep and readiness data (Oura, HealthKit).

The usual reason a task is avoided is not a missing reminder. The task is
unclear, unpleasant, not the user's job, or not for now. A list treats all
four the same.

## Decision

- **Letting go is the default.** A task the user does not touch for a set
  number of days fades: it leaves every list and goes to a Faded pile. A weekly
  sweep asks "still want these?". One tap keeps a task. A task the user does not
  keep is dropped (status `cancelled`, recoverable from the logbook).
- **Today does not carry over by itself.** At day rollover, undone Today tasks
  go to the Inbox band as "carry over?" rows. The user ratifies or lets go.
- **A stuck task asks why.** When the user pushes a task later a third time,
  the task asks one choice-card question: unclear / boring / not mine /
  not now. Each answer leads to one action. The card reuses the conversation
  loop.
- **Done is shown before what is left.** The weekly view leads with what the
  user completed and what they dropped. It does not lead with the backlog count.
- **AI stays a verb on one task.** AI suggests, the user taps. There is no
  chat box, and AI never drops a task without a tap.
- **Energy-aware Next is Septena only.** Septena orders Next tasks by the
  user's readiness. Septask has no health data and keeps plain order.

## Consequences

- The list stays short without effort from the user. This is the product
  difference against Things, Todoist and Reminders, which keep everything.
- A user can lose a task they wanted. Mitigations: dated, recurring and
  agent-owned tasks never fade. Faded tasks stay recoverable. A drop needs the
  sweep to pass.
- The task model gains user-signal fields (`touchedAt`, `deferCount`,
  `fadedAt`, `effort`). These are backend fields (ADR 0002) and wire-contract
  fields (`docs/IDENTIFIERS.md`). Both MCP servers must expose them in lockstep.
- Every user gesture on a task must stamp `touchedAt`. A mutator that forgets
  makes tasks fade early. Sync applies, recurrence spawning and the purge must
  not stamp it.
- Septask and Septena differ on one surface (Next ordering). The difference
  lives behind the runtime profile, not in a copied file.

## Links

- `docs/TASK_FADE_SPEC.md`
- `docs/TRIAGE_BAND_SPEC.md`, `docs/TASK_CONVERSATIONS_PLAN.md`,
  `docs/AI_TASKS_EXPLAINER.md`
- ADR 0002, ADR 0005
