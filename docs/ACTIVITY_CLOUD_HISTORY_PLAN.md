# Activity Cloud History — Plan

Status: planned, not built (2026-06-12).

## Problem

The Activity section reads HealthKit live into `HealthKitBridge`'s in-memory
fields: today's totals plus a trailing 7-day step array. Nothing is persisted,
nothing syncs. Consequences:

- History is capped at 7 days even though HealthKit holds years of data.
- macOS has no HealthKit, so the tile silently vanishes on Mac.
- Activity contributes zero `correlationFeatures` — the section's best
  justification (steps × mood/sleep/gut) is unwired.

Past days are effectively immutable (late watch-sync trickle aside), which
makes this ideal CloudKit material: read each day from HealthKit **once**,
persist a tiny daily-summary record, sync it everywhere.

## Design

### Entity: `ActivityDayEntity` (typed, not generic)

Follow the `NutritionDailySummaryEntity` pattern (Persistence.swift ~1451):

```swift
@Model final class ActivityDayEntity {
  @Attribute(.unique) var id: String   // "yyyy-MM-dd" — the day IS the identity
  var date: String                     // same as id
  var stepCount: Int?
  var activeKcal: Double?
  var exerciseMinutes: Int?
  var updatedAt: Date
  var cloudKitSystemFields: Data?
}
```

Typed beats a generic `MetricDaily(metricKey, value)` row here because:
CK schema promotion is **additive-only but additive is allowed** — when we
later want restingHR / VO2 / distance persisted, we add fields to this same
record type. Body-composition metrics (body fat, weight) come from Withings
and already have their own cache/flow; if they ever need CK persistence they
get their own type. One record type per fetch-domain.

### CloudKit: record type `ActivityDay`

- Schema enum next to the others in Persistence.swift (~2223):
  `recordName = "activity-day:\(yyyy-MM-dd)"`, fields `date`, `stepCount`,
  `activeKcal`, `exerciseMinutes`.
- Deterministic record names mean iPhone + iPad (both HealthKit-bearing, both
  fed by iCloud Health sync) write the **same record** for the same day —
  last-writer-wins converges because the underlying HealthKit values agree.
- `toCloudKitRecord()` / `apply(_:)` codec pair + `convenience init(cloudKit:)`
  in Persistence.swift, matching the existing extensions (~3200).
- Register in the `Schema([...])` array in `LocalStore` (~3218) and add
  `noteActivityDayChange(id:)` / `noteActivityDayDeletion(id:)` to
  CKEngine.swift (~253).

### Mutator: `ActivityMutator`

House invariant: mutators are the write boundary. Shape after `GutMutator`
(SeptenaServices.swift ~1745):

- `upsert(date:steps:activeKcal:exerciseMinutes:)` — fetch-or-create by id,
  **skip entirely if values are unchanged** (no `updatedAt` dirtying, no CK
  churn — this matters because the ingest loop re-reads a trailing window
  every refresh).
- On real change: optimistic local write → `context.save()` →
  `ckEngine?.noteActivityDayChange(id:)` → `DataChange.post("activity")`
  (scoped key, per the notification-scoping convention).

### Ingest (iOS only — the single writer)

Lives in/next to `HealthKitBridge`, called from the existing `refresh()` path:

1. **Steady state:** every refresh, run one `HKStatisticsCollectionQuery` over
   the trailing **14 days** for each of steps / activeKcal / exerciseMinutes,
   and upsert each day through the mutator. 14 days (not 1) absorbs late
   Apple Watch sync trickle; the unchanged-skip in the mutator makes the
   other 13 days free.
2. **Backfill (one-time):** sentinel-gated (`activity.import.v1` in the
   Settings JSON payload, per the existing sentinel pattern). Query the
   trailing **365 days** in one statistics-collection pass per metric, upsert
   all days with data. Run detached at background priority after launch —
   never on the launch critical path. CKSyncEngine batches the resulting
   ~365 queued records itself; no manual chunking needed.
3. **Date keys use real calendar dates** from the HealthKit statistics
   intervals — the ingester records historical truth and is exempt from the
   `DayClock` rule (which governs *views*). Nothing here should consult
   time-travel state.

watchOS: no change — the watch never reads HealthKit today and doesn't need
to; it keeps consuming `WatchSnapshot`.

### Read surfaces (all platforms, including Mac)

- **Dashboard tile** (`WeekDashboardView.activityDomainData()` ~1846): read
  the trailing-7-day bars + today's numbers from `ActivityDayEntity` instead
  of the bridge arrays. On iOS the bridge refresh still runs first, so the
  entity is fresh; on macOS the tile now **renders from synced data** instead
  of returning nil. Keep the live-HealthKit vitals (VO2/HRV/RHR) iOS-only for
  now. "Week" stays trailing 7 days (`sinceDate(daysBack: 6)`).
- **Destination** (`ActivityDestinationView`): replace the 7 `LogRow`s with a
  real history view from the entity — a Swift Charts step chart with a range
  picker (30d / 90d / 1y), same visual family as the Body section's Withings
  trend charts. This is the "nearly useless → useful" payoff.
- Views read `DayClock.today` for "today" as usual.

### Correlations

`ActivityPlugin.correlationFeatures(context:)` fetches `ActivityDayEntity`
rows and returns daily series (`[yyyy-MM-dd: Double]`, missing days omitted):

- `activity_steps` (continuous)
- `activity_exercise_minutes` (continuous)

`activeKcal` is largely collinear with the other two; leave it out of v1 to
keep the FDR-gated candidate pool honest.

### Docs / schema bookkeeping

- `docs/CloudKitSchema.md`: add `ActivityDay` to the field manifest **and**
  to the pending Dev→Prod deploy changelog table. Dev schema auto-creates on
  first write; Prod needs the additive deploy (it's already pending other
  types, so this just joins the batch — and remember Prod starts empty, the
  backfill re-runs naturally there since records arrive via sync or re-ingest).

## Out of scope (deliberate)

- **MCP tools** (`activity_history` read tool): natural follow-up, but the
  lockstep rule means in-app server + hosted gateway + skill briefs must land
  together — separate change.
- **Generic metric-tile framework** (optional sub-graph tiles for body fat
  etc.): this plan makes Activity the first *persisted* metric; the tile
  framework generalizes later on top of it.
- Walking distance / stairs / stand hours: add as fields later (additive),
  only when a surface wants them.
- Deleting/compacting history.

## Build order

1. Entity + schema enum + codec + `Schema([...])` registration + CKEngine
   note methods. (Build green; record type appears in Dev on first write.)
2. `ActivityMutator` with unchanged-skip upsert + scoped notification.
3. Ingest: trailing-14-day upsert wired into `HealthKitBridge.refresh()`.
4. Backfill: sentinel-gated 365-day import, detached after launch.
5. Tile reads entity (Mac tile comes alive). Verify macOS scheme.
6. Destination history chart (30d/90d/1y).
7. `correlationFeatures` in ActivityPlugin.
8. `docs/CloudKitSchema.md` manifest + pending-deploy changelog rows.

Verification: all three schemes build; on-device check that bars match the
Fitness app for the trailing week; Mac shows the tile after sync; backfill
runs once (sentinel) and re-running refresh causes zero CK uploads when
nothing changed (watch the CKEngine pending-change log).

## Traps noted

- Ingest must not join the launch-time `SeptenaClient` fetch path (≤4 parallel
  HTTP rule doesn't apply to HealthKit, but the backfill still runs detached
  to keep launch clean).
- `updatedAt`/`computedAt` must only move when values actually change, or
  every refresh re-uploads 14 records forever.
- Today's record is *expected* to change all day; that's fine — it's one
  small record, and the day freezes at rollover.
