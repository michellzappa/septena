# Pinned goals — plan

(Supersedes the earlier "hero habits" idea.)

The thing that started as "elevate one habit to a hero tile" turned out to be
**goal-work in disguise**. A prominent, tracked target with progress + history *is*
the Goal shape. So the real, generalizable feature is two small reuses of the
existing Goals system:

1. **A goal can target a single habit** — a per-habit completion metric, so you
   can say "do Surya namaskar daily, 7/week", not just the aggregate "habits done
   today".
2. **A goal can be pinned to the dashboard** — rendered as a tile at the top of
   the Week dashboard.

Then "Surya is more important than my other habits" = a habit (the data) + a goal
"do Surya daily" + that goal pinned. This **subsumes** the hero-habit idea and
generalizes far past it: you can pin *any* target to your front door — training
sets, body weight, a macro band — not just habits.

## Why this, not an `isHero` flag on habits

What the mocked tile was visualizing (streak + `90-day 94%` + progress) is a goal
metric. The codebase confirms the overlap and the two gaps:

- Goals already exist with full metric machinery: `GoalEntity` with
  `metricKey` / `metricWindow` / `metricComparator` / `metricTarget` /
  `metricTargetUpper` (`SeptenaCore/Persistence.swift:492`), evaluated per-section
  via `evaluateAim(metric:context:)`. "A target IS a goal" is already the model.
- **Gap 1:** habits only expose *aggregate* metrics — `habits.done_today`,
  `habits.days_active_week` (`HabitsPlugin.swift:121`). No per-habit metric, so a
  single habit isn't targetable yet.
- **Gap 2:** goals have **no dashboard presence** — no `goals` case in
  `HomepageDomain`, no pin. They live in the Coach surface (`GoalsView`) and the
  per-section `SectionGoalsStrip` only.

Bolting an `isHero` boolean onto habits would (a) be a bespoke one-off that doesn't
generalize, and (b) partly duplicate what goals already do. Pinning goals reuses
the central Goals system and builds the missing piece once.

## What stays from the hero-tile mock

The full-width tile design (informed by `DesignSpec.md` / `Theme.swift` /
`ModuleTile`) is still correct — it's just **backed by a goal, not a flag**:

- Full-width `ModuleTile`, 22pt radius, 3pt left accent stripe (the goal's section
  color), 28pt glyph badge.
- Headline stat in `SF Mono` (`.septenaMetric`): the goal's progress
  (current / target), reusing `GoalMetricProgressView`'s caption + bar logic.
- **History** adapts to the goal's metric:
  - goal targets a **habit** → borrow the underlying habit's **consistency
    heatmap** (`ConsistencyHeatmap`, the 12×12 ramp) — this is where the
    streak/chain lives (the one piece that's habit-not-goal; streaks come from
    `GoalMilestoneEntity`, surfaced here).
  - goal targets a **count/sum** (training sets, cups) → the histogram primitive.
  - goal targets a **latest value** (weight) → sparkline toward the target/band.
- **Today tap-target** — when the goal is habit-backed, a check ring completes the
  habit from the dashboard (the only genuinely new affordance vs. a normal tile).

## Implementation

1. **Per-habit goal metric** — `HabitsPlugin`: override
   `aimMetrics(context:) -> [GoalMetric]` to generate one (or a small set) per
   `HabitDefinitionEntity`, mirroring `IntakePlugin`'s per-kind generation
   (`IntakePlugin.swift:180`). Keys use the stable habit id, e.g.
   `habits.<habitID>.done_week` / `.done_today`. Extend `evaluateAim` to read
   `HabitDayStateEntity` filtered to that habit. (Keep the existing aggregate
   metrics too.)
2. **Pin flag on goals** — `GoalEntity`: add `pinned: Bool = false` (+ reuse
   `sortIndex` for pin order). Additive CloudKit field — safe to read before a Prod
   schema deploy; deploy on the normal cadence before relying on cross-device sync.
   Mirror in `GoalRecord.swift`.
3. **Mutator** — `GoalMutator.setPinned(id:pinned:)` (optimistic + CK queue +
   `dataChanged` post). Write boundary; no view writes the flag directly.
4. **Dashboard render** — `WeekDashboardView`: render pinned goals as full-width
   tiles at the top of the grid, ordered by `sortIndex`, above the half-width
   section tiles. New **goal→tile renderer** that picks history viz by metric type
   (heatmap / histogram / sparkline) and reuses `GoalMetricProgressView` for the
   progress line. This is the bulk of the new work — goals have no tile today.
5. **Pin affordance** — a "Pin to dashboard" toggle on the goal in `GoalsView` /
   `CoachView` and the `SectionGoalsStrip` row → `setPinned`.
6. **MCP both servers, lockstep** — `goals_create` / `goals_list` / `goals_update`
   already exist; surface `pinned` in the schema + the new per-habit metric keys in
   the metric catalog, and mirror in the hosted gateway
   (`../septena-mcp-gateway`) + the section skill.

## The streak residue

The one thing that is genuinely habit-not-goal is the **chain** ("don't break the
41 days"). It isn't a targetable metric — it lives in `GoalMilestoneEntity`. The
pinned-goal tile surfaces it by borrowing the underlying habit's consistency
heatmap (and can show the current streak number alongside the goal progress). So
no streak meaning is lost; it's just rendered, not targeted.

## Honest trade-off

This is **more work** than an `isHero` flag — goals currently have zero dashboard
presence, so we build the goal→tile renderer + the pin path + the per-habit metric.
But it's the right abstraction and you build it once: every future "I want this
target on my front door" is then free.

## Relation to Markers

The inverse of [Markers](MARKERS_PLAN.md). A pinned goal is the **Measure/target**
shape made prominent; a Marker is the **Occurrence** shape with explicitly *no*
target. Surya is a (pinned) goal; "saw something beautiful" is a marker. Together
they close the two gaps the taxonomy exposed: prominence for targets, and a home
for domain-less occurrences.
