# Drawer Modes — Log & Patterns

Spec for standardizing how section drawers display data. Today every section
hand-stacks "today's rows + (today-only) charts + time-travel" in one scroll, so
three different concepts share one surface and behave differently depending on
the date. This unifies them under one capability-driven scaffold and (where a
section warrants it) one toggle.

Status: **Phases 1 & 2 complete — built green on iOS + macOS, uncommitted.**
Code is the source of truth; when this spec and the code disagree, fix one of
them deliberately. Supersedes the earlier "Journal/Patterns" draft (renamed
Log/Patterns; now covers all 16 drawers).

Phase 2 (aggregate Patterns for the formerly single-mode loggables) is built:
shared `CompletionPatternsSection` (a `ConsistencyHeatmap`-backed aggregate
completion/adherence heatmap) drives Habits, Supplements, Chores, Medications;
Symptoms gets a bespoke severity-trend + rhythm-wheel pair. Groceries stays
single-mode (a stateless stock list, no time-series). GitHub/Activity remain
Patterns-only. Phase 2 sections default to Log with NO empty-state nudge — their
Logs are actionable checklists or "good when empty" event logs, not blank slates.

Built: `DrawerMode` enum + per-section persistence + `DrawerModeToggle` in
`SectionDrawer.swift`; the `mode:` binding (+ optional `modeStorageKey` for
per-instance memory like Intake kinds) renders the top-left toggle, hides the
calendar while in Patterns, forces Log on day-step, and hides the time-travel
pill in Patterns. Persistence lives in the toggle (explicit tap only), so the
empty-state nudge never sticks. Converted: **Sleep, Body** (read-only dual, no
nudge), **Gut, Mood, Training, Nutrition, Intake-kind** (editable dual, with the
one-shot empty-state nudge).

The 6 pure-data loggables (Habits, Supplements, Chores, Medications, Symptoms,
Groceries) and GitHub/Activity are single-mode — they pass no `mode` binding, so
they show no toggle and keep their current behavior unchanged. Phase 2 (aggregate
graphs that flip the 6 loggables to dual) remains future work.

## The model

A section drawer presents one of two modes — but only sections that have *both*
show a toggle. The toggle (top-left glass) switches:

| | **Log** | **Patterns** |
|---|---|---|
| Content | the list of individual records + point-in-time readouts | charts, heatmaps, rhythm wheels, trends |
| Scope | a single day | range-windowed (30 / 60 / 90 / 365 d) |
| Mutability | editable **iff user-authored**; read-only for provider data | read-only |
| Time travel | **owns it** — but only for user-authored Logs | none |
| Range picker | none | **owns it** |

The reframe that makes this DRY: time travel and "previous days" are not a third
thing — they are **Log, stepped to another date**. Patterns is cross-day and
read-only, so a day-stepper is meaningless there.

Two zones, not three. **Point-in-time readouts** (Sleep score rings, Body stat
tiles, today's macro totals) live at the **top of the Log view**, not in a
separate always-on header. They are the "standard" readout that sits above the
record list; flipping to Patterns swaps the whole thing for trends.

## Three capability flags per section

A section declares three orthogonal booleans; the scaffold (`SectionDrawer`)
draws chrome from them. No section hand-rolls "should I show a calendar."

- **`hasLog`** — has a records/readout list.
- **`hasPatterns`** — has a graphs/trends view.
- **`editable`** — the Log is user-authored (implies `hasLog`).

Derived chrome:

- **Mode toggle (top-left glass)** shown iff `hasLog && hasPatterns`.
- **Quick-add `+` (top-right, global, both modes)** shown iff `editable`.
- **Time-travel calendar** available iff `editable`, and only within Log mode.
- **Range picker** appears only within Patterns mode.

Note the change from the prior draft: quick-add tracks **`editable`**, not
`hasLog`. Body/Sleep have a Log view but are provider-dated — a records list with
no quick-add and no time travel.

## Per-section capability map (all 16)

| Section | hasLog | hasPatterns | editable | Toggle? |
|---|---|---|---|---|
| Training | ✓ | ✓ | ✓ | ✓ |
| Nutrition | ✓ | ✓ | ✓ | ✓ |
| Mood | ✓ | ✓ | ✓ | ✓ |
| Gut | ✓ | ✓ | ✓ | ✓ |
| Intake *(per-kind page)* | ✓ | ✓ | ✓ | ✓ |
| Body | ✓ | ✓ | ✓¹ | ✓ |
| Sleep | ✓ | ✓ | ✗ | ✓ |
| Habits | ✓ | ✗² | ✓ | — |
| Supplements | ✓ | ✗² | ✓ | — |
| Chores | ✓ | ✗² | ✓ | — |
| Medications | ✓ | ✗² | ✓ | — |
| Symptoms | ✓ | ✗² | ✓ | — |
| Groceries | ✓ | ✗² | ✓ | — |
| GitHub | ✗³ | ✓ | ✗ | — |
| Activity | ✗³ | ✓ | ✗ | — |
| Intake *(router)* | — | — | — | mode-less |
| Insights | — | — | — | no drawer |

¹ Body is `editable` iff manual weigh-in entry exists (it does today). If a
section's Log is purely provider-synced, set `editable = false` (like Sleep).
² **Patterns is a future feature** for the six pure-data loggables — there are no
section-level graphs today (streaks/heatmaps live only in the per-item
`LoggableDetailView`). They ship Log-only now; building aggregate graphs (e.g. an
all-habits completion heatmap) later flips `hasPatterns` true and the toggle
appears for free. This is net-new work, not part of the reshuffle.
³ GitHub and Activity are effectively graphs-only; their point-in-time readouts
(GitHub stat row, Activity vitals) sit atop the Patterns content. No Log list
worth a tab, so no toggle.

## Default mode on open

Mode is **per-section memory** (persisted per section key). Applies only to
sections that have a toggle. On open:

1. Restore the section's remembered mode, **except**
2. for **editable** dual sections: when remembered = Log **and** today has zero
   entries → show **Patterns** for this open only (empty-state nudge; don't
   persist it).
3. A manual toggle **always** persists.

Rationale: an empty Log first thing in the morning is a sad blank slate. Patterns
shows "nothing logged yet — here's your recent rhythm," and since `+` is global
top-right you can still log without leaving Patterns. The nudge does not apply to
read-only dual sections (Sleep) — there's no "today empty" authoring concept;
they just restore remembered mode.

(Decision: **memory-with-empty-nudge** over "memory-always-wins," to keep the
empty-state moment.)

## Time travel

- Time travel is a **Log-only** concept and exists only for **editable** Logs.
- Invoking it while in Patterns **forces Log** at the selected date.
- Stepping to a past day is a temporary excursion, not a mode change; returning
  to today restores the remembered mode.
- Patterns is never date-stepped. Provider-dated Logs (Sleep) have no time travel.

## Per-section content map (Log ⇄ Patterns)

What current content goes where. Nothing is deleted — it moves under a mode.

- **Training** — Log: active-draft CTA, session blocks, single-day sessions.
  Patterns: Z2 cardio, strength volume, muscle-load bars, progression picker
  (keeps its exercise + 30/60/90 controls).
- **Nutrition** — Log: today's macro totals (readout) + meal list + fasting gaps.
  Patterns: macro trend tiles (7-day mini-charts), "when you eat" rhythm wheel.
- **Mood** — Log: today's check-in list. Patterns: 30-day quadrant breakdown,
  "when you check in" rhythm wheel.
- **Gut** — Log: today's movements. Patterns: "when movements happen" wheel.
- **Body** — Log: stat grid (readout) + weigh-ins list. Patterns: 5 trend charts.
- **Sleep** — Log (read-only): score/duration readouts + last-14-nights list.
  Patterns: 4 trend charts.
- **Intake (per-kind)** — Log: the kind's entries. Patterns: its trend/wheel.
- **Habits / Supplements** — Log: today accordion + past-day rows. *(Patterns
  later: cross-item completion heatmap.)*
- **Chores / Medications / Symptoms / Groceries** — Log only (lists + summary
  strips). *(Patterns later if an aggregate graph is designed.)*
- **GitHub** — Patterns only: stat row (readout) + heatmap + sparkline.
- **Activity** — Patterns only: vitals readout + step chart (range picker).
- **Intake (router)** — mode-less; the split lives one level down on the kind
  page (`IntakeKindPageView`).

## Implementation sketch

Lands in the shared scaffold, not per section.

- **Types:** `enum DrawerMode { case log, patterns }`; a section passes its three
  capability flags (or a small `DrawerCapability` struct) + a `Binding<DrawerMode>`
  to `SectionDrawer`.
- **Scaffold (`Septena/Shell/Sections/SectionDrawer.swift`):**
  - Render top-left glass toggle iff `hasLog && hasPatterns`.
  - Render quick-add `+` iff `editable`.
  - Render calendar/`TimeTravelPill` iff `editable` **and** current mode `.log`;
    render range-picker slot iff current mode `.patterns`.
  - Invoking time travel sets mode → `.log`.
- **Persistence:** per-section remembered mode keyed by section `key`. The
  empty-nudge is computed at open from "today entry count == 0," never written.
- **Destinations:** each dual section splits its body into `logBody` and
  `patternsBody`; the scaffold shows one. The `isViewingToday` gymnastics
  largely disappear — Patterns is always cross-day; Log is always the selected
  day. Readouts move to the top of `logBody`.
- Log-only and Patterns-only sections pass the matching flags and get uniform
  chrome (no toggle, correct date control) for free.

## Phasing

1. **Phase 1 — the seven dual sections** (Training, Nutrition, Mood, Gut,
   Intake-kind, Body, Sleep): add the toggle + Log/Patterns split. Highest value,
   cleanest split. Sleep is the cleanest pilot.
2. **Phase 1 (cheap) — re-house the rest** onto the same scaffold: the six
   loggables as Log-only, GitHub/Activity as Patterns-only. Mostly a wrapper
   swap; no toggle appears.
3. **Phase 2 — aggregate graphs** for the six pure-data loggables (separate
   feature). Each one designed flips `hasPatterns` true and the toggle appears
   with no scaffold change.

## Out of scope / open

- Toggle as icon-swap button vs. 2-segment glass control (visual detail).
- ~~Patterns range picker unified vs per-section~~ — DONE: shared
  `DrawerRangePicker` + `DrawerRange` enum (section declares allowed windows);
  adopted by Training (30/60/90) and Activity (30/90/1y).
- watchOS unchanged — hand-wired per section, does not use this scaffold.
