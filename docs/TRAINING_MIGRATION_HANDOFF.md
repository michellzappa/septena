# Training → CloudKit Migration Handoff

> **Shipped — historical.** Training runs on CloudKit + SwiftData; sessions,
> entries and the exercise library are live, and `docs/CloudKitSchema.md` holds
> the authoritative field table. Kept for the migration reasoning and because
> `README.md` links it. The "Status: not started" line it used to carry was
> three months out of date.

Last updated: 2026-05-23 (status corrected 2026-08-23)

Sibling repos:
- iOS: `/Users/mz/Dev/septena` (this repo; formerly `septena-cloud`)
- FastAPI: `/Users/mz/Dev/septena-app`

This is a focused handoff for **the Training section**. The general
`MIGRATION_HANDOFF.md` in this repo is stale — ignore it; the recipe
below is the current proven one (validated by gut/caffeine/cannabis,
groceries, goals, habits/supplements/chores).

## Context

Six sections already live on CloudKit. See the Sync table in
Settings → Sync for the live picture. The migration **recipe** is now
mechanical; this doc highlights what's *different* about Training plus
the file-by-file checklist.

Training is **hermetic** — it does not read any other section's data.
The only outbound coupling is `NextSuggestionsSection` and the week
dashboard reading the suggested-workout endpoint. After migration those
consumers will read SwiftData instead, no behavioral change.

## Data model decisions

**Entities (3 new `@Model` types in `SeptenaCore/Persistence.swift`):**

1. **`ExerciseEntryEntity`** — one row per logged exercise (the per-day
   JSON files on the server). Fields:
   - `id: String` — new short UUID (CK record name); the server's
     opaque `file` field goes away
   - `date: String` (YYYY-MM-DD)
   - `time: String` (HH:MM, the session start time)
   - `sessionType: String` (id from SessionType: upper/lower/cardio/yoga/etc)
   - `exercise: String` (canonical name)
   - `weight: Double?`
   - `sets: String?` ("8" or "AMRAP")
   - `reps: String?`
   - `difficulty: String?` ("easy"|"medium"|"hard")
   - `durationMin: Double?`
   - `distanceM: Double?`
   - `level: Double?`
   - `note: String?`
   - `concludedAt: String?` (ISO8601, when the session ended)
   - `loggedAt: String?` (ISO8601, when the row was written)
   - `updatedAt: Date`
   - `cloudKitSystemFields: Data?`

2. **`ExerciseDefinitionEntity`** — the per-exercise catalog row, used
   for the type classifier (strength/cardio/mobility/core) and for the
   logger's "what fields does this exercise need" decision. Fields:
   - `id: String` (slug like `chest-press`)
   - `name: String`
   - `type: String` (strength|cardio|mobility|core)
   - `subgroup: String?` (free-form like "push", "pull", "back")
   - `aliases: [String]` (canonical name resolution — `row → rowing`)
   - `sortIndex: Int`
   - `updatedAt: Date`
   - `cloudKitSystemFields: Data?`

3. **`SessionTypeEntity`** — the day-type catalog (upper/lower/cardio/
   yoga + user custom). Fields:
   - `id: String`
   - `label: String`
   - `emoji: String?`
   - `exercises: [String]` (canonical exercise list for this type)
   - `sortIndex: Int`
   - `updatedAt: Date`
   - `cloudKitSystemFields: Data?`

**Out of scope (compute, not data — recompute client-side from the
three entities above):**
- `ProgressionPoint` — fold from filtered `ExerciseEntryEntity`
- `ExerciseSummary` — `Dictionary(grouping:)` rollup
- `CardioDay` (daily minutes + rolling 7d) — same
- `SuggestedWorkout` (days-ago + suggested type) — see "Suggested
  workout port" below

## Server side: one new endpoint

The existing `GET /api/training/entries` returns all entries but
without the config or session_types catalog. Mirror the pattern from
[septena#10](https://github.com/michellzappa/septena/pull/10) and add a
**single** new endpoint:

```python
# /Users/mz/Dev/septena-app/api/routers/exercise/sessions.py
@router.get("/api/training/export")
def training_export() -> Dict[str, Any]:
    """Full snapshot for the iOS CK bootstrap. Returns every entry on
    disk, plus the session-type and exercise catalogs from
    training-config.json. No filtering — user wants the whole history.
    """
    config = load_training_config()  # already exists, returns the json
    cache = get_training_cache()     # returns entries list
    return {
        "entries": cache["entries"],
        "session_types": config.get("session_types", []),
        "exercises": config.get("exercises", []),
    }
```

The legacy `exercises` field stays a flat array (`[{id, name, type,
subgroup, aliases?}, ...]`). All `entries` keep their existing wire
shape; iOS decodes via `ExerciseEntry` minus the `file` field (use
`id` instead, generated on the iOS side during bootstrap upsert).

Open the PR; ship it to your server; *then* start on the iOS side.

## iOS side: file-by-file checklist

Mirrors the recipe used for the last 6 migrations exactly. Times are
rough first-cut estimates from a developer who's done this before.

### 1. `SeptenaCore/Persistence.swift` (~30 min)

Add the three `@Model` entities above. Add three CK schema enums
(`ExerciseEntryCloudKitSchema`, `ExerciseDefinitionCloudKitSchema`,
`SessionTypeCloudKitSchema`) with `recordType`, `Field`, and
`recordName(for:)` / `entityID(from:)`. Add three
`extension Foo: ChecklistCloudKitBackedEntity` blocks with
`toCloudKitRecord()` and `apply(_:)`. Register the three entity types
in the `LocalStore` `Schema([...])` list.

Record name prefixes: `exercise-entry:`, `exercise-def:`, `session-type:`.

### 2. `SeptenaCore/CloudKit/CKEngine.swift` (~5 min)

Add six one-liners:
```swift
noteExerciseEntryChange(id:) / noteExerciseEntryDeletion(id:)
noteExerciseDefinitionChange(id:) / noteExerciseDefinitionDeletion(id:)
noteSessionTypeChange(id:) / noteSessionTypeDeletion(id:)
```

### 3. `SeptenaCore/SeptenaServices.swift` (~45 min)

- `recordProvider` block: three `hasPrefix` cases, identical pattern to
  the others.
- `applyFetchedRecord` block: three `case` arms (`ExerciseEntryCloudKitSchema.recordType`, etc).
- `applyDeletedRecord` block: same three cases.
- New `TrainingMutator` class (mirror `GroceryMutator`). Public methods:
  - `addEntry(date:time:sessionType:exercise:weight:sets:reps:difficulty:durationMin:distanceM:level:note:)`
  - `addSession(date:time:sessionType:entries:)` — convenience that
    calls `addEntry` per row, stamping a shared `concludedAt`
  - `updateEntry(id:...)`
  - `deleteEntry(id:)`
  - `addExerciseDefinition(name:type:subgroup:)`
  - `updateExerciseDefinition(id:...)`
  - `deleteExerciseDefinition(id:)`
  - `addSessionType(label:emoji:exercises:)`
  - `updateSessionType(id:label:emoji:exercises:)`
  - `deleteSessionType(id:)`
- Wire into `SeptenaServices.shared`: declare `let trainingMutator:
  TrainingMutator`, init in `init()`, call `bind(ckEngine:)` in
  `start()` alongside the other mutators.

### 4. `SeptenaCore/Models.swift` (~15 min)

Add the export DTO:
```swift
struct TrainingExportResponse: Codable {
  let entries: [ExerciseEntry]
  let sessionTypes: [SessionTypeConfig]
  let exercises: [ExerciseDefinition]   // new — see below
  enum CodingKeys: String, CodingKey {
    case entries, exercises
    case sessionTypes = "session_types"
  }
}

struct ExerciseDefinition: Codable, Identifiable, Hashable {
  let id: String
  var name: String
  var type: String              // strength|cardio|mobility|core
  var subgroup: String?
  var aliases: [String]?
}
```

`ExerciseEntry` already exists. Make `file` optional (server still sends
it but new CK-side entries won't have it). Add a memberwise init to
`SessionTypeConfig` and `ExerciseDefinition` if the auto-synthesized
one doesn't fit your needs (see how `CaffeineBean` ended up needing
both an explicit init and a custom decoder).

### 5. `SeptenaCore/SeptenaClient.swift` (~5 min)

Add one method:
```swift
func trainingExport() async throws -> TrainingExportResponse {
  try await getJSON("/api/training/export", as: TrainingExportResponse.self)
}
```

### 6. `SeptenaCore/ChecklistMirror.swift` (~60 min)

Add a section block at the end with:
- `replaceAllTrainingExport(_ response: TrainingExportResponse, context:)` —
  upsert by id, delete locals the server doesn't know about. Generate
  CK ids for entries on first import (`UUID().uuidString.prefix(8)`).
- `loadTrainingEntries(context:, since: String?) -> [ExerciseEntry]`
  — flat list, newest first
- `loadTrainingCardioHistory(context:, days:) -> CardioHistoryResponse`
  — daily minutes + rolling 7d; gap-fill missing dates with zero
- `loadTrainingProgression(context:, exercise: String) -> [ProgressionPoint]`
  — filter to one exercise, return ascending date
- `loadTrainingSummary(context:, since: String?) -> [ExerciseSummary]`
  — group by exercise, latest-weight + count + trend
- `loadSessionTypes(context:) -> [SessionTypeConfig]`
- `loadExerciseDefinitions(context:) -> [ExerciseDefinition]`
- `loadLastEntries(context:, exercises: [String]) -> [String: LastEntryValues]`
  — for each exercise, walk progression backward picking most-recent
  non-null per field (`weight`, `sets`, `reps`, etc.). See server-side
  `/api/training/last-entries` for the field-by-field strategy.

### 7. `SeptenaCore/CloudKit/Migration.swift` (~10 min)

- Add `BootstrapKey.training` constant.
- Add a bootstrap block: `client.trainingExport()` →
  `ChecklistMirror.replaceAllTrainingExport(...)` →
  `queueTrainingMirrorForUpload()` → flag the key.
- Add `queueTrainingMirrorForUpload()` helper at the bottom: iterate
  all three entity fetches, call `engine.noteExerciseEntryChange(id:)`
  etc.

### 8. Suggested workout port (~90 min, the only real puzzle)

The server's `GET /api/training/suggested-workout` does:

1. For each historical session, classify by checking the exercises in
   that day's entries against the session_types catalog. A day is
   "upper" if ≥3 upper exercises were logged; "lower" if ≥3 lower; etc.
2. Track `days_ago` per type since the last classified session of
   that type.
3. Suggest the type with the largest gap, respecting a 2-day minimum
   rest from the most recent session.

Two options:

- **Option A (recommended):** port this to a static helper in
  `ChecklistMirror.suggestedWorkout(context:)` returning
  `SuggestedWorkoutResponse`. The math is trivial in Swift once you've
  got `ExerciseEntryEntity` rows + `SessionTypeEntity` definitions.

- **Option B:** keep calling the server endpoint. Cheaper to ship but
  defeats the migration goal (still needs FastAPI alive).

Pick A. The dashboard / Next view will read `loadSuggestedWorkout`
directly from the local mirror.

### 9. Views (~3 hours total)

Same pattern as every prior section — replace `client.training*` and
`outbox.enqueue("/api/training/*")` with `ChecklistMirror.load*` and
`TrainingMutator` calls. Files to touch:

- `Septena/Sections/Training/TrainingDestinationView.swift` — the big
  one (849 lines, lots of computed properties feeding charts/heatmaps
  that all derive from `entries` and `cardioHistory`). Wire to
  `reload()` + `.onReceive(.septenaDataChanged)` like
  `GroceriesDestinationView` does.
- `Septena/Sections/Training/TrainingSessionView.swift` +
  `TrainingExerciseCard.swift` (in the same file, embedded) — the
  logger. The big call is `postTrainingSession(...)` which becomes
  `trainingMutator.addSession(...)`.
- `Septena/Sections/Training/EditExerciseEntrySheet.swift` — re-edit
  modal, becomes `trainingMutator.updateEntry(id: ...)`.
- `Septena/Sections/Training/TrainingDraftStore.swift` (embedded in
  TrainingDestinationView, lines ~936–1074) — the catalog cache. On
  first entry it currently does `await client.sessionTypes()` +
  `await client.suggestedWorkout()`. Both become synchronous
  `ChecklistMirror.load*` reads.
- `Septena/Shell/Dashboard/NextSuggestionsSection.swift` (line ~159) —
  switch `client.trainingEntries(since:)` and `client.suggestedWorkout()`
  to local mirror reads.
- `Septena/Shell/Dashboard/WeekDashboardView.swift` (lines 318, 456,
  647) — same swap.
- `Septena/Sections/Training/TrainingQuickAddMenu.swift` — only reads
  session-types via the draft store, may not need a touch.
- `Septena/Sections/Training/AddTrainingPage.swift` — currently a no-op
  shim. Probably stays untouched.

### 10. Settings Sync table + reset (~10 min)

- `Septena/Shell/Settings/SettingsView.swift`: flip the **Training**
  row from `.legacy` to `.cloudKit`.
- In `runResetZone()`: fetch the three new entity types, clear their
  `cloudKitSystemFields`, then `note*Change` them for re-upload. Add
  their counts to the total. Mirror exactly what was done for
  goals/gut/groceries.

### 11. Commit (~5 min)

Single commit, message style matches the prior migrations:
`feat(ck): migrate training from FastAPI to CloudKit`

## Acceptance criteria

1. Build succeeds (`xcodebuild -scheme Septena -destination 'generic/platform=iOS' build`).
2. Tap "Re-import All Sections from FastAPI" in Settings → Sync. Verify
   the bootstrap log shows `[Bootstrap] training imported: entries=N`.
3. Open the Training tab — the historical session log, cardio chart,
   strength volume tracker, and progression charts all render with
   real data.
4. Tap "Start training", pick a session type, log a workout, save.
   Quit the app, re-launch. The new session appears in the log.
5. Edit a logged entry's weight. Verify the change persists across an
   app restart.
6. Delete an entry. Verify it's gone after a restart.
7. Open the Next view — if you haven't trained in 2+ days, the "Time
   to train" card appears with the correct suggested type.
8. Settings → Sync shows **Training: CloudKit (green checkmark)**.

## Quirks & gotchas

1. **`sets`/`reps` are int OR string.** The server returns
   `"AMRAP"` literally for AMRAP sets, and integers otherwise. The
   existing `ExerciseEntry` decoder handles both — preserve this in
   the entity by keeping `sets: String?` and `reps: String?` and
   parsing only at compute time.

2. **The `file` field is going away.** It's the server's opaque
   filename and was the de-facto entity id. On CK we use a fresh
   short-UUID id, and `file` becomes a soft historical field on the
   wire only. Don't carry `file` into the CK record.

3. **Per-exercise `type` lives on the catalog, not the entry.** The
   logger looks up `ExerciseDefinition.type` to decide which fields to
   show (weight/sets/reps for strength, duration/distance for cardio).
   If a user logs an entry for an exercise not in the catalog (legacy
   data), default to strength.

4. **Draft session persistence is UserDefaults.** Don't migrate that
   to SwiftData — it's intentionally ephemeral local state. Only
   *completed* sessions become `ExerciseEntryEntity` rows.

5. **`SuggestedWorkout.daysAgo` uses string keys** (`"upper"`,
   `"lower"`, `"cardio"`, `"yoga"`). These string keys are the
   `SessionTypeEntity.id` values. Don't intern them — read them off
   the catalog.

6. **Cross-section coupling is read-only.** `NextSuggestions` and
   `WeekDashboardView` consume training data but don't write to it.
   Migration is one-way safe.

7. **No history retention question.** Unlike groceries (snapshot, no
   history) or supplements (30-day cap), Training keeps the full
   record. The user has years of workouts they care about. Whole
   history pulls during bootstrap, no day filter.

## When you're done

Move the section from "still on FastAPI" to "on CloudKit" in your
mental model, update this doc's status, and pick the next one:

- **Nutrition** is the next biggest. Similar shape (catalog +
  per-meal entries) but with the macros/recommendations engine on the
  server side that'll need similar treatment to suggested-workout.
- **Sleep / Body** depend on external integrations (HealthKit / Oura
  / Withings) — separate conversation about whether to keep those
  server-side or pull client-side.

— end of handoff —
