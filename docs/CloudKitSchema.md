# CloudKit Schema Manifest

> **Source of truth:** the Swift `*CloudKitSchema` enums + their `makeRecord`/`apply`
> functions. This doc is **derived from code** (commit `671d48b`, 2026-06-06) and is
> meant to be regenerated when the schema changes — it is *documentation of* the code,
> not a checked-in `.ckdb`. CloudKit's Development schema is auto-created from whatever
> the app first writes, so **this manifest === the Development schema**.
>
> **Purpose:** give a 1=1, field-level view of every record type so the
> Development → Production schema promotion can be verified by eye in the CloudKit
> Console. See [§ Production deploy](#production-deploy).

## How CloudKit schema promotion actually works

This is **not** SQL DDL. There is nothing to run.

- **Dev schema is auto-managed.** First write of a new record type or field in a debug
  build registers it in the Development environment automatically.
- **"Deploy Schema Changes to Production"** (CloudKit Console) promotes **record types,
  fields, and indexes only — never records.** It is **additive and one-way**: you cannot
  rename, retype, or drop a field in Production, and you cannot un-deploy.
- **Records (your actual data) do not move.** Production's private DB starts empty.
  Moving data is a separate step — see [`prod-cutover-plan`](../) memory / the migration
  routine, not this doc.

Because promotion is additive-only, the safe discipline is: **this manifest is the
target shape; the Console's Production schema must be a subset of it after deploy.**

## Topology

| Property | Value |
|---|---|
| Container | `iCloud.com.septena.cloud` |
| Database | **Private** (per-user) for everything below |
| Sync zone | `septena-v1` (custom zone, driven by `CKSyncEngine`) — holds the app's user record types |
| Out-of-band | `WatchSnapshot` lives in the **default zone**, written directly (NOT via the sync engine) |

Sync uses **zone-change fetches, not `CKQuery`** — so queryable/indexable fields are *not*
required for the app's own sync. They *are* required for any consumer that runs a
`CKQuery` (the MCP gateway; the `fetchAllRecords(recordTypes:)` repair path in
`Migration.swift`). See [§ Gotchas](#gotchas).

---

## Production deploy — the pending changelog

Promotion is additive, so all that matters is: **what exists in Dev that Production
must also have.** These known-recent additions (all build-verified on Dev, never yet
promoted to Prod unless the Console already shows them):

| # | Change | Record type(s) | Field(s) | Type |
|---|---|---|---|---|
| 1 | **New field** `occurredAt` | `HabitEvent`, `SupplementEvent`, `ChoreEvent`, `GutEvent`, `CaffeineEvent`, `CannabisEvent`, `ExerciseEntry` (7 existing event types) | `occurredAt` | Timestamp(Date) |
| 2 | **New record type** `MoodEvent` (whole type, 9 fields incl. its own `occurredAt`) | `MoodEvent` | all | — |
| 3 | **New field** `bucket` (optional supplement time-bucket) | `SupplementDefinition` | `bucket` | String |
| 4 | **New record type** `GoalMilestone` (whole type, 9 fields — latched achievement events) | `GoalMilestone` | all | — |
| 5 | **New record type** `ActivityDaySum` (read-once HealthKit daily summaries — steps / active kcal / exercise minutes) | `ActivityDaySum` | all | — |
| 6 | **New record types** for Symptoms | `SymptomDefinition`, `SymptomEvent` | all | — |
| 7 | **New record types** for Medications | `MedicationDefinition`, `MedicationDoseEvent` | all | — |
| 8 | **New field** `rhythmPayload` (optional rhythm-wheel widget blob) — default-zone `WatchSnapshot`, additive/ephemeral like `payload` | `WatchSnapshot` | `rhythmPayload` | Bytes(Data) |

`MoodEvent` reuses the CloudKit record slot vacated by the retired `AirReading` type
(Air section removed in the same merge). It is a *new* type from Production's point of
view regardless.

> ⚠️ **Unknown:** whether Production already has a baseline schema. The app has run
> Development-only, so Production may be **empty** (never deployed). If so, the entire
> manifest below is the deploy target, not just these three deltas. **Verify the
> Production schema state in the Console first** — don't assume the baseline exists.

### Deploy procedure

1. In a debug build, confirm every type/field below exists in **Development** (CloudKit
   Console → Schema → Record Types). Auto-registered on first write; force a write of
   each section's data if any are missing.
2. CloudKit Console → **Deploy Schema Changes to Production**. Review the diff — it
   should match the changelog above (or the full manifest if Prod was empty). Additive;
   no zone reset.
3. Verify each promoted type/field appears under the Production environment.
4. **Only then** migrate data and flip the gateway (separate steps — see cutover plan).

### Verification checklist (Console, post-deploy)

- [ ] `occurredAt : Timestamp` present on all 7 event types **and** `MoodEvent`
- [ ] `MoodEvent` record type exists with all 9 fields
- [ ] `SymptomDefinition` and `SymptomEvent` record types exist with all fields
- [ ] `MedicationDefinition` and `MedicationDoseEvent` record types exist with all fields
- [ ] `SupplementDefinition.bucket : String` present
- [ ] No type was promoted with a **different** field type than this manifest (additive
      mistakes can't be undone — if types diverge, the field is permanently wrong in Prod)

---

## Dev schema reconciliation (verified 2026-06-06)

Diffed the actual **Development** schema export against this code-derived manifest.
Three buckets. The third is the one that can break Production — read it first.

### 🔴 C. In code, MISSING from the Dev schema → **will fail to write in Production**

Production (unlike Development) does **not** auto-register fields on first write — the
schema is locked. Any field the app can write that isn't in the deployed Production
schema causes that record's save to **fail** (stuck `CKSyncEngine` change / broken sync).

These fields exist in code but never registered in Dev because they're optional and were
**never exercised in the dev build** (no record ever set a non-nil value):

| Record type | Missing field(s) |
|---|---|
| `Area` | `context` |
| `Project` | `completedAt`, `context`, `githubRepo` |
| `SessionType` | `kind` |
| `NutritionEntry` | `mealType`, `sugarG`, `saturatedFatG`, `alcoholG`, `sodiumMg`, `cholesterolMg`, `potassiumMg` |
| `NutritionDaySum` | `sugarG`, `saturatedFatG`, `alcoholG`, `sodiumMg`, `cholesterolMg`, `potassiumMg` |

**Fix (required before deploy):** in a Development build, write each field once so it
auto-registers — set a Project's `githubRepo`/`context` and complete one, set an Area
`context`, set a `SessionType.kind`, log a meal that populates every macro
(`sugarG`/`saturatedFatG`/`alcoholG`/`sodiumMg`/`cholesterolMg`/`potassiumMg`). Confirm
they appear in the Dev schema, **then** Deploy to Production. Otherwise a real user
hitting any of these in Prod gets a silent write failure.

### 🟡 A. In Dev schema, no current writer → orphaned ("unused field") cleanup candidates

| Item | Status | Recommendation |
|---|---|---|
| `AirReading` (whole type) | Feature removed; gone from code | Delete from Dev before deploy, or it's permanent cruft in Prod |
| `Area.slug`, `Area.previousSlugs` | Orphaned — local SwiftData props remain, but **no `*Record.swift` encodes them** and the gateway neither reads nor writes them | Decide: revive the slug feature (then fix iOS to encode) **or** delete |
| `Project.slug`, `Project.previousSlugs` | Same as Area | Same decision |

These cause **zero functional harm** if promoted — the cost is permanence + tidiness.
Cleanup is optional, but now is the only cheap moment.

### 🟢 B. In Dev schema, not in the (iOS-derived) manifest, but legitimate → **keep**

| Item | Why it's real |
|---|---|
| `CannabisStrain` (whole type) | **Gateway-managed catalog** (`listCannabisStrains`/`createCannabisStrain` in `septena-mcp-gateway`), the cannabis analog of `CaffeineBean`. iOS doesn't touch it yet. |
| `Users` | CloudKit **system record type** (default `roles` field). Built-in; cannot/should not be deleted. |

> Everything else in the export matches the manifest exactly (27 types reconciled).
> Note this manifest's tables are **iOS-write-derived**; the gateway is a second writer,
> so `CannabisStrain` and the orphaned `slug` fields don't appear in them — see this
> section for the full truth.

---

## Field manifest

**Type legend:** `String`, `Int(64)`, `Double`, `Bytes`, `Timestamp` (Date), `List<String>`.
Swift→CloudKit mapping used: `String→String`, `Int→Int(64)`, `Bool→Int(64)` (0/1),
`Double→Double`, `Date→Timestamp`, `[String]→List<String>`, `Data→Bytes`. "Nullable" =
encode omits the field when the Swift optional is nil.

### Task graph — zone `septena-v1`

These six are the task backend, written by `SeptenaCore/CloudKit/*Record.swift`.

#### Task  — recordName = bare entity `id` (no prefix)
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `title` | String | `String` | No | |
| `status` | String | `String` (`statusRaw`) | No | |
| `created` | String | `String?` | Yes | YYYY-MM-DD |
| `scheduled` | String | `String?` | Yes | |
| `deadline` | String | `String?` (`due`) | Yes | key `deadline` ↔ Swift `due` |
| `today` | Int(64) | `Bool` | No | |
| `todaySetOn` | String | `String?` | Yes | |
| `completedAt` | String | `String?` | Yes | string, not Timestamp |
| `area` | String | `String?` | Yes | ref-by-string (area id) |
| `project` | String | `String?` | Yes | ref-by-string (project id) |
| `notes` | Bytes (ENCRYPTED_STRING) | `String?` | read-only | legacy; never written, decode fallback only |
| `notesText` | String | `String?` (`notes`) | Yes | plaintext replacement for legacy `notes` |
| `recurrenceUnit` | String | `String?` | Yes | |
| `recurrenceInterval` | Int(64) | `Int?` | Yes | |
| `recurrenceAfterCompletion` | Int(64) | `Bool` | No | |
| `source` | String | `String?` | Yes | provenance; gateway sets `"mcp"` |
| `sourceClient` | String | `String?` | Yes | provenance |
| `acknowledgedAt` | Timestamp | `Date?` | Yes | |
| `createdAt` | Timestamp | `Date` | conditional | written only when `!= .distantPast` (sentinel guard) |
| `position` | Double | `Double` | conditional | manual drag order; written only when `!= 0` |
| `parentTaskId`, `remindAt`, `reservedDate1`, `reservedDate2`, `reservedString1`, `reservedInt1` | — | reserved | — | over-provisioned slots; never encoded/decoded |

#### Area  — recordName `area:{id}`
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `title` | String | `String` | No | |
| `context` | String | `String?` | Yes | |
| `reservedString1`, `reservedString2`, `reservedDate1`, `reservedInt1` | — | reserved | — | |

#### Project  — recordName `project:{id}`
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `title` | String | `String` | No | |
| `status` | String | `String` (`statusRaw`) | No | |
| `area` | String | `String?` | Yes | ref-by-string (area id) |
| `created` | String | `String?` | Yes | YYYY-MM-DD |
| `completedAt` | String | `String?` | Yes | |
| `notes` | Bytes (ENCRYPTED_STRING) | `String?` | read-only | legacy; decode fallback only |
| `notesText` | String | `String?` (`notes`) | Yes | plaintext replacement |
| `context` | String | `String?` | Yes | |
| `githubRepo` | String | `String?` | Yes | |
| `reservedString1`, `reservedString2`, `reservedDate1`, `reservedInt1` | — | reserved | — | |

#### Section  — recordName `section:{id}`
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `title` | String | `String` | No | |
| `color` | String | `String` | No | |
| `isEnabled` | Int(64) | `Bool` | No | |
| `showInToday` | Int(64) | `Bool` | No | |
| `hasOnboarded` | Int(64) | `Bool` | No | |
| `updatedAt` | **String** | `Date` | No | ISO8601 **string**, not a Timestamp |
| `reservedString1`, `reservedInt1` | — | reserved | — | |

#### Settings  — recordName = `id`, singleton `"app"`
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `payloadJSON` | String | `Data` (`payloadData`) | Yes | JSON blob as UTF-8 string |
| `updatedAt` | **String** | `Date` | No | ISO8601 string, not a Timestamp |
| `reservedString1`, `reservedInt1` | — | reserved | — | |

#### Goal  — recordName `goal:{id}`
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `text` | String | `String` | No | |
| `sections` | List<String> | `[String]` | No | |
| `created` | String | `String` | Yes | YYYY-MM-DD |
| `sortIndex` | Int(64) | `Int` | No | |
| `metricKey` | String | `String?` | Yes | optional measurement attachment |
| `metricWindow` | String | `String?` | Yes | |
| `metricComparator` | String | `String?` | Yes | |
| `metricTarget` | Double | `Double?` | Yes | lower bound when comparator=range |
| `metricBaseline` | Double | `Double?` | Yes | |
| `metricTargetUpper` | Double | `Double?` | Yes | upper bound for `range` ("between"); **NEW — pending Prod deploy** |
| `reservedString1`, `reservedString2`, `reservedDate1`, `reservedInt1` | — | reserved | — | |

#### GoalMilestone  — recordName `gms:{id}`  · **⚠ ENTIRE TYPE PENDING PROD DEPLOY**
Latched achievement events (goal rungs / PRs / streak milestones — see
`docs/GOAL_MILESTONES_PLAN.md`). Entity `id` is deterministic
(`<scope>|<rungKey>`), so two devices detecting the same crossing write the
same recordName — a benign same-content conflict, never a duplicate.
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `goalID` | String | `String?` | Yes | nil for goal-less scopes (PR/XP/streak) |
| `scope` | String | `String` | No | `goal:{id}` \| `exercise:{slug}` \| `habit:{id}` \| `training.volume` |
| `kind` | String | `String` | No | rung\|pr\|xp\|streak |
| `rungKey` | String | `String` | No | e.g. `kg:78`, `pr:100`, `xp:25000`, `streak:30`, `halfway`, `target`, `held30` |
| `label` | String | `String` | No | user-facing, resolved at detection time |
| `value` | Double | `Double` | No | the crossed value |
| `occurredAt` | Date/Time | `Date` | No | when the crossing was detected |
| `celebrated` | Int(64) | `Bool` | No | 0 = granted silently (grandfathered/backfill) |
| `presentedAt` | Date/Time | `Date?` | Yes | queued-celebration shown; syncs so one device's showing silences the rest |
| `reservedString1`, `reservedDate1`, `reservedInt1` | — | reserved | — | |

#### CoachVoice  — recordName `coachVoice:{coachKey}`
One row per coach (coachKey = CoachDomain rawValue: training/food/accountability/wholeLife/custom). The user's per-coach tone dials. **NEW — pending Prod deploy.**
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `warmth` | String | `String` | No | gentle\|balanced\|direct |
| `brevity` | String | `String` | No | terse\|balanced\|detailed |
| `challenge` | String | `String` | No | supportive\|balanced\|pushy |
| `formality` | String | `String` | No | casual\|neutral\|formal |
| `note` | String | `String` | No | custom coach free-text (may be empty) |
| `reservedString1`, `reservedString2` | — | reserved | — | future: custom name, spoken-voice id |

#### CoachMessage  — recordName `coachMsg:{id}`
One row per message; a coach's transcript = all rows with that `coachKey`. **NEW — pending Prod deploy.**
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `coachKey` | String | `String` | No | CoachDomain rawValue |
| `role` | String | `String` | No | coach\|user |
| `text` | String | `String` | No | |
| `createdAt` | Date/Time | `Date` | No | |
| `sortIndex` | Int(64) | `Int` | No | per-coach order |

### Checklists — zone `septena-v1`

#### HabitDefinition  — `habit-def:{id}`
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `title` | String | `String` | No | |
| `emoji` | String | `String?` | Yes | |
| `bucket` | String | `String` | No | |
| `sortIndex` | Int(64) | `Int` | No | |

#### HabitEvent  — `habit-event:{id}`
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `date` | String | `String` | No | |
| `habitID` | String | `String` | No | |
| `done` | Int(64) | `Bool` | No | |
| `skipped` | Int(64) | `Bool` | No | |
| `note` | String | `String?` | Yes | |
| `time` | String | `String?` | Yes | |
| `occurredAt` | Timestamp | `Date` | No | **⚠ PENDING PROD DEPLOY** · default `.distantPast` |

#### SupplementDefinition  — `supplement-def:{id}`
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `title` | String | `String` | No | |
| `emoji` | String | `String?` | Yes | |
| `bucket` | String | `String?` | Yes | **⚠ PENDING PROD DEPLOY** · nil = "anytime" |
| `sortIndex` | Int(64) | `Int` | No | |

#### SupplementEvent  — `supplement-event:{id}`
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `date` | String | `String` | No | |
| `supplementID` | String | `String` | No | |
| `done` | Int(64) | `Bool` | No | |
| `note` | String | `String?` | Yes | |
| `time` | String | `String?` | Yes | |
| `occurredAt` | Timestamp | `Date` | No | **⚠ PENDING PROD DEPLOY** · default `.distantPast` |

#### ChoreDefinition  — `chore-def:{id}`
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `title` | String | `String` | No | |
| `emoji` | String | `String?` | Yes | |
| `cadenceDays` | Int(64) | `Int` | No | |
| `sortIndex` | Int(64) | `Int` | No | |

#### ChoreEvent  — `chore-event:{id}`
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `choreID` | String | `String` | No | |
| `action` | String | `String` | No | |
| `date` | String | `String` | No | |
| `newDueDate` | String | `String?` | Yes | |
| `reason` | String | `String?` | Yes | |
| `note` | String | `String?` | Yes | |
| `time` | String | `String?` | Yes | |
| `sortKey` | String | `String` | No | |
| `occurredAt` | Timestamp | `Date` | No | **⚠ PENDING PROD DEPLOY** · default `.distantPast` |

### Intake — zone `septena-v1`

#### CaffeineEvent  — `caffeine-event:{id}`
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `date` | String | `String` | No | |
| `time` | String | `String` | No | |
| `method` | String | `String` | No | v60/matcha/other |
| `beans` | String | `String?` | Yes | |
| `grams` | Double | `Double?` | Yes | |
| `note` | String | `String?` | Yes | |
| `occurredAt` | Timestamp | `Date` | No | **⚠ PENDING PROD DEPLOY** · default `.distantPast` |

#### CaffeineBean  — `caffeine-bean:{id}`
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `name` | String | `String` | No | |
| `sortIndex` | Int(64) | `Int` | No | |

#### CannabisEvent  — `cannabis-event:{id}`
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `date` | String | `String` | No | |
| `time` | String | `String` | No | |
| `method` | String | `String` | No | vape/edible |
| `strain` | String | `String?` | Yes | |
| `hit` | Int(64) | `Int?` | Yes | |
| `grams` | Double | `Double?` | Yes | |
| `note` | String | `String?` | Yes | |
| `occurredAt` | Timestamp | `Date` | No | **⚠ PENDING PROD DEPLOY** · default `.distantPast` |

### Body — zone `septena-v1`

#### GutEvent  — `gut-event:{id}`
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `date` | String | `String` | No | |
| `time` | String | `String` | No | |
| `bristol` | Int(64) | `Int` | No | |
| `blood` | Int(64) | `Int` | No | |
| `volume` | String | `String?` | Yes | |
| `discomfortLevel` | String | `String?` | Yes | |
| `discomfortStart` | String | `String?` | Yes | |
| `discomfortEnd` | String | `String?` | Yes | |
| `note` | String | `String?` | Yes | |
| `occurredAt` | Timestamp | `Date` | No | **⚠ PENDING PROD DEPLOY** · default `.distantPast` |

#### MoodEvent  — `mood-event:{id}`  · **⚠ ENTIRE TYPE PENDING PROD DEPLOY**
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `date` | String | `String` | No | |
| `time` | String | `String` | No | |
| `bucket` | String | `String` | No | morning/afternoon/evening (≠ SupplementDefinition.bucket) |
| `quadrant` | String | `String` | No | hap/han/lan/lap |
| `arousal` | Int(64) | `Int` | No | 1…3 |
| `valence` | Int(64) | `Int` | No | 1…3 |
| `emotion` | String | `String` | No | |
| `note` | String | `String?` | Yes | |
| `occurredAt` | Timestamp | `Date` | No | default `.distantPast` |

#### SymptomDefinition  — `symptom-definition:{id}`  · **⚠ ENTIRE TYPE PENDING PROD DEPLOY**
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `title` | String | `String` | No | |
| `emoji` | String | `String?` | Yes | user-owned optional glyph |
| `bodySystem` | String | `String?` | Yes | |
| `defaultBodyRegion` | String | `String?` | Yes | |
| `sortIndex` | Int(64) | `Int` | No | |
| `archived` | Int(64) | `Bool` | No | default `false` |
| `createdAt` | Timestamp | `Date` | No | |

#### SymptomEvent  — `symptom-event:{id}`  · **⚠ ENTIRE TYPE PENDING PROD DEPLOY**
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `date` | String | `String` | No | |
| `symptomID` | String | `String` | No | ref-by-string to `SymptomDefinition.id` |
| `severity` | Int(64) | `Int` | No | clamped 0...10 |
| `durationMinutes` | Int(64) | `Int?` | Yes | |
| `bodyRegion` | String | `String?` | Yes | |
| `side` | String | `String?` | Yes | left/right/both by convention |
| `quality` | String | `String?` | Yes | |
| `triggerNote` | String | `String?` | Yes | |
| `reliefNote` | String | `String?` | Yes | |
| `note` | String | `String?` | Yes | |
| `source` | String | `String?` | Yes | manual/mcp/etc. |
| `occurredAt` | Timestamp | `Date` | No | event timestamp |

#### MedicationDefinition  — `medication-definition:{id}`  · **⚠ ENTIRE TYPE PENDING PROD DEPLOY**
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `title` | String | `String` | No | |
| `genericName` | String | `String?` | Yes | |
| `form` | String | `String?` | Yes | tablet/capsule/liquid/etc. by convention |
| `route` | String | `String?` | Yes | oral/topical/etc. by convention |
| `strengthValue` | Double | `Double?` | Yes | |
| `strengthUnit` | String | `String?` | Yes | |
| `defaultDoseValue` | Double | `Double?` | Yes | |
| `defaultDoseUnit` | String | `String?` | Yes | |
| `bucket` | String | `String?` | Yes | morning/midday/evening/bedtime/anytime |
| `scheduleKind` | String | `String?` | Yes | `daily` or `asNeeded`; defaults daily in app |
| `targetDosesPerDay` | Int(64) | `Int?` | Yes | defaults 1 in app for daily meds |
| `instructions` | String | `String?` | Yes | |
| `sortIndex` | Int(64) | `Int` | No | |
| `archived` | Int(64) | `Bool` | No | default `false` |
| `createdAt` | Timestamp | `Date` | No | |

#### MedicationDoseEvent  — `medication-dose-event:{id}`  · **⚠ ENTIRE TYPE PENDING PROD DEPLOY**
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `date` | String | `String` | No | |
| `medicationID` | String | `String` | No | ref-by-string to `MedicationDefinition.id` |
| `status` | String | `String` | No | taken/skipped/missed |
| `doseValue` | Double | `Double?` | Yes | |
| `doseUnit` | String | `String?` | Yes | |
| `reason` | String | `String?` | Yes | |
| `effectNote` | String | `String?` | Yes | |
| `sideEffectNote` | String | `String?` | Yes | |
| `source` | String | `String?` | Yes | manual/mcp/etc. |
| `occurredAt` | Timestamp | `Date` | No | event timestamp |

### Wearables (read-only providers) — zone `septena-v1`

Both keyed by date: `recordName = <yyyy-MM-dd>`, so upserts are idempotent across
devices. No separate `date` field is stored.

#### OuraNight  — `oura-night:{yyyy-MM-dd}`
| Field | CK type | Swift | Nullable |
|---|---|---|---|
| `sleepScore` | Int(64) | `Int?` | Yes |
| `readinessScore` | Int(64) | `Int?` | Yes |
| `totalH` | Double | `Double?` | Yes |
| `deepH` | Double | `Double?` | Yes |
| `remH` | Double | `Double?` | Yes |
| `lightH` | Double | `Double?` | Yes |
| `awakeH` | Double | `Double?` | Yes |
| `efficiency` | Int(64) | `Int?` | Yes |
| `hrv` | Int(64) | `Int?` | Yes |
| `restingHr` | Int(64) | `Int?` | Yes |
| `bedtime` | String | `String?` | Yes |
| `wakeTime` | String | `String?` | Yes |
| `stressHighMin` | Int(64) | `Int?` | Yes |
| `recoveryHighMin` | Int(64) | `Int?` | Yes |
| `stressSummary` | String | `String?` | Yes |

#### WithingsRow  — `withings-row:{yyyy-MM-dd}`
| Field | CK type | Swift | Nullable |
|---|---|---|---|
| `weightKg` | Double | `Double?` | Yes |
| `fatPct` | Double | `Double?` | Yes |
| `fatMassKg` | Double | `Double?` | Yes |
| `fatFreeMassKg` | Double | `Double?` | Yes |
| `muscleMassKg` | Double | `Double?` | Yes |
| `hydrationKg` | Double | `Double?` | Yes |
| `boneMassKg` | Double | `Double?` | Yes |

### Training — zone `septena-v1`

#### ExerciseEntry  — `exercise-entry:{id}`
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `date` | String | `String` | No | |
| `time` | String | `String` | No | |
| `sessionType` | String | `String` | No | |
| `exercise` | String | `String` | No | |
| `weight` | Double | `Double?` | Yes | |
| `sets` | String | `String?` | Yes | |
| `reps` | String | `String?` | Yes | |
| `difficulty` | String | `String?` | Yes | |
| `durationMin` | Double | `Double?` | Yes | |
| `distanceM` | Double | `Double?` | Yes | |
| `level` | Double | `Double?` | Yes | |
| `note` | String | `String?` | Yes | |
| `concludedAt` | **String** | `String?` | Yes | ISO8601 **string** despite the name |
| `loggedAt` | **String** | `String?` | Yes | ISO8601 **string** despite the name — NOT a Timestamp |
| `occurredAt` | Timestamp | `Date` | No | **⚠ PENDING PROD DEPLOY** · the only true Timestamp here · default `.distantPast` |

#### ExerciseDefinition  — `exercise-def:{id}`
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `name` | String | `String` | No | |
| `type` | String | `String` | No | |
| `subgroup` | String | `String?` | Yes | |
| `aliases` | List<String> | `[String]` | No | |
| `sortIndex` | Int(64) | `Int` | No | |
| `primaryMuscle` | String | `String?` | Yes | |
| `secondaryMuscles` | List<String> | `[String]` | No | default `[]` |
| `archived` | Int(64) | `Bool` | No | default `false` |

#### SessionType  — `session-type:{id}`
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `label` | String | `String` | No | |
| `emoji` | String | `String?` | Yes | |
| `exercises` | List<String> | `[String]` | No | |
| `sortIndex` | Int(64) | `Int` | No | |
| `archived` | Int(64) | `Bool` | No | default `false` |
| `kind` | String | `String?` (`kindRaw`) | Yes | optional/back-compat; legacy rows → `SessionKind.defaulted(for: id)` |

### Nutrition — zone `septena-v1`

#### NutritionEntry  — `nutrition-entry:{id}`
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `loggedAt` | Timestamp | `Date` | No | true Timestamp; **pre-existing** (not pending) |
| `emoji` | String | `String?` | Yes | |
| `foods` | String | `String` | No | |
| `note` | String | `String?` | Yes | |
| `mealType` | String | `String?` | Yes | |
| `source` | String | `String?` | Yes | |
| `proteinG` | Double | `Double` | No | |
| `fatG` | Double | `Double` | No | |
| `carbsG` | Double | `Double` | No | |
| `fiberG` | Double | `Double?` | Yes | |
| `sugarG` | Double | `Double?` | Yes | |
| `saturatedFatG` | Double | `Double?` | Yes | |
| `alcoholG` | Double | `Double?` | Yes | |
| `kcal` | Double | `Double?` | Yes | user override |
| `sodiumMg` | Double | `Double?` | Yes | |
| `cholesterolMg` | Double | `Double?` | Yes | |
| `potassiumMg` | Double | `Double?` | Yes | |
| `waterMl` | Double | `Double?` | Yes | |
| `photoAssetID` | String | `String?` | Yes | |

#### NutritionDaySum  (recordType `NutritionDaySum`) — `nutrition-day:{yyyy-MM-dd}`
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `date` | String | `String` | No | |
| `entryCount` | Int(64) | `Int` | No | |
| `firstLoggedAt` | Timestamp | `Date?` | Yes | pre-existing |
| `lastLoggedAt` | Timestamp | `Date?` | Yes | pre-existing |
| `computedAt` | Timestamp | `Date` | No | pre-existing |
| `kcal` | Double | `Double?` | Yes | |
| `proteinG` | Double | `Double?` | Yes | |
| `fatG` | Double | `Double?` | Yes | |
| `carbsG` | Double | `Double?` | Yes | |
| `fiberG` | Double | `Double?` | Yes | |
| `sugarG` | Double | `Double?` | Yes | |
| `saturatedFatG` | Double | `Double?` | Yes | |
| `alcoholG` | Double | `Double?` | Yes | |
| `sodiumMg` | Double | `Double?` | Yes | |
| `cholesterolMg` | Double | `Double?` | Yes | |
| `potassiumMg` | Double | `Double?` | Yes | |
| `waterMl` | Double | `Double?` | Yes | |

### Activity — zone `septena-v1`

#### ActivityDaySum  (recordType `ActivityDaySum`) — `activity-day:{yyyy-MM-dd}`  · **⚠ ENTIRE TYPE PENDING PROD DEPLOY**
Read-once daily HealthKit movement summaries. Written by the iOS ingest only
(`HealthKitBridge.ingestActivityHistory`); the day string is the identity so
iPhone + iPad converge on one record per day. macOS reads these via sync (it has
no HealthKit of its own).
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `date` | String | `String` | No | `yyyy-MM-dd` |
| `stepCount` | Int(64) | `Int?` | Yes | nil when HealthKit had no step data that day |
| `activeKcal` | Double | `Double?` | Yes | active energy burned |
| `exerciseMinutes` | Int(64) | `Int?` | Yes | Apple exercise minutes |

### Groceries — zone `septena-v1`

#### GroceryItem  — `grocery-item:{id}`
| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `name` | String | `String` | No | |
| `category` | String | `String` | No | |
| `emoji` | String | `String` | No | |
| `low` | Int(64) | `Bool` | No | |
| `lastBought` | String | `String?` | Yes | |
| `sortIndex` | Int(64) | `Int` | No | |

#### GroceryCategory  — `grocery-cat:{id}`
| Field | CK type | Swift | Nullable |
|---|---|---|---|
| `name` | String | `String` | No |
| `sortIndex` | Int(64) | `Int` | No |

### Out-of-band — **default zone** (NOT the sync engine)

#### WatchSnapshot  — recordName fixed singleton `watch-next-snapshot`
Written directly to the private DB's **default zone** to stay clear of `CKSyncEngine`.
Overwritten on every checklist mutation / app foreground. Ephemeral — regenerated on
demand, so it is not part of the user-data migration, but its **type still needs to exist
in Production** for the watch/widget path to write.

| Field | CK type | Swift | Nullable | Notes |
|---|---|---|---|---|
| `payload` | Bytes | `Data` | No | `NextItemsResponse` JSON blob |
| `date` | String | `String` | No | YYYY-MM-DD |
| `updatedAt` | Timestamp | `Date` | No | a real Timestamp here (unlike Section/Settings) |
| `rhythmPayload` | Bytes | `Data` | **Yes** | `RhythmWire` JSON blob for the time-wheel widget — holistic 24h rhythm (all enabled sections' events + training bands, trailing 7 days). Additive; older records simply omit it. |

---

## Gotchas

- **Name ≠ type.** `Section.updatedAt`, `Settings.updatedAt`, `ExerciseEntry.loggedAt`,
  and `ExerciseEntry.concludedAt` are stored as **ISO8601 Strings**, not Timestamps —
  despite the names. `WatchSnapshot.updatedAt`, `NutritionEntry.loggedAt`, and the
  `Nutrition*` timestamps *are* real Timestamps. Getting this wrong in a manual Console
  field-add is unrecoverable (additive-only).
- **`occurredAt` is dual-written, never replaces `date`/`time`.** The string `date`/`time`
  fields stay load-bearing (TZ-stable day buckets, old clients, the gateway). Don't drop
  them.
- **Queryable indexes.** Sync doesn't need them (zone-change fetches), but the MCP
  gateway and the `fetchAllRecords(recordTypes:)` repair path run `CKQuery`, which
  requires the system `recordName` index to be **Queryable** in Production. Dev adds this
  automatically; Production may need it set per type. See [`feedback_gateway_date_filtering`].
- **Reserved fields** on Task/Area/Project/Section/Settings/Goal are over-provisioned
  slots, never encoded. They won't appear in the Dev schema until first written, so
  they're irrelevant to this deploy.
- **`cloudKitSystemFields` staleness** is the #1 data-migration failure mode (Dev etags
  replaying as `serverRecordChanged`) — but that's the *data* step, not this *schema*
  step. Out of scope here.

## Regenerating this doc

The field-key constants live in `*CloudKitSchema` enums:
`SeptenaCore/Persistence.swift` (lines ~1319–1732) and `SeptenaCore/CloudKit/*Record.swift`
+ `SeptenaCore/WatchSnapshotPublisher.swift`. Types are inferred from each `makeRecord`/
`apply` pair and the `@Model` property declarations. When you add/change a field, update
the matching table here and re-flag the changelog.
