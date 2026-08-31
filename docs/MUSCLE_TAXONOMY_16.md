# 16-Group Muscle Taxonomy

Expands the `Muscle` enum from 10 → 16 groups so the per-muscle "sets this
week" view (reference: training apps' "sets per muscle / growth zone") can
surface sub-region imbalance — rear delts, lats vs upper back, forearms,
adductors — that the coarse 10-group model hides.

Decision locked 2026-06-09 (was 10; chose 16 over 12). Resolution model:
library is the standard source of truth, per-exercise stored tag is the
override/cache (see "Resolution" below).

## The 16 groups

`rawValue` is permanent (stored in CloudKit as a free string + emitted in MCP
enums). `label` is the display string. Order = anatomical, drives the grouped
picker and the card.

| # | rawValue      | label        | from (old 10) | notes |
|---|---------------|--------------|---------------|-------|
| 1 | `chest`       | Chest        | chest         | |
| 2 | `frontDelts`  | Front Delts  | shoulders     | pressing |
| 3 | `sideDelts`   | Side Delts   | shoulders     | lateral raises |
| 4 | `rearDelts`   | Rear Delts   | shoulders     | the hidden one |
| 5 | `lats`        | Lats         | back          | pulldowns / pull-ups |
| 6 | `upperBack`   | Upper Back   | back          | rows; traps/rhomboids |
| 7 | `biceps`      | Biceps       | biceps        | |
| 8 | `triceps`     | Triceps      | triceps       | |
| 9 | `forearms`    | Forearms     | — (new)       | grip / curls |
| 10| `quads`       | Quads        | quads         | |
| 11| `hamstrings`  | Hamstrings   | hamstrings    | |
| 12| `glutes`      | Glutes       | glutes        | incl. hip abduction (glute med) |
| 13| `calves`      | Calves       | calves        | |
| 14| `adductors`   | Adductors    | — (new)       | inner thigh; the Adduction machine |
| 15| `abs`         | Abs          | core          | |
| 16| `lowerBack`   | Lower Back   | core          | erectors; deadlift/back-ext |

## Migration (existing data)

No legacy fallback layer (decision 2026-06-09). Old rows store coarse 10 values
(`shoulders`/`back`/`core`); these are **migrated directly** to the precise
16-group raw values via the per-exercise backfill (tables below). A blanket
runtime map would be lossy for the splits (a `back` row can't be auto-resolved
to lats-vs-upperBack), so migration is per-exercise, which knows the answer.

Between the enum change shipping and the backfill running, an un-migrated
coarse value reads as unassigned (`Muscle(rawValue:)` → nil) — acceptable for
this single-user account; the backfill closes the window immediately.

No CloudKit schema deploy needed — the field is already a free string; only the
*values* change.

## Resolution

`muscle(for: exercise) = storedOverride ?? library[exerciseKey]`, with the
legacy fallback above for stale stored strings. Library is the standard for all
users; the stored tag is an override the user (or this backfill) sets.

## User catalog re-tag (a representative catalog)

| exercise | primary | secondary |
|---|---|---|
| ab-crunch | abs | — |
| abdominal | abs | — |
| abduction | glutes | — |
| adduction | adductors | — |
| arms | *(unassigned — user choice)* | — |
| biceps | biceps | — |
| calf-press | calves | — |
| chest-press | chest | triceps, frontDelts |
| chin-assist | lats | biceps |
| dead-lift | hamstrings | glutes, lowerBack |
| dip | chest | triceps, frontDelts |
| dip-assist | chest | triceps, frontDelts |
| diverging-seated-row | upperBack | lats, biceps |
| dumbbell-chest-press | chest | triceps, frontDelts |
| elliptical | *(cardio — none)* | — |
| lat-pull | lats | biceps |
| leg-curl | hamstrings | — |
| leg-extension | quads | — |
| leg-press | quads | glutes, hamstrings |
| rear-delt | rearDelts | upperBack |
| rowing | *(cardio — none)* | — |
| seated-row | upperBack | lats, biceps |
| shoulder-press | frontDelts | sideDelts, triceps |
| single-leg-press | quads | glutes |
| squat | quads | glutes, hamstrings, lowerBack |
| stairs | *(cardio — none)* | — |
| surya-namaskar | *(mobility — none)* | — |
| triceps-extension | triceps | — |

## Work inventory

**iOS / Core (this repo; formerly `septena-cloud`)**
- `SeptenaCore/Models.swift` — expand `Muscle` enum (16 cases, `label`, order),
  add legacy `Muscle(legacy:)` / fallback resolver.
- `SeptenaCore/DefaultExerciseLibrary.swift` — re-tag ~120 exercises to the new
  groups (the standard, for all users).
- `Septena/Sections/Training/ExerciseCatalogView.swift` — `musclePill` must map
  `raw → Muscle.label` (multi-word rawValues don't `.capitalized` cleanly);
  filter strip already iterates `Muscle.allCases`.
- `SeptenaCore/MCP/MCPToolCatalog.swift` — `muscleEnum` → 16 values.
- `SeptenaCore/MCP/MCPDispatch.swift` — `validMuscles` derives from enum (auto).
- `Septena/Shell/Sections/Plugins/TrainingPlugin.swift` — skill brief muscle list.
- One-time migration for stored values (core→abs etc.) if not relying on the
  read-time fallback alone.

**Gateway (`septena-mcp-gateway`)**
- `src/tools/training.ts` — `VALID_MUSCLES` → 16.
- `skill.md` — muscle list → 16.

**Then**: re-run the user-catalog backfill via `training_exercise_update`
(table above), and build the Phase 1 sets-per-muscle aggregation + card.
