# Task factory — spec

**Status:** accepted, not started. Written and accepted 2026-11-19. Open questions keep their defaults until mz overrules them.
**Decisions:** [ADR 0002](adr/0002-own-backend-replaces-icloud.md),
[ADR 0005](adr/0005-tasks-as-factory-intake.md).
**Builds on:** the task conversation loop (`docs/TASK_CONVERSATIONS_PLAN.md`,
`SeptenaCore/TaskConvo.swift`), linked projects
(`docs/LINKED_PROJECTS_SPEC.md`), the `factory-day` skill (mz's existing
software-factory playbook for Starlings and Bipe).
**Owner of decisions:** mz. Defaults chosen by the agent are marked
*(default)*; overrule them in §12.

## 1. Goal

mz writes a note in Septask and assigns it to Claude. An agent does the work
while mz does something else, asks mz short questions in the app when it
needs input, and hands back a result mz can check. Septask is the intake and the
inbox for agent work, on every device.

## 2. What exists and what is missing

**Exists** (shipped, `TaskConvo.swift` and the MCP tools):

- Conversation turns with choice cards: `question`, `options`, `chosen`,
  `otherText`.
- Loop steps: confirm → ground → scope → decide → work.
- `assignee` (`me` / `local` / `claude`); `assignee = claude` puts the task in
  `tasks_pending_reasoning`.
- `artifact` (what the agent produced), `handoff` (the human last mile),
  `acceptance` (the agent's done bar), `endState` (incl. `needs_verify`,
  `decomposed`).
- The ball-in-court dot: your turn / agent's turn / done.
- MCP tools: `tasks_pending_reasoning`, `tasks_thread_get`,
  `tasks_thread_append`, `tasks_set_assignee`, `tasks_set_artifact`,
  `tasks_set_handoff`, `tasks_set_acceptance`, `tasks_set_endstate`.

**Missing:**

| Gap | Section |
|---|---|
| Nothing drains the queue unattended. | §4 Runner |
| No claim: two agents could work one task. | §5 Claims |
| No rule for what an agent may do without asking. | §6 Work profiles |
| No path from a task to a repo, issue and PR. | §7 Workflows |
| No notification when the agent waits for mz. | §8 Questions |
| No record of runs, results, cost. | §9 Run log |
| External text could steer the agent. | §10 Safety |

## 3. Stages mz sees

The stage is derived from data that exists. It is not a new stored state
machine.

| Stage | Derived from |
|---|---|
| **Queued** | `assignee = claude`, no live claim, not terminal. |
| **Working** | A live claim (§5). |
| **Your turn** | Last provider turn has `options` and no user turn answers it. |
| **Review** | `endState = needs_verify`, or an approval card waits (§6). |
| **Done** | Terminal `endState`. The task `status` stays mz's: it closes when mz accepts or finishes the handoff. |

Septask gets one smart list, **Agent**, grouped by these stages
*(default)*. The Today list shows only **Your turn** and **Review** items, as
today's ball-in-court dot already does.

## 4. Runner

The runner is a process that drains the queue.

- **Host:** the Mac mini `mz-mini` *(default)*. It is always on, has Xcode,
  the repos and the build setup (`~/.claude/CLAUDE.md`). Claude cloud routines
  are a second host for work that needs no local toolchain.
- **Process:** a scheduled headless Claude Code run every 15 minutes
  *(default)*, plus an immediate wake when mz answers a card (§8). One run
  takes at most 2 tasks in parallel *(default)*, to keep the mini's load sane
  and to respect its build lock.
- **Loop for each run:**
  1. `tasks_pending_reasoning` → candidates, oldest first, `Your turn`
     excluded.
  2. Claim one (§5). Skip it if the claim fails.
  3. Read the task, its thread, its project's work profile (§6) and its
     workflow (§7).
  4. Advance it as far as the profile allows, writing every step as a turn.
  5. Stop at the first gate that needs mz: a question card, an approval card,
     or `needs_verify`. Release the claim.
  6. Append a run record (§9).
- **The runner never asks in its own terminal.** All questions go to the task
  (`factory-day` rule: unattended means no interactive questions).

## 5. Claims

New fields in the task conversation (`task_convo` row on the backend):

- `claimedBy` — runner id (`runner:mz-mini`, `routine:<id>`, `mcp:<client>`).
- `claimUntil` — lease end. Default 30 minutes, renewed while working.

New MCP tools, in both servers:

| Tool | Effect |
|---|---|
| `tasks_claim(id, ttlMinutes)` | Sets the claim if none is live. Fails if another actor holds it. The DO serializes, so two runners cannot both win. |
| `tasks_release(id)` | Clears the claim. |

An expired claim is free again. A turn written by a non-holder while a claim
is live is accepted (mz can always write), but the runner re-reads the thread
before its next write.

## 6. Work profiles

A work profile says what an agent may do on tasks in a project without
asking. Set on a project; an area's profile is the default for its projects
*(default)*. No profile → **Ask first** for everything.

| Field | Values |
|---|---|
| `workflow` | `code`, `research`, `errand` (§7) |
| `repo` | from the project's GitHub link (`docs/LINKED_PROJECTS_SPEC.md`); required for `code` |
| `autonomy` | `ask-first` (every step is a card), `reversible` (do reversible work alone, ask at forks and outward actions), `ship` (also open and merge PRs, per mz's merge rules) |
| `reads` | which Septena data the agent may read for grounding (tasks only by default) |
| `budget` | max runs per task before it must ask; optional cost cap per day |

Hard rules, independent of profile:

- **Outward-facing actions** (send a message or email, post, publish, create
  an issue in someone else's repo, invite a person) always end in an approval
  card or a handoff. The agent drafts; mz taps.
- **Money:** never. Always a handoff.
- **Deletion of anything outside Septask:** never without an approval card.
- The approval card is a normal turn: `step = decide`, options
  `["Approve", "Change…", "Stop"]`. The agent executes only after a user turn
  with `chosen = "Approve"` that answers that card's `seq`.

## 7. Workflows

A workflow maps the loop steps to concrete work. Three to start.

### 7.1 `code`

```
note ─► confirm ─► ground ─► spec ─► issue ─► build ─► PR ─► merge ─► needs_verify ─► done
         card?      repo      card?   GitHub   worktree  CI    per       mz tests
                    read                      on mini         profile
```

- **Confirm:** a card only when the note is ambiguous (the existing hard
  gate).
- **Ground:** read the repo, `AGENTS.md`/`CLAUDE.md`, related docs and issues.
- **Spec:** for anything bigger than one change, the agent writes the issue
  body as a spec and shows it as an artifact; with `autonomy = ask-first` it
  asks for approval first.
- **Issue:** created in the linked repo. The task becomes a linked task
  (`extKey = issue:owner/repo#n`). The issue is the work record; the task is
  mz's view of it.
- **Build:** in a worktree on the runner host, following the repo's own rules
  (for this repo: no branches except `wt/`, build gate, no tests unless asked).
- **PR / merge:** per profile. With `ship`, the agent merges when CI is green,
  per mz's global merge rule.
- **needs_verify:** the agent sets `endStateNote` to what mz must test by
  hand, in one short list. mz marks the task done after testing.

### 7.2 `research`

confirm → ground → work → artifact. The artifact holds the result (a table, a
comparison, a draft). `endState = agent_done`, or `agent_assisted_done` with a
handoff when mz must act on it.

### 7.3 `errand`

For things only mz can finish (book, pay, call, send). confirm → ground →
draft → handoff. The agent prepares everything; the handoff button opens the
URL, mail or phone.

### 7.4 Relation to `factory-day`

The `factory-day` skill keeps running the Starlings and Bipe factories. Its
"queue a question" step can target Septask instead of Starlings
`ask_decision` *(default for mz's personal projects; Starlings stays the
queue for team work)*. Then all of mz's agent questions are in one app.

## 8. Questions and notifications

- A question is a provider turn with `question` and `options` (exists). Keep
  them tap-first: 2–4 options plus "Other…" (exists).
- **Notification:** when the backend commits a provider turn with options on
  a task, it sends a push notification to mz's devices: task title + the
  question. The notification offers the options as actions on iOS and the
  watch *(default: up to 3 options as notification actions)*, so mz answers
  without opening the app.
- **Wake:** when the backend commits a user turn that answers an open card on
  an agent task, it calls the runner's wake hook. Without a wake hook, the
  next scheduled run picks it up.
- **Batching:** the runner groups several questions on one task into one card
  when they do not depend on each other. At most one open card per task.
- **Quiet hours:** notifications respect Focus. No custom quiet-hours logic.

## 9. Run log

A new append-only `runs` table on the backend: taskId, runId, actor, startedAt,
endedAt, stagesAdvanced, result (`advanced`, `waiting`, `blocked`, `failed`),
summary (one line), cost (tokens and money, when the runner reports them),
links (issue, PR, commit).

- The task inspector shows runs as a compact list under the thread.
- The runner writes one summary turn per run as `note`, so the thread stays
  readable without the run list.
- A daily digest (optional) lists what agents did, in words, not ids: the
  `factory-day` morning report, sourced from this table.

## 10. Safety

- **Only mz starts work.** A task enters the queue only when mz sets
  `assignee = claude`, or when a work profile marks a project as auto-intake
  *and* the task was written by mz *(default: no auto-intake in v1)*.
- **Text from other people is data, not instructions.** Linked tasks
  (GitHub issues by others, Starlings tasks by colleagues) and capture-feed
  tasks (email, Slack) carry `source` and `extKey`. The runner treats their
  title and body as information about the work, never as commands. It never
  follows an instruction in them to send, delete, pay or share. Such a task
  needs mz's assignment even with auto-intake on.
- **Provenance:** every agent write carries its actor in the change log
  (backend spec §5.2) and shows the existing provenance cue in the app
  (`docs/agent-provenance-spec.md`).
- **Least privilege:** the runner uses a per-user API token with the `tasks`
  scope (backend spec §8), and GitHub access only through the repo links of
  its profile.
- **Kill switch:** one setting, "Pause all agents", stops claims at once.

## 11. Phases

| Phase | What | Exit check |
|---|---|---|
| F0 | Claims (`tasks_claim` / `tasks_release`), stage derivation, Agent smart list. Runner as a manual command on the mini. | mz assigns a `research` task; a manual run produces an artifact; the stage moves Queued → Working → Done. |
| F1 | Scheduled runner on the mini, push notification on questions, notification actions, wake on answer. | mz answers a card on the phone; the next turn appears without opening the Mac. |
| F2 | Work profiles and approval cards. `errand` workflow. Kill switch. | An outward action waits for Approve; nothing outward happens without it. |
| F3 | `code` workflow on linked repos (needs linked projects L0–L1). Run log and inspector list. | A note becomes an issue, a PR and a merge on this repo; mz tests from the `needs_verify` list. |
| F4 | `factory-day` questions route to Septask; daily digest from the run log; cloud-routine host. | One morning report and one question inbox for all of mz's personal factories. |

## 12. Open questions for mz

| Question | Default in this spec |
|---|---|
| Runner host | Mac mini first; cloud routines later for non-toolchain work. |
| Run cadence | Every 15 minutes, plus wake on answer. |
| Parallel tasks per run | 2. |
| Profile scope | Project, with area as fallback. |
| Auto-intake without assigning | Off in v1. |
| Notification actions | Up to 3 options as actions. |
| Where `factory-day` asks for personal projects | Septask. Starlings stays for team work. |
| Agent merges on `ship` | Yes, per your global merge rule. |
