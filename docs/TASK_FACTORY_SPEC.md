# Task factory — spec

**Status:** accepted. F0 claims, stop and pause built 2026-11-19 (§5, ADR 0008). Agent smart list and manual runner built 2026-11-22 (§3, §4.1). F1a multi-user wake transport (SSE/WebSocket stream + signed webhooks) and scheduled/waking runner built 2026-11-24 (§4.2, §8, `#5`). Written and accepted 2026-11-19. Open questions keep their defaults until mz overrules them.
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

### 3.1 Review — canonical contract (shipped, `#87`)

**Review** is the ONE surface by this name across the app, backend, MCP tools,
and docs (Today rollover's default mode was renamed to **Ask** in ADR 0014, and
the Faded sweep uses **Sweep**).

- **Membership (single source of truth):** Open, non-heading, non-faded tasks
  with `conversation.endState == "needs_verify"` (`TaskConvo.needsHumanReview`
  in `SeptenaCore/ConvoDerived.swift`, mirrored by `TaskStore.readReviewTasks`
  and MCP `tasks_list(view: "review")`).
- **Sidebar visibility:** Progressive disclosure (`visibility: "whenNonEmpty"` in
  `registry/destinations.json`). Appears right below **Today** when non-empty
  (or while selected); always reachable via **Go ▸ Review** and **Quick Find**.
- **Store enforcement (`human_accepts`, `TaskStore.ts`):** Agents cannot set
  `status = "done"` on a task assigned to an agent (`claude`), already in
  Review (`needs_verify`), or held under a live claim. The store rejects with
  `human_accepts` and instructs the agent to call
  `tasks_set_endstate("needs_verify", note)`. Setting `needs_verify`
  automatically releases the agent's active claim. Plain tasks with no agent
  assignment/claim stay completable by agents; humans can always complete any
  task.
- **Human actions:** Each Review row shows title, `endStateNote`, linked
  issue/PR or artifact title, and two actions — **Accept** (completes task,
  transitions `endState` to `agent_assisted_done` so reopening later does not
  snap back into Review, with lossless `⌘Z` undo back to `needs_verify`) and
  **Send back** (appends a user turn with a note, reopens `endState` to `open`,
  assigns to `claude`, with lossless `⌘Z` undo).
- **Fade exemption:** Tasks awaiting human review (`needs_verify`) or an open
  choice card (`awaitsHuman`) never fade (`TaskFade.isEligible`).
- **Explanation & Settings:** Zero toggles. Explained in-place via the empty
  state (*"Work an agent finished appears here so you can check and accept
  it."*) and one footer sentence under **Settings ▸ AI & Agents**.

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

### 4.1 Manual runner (F0, built)

`scripts/task-runner.sh` runs ONE pass of the loop above by hand on
`mz-mini`. It is not scheduled. It starts headless Claude Code (`claude -p`)
with only the Septena task tools and read-only web research allowed, so F0
handles `research`-shaped work only.

- **Setup, once:** `claude mcp add --transport http septena https://api.septena.app/mcp`,
  then authenticate the server in an interactive `claude` session and enter
  the pairing code in Septena. Claude Code keeps the OAuth grant. The script
  holds no token.
- **Run:** `scripts/task-runner.sh` (one task), `--max 2` (two tasks, in
  turn), `--task <id>` (one named task), `--dry-run` (list, claim nothing).
- **Claim name:** `runner:<host>`; the backend adds the pairing.
- **Stops:** a claim or write refused as `paused` or `stopped` ends the pass;
  the script exits 3. Only mz resumes, in the app.
- **Log:** `~/Library/Logs/septena-runner/<timestamp>.log`.

### 4.2 Scheduled & waking runner on `mz-mini` (F1a, `#5`)

Two LaunchAgent templates live under `docs/agents/`:

- `docs/agents/app.septena.task-runner.plist` — scheduled 15-minute pass (`scripts/task-runner.sh --max 2`).
- `docs/agents/app.septena.task-runner-wake.plist` — persistent SSE wake listener (`scripts/task-runner-wake.mjs`) subscribed to `GET https://api.septena.app/v1/agent/events/stream`, triggering `scripts/task-runner.sh --max 2` immediately on `assigned`, `user_turn`, and `resumed` events.

`scripts/task-runner.sh` guards against overlap with an atomic `mkdir` lock (`/tmp/septena-task-runner.lock.d`, with stale-lock recovery), runs `--max 2` as two bounded parallel worker slots (`<agent>:w1` / `<agent>:w2`) with per-slot log isolation, and rotates logs in `~/Library/Logs/septena-runner/` (keeping the newest 100 by default).

**Install on `mz-mini`:**

1. Ensure Claude Code is paired with `https://api.septena.app/mcp` (see §4.1).
2. Store a bearer token (`sa1.*` app session or `sm2.*` MCP OAuth token with `tasks:read`) in a private file for the wake listener:
   ```bash
   mkdir -p ~/.config/septena ~/Library/Logs/septena-runner
   chmod 700 ~/.config/septena
   printf '%s\n' '<bearer-token>' > ~/.config/septena/wake-token
   chmod 600 ~/.config/septena/wake-token
   ```
3. Copy both plist templates into `~/Library/LaunchAgents/`, replace `REPLACE_WITH_USER` with your macOS username, and load them:
   ```bash
   for f in app.septena.task-runner.plist app.septena.task-runner-wake.plist; do
     sed "s/REPLACE_WITH_USER/$(whoami)/g" "docs/agents/$f" > "$HOME/Library/LaunchAgents/$f"
     launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/$f" 2>/dev/null || true
     launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$f"
   done
   ```
4. **Outbound webhooks (optional, for cloud routines / OpenClaw / n8n):** register an `https://` URL via `POST /v1/agent/webhooks` (`{ "url": "https://...", "secret": "..." }`, authenticated with a user bearer token). Every wake event (`assigned`, `user_turn`, `resumed`) sends a pointer-only JSON POST signed with `X-Septena-Signature: sha256=<hex>` over `${X-Septena-Timestamp}.${rawBody}` using HMAC-SHA256.

## 5. Claims

**Built 2026-11-19 (backend + api.septena.app connector). Rules: ADR 0008.**

Fields on the `convos` row:

- `claimedBy` — `<agent>@<pairing>`, e.g. `runner:mz-mini@a1b2c3d4`.
  Server-owned: a push cannot set it.
- `claimUntil` — lease end. Default 30 minutes, at most 4 hours, renewed by
  claiming again as the same agent.
- `runsSinceUser` — fresh claims since the last human turn. Server-owned.
- `stoppedAt` — the human's stop. App actors only.

MCP tools, on the api.septena.app connector only (ADR 0008):

| Tool | Effect |
|---|---|
| `tasks_claim(id, agent, ttlMinutes?, why?)` | Takes or renews the claim. Refuses with a rule: `paused`, `stopped`, `your_turn`, `held`, `budget`, `terminal`, `closed`, `not_found`. The DO serializes, so two agents cannot both win. |
| `tasks_release(id, agent, why)` | Clears the agent's own claim. `why` goes to the activity log. |
| `tasks_agent_events(since?, limit?)` | Pointer events since a cursor: `assigned`, `user_turn`, `stopped`, `resumed`, `paused`, `unpaused`. |
| `tasks_activity(id?, limit?)` | The change log in words, with reasons. |

Rules the store enforces:

- An expired claim is free again.
- A provider turn with options (a question) releases the claim.
- A human turn sets `runsSinceUser` to 0. The 6th fresh claim without one is
  refused (`budget`): the agent must ask.
- While `stoppedAt` is set, every agent write to the task is refused.
- While `agentsPaused` is true, every claim and every other agent write is
  refused (`paused`; a release still works), and
  `tasks_pending_reasoning` returns no tasks.
- A turn written by a non-holder while a claim is live is accepted (mz can
  always write), but the runner re-reads the thread before its next write.

`tasks_pending_reasoning` now leaves out stopped tasks and tasks whose
question waits for the human, and gives each task its `stage` (`queued` or
`working`, with the holder).

## 6. Work profiles

A work profile says what an agent may do on tasks in a project without
asking. Set on a project; an area's profile is the default for its projects
*(default)*. No profile → **Ask first** for everything.

| Field | Values |
|---|---|
| `workflow` | `code`, `research`, `errand` (§7) |
| `repo` | the project's `githubRepo`; required for `code` |
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
- **Wake (multi-user transport, decided 2026-11-21):** the wake plumbing on
  `api.septena.app` is built multi-user from day one, with `mz-mini` as the
  first runner and Settings UI added later. Two transports share the same
  `tasks_agent_events` event stream (`assigned`, `user_turn`, `resumed`):
  1. **Outbound webhook URL** attached to an agent key or pairing (HMAC-signed
     POST with event payload) — works for cloud routines, OpenClaw, n8n, and
     tunneled hosts.
  2. **Outbound SSE / WebSocket event stream** opened by the runner to
     `api.septena.app` — works behind home NAT/firewalls (Macs / `mz-mini`)
     with zero inbound ports or tunnels.
  Without either connected, the next 15-minute scheduled run picks the task up.
- **Onboarding vs. Settings (decided 2026-11-21):** first-run onboarding
  (`#103`) stays focused on connecting an interactive agent. "Always-on /
  Background agent" (webhooks, cloud routines, local runner setup) lives in
  **Settings ▸ AI & Agents** later, never blocking initial setup.
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
- **Kill switch:** one setting, "Pause all agents", stops claims and agent writes at once.
  Built: synced setting `agentsPaused`, toggle in Septask ▸ Settings ▸
  Connections & AI. Per task: **Stop** / **Resume** in the conversation.

## 11. Phases

| Phase | What | Exit check |
|---|---|---|
| F0 | Claims (`tasks_claim` / `tasks_release`), stage derivation, Agent smart list. Runner as a manual command on the mini. | mz assigns a `research` task; a manual run produces an artifact; the stage moves Queued → Working → Done. |
| F1a | Multi-user wake transport (signed webhook URL + SSE/WebSocket stream on `api.septena.app`) and scheduled/waking runner on `mz-mini` (15 min, max 2 parallel). | mz answers a card on the phone; `mz-mini` wakes immediately and posts the next turn with no interactive session open. |
| F1b | APNs push notifications when a provider turn with options commits + up to 3 option actions on iOS and watch (requires mz's APNs `.p8` key in Cloudflare). | A question arrives as a notification on iPhone/watch; mz taps an option from the lock screen and the turn commits. |
| F2 | Work profiles and approval cards. `errand` workflow. Kill switch. | An outward action waits for Approve; nothing outward happens without it. |
| F3 | `code` workflow on the project's `githubRepo`. Run log and inspector list. | A note becomes an issue, a PR and a merge on this repo; mz tests from the `needs_verify` list. |
| F4 | `factory-day` questions route to Septask; daily digest from the run log; cloud-routine host. | One morning report and one question inbox for all of mz's personal factories. |

## 12. Open questions for mz

| Question | Decision |
|---|---|
| Runner host | Decided (default, 2026-11-21): Mac mini first; cloud routines later for non-toolchain work. |
| Run cadence | Decided (default, 2026-11-21): Every 15 minutes, plus wake on answer. |
| Parallel tasks per run | Decided (default, 2026-11-21): 2. |
| Profile scope | Decided (default, 2026-11-21): Project, with area as fallback. |
| Auto-intake without assigning | Decided (default, 2026-11-21): Off in v1. |
| Notification actions | Decided (default, 2026-11-21): Up to 3 options as actions. |
| Where `factory-day` asks for personal projects | Decided (default, 2026-11-21): Septask. Starlings stays for team work. |
| Agent merges on `ship` | Decided (default, 2026-11-21): Yes, per your global merge rule. |
| F1 runner scope & wake transport | Decided (2026-11-21): Multi-user transport on `api.septena.app` (signed outbound webhook URL + SSE/WebSocket stream for NAT'd Macs); `mz-mini` is the first runner. |
| Background runner in onboarding | Decided (2026-11-21): Keep onboarding (`#103`) interactive-only; put "Always-on / Background agent" in Settings ▸ AI & Agents later. |
| F1 split | Decided (2026-11-21): Split into F1a (wake transport + runner, `#5`) and F1b (APNs push + notification actions, gated on mz's APNs `.p8` key). |
