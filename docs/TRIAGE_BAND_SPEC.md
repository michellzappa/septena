# Triage Band — Inbox *over* Today

**Status:** **Built + fully unified, rendered as a native "Inbox" section** —
Inbox is a normal section (area-style header, standard checkbox rows, all items)
on top of Today, on both the drawer and the full Tasks tab; the separate Inbox
page is retired. iOS + macOS + core tests green, uncommitted · **Date:**
2026-06-14. Code is the source of truth; when this spec and the code disagree,
fix one of them deliberately.

## Built (Phase 1 + full unify)

The band is the Today experience **everywhere**, and the separate Inbox page is
retired — one Today, no parallel inbox. iOS + macOS + 39 core tests green.

- **Model.** `isInTriageBand` added to both `TaskEntity` (`Persistence.swift`)
  and `SeptenaTask` (`Models.swift`) as mirrored single-sources, plus a
  `.triage` `TaskFilter` case (+ `convert` + a `"triage"` read view in
  `TaskReads`). The agent arm **reuses `showsAgentCue`**, so band == cue for
  agent rows and cue-decay doubles as ratification-by-timeout (§7).
- **`.today` now means ratified-and-due, globally.** `convert(.today)` excludes
  band members (`isOnToday && !isInTriageBand`), so unratified rows never appear
  in any Today surface — the invariant (§1) holds app-wide. This deliberately
  also keeps unratified agent proposals **out of the Next feed** until ratified
  (Next reads `.today`), which is the correct "Next = committed" behavior.
- **Inbox is a native section, not a bespoke widget** (revised per user
  feedback). It's rendered like any other group — labelled **"Inbox"**, header
  styled exactly like the area headers, with **standard task rows (checkbox,
  swipe, context menu)**, and **all items shown** (no cap / fold / collapse).
  - **Full Tasks tab** (`TaskListView`): `triageSection` = a `Section` with a
    **foldable** `inboxHeader` (same anatomy as the area `groupHeader` — tray
    icon, title, hairline — plus a live **count** and a fold chevron; tap to
    collapse/expand) over the canonical `row()`, on top of the Today groups.
  - **Drawer** (`TasksDestinationView`): a `DrawerSection("Inbox")` of `TaskRow`s
    above the "Today" section. (Fold/count not yet wired here — `DrawerSection`
    chrome change; follow-up.)
  - **No swipe actions on task rows** (removed by request — completion is the
    checkbox, everything else the menu). Inbox rows carry a visible trailing
    **`⋯` menu** (`row(quickMenu:)`) that opens the shared `rowActionsMenu`
    (Today / When / Move / Someday / Drop…) — one tap, not a hidden long-press.
  - **Triage *is* the normal task interaction** — no chips, no "Accept all".
    Complete (checkbox), open-to-edit, or the `⋯` menu. Each acknowledges an
    agent row so a dispositioned proposal leaves the Inbox: `flipStatus`/complete
    + the composer already acknowledged; added `acknowledge` to `applyMove`,
    `applyWhen`, and the context-menu `onMoveToToday`. The bespoke
    `TriageBandView` was **deleted**.
- **Separate Inbox *page* retired.** Removed the Inbox sidebar smart-list row;
  "New To-Do" now lands on Today (`SidebarView`). Dashboard Tasks tile + headline
  stat changed to **"Inbox"** backed by `triageCount` (so it counts the to-sort
  pile, not the old loose-only inbox), and the quick-add menu dropped "Go to
  Inbox" (`WeekTasksTile`, `tasksTile`, `tasksDomainData`, `TasksQuickAddMenu`).
  The `.inbox` `TaskFilter` case survives only as a loose-capture *create seed*
  and the (now unlisted) Reminders-setup route, not a navigable list.
- **Reminders import relocated.** Pending Apple Reminders are unratified
  captures too, so `RemindersInboxSection` now also renders on Today
  (`showsSetupCTAs: false` — only actual pending imports show; no setup prompt
  clutters Today for unconfigured users). Full setup CTAs remain on the (now
  unlisted) `.inbox` route.
- **Counts.** New `triageCount` on `TasksCounts`, computed in both
  `TaskReads.localCounts` and the sidebar aggregate; `todayCount` now excludes
  the band in both.
- **MCP (both servers, lockstep).** `tasks_list` gains a `view: "triage"` —
  in-app (`MCPDispatch` + `MCPToolCatalog`) and the hosted gateway
  (`listTasks.ts`: reads `source`/`acknowledgedAt`/`createdAt`, ports
  `isInTriageBand` incl. the 7-day cue-decay, adds the `triage` matcher) +
  `mcp.ts` description + `skill.md`. The gateway's `today` matcher was also
  brought back into lockstep (now excludes the band, matching the in-app
  `.today` change). The gateway skill now teaches that **everything the agent
  creates is a proposal** that lands in `triage` (since gateway creates carry
  `source: "mcp"`), not directly in `today`. Gateway typecheck clean.
> **Design note (revised 2026-06-14):** the first cut was a bespoke
> `TriageBandView` card (chips, Accept-all, cap, collapse). User feedback: make
> it look native — say "Inbox", header like the area headers, normal task rows
> with checkboxes, show everything. So the card was replaced by a plain section
> reusing the existing `groupHeader` + canonical row, and `TriageBandView` was
> deleted. Triage actions are now just the standard task affordances.

**Pending (needs the user):** **deploy the gateway** (`wrangler deploy`) so
`view:"triage"` goes live for consumer chat — an outward/production action, not
auto-run; it also depends on the prod CloudKit schema carrying
`source`/`createdAt`/`acknowledgedAt` (the existing prod-schema-deploy backlog),
without which the agent arm degrades gracefully (no `createdAt` → not band-held).

**Deferred** (noted, not built): a richer MCP *propose/accept* verb pair (so the
human's one-tap accept is reachable programmatically and the agent can learn
acceptance rates — the read-side `triage` view is enough for now); dashboard
tile triage-count *badge* on the glyph (the stat is wired, a badge is cosmetic);
Things-style swipe gestures and keyboard triage (interaction polish — held back
because the band renders as a card, not List rows, so both need restructuring +
on-device testing); a `SeptenaCore` unit test for the predicate (the DTO's
`SeptenaTask(TaskEntity)` init couples `Models.swift` to SwiftData, so it can't
join the curated pure-logic test target without a cascade — left out to keep the
suite green).

---

### Original spec / proposal

The question this answers: should Tasks have an **Inbox** separate from **Today**?
Answer: yes, the two are distinct — but they are **not two lists**. The inbox is
the *unratified layer of today*. It sits **on top of** the Today list, in the same
scroll, divided by a clean line. One surface, two planes.

The reframe that makes this work: a filling inbox isn't separate from your day,
it's **meta** to it — the stuff that hasn't yet earned a place in the day. So you
render it where that's literally true: above the day, in the way *just enough* to
invite clearing, never enough to block.

This is the Tasks-specific instance of a broader app pattern — a **proposal plane**
(agent proposes / human-captures-loosely) sitting above a **committed plane**
(trusted, do-now). See §8.

---

## 1. The load-bearing invariant

**Nothing unratified ever touches Today.** The moment an un-blessed item (agent
proposal, or a loose capture) renders *inside* the committed Today list, Today
stops being trusted — and an untrusted list is a dead list (the one GTD failure
mode that kills the whole system). The triage band is the quarantine that keeps
Today sacred. Everything else in this spec is tunable; this wall is not.

---

## 2. One surface, two planes

The Tasks "Today" surface renders top-to-bottom:

```
┌─────────────────────────────────────┐
│  ▾ To sort · 3        [Accept all]   │   ← Triage band  (UNRATIFIED plane)
│    • Email Dr. Sayid     → Today  ⌄  │
│    • Renew passport      → Fri    ⌄  │
│    • idea: gut x sleep   → Drop   ⌄  │
├──────────────────────────────────────┤   ← the clean division (ratification line)
│  TODAY                                │   ← Today list   (COMMITTED plane)
│    ☐ Ship triage spec                 │
│    ☐ 20m zone-2                        │
│    ☐ Call mum                          │
└─────────────────────────────────────┘
```

- **Top = the triage band.** Open items that have **not been ratified**: loose
  human captures *and* agent proposals. Each agent-touched row shows a **proposed
  disposition chip** inline (`→ Today`, `→ Fri`, `→ Errands`, `→ Drop`).
- **The line = ratification**, not date (§3).
- **Bottom = Today.** Only ratified items whose time is now. Untouched by the band.

Crucially, **ratifying a band item moves it across the line in view** — you watch
the day below assemble as you clear the band above. That co-visibility is the
entire reason this beats a separate Inbox tab.

The band is **collapsible** (`▾`/`▸`) and remembers collapsed/expanded per
launch-session. Collapsed it's a one-line summary (`▸ To sort · 3 [Accept all]`).
It **never blocks** scrolling to Today. Empty → the band is **absent**, not an
empty-state placeholder (no guilt surface).

---

## 3. The division is *ratification*, not date

Current model defines Inbox by *absence* (`no scheduled && no due && no project &&
!today`). That breaks the moment an agent proposes a task *with* a suggested date —
it would have a date but still not be blessed. So the band's membership is defined
by **ratification state**:

An open task is **in the triage band** iff it is *unratified*, i.e. **either**:

1. **Loose human capture** — `source != mcp`, and `scheduled == nil && due == nil
   && project == nil && area == nil && !today && status == open`. (Today's Inbox
   definition, unchanged.)
2. **Unacknowledged agent proposal** — `source == mcp && acknowledgedAt == nil &&
   status == open`, **regardless** of any `scheduled` / `project` the agent
   attached. The agent's suggested fields render as the *proposed disposition
   chip*; they are not yet authoritative for Today membership.

An item **leaves the band** the instant it is ratified:

- tap a disposition (§4) → fields applied **+** `acknowledgedAt = now` (for agent
  rows) → it either drops into Today below, or leaves this surface (later/someday),
  or is gone (drop).
- For agent rows, "ratify" reuses the **existing** `acknowledgedAt` clear — the
  same field that today decays the agent-cue glow. The band is the agent cue's
  natural home.

**Today list membership** is unchanged (`isOnToday`) *minus* the band set — i.e.
ratified-and-due-today. Concretely, `Today list = isOnToday && !inTriageBand`. An
unacknowledged agent task with `scheduled == today` is in the **band**, not the
list, until blessed. This is the one real change to the existing predicates.

---

## 4. The triage verb-set (the whole game)

From a band row, the disposition actions — and nothing else — are:

| Verb | Effect | Lands |
|---|---|---|
| **Today** | `scheduled = today` (today-flag during transition; see §7) | Today list, below |
| **Schedule…** | `scheduled = <date>` | Upcoming (off this surface) |
| **Project / Area…** | assign container, no date | Anytime (off this surface) |
| **Someday** | `status = someday` | Someday (off this surface) |
| **Drop** | `status = cancelled` | gone |

For agent rows, the agent's proposal **pre-selects** one verb (the inline chip);
the human ratifies with **one tap on the chip**, or expands (`⌄`) to override. The
band header offers **Accept all** when every row carries a proposal — clearing the
band in a single action. This is the Task-Conversations choice-card model
([docs/TASK_CONVERSATIONS_PLAN.md](docs/TASK_CONVERSATIONS_PLAN.md)) pointed at
*triage* instead of execution: options-not-chat, confirm-gated, one tap.

### Confirmation is human, but must be *effortless* (design mandate)

**Decision: the human always ratifies — the agent never auto-commits into Today.**
The §1 wall is absolute. But the cost of that decision is paid entirely in UX: if
confirming is slow, a busy user abandons the band and it rots. So *making
confirmation trivial* is a first-class requirement, not polish. The disposition a
user reaches for most (→ Today, → a known project) must be the cheapest motion on
every input:

- **Tap** — tapping the proposed chip *is* the accept (no second confirm step).
  The expand (`⌄`) is only for overriding, which is the rare path.
- **Swipe** — Things-style row swipes: swipe one way = accept the proposal (or
  → Today if none), the other = Someday/Drop. Triage a band without ever expanding
  a row.
- **Accept all** — the header one-tap when every row carries a confident proposal;
  the steady-state morning gesture.
- **Keyboard (Mac / iPad)** — the band participates in the existing keyboard-nav
  model ([memory: keyboard navigation]): arrow through rows, `Return` accepts the
  proposed disposition, dedicated keys for Today / Schedule / Drop, `⌘↩` accept-all.
  Triage a full band without the mouse.
- **Sensible default target** — loose captures with no agent proposal still offer
  → Today as the primary, pre-focused verb, so even an un-triaged-by-agent row is
  one tap from committed.

The bar: clearing a 5-item band the agent pre-sorted should be **one gesture**
(Accept all); overriding any single row should be **one more**. If triage ever
feels like data entry, the design has failed.

Asymmetric friction (the GTD capture/clarify split, preserved):

- **Capture INTO the band is zero-friction** — quick-add, App Intents, watch, MCP
  all drop loose items into the band; the count ticks; you never expand it to add.
- **Clearing the band is deliberate** — you expand and triage on purpose, so it
  never pollutes execution attention.

---

## 5. The agent's role

The band is the **human↔agent handoff surface** for tasks. Two populations, both
inbox-shaped because both are *captured-but-not-committed*:

- **Human captures, agent triages.** You fire a task at a stoplight; the agent
  later proposes a disposition (project, date, dup-flag). Next time you open, it's
  a one-tap chip, not a blank decision.
- **Agent captures, human approves.** Agent derives tasks (from mail, calendar,
  commits, other sections) → they land in the band as proposals with `source=mcp`,
  **never** straight into Today (the §1 wall).

Steady state for a busy, agent-assisted user: open app → band: *"sorted 5 — accept?"*
→ one tap → band gone, day below is ready. **Inbox-zero becomes a background
process, not a human chore** — which is the only thing that makes "inbox on top"
livable instead of a wall of guilt. The band can't rot because something is always
grooming it.

This also absorbs GTD's **weekly review**: instead of you processing to zero, the
agent pre-triages continuously and you do a fast confirm/adjust pass.

---

## 6. New back-of-pipe state: *Waiting (on agent)*

The agent era adds a state at the *back* of the pipe, not just the front. With
`tasks_set_assignee` an item can be **delegated to the agent and in progress** —
neither band (it's ratified) nor Today (you're not acting; you're blocked-waiting).
This is GTD's "Waiting For," reborn.

- Render as a third, **muted** zone *below* Today (or a Today subsection): "Waiting
  on Claude · 2". Not in the band (no decision needed), not in the actionable list
  (you can't act).
- Returns to Today (or the band, if the agent proposes a follow-up) when the agent
  completes or needs ratification.
- Out of scope for v1 if assignee-driven delegation isn't wired end-to-end yet;
  list here so the topology is complete.

Full agent-era task topology:

```
   CAPTURE          TRIAGE BAND        COMMITTED            WAITING            DONE
 (0-friction)  →   (unratified)   →  Today / Upcoming  →  (on agent)    →   done
                    human + agent      Anytime/Someday      delegated
```

---

## 7. Interaction with the `today`-flag retirement

The in-flight "today boolean retirement" ([memory], `isOnToday` collapsing to
`scheduled == today`) **simplifies** this, it doesn't fight it:

- "Triage → Today" becomes purely `scheduled = today`.
- Band membership (loose capture) becomes `scheduled == nil && project == nil &&
  area == nil && status == open` — no `today` flag to consult.
- Today list = `scheduled == today && ratified`.

Until the flag is gone, "Today" verb sets the flag *and* `scheduled=today` as it
does now; band logic treats `today == true && acknowledgedAt == nil && source==mcp`
as still-in-band (an agent *proposing* a pin is unratified). Net: build the band on
the **ratification** predicate now, and the flag retirement just deletes a clause.

---

## 8. The bigger pattern (why this matters beyond Tasks)

Inbox-over-Today is the first and sharpest instance of a pattern the whole
agent-assisted app wants: a **proposal plane** above a **committed plane**.
Provenance (`source`) and the agent-cue decay already exist app-wide. The same
band shape generalizes:

- **Habits / Supplements** — agent proposes a new habit to track → band over the
  list → ratify.
- **Correlations** ([memory: smart correlations]) — "I found a candidate: gut ×
  sleep — track it?" is a triage decision.
- **Groceries** — agent infers low stock → proposes add → ratify.

Designing this as "Proposed vs Committed" (not "Inbox vs Today") means solving the
interaction model for the agent-assisted app once. Tasks is just where the need is
most acute. **Not v1 scope** — but name it so the band component is built generic
enough to reuse (a `ProposalBand` over any committed list).

---

## 9. Surfaces

- **Tasks → Today (primary).** The band-over-list described above. Primary build.
- **Dashboard tasks tile.** Show a **triage count badge** ("3 to sort") when the
  band is non-empty; tapping deep-links into the band. The dial/home stays the
  ambient orientation layer — the band lives one level in, on the Tasks surface,
  not stacked on the dial.
- **Quick-add (everywhere).** All capture paths land loose → into the band. No
  capture path requires choosing a disposition (that's what the band is for).
- **Watch.** Capture into band (already loose). Triage verbs are a stretch;
  surfacing "N to sort" as a glance is cheap. Full triage UI = later.
- **App Intents / Siri.** "Add task X" → band. "What do I need to sort?" → band
  count + titles.

---

## 10. MCP implications (both servers, lockstep)

Per the MCP lockstep rule, any of this that touches tools lands in **both** the
in-app server (`SeptenaCore/MCP/`) and the hosted gateway, plus skill briefs.

- `tasks_pending_reasoning` already exposes the agent's queue; align it with the
  **band membership** predicate so "what's pending" = "what's in triage."
- A **propose-disposition** path: the agent attaches suggested `scheduled` /
  `project` to an `mcp`-sourced task *without* ratifying it (stays in band). Today
  `tasks_create` with a date would currently read as committed — the
  ratification-not-date rule (§3) fixes that: agent-sourced + `acknowledgedAt==nil`
  = proposal regardless of date. Document this so the gateway and in-app agree.
- A **ratify/accept** verb (or reuse `tasks_set_acceptance` / acknowledge) so the
  human's one-tap accept is also reachable programmatically and the agent learns
  acceptance rates.

---

## 11. Product decisions

**Resolved (2026-06-14):**

- ✅ **Ratification is always human; no agent auto-commit.** The §1 wall is
  absolute — the agent proposes, the human disposes. The cost is paid in UX:
  *effortless confirmation* is a design mandate (§4 "Confirmation is human, but
  must be effortless"), not optional polish.
- ✅ **Loose human captures STAY in the band.** No auto-aging into Anytime. The
  band-in-your-way is the deliberate forcing function; agent grooming (proposing
  dispositions on your own captures, not just its own) is the relief valve. A
  capture you never triage sits in the band until you do.
- ✅ **Tasks-only for v1.** Build the band for the Tasks Today surface only. Still
  build it as a reusable `ProposalBand` internally (§8) so a later second consumer
  is cheap, but wire exactly one consumer now. The cross-app proposal plane is
  explicitly out of v1 scope.

**Still open (lower-stakes, callable during build):**

1. **Band label / tone.** "To sort" vs "Inbox" vs "New" vs "Triage". Lean **"To
   sort"** (verb-forward, calm, implies it should empty). Count only when
   non-empty; never red/alarm styling.
2. **Default collapsed or expanded?** Lean **collapsed-with-count by default**,
   auto-expand only when the agent has high-confidence proposals ready (so the
   "accept all" moment is one tap from open). Mirrors the drawer-modes
   empty-nudge philosophy ([docs/DRAWER_MODES_SPEC.md](docs/DRAWER_MODES_SPEC.md)).
3. **Cap & overflow.** Show top N rows + "12 more" so a fat band never becomes a
   wall. N = ? (lean 5). Sort: agent-proposed-with-disposition first (one-tap
   wins), naked captures second.
4. **Waiting-on-agent (§6):** deferred until assignee delegation is wired
   end-to-end. Reserve the zone, don't build it in v1.

---

## 12. Suggested sequencing

1. **Phase 1 — the band, tasks-only.** Build `ProposalBand` over the Today list in
   the Tasks destination. Ratification predicate (§3), the 5 verbs (§4), collapse,
   absent-when-empty, dashboard count badge. Wire agent rows to existing
   `source`/`acknowledgedAt`. iOS + macOS.
2. **Phase 2 — agent proposal loop.** `tasks_pending_reasoning` ↔ band alignment,
   propose-disposition + accept verbs in **both** MCP surfaces + skill briefs,
   "Accept all." This is where the steady-state magic turns on.
3. **Phase 3 — generalize.** Lift `ProposalBand` to a reusable proposal plane;
   pick a second consumer (correlations or habits). Add Waiting-on-agent if
   delegation is ready.
4. **Watch / Intents glance surfaces** alongside as cheap adds.
