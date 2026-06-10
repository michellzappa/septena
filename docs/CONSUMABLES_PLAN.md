# Consumables Generalization — Execution Plan

Status: build started. Owner: MZ. Date: 2026-06-10.
Companion to the rationale doc [`CONSUMABLES_GENERALIZATION_STUDY.md`](CONSUMABLES_GENERALIZATION_STUDY.md)
— that doc argues *why* and *what*; this doc is the *how*, the locked
decisions, the schema, and the milestone gates. Where they conflict, the study
holds the reasoning and this doc holds the current build state.

## Locked decisions

Each is argued in the study's §10; adopted here so the build doesn't re-open
them. Building on an unconfirmed one is the only way this produces rework.

| Decision | Locked value | Source |
|---|---|---|
| Noun | `intake` everywhere (section key, entity prefix, CK record types, recordName prefixes, tool prefix, metric prefix, export tables). Default label "Intake", renamable. | study §3.1 |
| Architecture | **Option C** — one `intake` host section, dashboard renders one tile *per kind*, destination is a kind switcher. NOT dynamic section instances (Option B). | study §5 |
| Template set | Caffeine + Tea + Custom only. No cannabis/alcohol/nicotine templates ship — the binary carries no review-sensitive noun. | study §4, §8 |
| Deletion | Archive-only kinds (`archivedAt`); no `kind_delete` tool. Single-event/item delete stays (correction ≠ destruction). Kind **merge** is a first-class op. | study §4.3, §7.2 |
| Migrator | **Record-level, permanent, deterministic ids.** Consumes raw `CKRecord`s by record-type string; survives deletion of legacy `@Model` classes. Ids are pure functions of source (`intake-event:caffeine:<legacyID>`). | study §7.1, §7.2 |

Kind ids are opaque (`ik-<uuid>`), never derived from names. Method *values*
stored on events are stable lowercase tokens, never display labels.

## Milestone 0 — feasibility spike (DONE 2026-06-10, both green)

The two assumptions that would have forced a replan, verified against code:

**Record-level migrator — FEASIBLE.** The CloudKit path is string/data-driven,
not class-driven: `CKSyncEngine` hands the app raw `CKRecord`s dispatched by
`record.recordType` string (`SeptenaServices.swift:416`, `CKEngine.swift:461`);
record types are not pre-registered, so legacy types stay fetchable forever for
free (`CKEngine.swift:331`); field reads are generic subscripts and
`cloudKitSystemFields` is an opaque `Data` blob — neither needs the legacy
`@Model` class. The migrator is *additive* cases in the existing
fetched/deleted/`recordProvider` switches that map legacy records →
`IntakeEvent`. No surgery to existing decode paths.

**Dynamic per-kind metrics — FEASIBLE (~20 lines).** `GoalMetricCatalog.all`
already recomputes on every read (no launch-time cache); the only blocker is
`SectionPlugin.aimMetrics` being a `static var`. Change it to
`aimMetrics(context:)` so `IntakePlugin` enumerates live kinds; `evaluateAim`
already takes the full metric so it can `hasPrefix("consumable.")`-match. Goals
store `metricKey: String?`, so an arbitrary runtime key evaluates fine. Every
other plugin stays unchanged via a default. No schema change.

## CloudKit record types (additive — coexist with legacy)

Drafted for `docs/CloudKitSchema.md` on schema deploy. Follows the existing
conventions there: `recordName` = `<type>:<id>`, `occurredAt`/`date` pairing,
`updatedAt`, system fields. All fields optional at the CK layer (additive-only
promotion).

### `IntakeKind` — recordName `intake-kind:<id>`
| Field | Type | Notes |
|---|---|---|
| id | String | opaque `ik-<uuid>` |
| name | String | user display name (mutable) |
| symbol | String | SF Symbol token |
| color | String | hex/hsl token (per-kind, not `SectionTheme`) |
| sortIndex | Int(Int64) | user order |
| unit | String? | "g" \| "mg" \| "ml" \| nil |
| doseStyle | String | "amount" \| "count" \| "both" \| "none" |
| countNoun | String? | "hit" \| "cup" \| "puff" |
| containerNoun | String? | "capsule" \| "pack" \| nil |
| containerCap | Int? | nil = no container model |
| catalogNoun | String? | "Beans" \| "Strains" \| nil |
| flourish | String | motion token ("bloom" \| "ripple" \| …) |
| metricMode | String | "countEvents" \| "sumAmount" |
| methodsJSON | String | ordered method rows (token,label,symbol,defaultAmount,usesContainer) as JSON |
| templateID | String? | seeding template, if any |
| archivedAt | Date? | hide-don't-delete |
| updatedAt | Date | |

Methods are a JSON column (study §3): CK-additive-friendly, vocabularies are
small, avoids a 4th record type and sync-ordering concerns.

### `IntakeItem` — recordName `intake-item:<id>` (generalizes `CaffeineBean`)
| Field | Type | Notes |
|---|---|---|
| id | String | |
| kindID | String | → IntakeKind |
| name | String | |
| sortIndex | Int(Int64) | |
| archivedAt | Date? | |
| updatedAt | Date | |

### `IntakeEvent` — recordName `intake-event:<id>` (generalizes both event types)
| Field | Type | Notes |
|---|---|---|
| id | String | migrated: `intake-event:caffeine:<legacyID>` etc. |
| kindID | String | → IntakeKind |
| occurredAt | Date | canonical UTC instant |
| date | String | YYYY-MM-DD local, indexed (gateway string-filters this) |
| method | String | stable token from the kind's method rows |
| itemID | String? | → IntakeItem |
| amount | Double? | in kind.unit |
| count | Int? | hits/uses; container math reads this |
| note | String? | |
| updatedAt | Date | |

Id/title contract for these three goes into `docs/IDENTIFIERS.md` at schema
draft time.

## Build order

Each milestone lands green and shippable. Phase mapping to the study's phases
1–4 noted. Acceptance gate in the right column.

| # | Milestone | Gate |
|---|---|---|
| **0** | Feasibility spike | ✅ DONE — both feasible |
| **1** | `ConsumableContainer` + golden tests vs `CannabisCapsule` | ✅ DONE — `SeptenaCoreTests`, 6 tests, behavioral identity proven |
| 2 | `IntakeKind`/`IntakeItem`/`IntakeEvent` entities + `IntakeMutator` + CK extensions + sync dispatch + `Schema` reg. No UI. | ✅ CODE-COMPLETE (iOS build green). NO dev dashboard step — CloudKit **Development** auto-registers a record type/field on first write (see docs/CloudKitSchema.md); the types register the moment the app saves one. Only **Production** deploy is manual (far-off cutover). |
| 3 | Record-level migrator + verification report | ✅ CODE-COMPLETE (iOS green; 11 hermetic tests on the pure id/field core). Integration round-trip vs real data runs in dev (no deploy needed). Live-sync migrate-on-sight hook wired at milestone 7 (flag-gated). |
| 4 | Generic destination + kind wizard + Manage sheet. Behind host section, debug-only entry (no manifest row). | ✅ CODE-COMPLETE (iOS green). Reached via Settings ▸ "Intake (debug)". Launch + manual smoke-test pending. |
| 5a | Manifest row (`intake`) + IntakePlugin (destination, onboarding+templates, per-kind `aimMetrics(context:)`, Settings pane) + registry + `aimMetrics(context:)` protocol change. | ✅ CODE-COMPLETE (iOS green + 30 hermetic tests). Section is enable-able from Manage Sections; goals can target per-kind metrics. Debug entry kept (destination route until 5b tile). |
| 5b | Dashboard tile-per-kind in `WeekDashboardView` (`HomepageDomain.intake` returns N kind-tiles; data via MirrorReader outside the HTTP loadAll; aggregate row for non-Tiles modes) + debug entry removed. | ✅ CODE-COMPLETE (iOS green). Prod schema deploy (additive) gates the phase-2 release; `ADDING_A_SECTION.md` update still pending. |
| 6 | MCP tools in **both** servers + skill regen + aliases (lockstep) | Gateway fixtures match in-app catalog; `skill.md` regenerated |
| 7 | **Phase 2** cutover: caffeine template seed + migrate + flag flip + goals remap. Soak. | Builds + tests entirely in dev (schema auto-registers). Worthwhile alone even if 8 never ships |
| 8 | **Phase 3**: cannabis synthesis from own data + kind merge + hygiene sweep + CI grep gate | iOS target contains no `cannabis` (case-insensitive) |
| 9 | **Phase 4**: legacy removal (migrator **stays** — it's record-level) | Legacy `@Model`/plugins/intents/tools gone; CK types dormant |

### Follow-up (not gating the above)
- Watch generalizes by rendering `SuggestionBlocks` rows received over `NextWire`
  instead of compiled-in ones; old cannabis wiring keeps working because
  `cannabisUsesPerCapsule`/`cannabisLastVapeHit` stay emitted from generic data.
- Dynamic `AppEntity` intents replace `CaffeineIntents`/`CannabisIntents`
  (kind/method become queries over user kinds).

## Open questions still live (study §9)

Not blocking milestones 1–4; decide before the surface they touch:
- Aggregate vs per-kind dashboard tile (Option C leans per-kind; cap at N). → milestone 5
- Template import format (MCP-only is zero-UI, fits agent-first). → milestone 6
- `CannabisStrain` gateway records: migrate into `IntakeItem` or leave dormant. → milestone 6
- Cost tracking per item/container (nicotine/alcohol budgets). → later or never
- HealthKit `dietaryCaffeine` write for mg-caffeine kinds. → future, opt-in
- Per-kind quick-log widgets. → future

## App Review posture

After milestone 8 the binary holds: a generic intake tracker, caffeine/tea
templates, a symbol picker including `leaf` among hundreds, no substance nouns
beyond coffee/tea. User kind names are user data — same review status as note
contents. Screenshots/metadata never show a cannabis tracker. Risk *reduction*,
not a guarantee; re-scan 1.4.3 at submission. Not legal advice.
