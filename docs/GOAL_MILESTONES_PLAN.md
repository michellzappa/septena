# Goal Milestones

> **STATUS: SHIPPED 2026-06-10** (committed since; `MilestoneEngine.swift`,
> `MilestonePresenter.swift`, and the `Milestone` rows in `CloudKitSchema.md`
> are the truth — this file is kept because those three cite it). Implementation notes where reality diverged from the plan:
> - Detection runs **inside the mutators** (`ChecklistMutator.setHabitState`,
>   `TrainingMutator.addEntry`, `WithingsStore.upsert`), so every write path
>   (views, App Intents, MCP) detects — not just view-side call sites.
> - **One presentation path, not two**: `MilestonePresenter` at the app root
>   consumes the inbox on a debounced `.septenaDataChanged` (≈0.6s after the
>   earning log — effectively inline) plus scene-activation; there is no
>   separate inline path. Habit/training/body all present identically.
> - Each scope writes an **`init` sentinel row** on first evaluation —
>   without it, a scope whose grandfather pass grants nothing would look
>   like a first pass forever.
> - `celebrate:` parameter distinguishes live triggers from reconciles —
>   launch/scene reconciles grant silently so CK-synced history from another
>   device never reads as a live crossing.
> - The legacy `StreakMilestones`/`HabitMilestoneStore` (UserDefaults)
>   bookkeeping in LogCommit.swift was REPLACED by the engine; `IgnitionView`
>   was generalized (headline/caption) and reused for PR/target/held30 cards
>   via the new `LogCommitStyle.milestone` case.

Turn continuously-true goal state into discrete, latched, celebrateable events.
Today the app only *monitors* — current values, trailing windows, heatmaps. A
milestone is the missing primitive: "the smoothed weight crossed 78kg", "first
100kg bench", "30 days within the caffeine limit". One event type, three
detector shapes, consumed first by CommitMotion and the nudge layer; the share
card (the viral loop) is a later, third consumer of the same events.

**Done-line:** a Withings sync lands a weight that pulls the trailing-7-day
average past the next rung of an active weight goal → a `GoalMilestoneEntity`
row is written exactly once (any device, any number of re-evaluations) → on
next foreground the app presents the celebration with a tiered CommitMotion
flourish → the milestone appears permanently in the goal's history, synced via
CloudKit.

## Scope

**In (v1):**
- `GoalMilestoneEntity` + `GoalMilestone` CK record (additive; joins the
  pending prod-deploy changelog in `docs/CloudKitSchema.md`).
- Three detectors: smoothed-level rungs (weight/body metrics), training PR +
  cumulative-volume XP, adherence-streak rungs (habits first).
- Latching with deterministic milestone ids; silent grandfathering on first run.
- Tiered celebration via `CommitFlourish` + a queued "while you were away"
  presentation for background-detected milestones.
- One nudge: "one day from a streak rung".

**Out (later):**
- Share card / recap artifact (consumer #3 — separate plan once events feel right).
- MCP exposure (`milestones_list`) — when added, lands in BOTH the local server
  and the hosted gateway in the same change, per the lockstep rule.
- Caffeine/cannabis/macro-band adherence streaks (same detector, flip on after
  habits proves it; limit streaks need the day-rollover path below).
- Sleep / resting-HR / HRV smoothed rungs (same detector as weight, new metric
  keys).
- Watch/widget surfaces.

## 1. The entity

`SeptenaCore/Persistence.swift`, alongside `GoalEntity` (Persistence.swift:453).

```swift
@Model final class GoalMilestoneEntity {
  @Attribute(.unique) var id: String   // deterministic: "<goalOrScopeID>|<rungKey>"
  var goalID: String?                  // nil for goal-less milestones (PR/XP/streaks)
  var scope: String                    // "goal" | "exercise:bench-press" | "habit:<id>" | "training.volume"
  var kind: String                     // "rung" | "pr" | "xp" | "streak"
  var rungKey: String                  // "kg:78" | "pr:100" | "xp:25000" | "streak:30" | "target" | "held30"
  var label: String                    // user-facing, resolved at detection time
  var value: Double                    // the crossed value (smoothed kg, PR kg, streak days…)
  var occurredAt: Date                 // when the crossing was detected
  var celebrated: Bool                 // false = granted silently (grandfathered / historical)
  var updatedAt: Date
  var cloudKitSystemFields: Data?
}
```

The **deterministic id is the load-bearing decision**: `scope + rungKey` means
multi-device evaluation (iPhone, Mac, watch all run detectors against the same
mirror), re-fetches, and repeated passes can never duplicate a milestone —
insert is idempotent by `@Attribute(.unique)` + CK record name collision.

Rules baked in:
- **Never revoke.** Deleting the set that earned a PR, editing a weight entry —
  the row stands. The unique id prevents re-earning.
- **`celebrated == false` rows are history, not moments.** Grandfathering and
  backfill grant rows silently; only crossings detected *now* (against
  `DayClock.now`) set `celebrated = true` and animate.

## 2. CloudKit record

New file `SeptenaCore/CloudKit/GoalMilestoneRecord.swift`, copying the
`GoalCloudKitSchema` pattern (GoalRecord.swift:1):

- `recordType = "GoalMilestone"`, `recordName = "gms:{id}"`.
- Fields: `goalID`, `scope`, `kind`, `rungKey`, `label`, `value`, `occurredAt`,
  `celebrated` (Int 0/1) + the usual reserved slots.
- `CKEngine.noteGoalMilestoneChange(id:)` / deletion notifier; dispatch case in
  the host `recordProvider` / `applyFetchedRecord` switch in `App.swift`.
- Add the type to `docs/CloudKitSchema.md` and the front-loaded Dev→Prod
  changelog (it joins occurredAt×7 + MoodEvent + SupplementDefinition.bucket).
- Conflict note: two devices writing the same recordName is a benign conflict —
  same content by construction; last-writer-wins is fine.

## 3. MilestoneEngine (detection)

New `SeptenaCore/Milestones/MilestoneEngine.swift` — a pure evaluator the app
target calls from three trigger points. It never reads `Date()`; trigger sites
pass `DayClock.now` / `DayClock.today` in.

Common shape per detector: compute the current ladder position, fetch existing
milestone ids for the scope (one indexed fetch), insert any rung whose key is
absent. Rungs below the newest crossing that were never granted (e.g. fast
progress skipped kg:77) are granted in the same pass with `celebrated = false`
except the topmost, which is the celebrated one.

### 3a. Smoothed-level rungs (weight, body metrics)

- Input: an active goal whose `metricKey` is a body metric (Withings-backed),
  with `metricBaseline` + `metricTarget` (+ `metricTargetUpper` for range).
- Signal: **trailing-7-day mean** of the metric from `WithingsRowEntity` rows
  (one row per day, `id == "yyyy-MM-dd"`). Days without a reading are simply
  absent from the mean (no interpolation). Require ≥3 readings in the window
  before evaluating at all — a single weigh-in after a gap is not a trend.
- Ladder, derived from the goal (the user creates ONE goal, never rung-goals):
  - one rung per whole unit of progress from baseline toward target
    (kg → 1.0 steps; fat % → 0.5 steps; muscle mass → 0.5 steps),
  - `halfway`,
  - `target` (for range goals: smoothed value entered the band),
  - `held30` — smoothed value on the target side (or in band) for 30
    consecutive evaluated days. Maintenance is the real achievement in weight;
    this is the rung nobody else celebrates.
- Direction comes from baseline vs. target — works for loss and gain. If the
  goal's metric fields change (`updateGoalMetric`), the old rows stand as
  history and the ladder is simply recomputed from the new baseline/target; no
  reconciliation.

### 3b. Training PR + XP

Two ladders from `ExerciseEntryEntity` (Persistence.swift:1074), no goal
required:

- **PR** — max `weight` per exercise (strength-type definitions only, from
  `ExerciseDefinitionEntity.type`). Monotonic by definition: needs no smoothing
  or latching logic beyond the id. `rungKey = "pr:<weight>"`,
  scope `exercise:<slug>`. Require at least N=3 prior entries for the exercise
  before PRs fire — the first-ever log of a movement is a baseline, not a record.
- **XP** — lifetime total volume (Σ weight × sets × reps where all present),
  scope `training.volume`, with widening rungs: 10t, 25t, 50t, 100t, 250t,
  500t, 1000t… (×2.5/×2 alternating). Widening spacing keeps cadence roughly
  constant as training volume grows.

### 3c. Adherence-streak rungs

- v1: habits only. Reuse the exact `ConsistencyStats.make()` ordinal logic
  (LoggableDetailView.swift:46) — move the struct into SeptenaCore so the
  engine and the detail view share one implementation rather than forking it.
- Ladder: 7 / 30 / 50 / 100 / 365, scope `habit:<id>`. Day 7 ships — the first
  rung must arrive while the habit is still fragile.
- The streak resets on a miss; earned rungs never do. After a reset the same
  rungKey can't re-fire (id already exists) — by design: the *first* 30-day
  streak is the story. If repeat celebrations prove wanted later, version the
  rungKey ("streak:30#2") — explicitly deferred.
- Limit-based streaks (caffeine under N) are **out of v1** but the trigger
  exists for them: a "stayed under" day is only knowable at day end, so they
  evaluate on the rollover trigger, never at log time.

## 4. Trigger points

| Trigger | Detector | User present? |
|---|---|---|
| Training log commit (the `SectionLog.newLog` write path) | PR + XP | yes → celebrate inline |
| `.septenaWithingsChanged` (posted by `WithingsStore.upsert`) | smoothed rungs | usually no → queue |
| Habit toggle commit | streak rungs | yes → celebrate inline |
| `DayClock` day rollover + scenePhase `.active` reconcile | streak integrity, future limit-streaks, `held30` | no → queue |

Detection runs on the main actor against the local mirror — it's a handful of
indexed fetches, cheap enough to run synchronously at the mutator boundary.
**No new launch-time HTTP** is involved anywhere (the `SeptenaClient` ≤4
parallel-call ceiling is untouched).

CloudKit-fetched `GoalMilestone` records from *another* device fold in silently
— `apply(record)` never triggers a celebration; the device that detected the
crossing owns the moment.

## 5. Presentation

Two paths:

- **Inline** (user just logged): ride the existing commit flow — the milestone
  upgrades the flourish the log was already firing. Tiering by kind:
  - XP rung → the section's normal `logFlourish`, `intensity ~1.2` (a slightly
    louder version of the log itself, no interruption),
  - streak rung → `.burst`, medium intensity, with the rung label,
  - PR / goal `target` / `held30` → the full moment: `.burst` at high
    intensity + a milestone card (sheet/overlay) naming the rung.
- **Queued** (background detection): a lightweight `MilestoneInbox` — fetch
  `celebrated == true` rows not yet presented (add `presentedAt: Date?` to the
  entity) on scenePhase `.active`; present the topmost as a card, mark the rest
  presented quietly into goal history. Never stack three confetti bursts on
  launch.

If everything is special, nothing is: only the top tier (PR / target / held30)
ever gets the full-screen moment, and later only that tier gets a share prompt.

Goal history surface: the goal's detail/edit view gains a milestone timeline
(reverse-chronological rows, granted-silently rows included, dimmed). Cheap,
and it makes the entity legible before any celebration polish.

## 6. Nudge

One `NotificationDescriptor` to start, on the habits plugin
(HabitsPlugin.swift, pattern at NotificationKit.swift:1):

- `id: "habits.streakRung"`, priority above the generic incomplete nudge.
- `evaluateNotification`: if any habit's current streak == rung − 1 for a rung
  not yet earned and today's toggle is pending → "One day from a 30-day
  streak — log <habit> to lock it in." Learned fire time via
  `NextScoring.learnedLateMinute`, same as the incomplete nudge.
- Nudge to *mark*, not nag to *do* — consistent with the nudge layer's charter.

## 7. Grandfathering (first run after ship)

On first detector pass per scope, existing users instantly qualify for many
rungs (a long-time lifter qualifies for every XP rung at once). Rule: the first
pass for a scope grants ALL currently-qualified rungs with
`celebrated = false`. Only rungs crossed by *subsequent* writes celebrate.
Implementation: "first pass" = no milestone rows exist yet for the scope; no
separate flag needed. This also covers restore-from-CloudKit on a new device —
rows sync in, so the pass finds them and stays quiet.

## 8. Weight, tone

Celebration only ever tracks movement **toward the user's own stated goal** —
no goal, no weight milestones, period (PR/XP/streaks don't need goals; body
metrics do). Copy stays neutral and numeric ("Trailing average crossed 78 kg",
"Held 30 days") — never body commentary. `held30` deliberately makes
*maintenance* a first-class achievement. This is the deliberate answer to the
disordered-eating concern; revisit if user feedback says it's not enough.

## Sequence

1. Entity + CK record + engine notifiers + schema doc row (no detection yet) —
   builds green, syncs an empty type.
2. Shared `ConsistencyStats` moves to SeptenaCore.
3. MilestoneEngine + the three detectors, pure functions with the trigger
   wiring behind a single call site each. Grandfathering rule included from the
   first pass — it cannot be retrofitted after rows exist.
4. Inline presentation (training + habits) with tiered flourishes.
5. Withings trigger + MilestoneInbox queued presentation.
6. Goal-detail milestone timeline.
7. Streak nudge.
8. Build-verify iOS + macOS + watch (entity lives in SeptenaCore, compiled into
   all targets even though v1 surfaces are iOS/macOS only).

## Traps

- **Grandfathering before celebration** — step 3 must land complete before any
  presentation ships, or launch day is a confetti avalanche that devalues the
  system permanently.
- **Time travel**: detectors receive `DayClock.now/today` from the trigger
  site; the queued path additionally refuses to celebrate rows whose
  `occurredAt` is in the future relative to the wall clock (time-travel
  artifacts present silently).
- **Withings rows are per-day upserts** — a re-sync rewrites history; the
  smoothed mean must be recomputed from rows, never cached, and the
  deterministic id absorbs the re-fire.
- **`reps` is a String** (`"12"` or `"AMRAP"`) — XP volume parses defensively;
  AMRAP sets contribute weight × sets × 0 unless a numeric is present (i.e.
  they're skipped, documented as such).
- **Don't invent a fourth detector shape.** Anything new must reduce to
  smoothed-level / monotonic-max / streak, or it waits for its own plan.
- **MCP lockstep** applies the day milestones get a read tool — both servers,
  same change.

## Cross-references

- `docs/CloudKitSchema.md` — add the `GoalMilestone` row + changelog entry.
- `Septena/Shell/UI/CommitMotion.swift` — flourish/intensity contract.
- `SeptenaCore/NotificationKit.swift` — descriptor/plan contract.
- Share-card / viral-loop layer: separate future plan; it consumes
  `celebrated == true`, top-tier milestones only.
