# Task Row Visual Language — Spec

Status: **v1 built behind a flag (`taskRowLanguageV2`, on by default); local MCP
round-trip tested.** This is the bridge from what the Tasks list renders *today*
to the adjusted design we converged on. It is a UI + data-mapping spec; it does
**not** define the agent triggers that *produce* the states (separate — see §3.5).

**Shipped in v1** (decisions in §7 locked to their leans): `TaskCheckbox` form
morph (dashed proposal + haloed unread-context corner dot), Today moved off the
box to a right-edge amber chip, the agent cue lifted off the right edge,
`origin` provenance on `tasks_create` in **both** MCP servers (local default =
committed; gateway default = proposal) returning `placement`, and the gateway
`skill.md` doctrine. Verified via local MCP: `origin: agent_suggestion` →
`inbox_proposal` (lands in `triage`); omitted → `committed` (Anytime, not inbox).
Gateway **deployed** (`wrangler`); `acknowledgedAt` confirmed in the prod CK
schema so committed gateway writes stick. **Deferred:** the unread-context dot's
production trigger (§3.5), the sort-pill `↗`, the per-connection "tasks arrive
as" settings UI, the awaiting/dimmed state, and wiring a dashed/dot box tap to
*open the conversation* (today it still completes — §5).

Related: `docs/TRIAGE_BAND_SPEC.md` (the inbox/unratified layer),
`docs/TASK_CONVERSATIONS_PLAN.md` (the task-as-conversation model),
`docs/DesignSpec.md` §3 (row anatomy), §4 (color).

---

## 1. Principles (the rules everything below obeys)

1. **One control, one axis.** The leftmost control encodes a **single** axis —
   *readiness / whose-turn* — and nothing else. Sorting (a *location* axis) and
   discussion (*navigation*) never become left controls. Overloading the one
   control whose tap mutates state (completion) is the bug class we are avoiding
   (cf. the macOS "Space completes the task" trap in `CLAUDE.md`).
2. **Phase is carried by form, never by color.** Solid / dashed / dimmed-out /
   filled — the *shape* of the box tells you the state. No hue means "this is in
   the agent phase."
3. **Color is identity, only.** Section/area accents and the app accent are the
   sole color language (per `DesignSpec.md` §4). The one sanctioned *status*
   color is the temporal one (today/overdue), and it lives on a right-side chip,
   never on the structural control. (Open decision — see §8.)
4. **Left = readiness, right = location & time.** Two non-competing edges. The
   left morphs by state; the right holds the sort target, the date/today chip,
   and structural glyphs.
5. **Ratification is the inbox boundary.** A "proposal" is an *unratified* task.
   Sorting it into a place *is* the ratification. Therefore a proposal cannot
   exist outside the inbox — the dashed state is a property of the unratified
   zone.

---

## 2. Where we are now (as-is)

### 2.1 Row components

All task rows descend from a shared skeleton. Files:
`Septena/Shell/Tasks/TaskComponents.swift`, `TaskListView.swift`.

- **`TaskCheckbox`** (`TaskComponents.swift:74`) — rounded-square checkbox.
  - `tint: Color?` — section accent, used for the check-animation echo/ring.
  - `isToday: Bool` — when true, the box stroke **and** fill switch to
    `Theme.todayAccent` (amber). This is the "today-colored checkbox."
  - `feel: CheckFeel` — `.stamp` (tasks) / `.echo` (habits) celebration.
- **`CheckableRow<Trailing>`** (`:383`) — shared skeleton: optional leading
  emoji slot (tasks pass nil), title + optional subtitle `VStack`, a generic
  `trailing()` builder, and a selection highlight.
- **`TaskRow`** (`:496`) — the canonical task wrapper. Owns the trailing region:

  ```
  accessory (Inbox "file here") · date  →  recurrence · notes · status-dot
  ```

  - **accessory** — inboard-most, variable width. Only the Inbox passes it: the
    one-tap "file here" capsule (`TaskListView.suggestionCapsule(for:)`, ~`:1194`).
  - **`trailingDate`** (`:597`) — completed (✓ + date) / overdue (red, semibold) /
    future deadline (flag + date) / scheduled (calendar + date).
  - **recurrence / notes** — fixed micro-glyphs.
  - **status-dot** — a *single* slot, priority order (`:582`):
    1. `ConvoBadgeView(convo:)` — live conversation badge.
    2. `AgentCueMarker(tint: accent)` (`:345`) — `circle.fill` in the **section
       accent**, shown while `showsAgentCue()` (agent-created, unacknowledged).
    3. `ArrivedTodayMarker(tint: Theme.todayAccent)` (`:361`) — hollow `circle`
       in amber, shown while `showsArrivedToday()`.

- **Inbox sorter** — `SuggestionEngine.shared` (on-device, learned) suggests a
  destination list from the task title; `RemindersInboxSection.swift` +
  `suggestionCapsule`. **This is local, synchronous, not Claude/MCP.**

### 2.2 Data & derived flags (`SeptenaCore/Models.swift`)

- **`TaskSource`** (`:19`) — `"app"` or `"mcp"`. **No solicited-vs-volunteered
  distinction** — every MCP-authored task is treated the same.
- **`showsAgentCue()`** (`:96`) — `source == mcp && acknowledgedAt == nil &&
  within AgentCue.decayWindow (7d)`. Transient glow.
- **`isInTriageBand`** (`:152`) — open AND either (mcp → `showsAgentCue()`) or
  (human capture with no disposition: no scheduled/deadline/project/area, not
  today). The inbox/unratified population.
- **`showsArrivedToday()`** (`:109`) — non-agent "landed this morning" cue.
- **`isOverdue`** (`:121`) — deadline ≤ today (only a hard deadline reddens).
- **`isOnToday`** (`:132`) — today pin ∪ scheduled-arrived ∪ deadline-arrived.
- **`TaskConvo`** (`TaskConvo.swift:78`) — `confirmedIntent`, `acceptance`
  (agent-done bar, ≠ status), `thread: [ConvoTurn]`, `handoff`, `endState`,
  `assignee`, `isTerminal`.

### 2.3 AI / MCP surface

Two servers, edited in lockstep (`CLAUDE.md`): in-app `LocalMCPServer`
(`SeptenaCore/MCP/`) and the hosted gateway (`../septena-mcp-gateway`).

- **`tasks_create`** (`MCPToolCatalog.swift:82`) — inputs: `title`, `today`,
  `scheduled`, `deadline`, `area`, `project`, `notes`. **No `proposed` /
  acceptance seed.**
- Conversation tools: `tasks_thread_get/append`, `tasks_set_acceptance`,
  `tasks_set_endstate`, `tasks_set_handoff`, `tasks_set_artifact`,
  `tasks_set_assignee`, `tasks_pending_reasoning`.

---

## 3. Where we're going (to-be)

### 3.1 Left control — readiness vocabulary (form only)

| Form | State | Data source |
|---|---|---|
| **solid** `[ ]` | ready / committed | default (open, not in band) |
| **solid + accent dot** | committed, **unread context** | committed AND conversation has unread inbound (see §4.5) |
| **dashed** `[ ]` | **proposal** (unratified, agent-volunteered) | `isInTriageBand && source == mcp` |
| **filled + ✓** | done | `status == done` |

- **Dropped:** the *dimmed / "awaiting Claude"* form. Not in v1.
- The **dot's presence** = phase ("there's unread context"); the **dot's hue**
  = identity (section/app accent), reusing today's `AgentCueMarker(tint: accent)`.
  There is **no dedicated agent color.**
- **Human captures in the inbox stay solid.** Dashed is reserved for
  agent-*volunteered* proposals; a thing you typed is already committed, it just
  lacks a home. So `isInTriageBand && source == app` → **solid** (+ right pill).
- **Tappable:** the dashed box and the dotted box open the task conversation on
  tap (same destination as a row tap). Plain/done complete on tap as today.

### 3.2 Right slot — location & time

Precedence into the single flexible slot (micro-glyphs always ride along):

```
agent sort pill  ▸  date / today chip  ▸  (recurrence · notes glyphs)
```

- **Sort pill** (Inbox only) — the evolved "file here" capsule. Renders the
  destination (optionally `↗`) when the **local** sorter is confident; **silent**
  otherwise. One tap = file (ratify). The `↗` lives **here**, never on the
  checkbox. **Areas have no colors**, so the pill wears the Tasks/app accent — a
  destination-area tint isn't available.
- **Date / today chip** — `trailingDate` as today, but it is now the *only* home
  for "today" (see §3.3). Overdue keeps its red treatment (coexists with an
  agent pill as a small flag glyph — §8).
- The arrived-today cue ("landed in Today on its own", `showsArrivedToday`) is an
  **amber checkbox** (Things-style "new on Today"), not a right-edge dot. This is
  the one sanctioned place amber rides the *control*: it's the app's temporal
  identity color, the trigger is the *narrow* rollover-arrival condition (a
  scheduled/due plan whose day came — not every today task, not hand-added ones),
  and it self-clears at the next rollover, so the Today list never goes all-amber.

### 3.3 Color rules (the cleanup)

- **Remove `isToday` tinting from `TaskCheckbox`.** The box no longer turns
  amber. Today is communicated solely by the right-side chip. The checkbox stays
  neutral so *form* alone carries readiness.
- The only colors on a row: section/area **identity** accents (the dot, the sort
  pill's destination tint) and the **temporal** chip (today/overdue). Nothing
  else encodes state with color.

### 3.4 Provenance — how a task becomes dashed

The missing axis is **solicited vs volunteered**, orthogonal to `source`:

- *Solicited* — you asked (in-session "add a task…"). Committed → **solid**,
  placed where specified.
- *Volunteered* — a background agent proposed it (e.g. an email watcher, a
  meeting-transcript extractor). Unratified → **dashed**, lands in the inbox.

Both arrive via `tasks_create`, so provenance must be **declared**, not inferred.
Two mechanisms, used together:

1. **Per-connection default (the trust boundary).** Each MCP connection is
   classified *committed* or *proposal* source. Interactive Claude → committed;
   background watchers → proposal. A proposal-source task **always** lands in the
   inbox unratified — a background agent can never inject a committed task into a
   project/Today unreviewed. Lives in the connection ("Claude Access") settings:
   *"new tasks arrive as: Proposals (review first) / Committed."*
2. **Per-task override.** `tasks_create` gains `proposed: bool`. Lets a
   committed-source Claude drop a genuinely speculative item as a proposal.

**Resolution:** a task is dashed iff its effective acceptance is *pending* =
`proposed: true` OR (connection default = proposal, not overridden).

**Data-layer change.** Today `isInTriageBand` treats *all* mcp rows as proposals
(`source == mcp → showsAgentCue`). Target: it must key off the *proposed* seed,
not blanket `source == mcp`, so a **solicited** MCP task is committed/solid.
Implementation options:
- explicit field (recommended for clarity): seed an "unratified" provenance bit
  at creation; `isInTriageBand` (mcp branch) reads it; or
- reuse existing machinery: a *solicited* mcp task is created already-acknowledged
  (`acknowledgedAt = createdAt`) → `showsAgentCue` false → not in band → solid.

Both MCP servers + the gateway `skill.md` change in lockstep.

#### 3.4.1 Exposing provenance to *every* agent surface

Safety must **not** depend on an agent having read the skill — a future user will
wire up a third-party watcher that calls `tasks_create` naively. Two tracks:

**Track A — correct without the agent knowing anything (the safety floor).**
- **Omitting the provenance field resolves to the connection default
  *server-side* — never to a hardcoded `false`.** A naive agent that never sets
  it still gets the safe outcome: `effective = explicit ?? connectionDefault`.
- **New/unknown connections default to *proposal* (secure by default).** Plug in
  any agent, change no settings → worst case is "lands in the inbox to review,"
  never "committed into a project unreviewed." The user *promotes* a connection
  to committed once trusted.
- **First-party/local surfaces may auto-trust.** The local Claude Code server
  (loopback, static token, the user's own machine) → committed by default; the
  hosted gateway and third-party background agents → proposal until promoted.

**Track B — let capable agents do better (the exposed affordance).**
- **Schema (both servers).** Prefer an `origin` **enum** over a boolean —
  polarity-proof and extensible: `origin: "user_request" | "agent_suggestion"`
  (future: `"automation"`, `"import"`). Optional; omitted → connection default.
- **Description teaches the semantic, not the field:** "`agent_suggestion` if you
  surfaced this yourself (scanning email, transcripts, proactively) rather than
  the user asking for this exact task; `user_request` when they asked. Omit and
  the connection's trust setting decides."
- **Skill doctrine authored once.** Write the solicited-vs-volunteered paragraph
  in the **Tasks section skill brief**; `SectionRegistry.fullSkillMarkdown()`
  generates it into the gateway `skill.md`, so both surfaces carry one doctrine.
- **Tool result echoes the resolved state** — `{ id, placement: "inbox_proposal"
  | "committed" }` — so the agent observes the outcome and calibrates with no
  retraining.

Defense in depth: connection default = floor, `origin` = refinement, description
+ skill = teaching, result = reinforcement.

### 3.5 The dot trigger (out of scope here, render contract defined)

The dotted state = **committed task with unread inbound conversation content.**
This spec defines the *render contract* (dot iff committed AND unread inbound)
and a derived flag to drive it — e.g. `TaskConvo.hasUnreadInbound` (an inbound
turn newer than the user's last view/ack). **What makes Claude enrich a
committed task and post that inbound turn is the separate trigger work** (a task
pulled into Today with no next-step, a `blocked` mark, an aging untouched task,
or on-demand when the project is opened).

### 3.6 What changes vs today (delta summary)

- `TaskCheckbox`: add the readiness `form` (solid/dashed/dot/done); **remove**
  `isToday` amber tinting.
- Move the agent signal from the **right** status-dot slot to the **left** box:
  - `AgentCueMarker` (creation glow) → becomes the **dashed** box for proposals.
  - new committed-unread → the **left accent dot**.
  - `ConvoBadgeView` (right) → folds into the left dot / dashed semantics.
- Inbox "file here" capsule → confident `Destination ↗` pill, destination-tinted.
- `isInTriageBand` mcp branch → key off *proposed*, not raw `source == mcp`.
- `tasks_create` → add `proposed`; add per-connection default.

---

## 4. Surface behavior

- **Inbox (unratified):** solid (your capture) or dashed (agent proposal); right
  sort pill when the local sorter is confident. The band header carries "sort
  me"; no left dot here.
- **Area / project (committed):** always solid; left accent dot when there's
  unread context; right holds today/glyphs. No dashed, no proposals.
- **Today / Next (committed, flat):** same as area/project — solid + optional
  dot; today is intrinsic so the chip is suppressed as today.

---

## 5. Interaction

- tap **plain / done** box → toggle completion (unchanged).
- tap **dashed / dotted** box → open the task conversation (= row tap).
- tap **sort pill** → file to the suggested destination (ratify).
- row tap → task detail / conversation (`TaskDetailView` / `ConversationCard`).
- "Discuss" is **not** a control — it is the dot (signal) + the row tap (open).

---

## 6. Build plan

Ship behind a feature flag; one green build via `scripts/build.sh`.

1. `TaskCheckbox`: add `Readiness` form enum (`solid`, `dot`, `dashed`, plus
   existing done); render dashed border + haloed corner dot; drop `isToday`
   tint. Make `dot`/`dashed` tappable → open conversation.
2. `TaskRow`: relocate the agent signal from the trailing status-dot slot into
   the box form; keep `ConvoBadge` logic as the dot driver; rebuild the trailing
   precedence ladder (sort pill ▸ date/today ▸ glyphs).
3. Inbox capsule → destination-tinted `Label ↗` pill; confidence-gated
   (`SuggestionEngine`).
4. Data + agent surface (see §3.4 / §3.4.1): `isInTriageBand` mcp branch keys off
   the provenance seed (not raw `source == mcp`); add the `origin` enum to
   `tasks_create` in **both** servers, resolving omitted → connection default
   server-side; author the doctrine in the Tasks section skill brief (generates
   gateway `skill.md`); echo `placement` in the tool result; add the
   per-connection "tasks arrive as" default with **new connections =
   proposal**, first-party/local auto-trusted.
5. (Deferred-trigger-dependent) wire the committed-unread dot to
   `TaskConvo.hasUnreadInbound`.

---

## 7. Open decisions

- **Today-amber.** ~~Keep amber on the right today chip, or strip it?~~ **Resolved
  (broad):** amber is the app's temporal identity color. It rides the **checkbox**
  for a task that just *landed on Today on its own* (`showsArrivedToday`,
  Things-style "new on Today") and the right Today chip for today-pinned rows.
- **Awaiting state.** Dropped from v1. Re-add the dimmed box later if "don't poke
  this, it's mid-processing" proves needed.
- **Proposal-source override.** Is the per-connection "proposal" default
  **absolute** (background agents can *only* propose), or can a per-task
  `origin: user_request` commit? *Lean: absolute — the dashed layer's value is
  that nothing speculative reaches committed lists unreviewed.*
- **Provenance field shape.** `origin` enum (`user_request` /
  `agent_suggestion`, extensible) vs a bare `proposed` boolean. *Lean: enum —
  self-documenting and polarity-proof for agents that never read the doc.*
- **Auto-trust policy.** Confirm first-party/local (Claude Code loopback) is
  committed-by-default while all other new connections default to proposal.

---

## 8. Out of scope

- Area-identity color on the checkbox (rejected: color = identity, but the box
  must stay form-only for phase).
- A left "sorter" or "discuss" control (rejected: §1.1).
- The dot's production trigger (§3.5).
- Watch/compact collapse rules for the right slot (collapse the pill to the left
  signal when there's no room) — to be specified with the watch pass.
