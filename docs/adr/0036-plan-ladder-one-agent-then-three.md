# 0036. Four plan levels: an account adds the server, Plus adds more than one

- Status: accepted (2026-11-24)
- Date: 2026-11-24
- Deciders: mz
- Amends: [ADR 0010](0010-free-server-tier-with-limits.md) (the connector and
  agent caps, live sync and the Logbook window of the free account) and
  [ADR 0023](0023-sync-across-devices-is-plus.md) (adds agents next to
  devices; the one-device rule stands)

## Context

The plan table had grown by feature, and a review found six breaks:

1. Signing in took something away: the Logbook was whole with no account and
   90 days on a free account. (No app enforced it.)
2. Agents had three limits: 25 changes a day, 10 runs a month, and a count of
   connected agents that only logged.
3. Slow sync on a free account with one device mostly delays the agent, at the
   moment the account should show that agents work.
4. The copy said nothing in Plus is capped. Files stop at 10 GB, history at
   365 days, and each task has a run budget.
5. Plus sold 90 days to restore deleted tasks. The Apple app uses one fixed
   30-day window.
6. The spec listed a local MCP server on the Mac for people with no account.
   That server was removed on 2026-11-21.

The count can now carry a limit: each connected agent has an identity, a name
and a row in Settings, apart from devices (#323). There is no hosted AI. Users
pay their own AI provider, so one more agent costs us server traffic only.

## Decision

**An account adds the server. Plus adds more than one. Pro removes the agent
limit.** An agent is one more thing that reads and writes the list, as a
device is.

| | On this device | Free account | Plus | Pro (later) |
|---|---|---|---|---|
| Reason to exist | Try it | One of each | All my devices | All my agents |
| Devices | 1, not synced | 1, backed up, live | All | All |
| Connected agents | 0 | 1 | 3 | No limit |
| Synced files | No | No | 10 GB | 50 GB *(working value)* |
| Change history | On the device | 30 days | 365 days | All we keep *(working value)* |
| Restore deleted | 30 days | 30 days | 90 days (planned; 30 today) | 90 days |
| Shared projects (planned) | No | Join | Create and invite | Create and invite |
| Price | €0 | €0 | €60 a year, €7 a month | €120 a year, €14 a month *(working value, not decided)* |

Rules:

- **Launch three levels.** Pro is designed and hidden: no page, no product, no
  code. Add it when overnight agent runs ship (#5), or when the
  `agent_limit_over` logs show enough accounts at 3.
- **One agent is one connection** used in the last 30 days. claude.ai counts
  once for all its chats. Claude Code counts once per machine. Counting
  by provider is not possible: the server only knows the name a client gives.
- **No agent without an account.** Agents talk to the server, never to a
  device.
- **The two meters go.** The limits on changes a day and runs a month leave
  the plans. One abuse cap stays on the server for a free account: 500 agent
  changes a day. It is not a plan feature and not on the pricing page. Runs
  are still counted, for measurement.
- **Live sync on every account.** Speed is not for sale.
- **Never on the ladder:** tasks, projects, areas, the Logbook, export, sync
  speed. Devices stop at Plus.
- **Replacing an agent is free,** as moving a device is. One replacement a day
  once limits are enforced, as for devices (#262) *(default)*.
- **Losing Plus** (trial end or lapse): the account keeps one agent. The user
  picks it; until then the agent used last keeps working. The others are
  refused with one line and stay listed. Nothing is deleted *(default)*.
- **Companions** (the watch, the orb) are neither devices nor agents
  (ADR 0034, proposed).

All limits stay in log-only mode (`ENTITLEMENT_ENFORCE` is false, and the
agent count only logs). Enforcing the agent count is separate work.

## Consequences

- The pricing page has one sentence per level, and every number on it is a
  count or a size.
- Plus loses "no limit on agents" before anyone bought it. The 3 can go up
  later. It must not go down for an account that pays.
- Until Pro exists, someone with 3 agents replaces one.
- Many people will never reach the agent limit, because claude.ai is one
  connection. Devices still do most of the selling.
- A busy agent on a free account costs more traffic than before, and so does
  the live socket. Both are unmeasured. Measure before #267.
- `agentRunsPerMonth` and `logbookDays` leave the plan table.
- Pro needs more than a row: `resolvePlan` knows free and Plus only, and Pro
  needs store products, a paywall and upgrade rules.
- Android has no signed-out mode yet, so the first level is Apple only there.

## Links

`registry/plans.json`, `docs/SYNC_SUBSCRIPTION_SPEC.md` §3, §6.3. Reasoning:
Starlings Septena workspace, `/strategy/free-and-paid-plans`.
