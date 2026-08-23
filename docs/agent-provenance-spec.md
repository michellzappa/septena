# Agent Provenance & Freshness Cue — Spec + Plan

**Status:** Draft · 2026-06-02
**Goal:** Items created (later: edited/completed) by the MCP gateway ("Claude") are visibly marked in the Septena UX, with a calm freshness cue that clears when the user engages and decays on its own.

---

## 1. Concepts (the two-field split)

Two things get conflated; keep them separate fields.

| | **Provenance** | **Freshness cue** |
|---|---|---|
| Question | *Who/what created this?* | *Have I seen it yet?* |
| Field | `source` (+ optional `sourceClient`) | derived from `source == agent && acknowledgedAt == nil` |
| Lifetime | **Permanent / immutable** — audit trail | **Transient** — clears on engagement, auto-decays |
| Writer | MCP server tool, at create | iOS app, on engagement |

The cue is **derived**, not stored. You store `source` and `acknowledgedAt`; the glow is `source == "mcp" && acknowledgedAt == nil && createdAt within window`.

---

## 2. Architecture reality (drives where things are stamped)

```
Claude (claude.ai)  ──bearer──►  Gateway Worker (mcp.septena.app)
                                        │  holds rotating ckWebAuthToken
                                        ▼
                                  CloudKit Web Services REST  ──writes "Task" record──►  user's PRIVATE DB
                                        ▲
   iOS app  ──ClaudeGatewayProvider pushes token every ~7h──┘

   iOS app  ◄── CKSyncEngine.fetchChanges() folds remote record into SwiftData ──
```

**Consequences:**
- Writes do **not** pass through the iOS app. The trustworthy choke point for the provenance stamp is the **MCP server tool code in the gateway Worker repo** (separate from this repo), not the app.
- The app's only jobs are: (a) read `source`/`acknowledgedAt` off the fetched record, (b) render the cue, (c) write `acknowledgedAt` back when the user engages, (d) never set `source = mcp` itself.
- Precedent already shipped: `nutrition_entry_log` sets `source = "mcp"` and `NutritionEntryEntity.source` round-trips through CloudKit. This spec is "do the nutrition pattern everywhere, add the cue."

---

## 3. Data model changes

### 3.1 Per-entity fields (SwiftData `@Model`)

No shared base entity exists — each `@Model` is standalone — so the fields are added per entity. v1 scope = **TaskEntity only**; the field names are fixed now so later sections are copy-paste.

Add to `TaskEntity` (`SeptenaCore/Persistence.swift`):

```swift
var source: String?           // nil/"user"/"manual" = human; "mcp" = agent. Permanent.
var sourceClient: String?     // friendly label, e.g. "Claude". Optional, permanent.
var acknowledgedAt: Date?     // nil until user engages. Transient cue state. (UTC instant)
var createdAt: Date           // canonical creation instant. (UTC instant) — see 3.1.1
```

- `source` values: `"app"` (authored in the Septena app), `"mcp"` (gateway/Claude); legacy rows are `nil` → treated as human. The app stamps `source="app"` + `sourceClient="Septena iOS/Mac/Watch"` on every native create. This gives positive provenance for app rows AND — crucially — **self-registers the `source`/`sourceClient` CloudKit fields in dev**: native CKSyncEngine writes auto-extend the dev schema, whereas the gateway's Web Services writes get rejected (dropped) until the field exists. So one in-app task create is what unblocks the gateway's `source="mcp"` from sticking.
- `acknowledgedAt` is a **synced** field (stored on the record), so dismissing on phone clears the cue on Mac. Native `Date` to match the app's instant convention (see below).

#### 3.1.1 `createdAt: Date` — the "one shape" for creation time

The app already standardized on **native `Date` (UTC instant; `NSDate` in CloudKit)** for every instant-in-time field: `occurredAt` on 8 event entities, plus `loggedAt`, `computedAt`, `lastSyncedAt`. The only holdouts are `TaskEntity.created` and `ProjectEntity.created`, still legacy `String? "YYYY-MM-DD"`. So the consistent shape is a `Date`, **not** an ISO string.

- **New field:** `createdAt: Date` (default `.distantPast` sentinel, mirroring the `occurredAt` migration pattern).
- **Name:** `createdAt`, not `occurredAt` — a task isn't an event; `occurredAt` means "when the logged thing happened." `createdAt` = "when it entered the system." Same *type*, honest *name*.
- **Legacy `created: String?` stays for now** as the wire/DTO field (`SeptenaTask`, gateway, `SeptenaDate`), with `createdAt` as the new source of truth. Fully retiring `created` touches the wire DTO + gateway and is a follow-up; flag it but don't block v1 on it.
- **Backfill:** add a `createdAt` pass to the existing one-shot migration (`OccurredAtBackfill` in `SeptenaCore/CloudKit/Migration.swift`, gated by a new UserDefaults key e.g. `"tasks.createdAtBackfill.v1"`): for each task, `createdAt = EventTimestamp.from(date: created, time: nil)` (→ local noon of the `created` day, the same rule used for day-granular events), then `ck.noteTaskChange(id:)` so it propagates. Rows with no `created` fall back to `.now`.
- **Writers going forward:** app sets `createdAt = Date.now` on user create; the **gateway** sets `createdAt` (NSDate, now) when it writes an MCP-created record.

### 3.2 CloudKit schema (record type `"Task"`)

Add to `TaskCloudKitSchema.Field` (`SeptenaCore/CloudKit/TaskRecord.swift`):

```swift
static let source = "source"               // CKString
static let sourceClient = "sourceClient"   // CKString
static let acknowledgedAt = "acknowledgedAt" // NSDate
static let createdAt = "createdAt"         // NSDate
```

Wire into `TaskEntity.toCloudKitRecord()` (write) and `TaskEntity.apply(_:)` (read). `acknowledgedAt` and `createdAt` map to CloudKit `NSDate`, matching every other instant field (`occurredAt`, `loggedAt`).

**Schema-registration trap (from memory `prod_cutover` / `gateway_date_filtering`):** these are new CloudKit fields. The CK schema is auto-managed and must learn the fields before either side writes them.
- **Dev:** first native app write with the field auto-creates it; do that before pointing the gateway at it.
- **Prod:** the prod schema deploy is already pending (per `project_event_occurred_at`) — fold these three fields into that same deploy rather than a separate one.
- Reads of records lacking the field must tolerate absence (optional `String?`, no force-unwrap) — mirror the existing `createWithFieldFallback`/optional-field handling so unknown-field writes/reads don't throw.

### 3.3 Gateway / MCP server — `../septena-mcp-gateway` (Cloudflare Worker, TypeScript)

The stamp lives in `createTask()` at `src/tools/writeTasks.ts:124`. The reference pattern is already in `src/tools/nutrition.ts:192` (`logNutritionEntry` sets `source: { value: "mcp" }`).

**3.3.1 Stamp the three fields.** In `createTask`'s `fields` object, add:

```typescript
const fields: Record<string, { value: unknown }> = {
  title:   { value: input.title },
  status:  { value: "open" },
  created: { value: todayYMD() },          // legacy YYYY-MM-DD string — KEEP
  createdAt:    { value: Date.now() },     // NEW — epoch ms → CloudKit TIMESTAMP (NSDate)
  source:       { value: "mcp" },          // NEW
  sourceClient: { value: "Claude" },       // NEW (see 3.3.3)
  today:   { value: input.today ? 1 : 0 },
};
// ...existing optional fields unchanged. Do NOT set acknowledgedAt → leaves it nil → cue on.
```

- **`createdAt` uses `Date.now()` (epoch milliseconds).** That's exactly how the gateway already writes `loggedAt`/`completedAt`; CloudKit Web Services infers TIMESTAMP from a numeric value, and it lands as `NSDate` — the same field the iOS app reads as `Date`. Keep writing the legacy `created` YYYY-MM-DD string too, until it's retired app-wide.
- Never trust a client-supplied "human" flag; the gateway knows every write here is via MCP.

**3.3.2 Switch `createTask` to `createWithFieldFallback` (the ordering fix).** Today `createTask` calls raw `modifyRecords` (`writeTasks.ts:136`), which fails the whole create if any field is unknown to the CK schema. `logNutritionEntry` instead uses `client.createWithFieldFallback({ ... protectedFields })` (`cloudkit.ts:298`), which drops unknown fields and retries. Adopt it for tasks:

```typescript
const { droppedFields } = await client.createWithFieldFallback({
  recordType: "Task",
  recordName: id,
  fields,
  protectedFields: ["title", "status", "created"],  // the new fields are NOT protected
});
```

Because `source`/`sourceClient`/`createdAt` are **not** in `protectedFields`, the gateway change is safe to deploy *before* the CloudKit prod schema learns them: creates still succeed (fields silently dropped), and provenance starts sticking the moment the schema catches up. This removes the deploy-ordering dependency between the two repos. Optionally surface `droppedFields` in the tool result for observability.

**3.3.3 `sourceClient` — hardcode `"Claude"` for v1.** The bound `clientId` exists in the access-token record but `getCkTokenForAccessToken()` (`storage.ts:133`) doesn't return it. Plumbing it through (return the full `AccessTokenRecord`, map `clientId` → friendly name) is a clean follow-up, but since only Claude connects to `mcp.septena.app` today, a literal `"Claude"` is correct now and costs nothing to generalize later.

**3.3.4 Out of scope for v1.** Don't stamp `tasks_update`/`tasks_complete`/`tasks_defer` — those are the higher-stakes edits that belong to the later triage posture (§7 "Later"). v1 marks creates only.

---

## 4. UX spec

### 4.1 Posture: marker, not triage (v1)

Creating a task is low-risk → the item lands directly in the list, visually flagged, dismissible. Reserve a **triage/accept queue** for later destructive agent actions (delete/complete/reschedule), which the metadata is being shaped to support but v1 does not build.

### 4.2 The marker (TaskRow / TaskRowView in `Septena/Shell/Tasks/TaskComponents.swift`)

When `source == "mcp" && acknowledgedAt == nil && <within decay window>`:

- **Leading icon** on the row, placed after the checkbox (~`TaskComponents.swift:110`), styled with the `Theme` accent so it reads as native. **No sparkles** — use a neutral provenance glyph. Candidates (pick one in 6.4): `wand.and.rays`, `cpu`, `dot.radiowaves.left.and.right`, or a custom monochrome "Claude" mark. Fallback if no glyph feels right: a small filled accent **dot** (unread-marker style).
- Optional **faint row tint** using `Theme` accent at low opacity; must respect existing theme + accessibility (`Septena/Shell/UI/Accessibility.swift`, `Theme.swift`).
- **Provenance pill** ("Claude") is the *permanent* layer — show it in the task **detail/edit** view (not always-on in the row) to avoid clutter. The row icon is the transient layer; the pill is the forever layer.

### 4.3 Clearing the cue (engagement = acknowledgment)

Any of these set `acknowledgedAt = now` (and enqueue a normal CloudKit mutator write):
- Tapping to open / focus the row (edit mode).
- Completing it.
- Editing title/notes/schedule.
- Explicit swipe action: **"Mark seen"** (acknowledge without otherwise touching).
- A list-level **"Mark all seen"** when Claude added a batch.

Acknowledgment is idempotent: if already set, no-op (don't churn writes / `updatedAt`).

### 4.4 Auto-decay

Even if never engaged, the cue stops showing when `createdAt` is older than the decay window. Recommended window: **7 days** (configurable constant). Provenance (`source`) remains forever; only the glow expires. This prevents a month-old ignored item from still glowing.

---

## 5. SwiftData query for "show the cue"

The cue is a view-time predicate, not a stored flag. With `createdAt: Date` in place it's clean:

```swift
func showsAgentCue(_ t: TaskEntity, now: Date) -> Bool {
    guard t.source == "mcp", t.acknowledgedAt == nil else { return false }
    return now.timeIntervalSince(t.createdAt) < AgentCue.decayWindow   // 7d
}
```

---

## 6. Decisions (resolved)

1. **Creation-time shape → `createdAt: Date`** (NSDate in CloudKit). One shape app-wide, matching the `occurredAt`/`loggedAt` convention; retires the legacy `created: String?` holdout. Decay reads `createdAt` directly. **Resolved.**
2. **Scope of v1 → TaskEntity only.** Field names fixed now so per-section rollout (habits, supplements, chores, training, goals…) is copy-paste later. **Resolved.**
3. **Cue surfacing → visible in the list, as a leading icon** (not detail-only). `sourceClient` "Claude" pill stays in detail/edit to avoid row clutter. **Resolved.**
4. **Marker glyph → a neutral icon, NOT sparkles.** Still to pick the exact glyph (`wand.and.rays` / `cpu` / `dot.radiowaves.left.and.right` / custom Claude mark / accent dot) — a visual choice, not a structural one; settle during row implementation.

---

## 7. Implementation plan (v1 = tasks, marker-only)

**Gateway repo (`../septena-mcp-gateway`) — handed off, NOT done here.**
See [agent-provenance-gateway-handoff.md](agent-provenance-gateway-handoff.md) for the full instructions. In short: stamp `source/sourceClient/createdAt` in `createTask`, and switch it to `createWithFieldFallback` so it can deploy before the schema learns the fields.

**This repo — DONE (build-verified, iOS Debug, EXIT=0):**
- [x] `TaskEntity` gains `source`, `sourceClient`, `acknowledgedAt: Date?`, `createdAt: Date` (`Persistence.swift`). Backend sets `createdAt = Date()` on user create (`TasksBackend.swift`).
- [x] Four field keys in `TaskCloudKitSchema.Field`; `toCloudKitRecord()` write (createdAt only once non-sentinel) + `apply(_:)` read, optional-tolerant (`TaskRecord.swift`).
- [x] `TaskCreatedAtBackfill` (`Migration.swift`, key `"tasks.createdAtBackfill.v1"`) derives `createdAt` from legacy `created`; called in `App.swift` after `OccurredAtBackfill`.
- [x] `AgentCue` constants (`decayWindow = 7d`, `mcpSource`) + `SeptenaTask.showsAgentCue(now:)` (`Models.swift`); DTO carries the four fields, mapped from the entity in `SeptenaTask(_:)` (`Persistence.swift`).
- [x] `AgentCueMarker` (accent dot — NOT a sparkle; glyph is a one-line swap) rendered in `TaskRow` + `TaskRowView` (`TaskComponents.swift`).
- [x] Acknowledgment path: `acknowledge(id:)` on `TasksBackend`/`CloudKitTasksBackend`/`TaskMutator` (idempotent, syncs); called on open (`startEdit`), complete (`toggle`), and an explicit "Mark seen" trailing swipe shown only while the row glows (`TaskListView.swift`).

**Still open on the iOS side:**
- [ ] Register the new CK fields: dev via a native app write; prod folded into the pending schema deploy. Confirm round-trip (write on phone → read on Mac).
- [ ] Provenance pill ("Claude") in task detail/edit view (the permanent layer; §4.2).
- [ ] Optional "Mark all seen" affordance for batch agent adds.

**Later (out of v1):**
- Generalize fields to other sections (habits, supplements, chores, training, goals, gut, mood).
- Triage/accept queue for agent **edits/deletes/completes** (the higher-stakes posture), keyed off an `action` dimension (created|completed|edited|deleted by agent).
```
