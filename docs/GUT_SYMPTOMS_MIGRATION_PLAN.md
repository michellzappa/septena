# Gut → Symptoms migration plan

Move the symptom-shaped data out of the Gut bowel-movement log and into the
Symptoms section. After this, **Gut is a pure Bristol log** (type + volume +
note) and **every flag — blood, discomfort, and general GI symptoms — lives in
Symptoms** as first-class, separately selectable symptom types.

Status: **built (Phase A), uncommitted, 2026-06-12.** All 3 schemes BUILD
SUCCEEDED, SeptenaCoreTests 35/35, gateway typecheck clean. Lossless, staged
(copy → verify → strip-surfaces). The dormant storage + migrator seam stay until
Phase B.

## What shipped (Phase A)

- **Migrate (copy):** `GutSymptomMap` (pure, tested), `SymptomsMutator`
  `ensureDefinition`/`upsertMigratedEvent`, `GutSymptomMigrator`
  (`gut.symptomMigration.v1` gate, runs post-fetch in `start()`). 6 digestive
  starters added.
- **Strip surfaces:** removed blood + discomfort from the Gut editor, detail
  lines (destination + browse-day), dashboard tile (now shows avg Bristol),
  export columns, the two goal metrics (`gut.blood_count`/`gut.discomfort_count`),
  onboarding, Coach/Virtue gut summaries, and both MCP servers
  (`gut_event_log`/`gut_events_list` lose blood/discomfort, keep volume) +
  `skill.md`. `GutMutator.addEntry/updateEntry` lost the symptom params.
- **Kept dormant (the migrator seam):** `GutEventEntity.blood/discomfort*` storage
  + CK `GutEvent` field mapping. Stripping these is **Phase B**, a later release
  *after* the migration has run on all the user's devices — removing them now
  would delete the source before the gated migrator reads it.

## Verify (do this before Phase B)

Launch the app once; the migrator logs
`GutSymptomMigrator: upserted N symptom events from M gut rows` (expect the two starter types:
Abdominal discomfort and Blood in stool events). Confirm they appear in Symptoms with
aligned timestamps before removing the dormant storage.

## Why

Gut today is a bowel-movement log where the "symptom-ish" data are *fields on a
movement* (`blood`, `discomfortLevel` + window), not standalone events. The
schema can't express "bloated at 3pm, no movement." Dedicated gut apps keep the
stool log minimal (Bristol type) and treat blood/pain/bloating as separate
symptom flags. Forcing `blood`/`discomfort` onto every movement row is
over-specialized; generalizing them as symptoms is what works for most people
and lets the user isolate their own two chronic signals (blood, discomfort).

## Current state (verified)

- `GutEventEntity` (`SeptenaCore/Persistence.swift:733`): `id, occurredAt, date,
  bristol, blood, volume, discomfortLevel, discomfortStart, discomfortEnd, note`.
  CK type `GutEvent` (`Persistence.swift:1761`).
- `SymptomDefinitionEntity` / `SymptomEventEntity`
  (`Persistence.swift:829` / `:866`). CK types `SymptomDefinition` /
  `SymptomEvent` (`:1804`) — **not yet deployed to prod**.
- `SymptomStarter.all` (`SymptomsPlugin.swift:156`) already ships Nausea +
  Abdominal pain (both `bodySystem: "Digestive"`).
- The account's gut rows: some have `discomfortLevel`
  and some carry a `blood` flag. → N symptom events to
  create.

## Target shape

**Gut after:** `bristol` + `volume` + `note`. Drop `blood`, `discomfortLevel`,
`discomfortStart`, `discomfortEnd`.

**Symptoms catalog gains 6 digestive starters** (joining Nausea, Abdominal pain):
Bloating, Gas, Cramps, Reflux/Heartburn, **Blood in stool**, **Abdominal
discomfort**. The last two are also the migration targets and ship as universal
starters (legitimately general GI symptoms).

**Migration map:**

| Gut field | → definition | severity | carried |
|---|---|---|---|
| `discomfortLevel` (7) | Abdominal discomfort | low→3, med→6, high→9 | `occurredAt`; window→`durationMinutes`; `note` |
| `blood` > 0 (17) | Blood in stool | 1→3, 2→6, 3→9 | `occurredAt`; `note: "with BM"` |

- Movement `note` attaches to the discomfort event if discomfort is present,
  else to the blood event, so it's never duplicated.
- `occurredAt` preserved → timeline stays aligned. Exact which-stool linkage is
  dropped (acceptable: rare flare events, timestamp lets you eyeball the match).

## Build order

### 1. Catalog — add digestive starters
`Septena/Shell/Sections/Plugins/SymptomsPlugin.swift` (`SymptomStarter.all`):
add Bloating, Gas, Cramps, Reflux/Heartburn, Blood in stool, Abdominal
discomfort. Stable `starter-*` ids, `bodySystem: "Digestive"`, sensible regions
(Abdomen / Stomach / Rectum).

### 2. Migrator (copy, idempotent)
New one-shot migrator (mirror the consumables-purge record-level migrator
pattern; run from `SeptenaServices.start()` behind a `SettingsKey` done-flag).
For each `GutEventEntity`:
- if `discomfortLevel` non-empty → upsert `SymptomEvent` with deterministic
  `id = shortHash("gut-discomfort:" + gutEvent.id)`, `symptomID` =
  "Abdominal discomfort" definition (create from starter if absent), severity
  per map, `durationMinutes` from `discomfortStart/End` span, `occurredAt`,
  `note`, `source: "migrated-gut"`.
- if `blood > 0` → upsert `SymptomEvent` `id = shortHash("gut-blood:" + id)`,
  "Blood in stool" definition, severity per map, `occurredAt`, note `"with BM"`.
- Upsert keyed on deterministic id → re-running is a no-op (no dupes, CK-safe).
- Go through `SymptomsMutator.addEvent` / a mutator upsert path — **never write
  entities directly** (write-boundary invariant).
- Definitions created via `SymptomsMutator.addDefinition`; ensure-once by title.

### 3. Verify gate
After migration, assert created count == (#discomfort + #blood). Log result.
Only after this is confirmed do we proceed to step 4 (separate change / commit so
there's a rollback window).

### 4. Strip Gut (separate change, after verify)
- `GutEventEntity`: remove `blood`, `discomfortLevel`, `discomfortStart`,
  `discomfortEnd`. Leave CK `GutEvent` fields orphaned (additive-only schema;
  harmless — stop reading/writing them).
- `GutMutator` (`SeptenaServices.swift:1929`): drop those params from
  `addEntry`/`updateEntry`.
- Gut editor `EditGutEntrySheet.swift`: remove the Blood + Discomfort form
  sections. `AddGutPage.swift` unaffected (Bristol palette only).
- `GutDestinationView.swift`: drop blood/discomfort from the detail line.
- `GutPlugin.swift`: remove export columns `blood, discomfortLevel,
  discomfortStart, discomfortEnd`; retire goal metrics `gut.blood_count` and
  `gut.discomfort_count` (replaced by `symptoms.*`). Update onboarding bullets.

### 5. MCP lockstep (both servers, same change)
- In-app: `MCPToolCatalog.swift:392` + `MCPDispatch.swift:894` — `gut_event_log`
  loses `blood`, `volume`?(keep volume), `discomfortLevel/Start/End`;
  `gut_events_list` output drops `blood`/`discomfortLevel`. `volume` stays.
- Hosted gateway (`../septena-mcp-gateway`): same edits to the gut tools.
- Regenerate `skill.md` from `SectionRegistry.fullSkillMarkdown()` so the gut
  skill brief no longer advertises blood/discomfort.

### 6. Docs
- `docs/CloudKitSchema.md`: note `GutEvent.blood/discomfort*` orphaned; Symptoms
  unchanged (already pending prod deploy).
- `docs/ADDING_A_SECTION.md` / section skill text if they reference gut fields.

## Open micro-choices (recommended defaults)
- Naming: **"Blood in stool"** (plainer) over "Rectal bleeding".
- Ship blood/discomfort as **universal starters**, not user-only.

## Traps
- Symptoms CK type still pending prod deploy → migration is dev/local-first,
  rides the prod cutover (`docs/prod_cutover`). Migrated events won't sync to
  prod until that schema lands.
- Build tree is mid-purge (`purge-legacy-consumables` branch) — verify all three
  schemes compile before/after.
- Don't run the migrator before the catalog step (definitions must exist).
