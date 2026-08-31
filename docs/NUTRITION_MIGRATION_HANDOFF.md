# Nutrition → CloudKit Migration Handoff

> **Shipped — historical.** Nutrition runs on CloudKit + SwiftData through
> `NutritionMutator`; the record shapes below live for real in
> `docs/CloudKitSchema.md`, which is the authoritative field table. This file is
> kept for the migration reasoning and because `README.md` links it. The
> "Status: not started" line it used to carry was four months out of date.

Last updated: 2026-05-24 (status corrected 2026-08-23)

Sibling repos:
- iOS: `/Users/mz/Dev/septena` (this repo; formerly `septena-cloud`)
- FastAPI: `/Users/mz/Dev/septena-app`

Follows the proven recipe from
[`TRAINING_MIGRATION_HANDOFF.md`](TRAINING_MIGRATION_HANDOFF.md) and the
six already-migrated sections (tasks, habits/supplements/chores, goals,
gut/caffeine/cannabis, groceries, training). This doc covers what's
**different** about nutrition plus the file-by-file checklist.

## Why this is the right time

Six sections live on CloudKit; nutrition + sleep + body are still
on FastAPI. Nutrition is the next biggest write surface and has no
external-integration entanglement (unlike sleep/body which depend on
HealthKit/Oura/Withings) — so it's the natural next move.

Nutrition is **hermetic**: it does not read any other section's data.
Outbound coupling is the WeekDashboardView macro tiles + the
NextSuggestions card; both swap to local SwiftData reads with no
behavioral change.

## Design decisions (locked)

These choices were debated against "but the JSON+SQL backend is
flexible" — recorded here because **CloudKit Production schema is
forever-additive-only**. You can never rename, retype, or remove a field
after deploy. Every field below is a deliberate v1 commitment.

| Decision | Choice | Why |
|---|---|---|
| `foods` list shape | `\n`-joined `String` | Matches edit-sheet wire format. Accepts that per-food history view + barcode lookup are off the table for v1. |
| MacrosConfig location | `NSUbiquitousKeyValueStore` | Same as other prefs. No CK record schema for user targets. |
| `kcal` | Stored, user-overridable | Falls back to `4P + 9F + 4C + 7A` when nil. |
| Rollout | Single PR, hard cut | Matches training/groceries. No dual-write window. |
| Timestamps | `loggedAt` + `updatedAt` only | Drop `createdAt` (audit trail not surfaced anywhere). |
| Date/time strings | Dropped | `loggedAt: Date` (UTC) is the source of truth. |
| Daily aggregates | Synced `NutritionDailySummary` record per day | Cold-launch tiles + second-device sync don't recompute from scratch. |
| External access (MCP, webapp) | Punted | Same as every other CK section. Per-user `ckWebAuthToken` flow is a separate project. |
| Bootstrap safety | Dry-run + verify, then flip flag | Idempotent re-bootstrap if interrupted. |
| `schemaVersion: Int` | **Skipped** (known risk) | Old clients reading + writing a v2 record will silently strip new fields. `cloudKitSystemFields` limits blast radius. |

## Data model

Two new `@Model` entities in `SeptenaCore/Persistence.swift`.

### 1. `NutritionEntryEntity` — one row per logged meal/snack

```swift
@Model final class NutritionEntryEntity {
    @Attribute(.unique) var id: String        // UUID, CK record name suffix
    var loggedAt: Date                         // UTC, when meal happened
    var updatedAt: Date                        // last edit
    var emoji: String?
    var foods: String                          // \n-joined
    var note: String?
    var mealType: String?                      // breakfast|lunch|dinner|snack
    var source: String?                        // manual|import|barcode|mcp

    // Macros (g)
    var proteinG: Double
    var fatG: Double
    var carbsG: Double
    var fiberG: Double?
    var sugarG: Double?
    var saturatedFatG: Double?
    var alcoholG: Double?

    // Other nutrients
    var kcal: Double?                          // user override; falls back to 4P+9F+4C+7A
    var sodiumMg: Double?
    var cholesterolMg: Double?
    var potassiumMg: Double?
    var waterMl: Double?

    var cloudKitSystemFields: Data?
}
```

Record name: `nutrition-entry:<uuid>`

### 2. `NutritionDailySummaryEntity` — one row per day

Computed locally by `NutritionMutator` on every entry change, then synced
so other devices read totals without rescanning entries.

```swift
@Model final class NutritionDailySummaryEntity {
    @Attribute(.unique) var id: String         // YYYY-MM-DD in user's TZ at compute time
    var date: String                            // same
    var entryCount: Int
    var firstLoggedAt: Date?                    // fasting window detection
    var lastLoggedAt: Date?

    // Totals — nil when no entry that day reported the field
    var kcal: Double?
    var proteinG: Double?
    var fatG: Double?
    var carbsG: Double?
    var fiberG: Double?
    var sugarG: Double?
    var saturatedFatG: Double?
    var alcoholG: Double?
    var sodiumMg: Double?
    var cholesterolMg: Double?
    var potassiumMg: Double?
    var waterMl: Double?

    var computedAt: Date
    var cloudKitSystemFields: Data?
}
```

Record name: `nutrition-day:<YYYY-MM-DD>`

### Out of scope (compute, not data)

- `NutritionStatsResponse` — derived from `NutritionDailySummaryEntity` rows
- Fasting window detection — derived from consecutive days' `lastLoggedAt`/`firstLoggedAt`
- Macro deficit/surplus charts — derived from summaries + targets
- Macro recommendations engine — keep local-only or carry the existing
  client-side computation (see `NutritionRecommendations.swift`)

## Server side: one new endpoint

Add to `/Users/mz/Dev/septena-app/api/routers/nutrition/`:

```python
@router.get("/api/nutrition/export")
def nutrition_export() -> Dict[str, Any]:
    """Full snapshot for iOS CK bootstrap. Every entry on disk, no
    filter. iOS computes daily summaries client-side from these.
    """
    return {"entries": load_all_nutrition_entries()}
```

No catalog tables. No daily summaries from the server — iOS computes
them. Ship + deploy this *before* starting iOS work.

## iOS side: file-by-file checklist

### 1. `SeptenaCore/Persistence.swift` (~30 min)

Add the two `@Model` entities above. Add two CK schema enums
(`NutritionEntryCloudKitSchema`, `NutritionDailySummaryCloudKitSchema`)
with `recordType`, `Field` enum, `recordName(for:)`, `entityID(from:)`.
Add two `extension Foo: ChecklistCloudKitBackedEntity` blocks with
`toCloudKitRecord()` and `apply(_:)` plus the `convenience init(cloudKit:)`.
Register both entity types in the `LocalStore` `Schema([...])` list.

Record name prefixes: `nutrition-entry:`, `nutrition-day:`.

### 2. `SeptenaCore/CloudKit/CKEngine.swift` (~5 min)

Add four one-liners:
```swift
noteNutritionEntryChange(id:) / noteNutritionEntryDeletion(id:)
noteNutritionDayChange(id:)   / noteNutritionDayDeletion(id:)
```

### 3. `SeptenaCore/SeptenaServices.swift` (~45 min)

- `recordProvider`: two `hasPrefix` cases.
- `applyFetchedRecord`: two `case` arms.
- `applyDeletedRecord`: two cases.
- New `NutritionMutator` class (mirror `GroceryMutator`). Public methods:
  - `addEntry(loggedAt:emoji:foods:proteinG:fatG:carbsG:fiberG:sugarG:saturatedFatG:alcoholG:kcal:sodiumMg:cholesterolMg:potassiumMg:waterMl:mealType:source:note:)`
  - `updateEntry(id:...)`
  - `deleteEntry(id:)`
  - `rebuildSummary(forDay:)` — private; called from add/update/delete.
    Groups entries by `Calendar.current.startOfDay(for: loggedAt)`,
    sums each optional nutrient with nil-propagation (nil if no entry
    reported it), upserts the `NutritionDailySummaryEntity`, queues for
    CK upload.
- Wire into `SeptenaServices.shared`: declare `let nutritionMutator:
  NutritionMutator`, init in `init()`, `bind(ckEngine:)` in `start()`.

### 4. `SeptenaCore/Models.swift` (~10 min)

Add the export DTO:
```swift
struct NutritionExportResponse: Codable {
  let entries: [NutritionEntry]
}
```

`NutritionEntry` (the existing wire DTO) stays as-is; we just decode and
discard fields we don't store. The legacy `file` opaque-id stays on the
wire and becomes a soft historical field — generate fresh UUIDs on
bootstrap.

### 5. `SeptenaCore/SeptenaClient.swift` (~5 min)

Add one method:
```swift
func nutritionExport() async throws -> NutritionExportResponse {
  try await getJSON("/api/nutrition/export", as: NutritionExportResponse.self)
}
```

Mark the old ones for **deletion in the same PR** (don't leave them
around — hard cut):
- `nutritionEntries(since:)` ❌
- `nutritionStats(days:)` ❌
- `nutritionMacrosConfig()` ❌
- `addNutritionEntry(...)` ❌

### 6. `SeptenaCore/ChecklistMirror.swift` (~60 min)

Add a section block at the end with:
- `replaceAllNutritionExport(_ response: NutritionExportResponse, context:)` —
  upsert entries by id (generate fresh UUIDs since server `file` is opaque),
  delete locals the server doesn't know about. **Backfill rule**:
  parse server `date`+`time` strings as `TimeZone.current` to produce
  `loggedAt`. Set `updatedAt = loggedAt` (no edit history available).
  All optional nutrient fields stay nil.
- `rebuildAllNutritionSummaries(context:)` — group entries by day,
  produce `NutritionDailySummaryEntity` rows, upsert.
- `loadNutritionEntries(context:, since: Date?) -> [NutritionEntryEntity]`
- `loadNutritionSummaries(context:, days: Int) -> [NutritionDailySummaryEntity]`
  — newest-first; gap-fill missing dates with empty summaries
- `loadNutritionToday(context:) -> NutritionDailySummaryEntity?`

### 7. `SeptenaCore/CloudKit/Migration.swift` (~15 min)

- Add `BootstrapKey.nutrition`.
- Bootstrap block:
  1. `let response = try await client.nutritionExport()`
  2. `let serverCount = response.entries.count`
  3. `ChecklistMirror.replaceAllNutritionExport(response, context:)`
  4. `ChecklistMirror.rebuildAllNutritionSummaries(context:)`
  5. **Verify**: fetch local `NutritionEntryEntity` count. If
     `local != serverCount`, log `[Bootstrap] nutrition mismatch:
     local=N server=M` and **return without setting the flag** — user
     retries next launch or via Settings → Re-import.
  6. `queueNutritionMirrorForUpload()` — iterate entries + summaries,
     call `note*Change(id:)` on each.
  7. Set `BootstrapKey.nutrition`.
- Add `queueNutritionMirrorForUpload()` helper at the bottom.

### 8. MacrosConfig → `NSUbiquitousKeyValueStore` (~30 min)

Today `MacrosConfig` is fetched from `/api/nutrition/macros-config` and
cached. Replace with a `NutritionPrefs` actor (or struct + static
accessors) reading/writing from `NSUbiquitousKeyValueStore.default`
under keys like:
```
nutrition.target.proteinG
nutrition.target.fatG
nutrition.target.carbsG
nutrition.target.fiberG
nutrition.target.sugarG
nutrition.target.saturatedFatG
nutrition.target.alcoholG
nutrition.target.kcal
nutrition.target.sodiumMg
nutrition.target.cholesterolMg
nutrition.target.potassiumMg
nutrition.target.waterMl
nutrition.range.<field>.min / .max
nutrition.fasting.enabled
nutrition.fasting.windowStartHour
nutrition.fasting.windowEndHour
nutrition.macroColors.protein / .fat / .carbs / .fiber  (existing pattern)
```

UI surfaces only the targets you want today; the slots are ready for the rest.

### 9. Views (~3 hours total)

Same pattern as every prior section — replace `client.nutrition*` and
`outbox.enqueue("/api/nutrition/*")` with `ChecklistMirror.load*` and
`NutritionMutator` calls. Files to touch:

- `Septena/Sections/Nutrition/NutritionDestinationView.swift` — the big
  one. 7-day histogram + meal log grouped by day. Swap `entries` /
  `stats` / `macrosConfig` `.task` fetches for `@Query` on
  `NutritionEntryEntity` + `NutritionDailySummaryEntity` + a
  `NutritionPrefs` snapshot. Wire `reload()` +
  `.onReceive(.septenaDataChanged)` like `GroceriesDestinationView`.
- `Septena/Sections/Nutrition/EditNutritionEntrySheet.swift` — re-edit
  modal. `HTTPOutbox` PUT/POST becomes `nutritionMutator.updateEntry(id:...)`
  / `nutritionMutator.addEntry(...)`.
- `Septena/Sections/Nutrition/NewNutritionEntrySheet.swift` — same swap.
- `Septena/Sections/Nutrition/NutritionQuickAddMenu.swift` — reads
  history for "recent foods"; swap to `loadNutritionEntries(since:)`.
- `Septena/Sections/Nutrition/NutritionSearchSheet.swift` — reads
  `nutritionHistory`; swap to local fetch.
- `Septena/Sections/Nutrition/NutritionRecommendations.swift` — pure
  compute over entries + targets; targets now come from `NutritionPrefs`.
- `Septena/Sections/Nutrition/AddNutritionPage.swift` — likely no-op
  shim, may need no touch.
- `Septena/Shell/Dashboard/WeekDashboardView.swift` — three call sites
  (search `nutritionStats`, `nutritionEntries`, `nutritionMacrosConfig`).
  Swap to summary reads.
- `Septena/Shell/Dashboard/TodayLogView.swift` — same.
- Any `NextSuggestionsSection` reads — verify.

### 10. Settings Sync table + reset (~10 min)

- `Septena/Shell/Settings/SettingsView.swift`:
  - Add `nutrition` and `nutritionDays` (or whatever you name the
    summary count) to `DomainCounts`. Populate in `fetch()`.
  - Flip the **Nutrition** row from `.legacy` to `.cloudKit`. Show both
    entry count and day-summary count.
- In `runResetZone()`: fetch both entity types, clear
  `cloudKitSystemFields`, then `noteNutritionEntryChange` /
  `noteNutritionDayChange` for re-upload. Mirror the
  goals/groceries/training pattern.
- Macro color pickers (currently around line 1111–1143): point at
  `NutritionPrefs` instead of `store.macros`.

### 11. Commit (~5 min)

Single commit:
`feat(ck): migrate nutrition from FastAPI to CloudKit`

## Acceptance criteria

1. Build succeeds (`xcodebuild -scheme Septena -destination 'generic/platform=iOS' build`).
2. Tap "Re-import All Sections from FastAPI" in Settings → Sync. Verify
   log shows `[Bootstrap] nutrition imported: entries=N days=M`.
3. Open Nutrition tab — historical meal log, 7-day macro histogram,
   today's totals all render with real data.
4. Tap quick-add, log a new meal, save. Quit app, re-launch. New entry
   appears; today's summary tile updated.
5. Edit a logged entry's protein. Verify change persists across
   restart, and the day's summary reflects the new total.
6. Delete an entry. Verify it's gone after restart and summary
   recomputed.
7. Open WeekDashboardView nutrition tile — last 7 days render from
   summaries (not entries).
8. Verify on a second device that summaries arrive via CK pull (no
   client-side recompute needed on cold launch).
9. Settings → Sync shows **Nutrition: CloudKit (green checkmark)** with
   correct entry + day counts.

## Quirks & gotchas

1. **Backfill TZ caveat.** Server `date`+`time` strings have no
   timezone. Bootstrap interprets them as `TimeZone.current`. Entries
   logged during travel may shift by hours; entries near midnight may
   shift by a day. This was already ambiguous in the source — document
   in `TODO.md` and move on.

2. **All-nil summary fields.** If no entry on a given day reported
   `sodiumMg`, the summary's `sodiumMg` is nil (not 0). Tiles must
   render nil as "—" not "0 mg". Same rule for every optional
   nutrient.

3. **kcal fallback math** lives in one helper, applied on read:
   `entry.kcal ?? (4*proteinG + 9*fatG + 4*carbsG + 7*(alcoholG ?? 0))`.
   Summary sums the *effective* value (fallback if nil), not nil.

4. **Concurrent-edit failure mode** is last-write-wins on the whole
   record. Adding a food on phone while editing kcal on laptop offline
   = phone's add lost. This is an accepted tradeoff of `foods: String`.
   If users complain, add a child `FoodLogEntity` later (CK schema
   addition is forward-compatible).

5. **Validation moves client-side.** No server to reject `kcal < 0`,
   negative macros, malformed mealType. Enforce in `NutritionMutator`
   *and* in the edit sheet — both writers must validate.

6. **No external/web/MCP access** until per-user `ckWebAuthToken`
   capture is built. Document in `TODO.md`. Same as every other CK
   section.

7. **Summary record name is a date string in user's TZ.** A user
   crossing timezones might see the same calendar day's summary
   reshuffle. Acceptable for v1 (matches today's UX); if it becomes a
   problem, switch to UTC-day keys.

8. **Cross-section coupling is read-only.** `WeekDashboardView` and
   `NextSuggestions` consume nutrition but don't write. Migration is
   one-way safe.

9. **No history retention question.** Like training, nutrition keeps
   full history. Whole-history pull during bootstrap, no day filter.

10. **`schemaVersion` is intentionally absent.** Known risk: old
    clients round-tripping records may strip future fields.
    `cloudKitSystemFields` blob preserves CK-side metadata but doesn't
    save unknown application-level fields. If a v2 ships, gate writes
    behind a CK schema check at boot.

## When you're done

Move nutrition from "still on FastAPI" to "on CloudKit" in your mental
model, update this doc's status to **shipped**, and pick the next
section:

- **Sleep / Body** depend on HealthKit / Oura / Withings —
  separate conversation about whether to keep external pulls
  server-side or move them client-side.

— end of handoff —
