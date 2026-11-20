# 0008. Agent loop rules live in the store; the human holds the stop

- Status: accepted (2026-11-19), agent default — mz may overrule
- Date: 2026-11-19
- Deciders: mz (agent proposed, from a comparison with roma.app)

## Context

ADR 0005 makes tasks the intake for agents. `docs/TASK_FACTORY_SPEC.md` F0
asks for claims. roma.app (a to-do app for agents, YC-backed) shows what a
mature agent loop adds on top of claims:

- Claims are leases. A held task is released when the agent goes quiet.
- The human can stop an agent on one task, and the agent cannot restart
  itself.
- Handoff chains are capped, so agents cannot loop without a human.
- Agents learn about work through event deliveries that carry pointers, never
  content.
- Every write carries a reason, and the log is readable.

Septena had none of these. The connector served the old CloudKit tools'
shapes, with a fixed `mcp:claude` actor and no claim.

## Decision

- **The rules live in the user's Durable Object (`TaskStore`), not in a
  connector or a prompt.** Any caller is held to them, including a future
  runner or a third-party agent.
- **Claims are leases.** The default lease is 30 minutes and the maximum is
  4 hours. The holder renews the lease while it works. An expired claim is
  free. The claim records the agent's own name, scoped to its pairing
  (`runner:mz-mini@<client>`).
- **Asking ends the claim.** When an agent writes a question (a provider turn
  with options), the store releases its claim. A task whose question waits for
  the human cannot be claimed (`your_turn`).
- **The stop belongs to the human.** `convo.stoppedAt` is written only by an
  app actor. While it is set, the store refuses every agent write to that
  task. "Pause all agents" (`agentsPaused`, synced setting) refuses every
  claim. No agent can clear either one.
- **Run budget.** An agent may take at most 5 fresh claims on a task between
  two human turns. Then it must ask. Only a human turn refills the budget, so
  an agent cannot reset it by writing a "user" turn.
- **Events are pointers.** `tasks_agent_events` returns an event kind and a
  task id with a cursor. The agent reads the task itself. A task's text never
  arrives as an order through the event feed.
- **Reasons are logged.** The change log has a `reason` column. Claim and
  release take a `why`. `tasks_activity` shows the log in words.
- **These tools exist on the api.septena.app connector only.** A claim needs a
  single writer. The CloudKit gateway and the in-app server have none, and
  Septena is leaving iCloud (ADR 0002). Their task tools stay as they are.
  This is a deliberate exception to the "edit both MCP servers in lockstep"
  rule in `CLAUDE.md`.

## Where this goes further than Roma

- The stop and the pause are enforced by the store, not by a prompt.
- Asking a question releases the claim, so no lease is wasted while the
  human thinks.
- The budget refills only on a human turn, so an agent cannot refill it.
- The pause is account-wide and synced. It holds on every device and for
  every agent at once.

## Consequences

- A runner (spec F1) needs only the connector: poll `tasks_agent_events`,
  claim, work, release. Push delivery to a runner is still open (spec §8).
- A Claude chat that relays the user's answer as a "user" turn does not
  refill the budget. The user answers in the app, or the agent asks again.
- Old app builds ignore the new conversation columns. They cannot show or set
  the stop, but they cannot clear it either: a push sends only the fields
  that changed.

## Links

- `docs/TASK_FACTORY_SPEC.md` §5, §10
- `backend/src/store/TaskStore.ts` (`claim`, `release`,
  `agentRefusal`, `agentEvents`)
- `backend/src/shadow/agent.ts`
