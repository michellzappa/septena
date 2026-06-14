# Spotlight Readability Plan — making Septena legible to Apple Intelligence

Status: **Phases 0–1 built, iOS + macOS green, pending on-device verification**
(2026-06-14). Companion to
`docs/CORE_AI_iOS27_PREP.md` (Track C0) and `docs/APP_INTENTS_BACKLOG.md`. This
doc owns the *readability* surface specifically: getting Septena's data into the
on-device Spotlight semantic index so Siri / Apple Intelligence can answer
questions about the user, not just take actions.

## Why this, why now

iOS's "personal context" Siri does **not** read an app's private storage. It
reads what the app **donates into Spotlight's semantic index**. The mechanism is
settled and verified against Apple's primary docs:

- **`IndexedEntity`** (refines `AppEntity`) — *"An interface that allows you to
  include an entity in your app's Spotlight index."* Apple: *"Adding entities to
  Spotlight makes them discoverable by Apple Intelligence."* It exposes
  `attributeSet` / `defaultAttributeSet` (`CSSearchableItemAttributeSet`, both
  have default implementations) and `hideInSpotlight`.
  **Availability: iOS/iPadOS 18.0+, macOS 15.0+** — *below our 26.0 floor, so no
  `@available` guard is needed.*
- Donation API (both iOS 18+, on `CSSearchableIndex`):
  - `func indexAppEntities(_ appEntities: [some IndexedEntity], priority: Int = 0) async throws`
  - `func deleteAppEntities<Entity>(identifiedBy: [Entity.ID], ofType: Entity.Type) async throws`
  - `func deleteAppEntities<Entity>(ofType: Entity.Type) async throws`
- Conformance alone does **not** index — you must donate, re-donate on change,
  and delete on removal.

The gap this plan closes: Septena has strong App Intents **writes** and
`AppEntity` resolution (pickers), but **zero** Spotlight indexing — so today Siri
can log for you but cannot recall anything you logged.

## Invariants (do not violate)

- **Observer-driven, not call-site-driven.** Every mutator already posts a
  scoped `.septena*Changed` / `DataChange` notification. The indexer reconciles
  off those signals instead of threading CoreSpotlight calls through every
  mutator method. One new mapping per entity type, never new call sites.
- **Respect the section gate.** Section enabled-state is user data
  (`SeptenaServices.isSectionEnabled(_:)` / `enabledSectionKeys()`, the same gate
  MCP + App Intents read). Disabling a section must **remove** its items from the
  index; re-enabling re-indexes. This is privacy-sensitive.
- **Not a third lockstep surface.** This is App-Intents/Spotlight only — no MCP
  tool changes, so the MCP lockstep rule doesn't apply here.
- **Index the synced mirror, not the pre-sync one.** Backfill runs *after*
  `services.absorbRemoteChanges()` in the launch path, never inside `start()`
  (which deliberately doesn't await a server round-trip).

## The one product decision (gates Phase 2 only)

`IndexedEntity` makes data "discoverable by Apple Intelligence." Two postures:

- **(A) Index-by-default, gated by section enablement** *(recommended for
  catalog entities)* — if a section is on, its items index; disabling purges.
  This matches today's model (enabling a section already exposes it to
  Siri/pickers/MCP). No new UI, one mental model.
- **(B) Opt-in per-section "Discoverable in Spotlight" toggle** — a new
  CloudKit-synced `SectionEntity` flag, default off, for the sensitive
  historical-log surface. More privacy-forward; costs a synced field + settings
  UI + onboarding copy + a second gate.

**Recommendation:** ship Phase 0/1 (catalog entities) under (A) — those are
already Spotlight-suggested via `AppEntity`, so indexing them changes nothing
privacy-wise. **Hold the (A)/(B) call for Phase 2** (meals, moods, workouts are
the sensitive surface). This decision blocks Phase 2 and is the product owner's.

---

## Phase 0 — one entity, end to end (BUILT — pending device test)

**Goal:** a Septena task appears in iOS/macOS Spotlight, attributed to the app,
donated on mutate, backfilled on launch, pruned on delete.

- **`Septena/App/Intents/TaskIntents.swift`** — `TaskChoice: AppEntity,
  IndexedEntity`; add a defaulted `notes` field (picker constructors unaffected)
  and an `attributeSet` (title → `title`/`displayName`, notes →
  `contentDescription`, broadening `keywords`).
- **`Septena/App/Intents/SpotlightIndexer.swift`** (new) — `@MainActor`
  singleton. `start()` observes `.septenaTasksChanged` and reconciles
  (debounced). `backfillTasks()` runs the same reconcile once at launch. Reconcile
  = fetch all `TaskEntity`, `indexAppEntities`, `deleteAppEntities(identifiedBy:)`
  for the diff against a **persisted** id snapshot (so a delete made while closed
  is still pruned next launch).
- **`Septena/App/App.swift`** — after the `app.absorbRemoteChanges` span, call
  `SpotlightIndexer.shared.start()` then `await …backfillTasks()`.

**Acceptance:** (1) create a task → it's findable in Spotlight, attributed to
Septena; (2) delete it → gone within seconds; (3) fresh install with existing
CloudKit data → tasks searchable after launch+sync.

**Risks / verify on device:** whether log-style entities rank in *personal-context
Siri* vs. literal Spotlight string-match (the whole thesis — Phase 0 is the
proof); re-index churn (full reindex each launch is fine at task volumes —
sentinel/incremental is a Phase 1 optimization).

## Phase 1 — roll across the other 7 catalog entities + section gating (BUILT — pending device test)

- `IndexedEntity` + `attributeSet` added to `HabitEntity`, `SupplementEntity`,
  `ChoreEntity`, `ExerciseChoice`, `TrainingSessionTypeChoice`,
  `GroceryItemChoice`, `GroceryCategoryChoice` (`Septena/App/Intents/*.swift`).
- `SpotlightIndexer` generalized: a generic `reconcile<E: IndexedEntity>` (index
  present, prune the diff) + one section-gated builder per type. Observes
  `.septenaTasksChanged` (tasks) and `.septenaDataChanged` (catalogs), debounced.
- **Section-gating solved without a SeptenaCore→app callback:** each builder
  returns `[]` when its section is disabled, so the existing prune step *is* the
  purge. The only SeptenaCore edit is `SettingsMirror.setSectionEnabled` (labeled
  overload) now posting `.septenaDataChanged` — it previously notified no one, so
  the main Settings toggle wouldn't have triggered a reconcile. (The positional
  overload already posted it.)

**Acceptance (device):** disabling a section purges exactly its items in seconds;
re-enabling restores them; renames/adds reflect within a beat.

## Phase 2 — high-value historical LOG events (blocked on the (A)/(B) decision)

Prioritized subset (richest text, highest "Siri knows what I did" value):
1. **Meals** — `NutritionEntryEntity` → `MealLogEntity` (foods, mealType, kcal,
   `loggedAt`). Section `nutrition`.
2. **Moods** — `MoodEventEntity` → `MoodLogEntity` (emotion, note, `occurredAt`).
3. **Workouts** — `ExerciseEntryEntity` → `WorkoutLogEntity` (exercise,
   sets/reps/weight, `occurredAt`).

Defer gut events (sensitive, low query value) and habit/supplement/chore
completions (better answered by aggregates/read-intents than per-event rows that
would flood the index). New `IndexedEntity` types in `Septena/App/Intents/`;
donate on `addEntry`/`updateEntry`/`deleteEntry`; use `occurredAt` for the
attribute's `startDate` so recency ranks. Consider a trailing-window cap (e.g.
12 months) for backfill volume.

**Acceptance:** "what did I eat yesterday" surfaces meal rows; disabling
Nutrition purges them.

## Phase 3 — read-intents (AI-9) + privacy toggle

- **Read-intents:** `hydration_today`, `nutrition_day_summary`, "what's on
  today" as `AppIntent`s returning dialog + snippet. These answer **aggregates**
  no per-row index can. Reuse existing summary logic; App-Intents-only (do not
  fork a third MCP surface).
- **Privacy toggle:** implement (B) only if product chose it.

---

## Build / verify

`xcodegen generate` after adding files (project.yml is source of truth). Then:

```
xcodebuild -scheme Septena    -destination 'generic/platform=iOS' -configuration Debug build
xcodebuild -scheme SeptenaMac -destination 'platform=macOS'       -configuration Debug build
```

On-device verification is mandatory per phase — Spotlight behavior, attribution,
and Apple-Intelligence discoverability of entities cannot be confirmed in a unit
test or simulator alone. Leave the tree green; the committer-cron commits.
