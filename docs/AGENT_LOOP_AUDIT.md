# Agent comment loop: audit

Status: current, 2026-11-27 (#619). Rules: ADR 0008. Wake transport:
`docs/TASK_FACTORY_SPEC.md` §4.2, §5, §8.

The loop: an agent writes on a task, the app shows it, the user replies, the
agent hears of the reply, reads it and writes the next turn. This document
lists each hop, how it fails, the test that covers it and its status.

Decisions by mz (2026-11-22) that the loop keeps:

- A webhook pushes replies to the agent. An hourly `tasks_agent_events` poll
  with a cursor is the fallback for an agent that cannot take a webhook.
- Every comment names the agent that wrote it (#316).
- Comments show in the Review list and in the task's thread.
- Notifications are a user setting, global with per-agent overrides: every
  comment / only when an agent needs my answer or approval (default) / daily
  digest / off.

Tests: `backend/test/agentLoop.test.ts` (round trips) and
`backend/test/agentWake.test.ts` (transport). Both run in backend CI.

## Hops

| # | Hop | Code | Failure mode | Test | Status |
|---|---|---|---|---|---|
| 1 | Agent claims and writes a turn | `TaskStore.claim`, `agentRefusal`, `applyTurn` | Refused when paused, stopped, `your_turn`, held, budget, terminal. A question (provider turn with options) ends the claim. | agentLoop "hop 1-6"; humanAccepts | ok |
| 2 | The app shows the turn | sync pull of `turns`; thread and Review on every client | A question pushes APNs to Apple devices only. Android and web learn of it at the next sync. | none in backend (clients are tested by hand) | gap: #743 to #747 |
| 3 | The user replies | `push` from the app, or `POST /v1/tasks/:id/answer` | Allowed on a stopped task and during a pause (the human can always write). A stale answer to an old question is refused (`stale`). | agentLoop "hop 1-6", stop, pause; apns (answer route). The `stale` refusal has no test. | ok |
| 4 | `user_turn` event | `TaskStore.agentEvents` | Only human `user` turns count; agent and on-device provider turns do not. | agentLoop "hop 1-6", poll tests | ok |
| 4a | Webhook delivery | `dispatchAgentEvents` → `deliverWebhookWithRetry` | Before #619: one attempt, no retry. Now three attempts (waits 1 s, 5 s) on a network error, timeout, 408, 425, 429 or 5xx. Other 4xx and a blocked URL are not retried. `failureCount` counts deliveries that gave up. Retries live in memory: an evicted Durable Object loses them. | agentLoop "fails is sent again", "4xx"; agentWake dispatch | fixed; durable retry: #748 |
| 4b | Poll | `tasks_agent_events(since, limit)` | Before #619: when one call scanned 10 pages (5000 change rows) without filling its page, `nextSince` jumped to the head and skipped every row it had not read. Now the cursor stops at the last row read. A cursor older than the change log TTL (`changeLogTtlDays`) misses the purged rows. | agentLoop "never skips or repeats", "5000 agent writes" | fixed |
| 4c | SSE / WebSocket stream | `handleAgentEventsStream` | Replays from `since` / `Last-Event-ID`, then streams every kind. | agentWake stream tests | ok |
| 5 | The agent reads the reply | `tasks_thread_get` / `readTask` | Events are pointers only; the webhook body carries no task text. | agentLoop "hop 1-6" | ok |
| 6 | Next claim and turn | `TaskStore.claim` | The human turn sets `runsSinceUser` to 0, so the next claim is run 1. | agentLoop "hop 1-6" | ok |

## Edge cases

| Case | Behavior | Test | Status |
|---|---|---|---|
| The claim runs out while the user replies | The reply lands. The task is free: the first agent to claim it wins, and the other gets `held` with the holder's name. | agentLoop "claim that runs out while the user replies" | ok |
| The same agent claims again after its lease ran out | A fresh run (`renewed: false`), counted against the budget. | agentLoop "taken again by the same agent" | ok |
| Stop in the middle of a conversation | The user's reply lands and wakes the agent (`user_turn`). Its claim and writes are refused (`stopped`). An agent cannot lift the stop. Resume sends `resumed`, a wake event. | agentLoop "stop" | ok |
| Pause in the middle of a conversation | The reply lands and wakes the agent, whose claim is refused (`paused`). Before #619 the unpause woke nobody, so the reply waited for the hourly poll. Now `unpaused` is a wake event (webhook and `scripts/task-runner-wake.mjs`), with `taskId` null. | agentLoop "pause" | fixed |
| Two agents connected | Turns carry no author column. The change log holds the actor (`mcp:<agent>@<pairing>`), and History shows it. A thread turn does not name its agent yet. | none | gap: #316 |
| Notification setting | Not built on any platform. The backend pushes only questions (the default mode), to Apple devices. | none | gap: #743 (backend), #744 (iPhone and iPad), #745 (Mac), #746 (Android), #747 (web) |

## Defaults chosen in #619

- `unpaused` wakes agents. Reason: a reply that came in during a pause woke
  an agent that was then refused, and nothing woke it again. mz can overrule.
- Retry timing: three attempts, waits of 1 s and 5 s, so the whole delivery
  stays inside one Durable Object turn. A receiver dedupes on `rev`.
