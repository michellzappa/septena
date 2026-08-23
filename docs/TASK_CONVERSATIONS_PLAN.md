# Task Conversations — Plan

> **Shipped — historical, and still the design rationale.** The loop described
> here is built in both shells. Two things it calls for remain explicit v1
> non-goals: rendering `subtasks` (epic decompose) as more than stored ids, and
> any human override of assignee. This is the *why* document — read it for
> intent, not for current behavior.

**Goal (north star):** take the user from a *simple input* — a brain-dumped
title — to *meaningful progress on every task*, by having AI ground it in real
context, ask the few questions that clarify meaning and narrow scope, and route
each task to its meaningful next move. **Progress ≠ completion:** the loop
guarantees a next move for every task type, including the ones AI can't do
itself.

Turn every task page into a short agent-driven exchange that points toward a
solution. Not a chatbot bolted onto tasks — a **decision machine**: the agent
grounds the task, then hands you the smallest possible choice. Free text is the
escape hatch, never the default surface.

Status: **design dry-run done, nothing built.** Derived from two manual
walk-throughs of task `2zzxx2` (see Appendix). UX/data in §1–4, engine in §5–6,
build phasing in §7.

**Two constraints shape everything below:**

1. **Model-agnostic: ONE interaction contract in the backend.** Models are
   interchangeable *providers* behind a single protocol. Model choice is policy +
   UX affordance, never wiring. Add a better provider (e.g. Apple PCC as it
   improves) and the loop, data shape, queue, and mutators are untouched — §5.
2. **Septena offers no inference and holds no keys.** This is now just a
   *provider-admissibility rule* ("zero cost to Septena"), not an architectural
   fork: admissible = on-device, Apple PCC, or the user's own Claude. A hosted
   model Septena would pay for is simply inadmissible — §5.

## 1. The one idea

A task stops being a string and becomes a tiny state machine with a transcript.
The agent's job is **to shrink the open question to a few buttons**, not to
answer it for you and not to chat about it. Every turn the user takes is a tap.

The whole loop, in order — the first three steps are the product:

```
capture        you brain-dump a title
  ↓
❶ CONFIRM      agent plays back its reading as a choice card. HARD GATE.
  ↓            no grounding, no work, until you tap "yes, that one".
❷ GROUND       agent gathers context (file:line, links, people, sibling tasks)
  ↓            — and discovers the task's SIZE.
  ├─ if epic ─▶ ❸ʹ SCOPE   decompose into subtasks / MVP-first / defer-as-note.
  ↓                        sets endState=`decomposed`; children run their own loop.
❸ DECIDE       agent collapses the open question to 2–4 options + "Other",
  ↓            authors the acceptance line, hands you the card
  ↓
   WORK        agent does the doable part; you do the human last mile
  ↓
   END         a terminal end-state is recorded (§4)
```

**The loop is a state machine, not a fixed pipeline.** Grounding routes the path
— a single-loop task goes straight to ❸; an epic branches to ❸ʹ. Turns-to-
resolution is data-dependent (see non-negotiable #6).

## 2. Non-negotiables (each one cost us a wrong turn in the dry-run)

1. **Confirm is step 0, a hard gate.** A fresh task's first agent action is
   always a question, never an answer. Run 1 skipped this and "fixed" list-row
   padding for a page-padding complaint. The title `"Tasks has less padding"`
   had two readings; the agent silently picked one. The gate is the headline
   feature, not a nicety.

2. **Choice-card is the primitive, not a chat box.** `{question, options[2..4],
   Other}`. This matches Septena's tap-to-log grammar (works on watch, lock
   screen, Control Center) **and** forces discipline: to offer real options the
   agent *must* ground first. An open text question lets the agent stay vague; a
   card does not. The affordance enforces the method.

3. **Disposition is derived and re-evaluated every turn — never stamped.** In the
   dry-run a single task went `agent_doable → decision_needed → agent_doable →
   needs_verify`. Store the facts (confirm-state, acceptance, thread); *compute*
   disposition / stage / badge from them.

4. **Acceptance is agent-authored after grounding — not captured at intake.** You
   can't write "rows match at 16pt" from the title; it's invisible until the
   agent diffs the code. Capture = title only. The agent proposes the acceptance
   line back to you as part of step ❸.

5. **The agent shrinks the decision; it does not make it.** Taste calls
   (which gutter is canonical, what "Protocols" should become) stay yours. The
   agent pre-computes the trade-offs so the call takes one tap.

6. **Size is discovered, not given — never assume question → build.** `confirm`
   resolves *meaning*; `ground` reveals *size*. The `Protocols` dry-run proved
   it: one confirm tap → a 15-surface section build (`docs/ADDING_A_SECTION.md`).
   When grounding finds an epic, the loop branches to `scope` (decompose /
   MVP-first / defer-as-note) and **must not march to `work`.** This is the
   confirm-gate one level up: confirm guards meaning, scope guards size; both are
   "discover before you act."

## 3. Data shape

Split hard between **stored facts** and **derived view-state**. Only the left
column touches CloudKit.

### Stored (new fields on `TaskEntity`)

| field | type | who writes | notes |
|---|---|---|---|
| `confirmedIntent` | `String?` | agent, you approve | null until the step-0 gate passes. The agreed meaning. |
| `acceptance` | `String?` | agent | one falsifiable line; written during ❸ |
| `context` | `[ContextRef]` | agent | grounding: `file:line`, URLs, people, sibling task ids |
| `thread` | `[Turn]` | both | the decision log, below |
| `subtasks` | `[TaskRef]` | agent (on `scope`) | children an epic decomposed into; each runs its own loop |
| `assignee` | `me \| local \| claude` | user (override) | default = router-decided; user can **mark for Claude** to force it into the async queue (see §6) |
| `artifact` | `Artifact?` | agent | what the agent *produced* (`agent_assisted`): research, a table, a draft. CloudKit-backed like any field |
| `handoff` | `Handoff?` | agent | the human last-mile, rendered as the terminal action button: `{instruction, actionType: open_url\|compose\|call\|none, payload?}` |
| `endState` | `EndState?` | set at terminal only | §4 |

Two completion bars (do not conflate): **`acceptance` = the agent is done**
(deliverable met); **task `status` = the human is done** (last mile complete).
`agent_assisted` reaches `acceptance` while `status` stays open until the
`handoff` action is taken.

`Turn` (the decision-log unit — structured, not prose; corrected by the `2zzxx2`
and `Protocols` dry-runs):

```
Turn {
  seq:      Int
  role:     user | provider           // propose vs choose are SEPARATE turns
  step:     confirm | ground | scope | decide | work
  provider: onDevice | claude | null  // null = deterministic `compute`
  confidence: Double?                 // provider turns; the escalation trigger
  question: String?        // provider turns: the prompt
  options:  [String]?      // the buttons offered
  chosen:   String?        // user turns: which button…
  otherText: String?       // …or the free-text escape hatch
  inReplyTo: Int?          // user turn → the proposal turn it answers
  note:     String?        // narration
  ts:       Date
}
```

`confirmedIntent`/`acceptance` are **denormalized "current value" caches** of what
the thread already records — quick to read, never the source of truth. `confirm`
writes the turn *and* `confirmedIntent` in one atomic mutator save.

### Derived (computed, never stored)

- `disposition` — re-evaluated per turn: `agent_doable | agent_assisted |
  human_only | decision_needed | needs_verify | reference`
- `size` — `single | epic`, decided by `confirm`+`ground`; `epic` routes to `scope`
- `stage` — `open → clarifying → in_progress → awaiting_human → {terminal}`
- `pendingReasoning` — derived: a step no *sync* provider could resolve. Drives
  the queue an *async* provider (today: the user's Claude) drains (§6).
- `badge` / `nextAction` — **ball-in-whose-court**, the daily-driver signal:
  - 🟡 **Claude needs you** — open question in thread (incl. unconfirmed intent)
  - 🔵 **Claude working** — agent owns the next move
  - ⚪ **You only** — `human_only`; agent limited to reminders/breakdown
  - ✅ **Done** · ⚫ **Won't do**

Fresh task defaults to 🟡 — not because work is blocked, but because *intent* is.

## 4. End-states (open enum — runtime keeps minting new ones)

`agent_done` · `human_done` · `agent_assisted_done` · `needs_verify` (agent
shipped, human must eyeball — appeared unbidden in the `2zzxx2` dry-run when the
fix touched a SwiftUI `List`) · `decomposed` (an epic that became `subtasks[]`;
the parent's work now lives in the children — surfaced by the `Protocols`
dry-run) · `reminder_set` / `promoted_to_today` (`human_only` hand-offs — the
agent can't act, so it curates attention; see below) · `wont_do` · `open`.
Terminal states carry an optional `endStateNote` (e.g. `needs_verify`: *what* to
verify).

**Conversation end-state ≠ task status** (the `Pay Gemeente` dry-run). A
`human_only` task reaches a *conversation* terminal (`reminder_set`) while its
*task* `status` stays `open` until the human acts. Two axes — never overload
task status with the conversation's end-state.

**The agent curates attention on tasks it can't do.** For `human_only`, value =
surfacing the right lingering/timely tasks onto **Today** (= set `scheduled =
today`, per the today-boolean-retirement direction), or a reminder via the
existing local-notifications layer. **Bounded by a Today budget** — rank by
timeliness × importance, promote only the top few, hard daily cap (user-tunable).
"Curate, don't flood" is the load-bearing constraint; same shape as the
anti-stuck budget (§6).

The enum is deliberately not closed. Two of these (`needs_verify`, `decomposed`)
were not in the original list; the dry-runs surfaced them. Treat as append-only.

## 5. One interaction contract, pluggable model providers

The backend speaks **one protocol**; models are interchangeable adapters behind
it. This is the load-bearing decision: the loop, data shape, queue, and mutators
never reference a specific model.

**The contract — every reasoning step is a pure request:**

```
ReasoningRequest
  in:  { task, step, confirmedIntent?, context[], question, candidateOptions? }
  out: { options[]?, acceptance?, turn, endState?, confidence }
```

Swift `compute` produces the facts (`context[]`); the provider returns a
structured decision; `TaskMutator` applies it. The request never knows which
model answered.

**Provider — an adapter fulfilling requests, self-declaring:**

```
delivery:    sync (resolves inline) | asyncPull (parks, resolves on connect)
privacy:     onDevice | applePCC | userCloud
capability:  which steps/dispositions it handles + quality tier
cost/auth:   in-process free | user's own account
```

**Admissible providers** (the no-inference rule = "zero cost to Septena", one
policy line):
- **Apple on-device** (FoundationModels) — sync · onDevice · free
- **Apple Private Cloud Compute** — sync · applePCC · free to the app. *The bet:
  this improves; when it does, more steps resolve inline and the §6 queue shrinks
  with zero protocol change.*
- **the user's own Claude via MCP** — asyncPull · userCloud · user pays
- A hosted model Septena would pay for is **inadmissible**.

**Router** — per step, picks the most private / cheapest *capable* provider the
user's policy allows; escalates on low `confidence` or capability gap; if no
*sync* provider is capable, parks for an *async* one. UX surfaces this as a model
picker (`Auto` / `On-device only` / `Use my Claude`) and per-turn provenance
badges ("on-device" vs "↑ asked Claude") — affordances over the router, not
forks in the backend.

Mapping to the CLAUDE.md invariants:

- **Conversation lives in Septena, CloudKit-backed.** The task page IS the thread
  — syncs to watch/Mac, survives sessions, sits where its grounding sits.
- **Write path = a mutator.** Extend `TaskMutator` with `confirmIntent`,
  `appendTurn`, `setOptions`, `setAcceptance`, `setEndState`. Views, App Intents,
  **and the MCP gateway** all write through it — never the thread directly.
- **The MCP tools are ONE provider adapter** (the user's-Claude provider), not
  the mechanism. It brings its own brain and uses plain tools:
  `tasks_pending_reasoning` (the async queue) · `tasks_thread_get` ·
  `tasks_thread_append` · `tasks_set_options` · `tasks_set_acceptance` ·
  `tasks_set_endstate`. An Apple-model provider satisfies the *same*
  `ReasoningRequest` in-process and touches none of these. Gateway `skill.md`
  regenerates from `SectionRegistry.fullSkillMarkdown()` — keep in lockstep.
- **Schema** — new fields are additive (CloudKit prod deploy is additive-only);
  record in `docs/CloudKitSchema.md`. `Turn[]`/`context[]` serialize to a JSON
  blob field to avoid new record types.
- **Grounding (`compute`) runs in-app** (local SwiftData mirror, no token
  needed) regardless of provider. The async (Claude) provider's reads go
  gateway→CloudKit private DB with the user's `ckWebAuthToken` (server-to-server
  keys hit only the public DB) — already the path that works today.

## 6. Runtime — sync resolves inline, async parks in a queue

Delivery is a **provider property**, not an engine-wide trait. A `sync` provider
(Apple on-device/PCC) resolves a `ReasoningRequest` inline. An `asyncPull`
provider (today only the user's Claude) can't be initiated by the app, so its
requests **park in a reasoning queue and resolve when that provider connects.**

**The queue is the async-delivery mechanism, not a Claude-specific path.** As
sync providers grow capable, more steps resolve inline and the queue shrinks —
no protocol change. **Turn-based / cadence-bound is therefore the interim cost of
*async* providers**, accepted for now, not a property of the system forever.

**Mark-for-Claude = user-initiated routing (the queue's second feeder).** Beyond
the system's confidence-based escalation, the user can set `assignee = claude` to
push a task into `tasks_pending_reasoning` proactively — "don't step this
locally, my Claude takes it." Symmetric to the agent curating Today (bounded):
the agent hands the human a focused Today; the human hands the agent a marked
queue; each side **pulls**. The mark is also a per-task tempo choice
(foreground/stepwise vs handed-off/async).

*How far does a marked task run unattended?* **To the next gate that genuinely
needs the human** — the provider drains confirm→ground→decide→*reversible* work,
self-deciding what it's confident about, and bounces back to a 🟡 card only at a
genuine taste fork or an irreversible/outward action (the `handoff`). Carve-out:
marking raises autonomy but **does not waive the confirm-gate when meaning is
ambiguous** — an unclear title still returns 🟡 "what did you mean?", never a
guess. Self-confirm when confident; bounce when meaning or stakes are real.

**Two tempos, and the foreground one is action-based.** Foreground =
**press-to-advance**: nothing auto-runs; every step ends in a button (a choice
card to pick, or a `handoff` to act on), and the user advances one step per
press. Full control, no surprise, and a press resolves inline whenever the
chosen provider is `sync` (incl. a limited local model). Background = the
scheduled drain (§ above) for bulk/overnight — the only place async matters. This
is the answer to "how automatic?": foreground zero-auto, background batched.

**The loop (provider-neutral):**

```
capture → ❶ confirm (a provider drafts the playback card; the gate stays manual)
        → ❷ ground  (Swift `compute` — facts, file:line, refs; provider-agnostic)
        → ❸ decide  (router picks a provider; sync → options inline;
                      no capable sync provider → park in `pendingReasoning`)
        → an async provider (manual or scheduled) drains the queue:
            reads task + context, writes options / acceptance / Turn back
        → app renders the result as a choice-card; user taps; tap writes back
        → ❹ work → END
```

**This already runs by hand.** A Claude Code session on the MCP gateway *is* the
queue-drainer — this plan was produced that way (see Appendix). The build just
formalizes the round-trip into structured fields.

**Initiation / cadence** — the only automation knob, and it stays the user's:
- *Manual* — open Claude, "work my Septena queue."
- *Scheduled* — a **user-owned** Claude Code routine (`/schedule` / cron):
  "each morning, connect to the Septena MCP and drain `tasks_pending_reasoning`."
  Septena ships no scheduler of its own.

**Anti-stuck brakes** (enforced in-app *and* as MCP-tool guards, so a runaway
scheduled routine can't thrash the queue):
1. **Step fingerprint** — hash `(step, input-state)`; a recurrence → halt, flip
   to 🟡 "stuck here". The `thread[]` is the dedup substrate.
2. **Progress requirement** — a turn must change state (new context / option /
   end-state) or it doesn't count; no-progress turns trip the breaker.
3. **Budget caps** — max turns / task / day; the gateway rejects over-budget calls.
4. **No re-asking settled questions** — check `confirmedIntent` before `confirm`;
   never re-litigate (Run 1's exact failure).

## 7. Build phasing

- **Phase 0 — plumbing, no UI.** Stored fields + `TaskMutator` methods + the MCP
  tools above. Prove a turn round-trips CloudKit from a hand-driven Claude
  session. Disposition/stage derived in code, logged not shown.
- **Phase 1 — the gate + the card.** Confirm-gate and choice-card UI on the task
  detail, for one disposition (`agent_doable` code tasks). Layer 2 only (the
  user's Claude); no on-device model yet. Smallest thing that shows the idea.
- **Phase 2 — grounding + badges + the queue.** Layer-1 Swift compute authors
  `context`/`acceptance`; `needsClaude` + the 🟡/🔵/⚪ badge land in the list so
  the backlog becomes a triage queue.
- **Phase 3 — full disposition + end-states + decision-log view + anti-stuck.**
- **Phase 4 — frictionless capture + scheduled-routine recipe.** Brain-dump a
  title anywhere (watch/Control Center); document the user-owned scheduled
  drainer. Apple on-device model (Layer 1 interpret) optional here.

## 8. Open risks / unresolved

- **Cadence latency is a property of *async* providers, not the system.** With
  only the user's Claude (async) today, answers land when it connects. As a
  capable *sync* provider (Apple PCC) qualifies, that step's latency vanishes
  with no protocol change. The interim cost is real but self-resolving.
- **Provider capability is unmodelled.** The router needs each provider to
  declare which steps/dispositions it can handle at what quality — and a fallback
  chain when the chosen one fails or returns low `confidence`. Designed, not
  specified.
- **Offline / no capable provider.** A step no sync provider can do, with no
  async provider connected, parks at 🟡 indefinitely. `compute` + the best
  available sync provider must resolve as much as possible so the app is useful
  with zero Claude ever connected.
- **Scope discipline.** `human_only` tasks (door handles, payments) want
  reminders, not conversations. Only agent-eligible dispositions get the
  conversation UI; everything else stays a plain row.
- **Resolved — "is Apple on-device worth v1?"** Dissolved by the provider seam:
  you don't decide per-model. Build the one contract; ship with whatever
  providers are admissible now (at minimum the user's Claude); register Apple
  on-device/PCC as providers when they qualify. No fork either way.

---

## Appendix — the two dry-runs (empirical basis)

**Run 1 (wrong).** Task `2zzxx2` "Tasks has less padding than next and week".
Agent skipped confirm, grounded the *list rows*: Tasks rows `Theme.hPadding`
(12 iOS) vs Next rows `rowHInset`/`Spacing.xl` (16). Proposed a fix. **User: wrong
target — I meant the page, not the rows.** → birthed non-negotiable #1.

**Run 2 (right).** Confirmed first (page-level inset across the 4 main tabs).
Grounded: no shared page gutter exists — Tasks is the only tab built on a
SwiftUI `List` (wide system margins / `listLeadingInset=20` on iPad), while
Week/Next use `Theme.pageGutter=12` and Goals hardcodes 16. Offered a choice
card; user chose **unify all four on one gutter**. Honest end-state:
`needs_verify` (the `List` margin can't be confirmed from source). → birthed the
choice-card-forces-grounding finding and the `needs_verify` end-state.
