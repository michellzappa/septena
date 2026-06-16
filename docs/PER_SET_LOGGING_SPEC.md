# Per-Set Logging — Spec

Status: **proposed** (not built). Owner: Training section.
Related: the effort-scale work ([RIR/Difficulty](../README.md)), `TrainingEffort.swift`,
`docs/CloudKitSchema.md` (record type `ExerciseEntry`).

## Problem

Today a logged strength entry is **aggregate**: one `ExerciseEntry` row carries
`sets:"3"`, `reps:"8"`, `weight:100`, `difficulty:"hard"`. That collapses a real
working set sequence — `100×8 @RIR1`, `100×7 @RIR1`, `95×6 @RIR0` — into a single
averaged-looking row. We lose:

- **Per-set fatigue drop-off** (8 → 7 → 6 reps), the core progression signal.
- **Per-set effort.** The new RIR scale is recorded once for the whole exercise,
  but RIR is *inherently per-set* — the last set is where you hit RIR 0, not the
  first. One difficulty for three sets is the weakest part of the current model.
- **Honest volume.** `effectiveHardSets` multiplies `sets × difficulty-weight`, so
  three sets all inherit one difficulty. A 3-set entry logged "hard" counts as 3
  hard sets even if only the last was truly hard.

This is the structural ceiling I flagged when we chose the one-axis effort model:
RIR only earns its keep once it's captured **per set**.

## Goal

Capture each working set as its own `{weight, reps, rir}` tuple, drive analytics
and progression off the real sequence, and keep the input fast enough for the gym
(the dominant action is "+ set, same as last, log").

Non-goals: warm-up tracking, tempo, rest-per-set logging, RPE-as-decimals,
supersets (separate effort).

## Data model — three options

### Option A — one `ExerciseEntry` record per set (row-per-set)
Each set is an existing entry with `sets:"1"`, its own `reps`/`weight`/`difficulty`,
grouped for display by `(date, sessionType, exercise, time)`.
- **+** Most normalized; zero new fields (maybe an additive `setIndex:Int`).
- **−** Record count ~3× ; every history/log/aggregation view and the "one card =
  one entry" assumption in `DraftSession`/`markDone` has to learn grouping. High
  blast radius across the log list, `LogRow`, MCP `training_entries_list`, exports.

### Option B — embedded per-set breakdown on the existing row  ✅ recommended
Keep **one row per exercise**, add a single additive field `setLog` (String, JSON):
`[{ "w":100,"r":8,"rir":1 }, { "w":100,"r":7,"rir":1 }, { "w":95,"r":6,"rir":0 }]`.
The existing `sets`/`reps`/`weight`/`difficulty` stay populated as a **summary**
(set count, top-set weight, hardest set's difficulty) so every current reader,
chart, export, and MCP client keeps working untouched.
- **+** Additive single CloudKit field (no zone reset, no schema-order deadlock);
  preserves the one-card/one-entry model and all grouping/history code; legacy
  rows simply have no `setLog` and render as a single summary set; new readers
  prefer `setLog` when present.
- **−** Per-set data isn't server-queryable (filtered client-side — which is
  already our constraint, see `feedback_gateway_date_filtering`). `setLog` and the
  summary fields must be kept consistent on write.

### Option C — child `ExerciseSet` CloudKit record type
A normalized child referencing its parent `ExerciseEntry`.
- **+** Fully queryable per-set; cleanest long-term.
- **−** New record type + reference syncing in `CKEngine`, biggest migration,
  most sync surface. Reserve for if/when server-side per-set queries are needed.

**Recommendation: Option B.** It matches how the app already carries rich data,
stays additive and back-compatible, and keeps the gym-input and history paths
intact. Revisit C only if a server-side per-set query becomes a hard requirement.

## Schema (Option B)

`docs/CloudKitSchema.md` → `ExerciseEntry`: add one nullable field.

| Field | CK Type | Swift | Notes |
|---|---|---|---|
| `setLog` | String | `String?` | JSON array of `{w:Double?, r:Int?, rir:Int?}`, in set order. Nil = legacy aggregate row. |

- `ExerciseEntryEntity` gains `var setLog: String?` (SwiftData lightweight add).
- `DraftEntry` gains `var setRows: [SetRow]` (transient, drives the card); on
  `markDone` it encodes to `setLog` **and** recomputes the summary fields:
  `sets = setRows.count`, `weight = topSet.weight`, `reps = topSet.reps`,
  `difficulty = hardest set's key` (min RIR → `TrainingEffort` key).
- `SetRow = { weight: Double?, reps: Int?, rir: Int? }`. RIR (not difficulty
  string) is the per-set canonical here, mapped through `TrainingEffort` for
  display; the summary `difficulty` is derived for legacy consumers.

## Reads / analytics

- `effectiveHardSets` & `weeklyVolumeTrend`: when `setLog` present, count **actual**
  hard sets (per-set RIR ≤1 / difficulty hard|max) instead of `count × one weight`;
  fall back to today's aggregate logic when absent. This makes the volume number
  honest for both old and new data.
- `liftedKg` (Live Activity) and PR/`recentByExercise`: prefer the real set list;
  PR = best single set.
- `DifficultyGlyph` / row summary: show the summary difficulty (hardest set);
  optionally a "3×" multiplier hint.

## UI (the gym card)

- The expanded `TrainingExerciseCard` becomes a **running set list**: each logged
  set is a compact row (`100 × 8 · RIR 1`), with the live editor at the bottom.
- Primary action is **"+ Set"** → clones the previous set (weight/reps/RIR
  pre-filled from the last row, or from `lastByExercise` for set 1), so a straight-
  across triple is three taps. Edit any row inline; swipe to delete.
- Per-set RIR/difficulty uses the **existing 4-pill picker** (`difficultyPicker`),
  now bound to the set row instead of the whole entry.
- "Done" finalizes the exercise (encodes `setLog`, writes summary, starts the
  rest timer — already built). Rest timer triggers on each **+ Set**, not just
  on exercise-done, so the countdown matches real between-sets rest.

## MCP (lockstep — both servers + skill)

- `training_entry_log` / `training_entry_update` gain an optional `sets` array
  param: `[{weight, reps, rir}]`. When provided, the gateway/in-app server writes
  `setLog` + derives the summary fields; when only the flat `weight/sets/reps`
  are sent (today's contract), behavior is unchanged.
- `training_entries_list` returns `setLog` (parsed) when present.
- Update `SectionRegistry` skill brief + the gateway `skill.md` in the same change.

## Back-compat & migration

- **No migration needed.** Legacy rows (`setLog == nil`) render as one summary set
  and score exactly as today. New writes populate both. A row edited in the new UI
  upgrades itself (writes `setLog`).
- The summary fields remain the source of truth for any reader that doesn't know
  about `setLog`, so old app versions / the current gateway keep working.

## Watch

- Watch logging stays summary-level for v1 (one weight/reps/RIR → a 1-set `setLog`
  or just the aggregate). Per-set on the wrist is a later pass.

## Phasing

1. **Schema + model**: add `setLog` (CK additive + `ExerciseEntryEntity` + decode);
   `SetRow`, `DraftEntry.setRows`; summary-derivation on `markDone`. No UI yet —
   single-set writes round-trip identically.
2. **Card UI**: set-list + "+ Set" + per-set RIR; rest timer per set.
3. **Analytics**: honest hard-set counting + PR from real sets.
4. **MCP**: `sets[]` param in both servers + skill.
5. **Prod**: deploy the additive `setLog` field; backfill not required.

## Open questions

- Summary `difficulty` when sets span rungs: hardest set (proposed) vs last set?
- Show per-set RIR in the history log, or only in the exercise detail view?
- AMRAP sets (`reps:"AMRAP"`): a `SetRow` with `reps:nil` + an `amrap:Bool`?
