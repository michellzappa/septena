# Native CloudKit Project Sharing Spec

**Status:** planning / migration spec. Not started. Sequenced AFTER Septask
P2 (docs/SEPTASK.md "P0 Findings"): Phase 0's dev spike may start any time,
but Phases 1–2 rewrite SeptenaCore identity + CKEngine internals that the
Septask target compiles — land Septask on today's single-engine core first so
sharing lands once and Septask inherits it (Phase 5 then becomes near-free).

Goal: add Apple-native collaboration for Septask/Septena task projects using
CloudKit sharing (`CKShare`), while preserving Septena's requirement that
private data stays in the user's CloudKit account. Native sharing is for trusted
iCloud collaborators. Web links are a separate feature and must not be conflated
with this design.

---

## 1. Recommendation

Start with **project sharing only**.

Do **not** include area sharing in the first native sharing migration.

Why:

- A project is a bounded, intentional collaboration unit.
- It maps directly to the user-demand gap: shared projects/lists.
- It limits accidental exposure of broader life structure.
- It is easier to explain: "Share this project."
- It is the smallest record graph that can prove native CloudKit sharing works.

Area sharing should be revisited only after project sharing is reliable. Areas
are a broader privacy boundary. Sharing an area means either sharing every
project in the area plus direct area tasks, or inventing a new area-share graph.
Both are harder to explain and riskier to migrate.

---

## 2. Product Shape

Native sharing UX:

```text
Project detail -> Share Project -> native iCloud share sheet
```

Expected user behavior:

- Owner opens a project in Septask or Septena Tasks.
- Owner taps "Share Project."
- App presents Apple's CloudKit sharing UI (`UICloudSharingController` on iOS /
  iPadOS; platform equivalent/custom wrapper on macOS if needed).
- Owner invites people through Messages/Mail/contacts.
- Participant accepts with iCloud.
- Shared project appears in participant's Septask/Septena task lists.
- Participant can add/edit/complete tasks if permission allows.
- Owner can manage participants and revoke sharing.

UI should distinguish native sharing from web links:

```text
Share with iCloud users
Invite people to collaborate in Septask.

Create web link
Let anyone with the link view or update this project.
```

Web links belong in a separate Cloudflare-helper spec. They may expose a mini
web task app, but they are not native CloudKit sharing and should not drive this
schema migration.

---

## 3. Current Code Baseline

Current task records:

- `TaskEntity.id` is the CloudKit `Task` record name.
- `TaskEntity.project` is a string project ID.
- `TaskEntity.area` is a string area ID.
- `TaskRecord.toCloudKitRecord()` writes all tasks into
  `SeptenaCloudKit.zoneID` in the user's private database.

Current project records:

- `ProjectEntity.id` is a short ID.
- CloudKit record name is `ProjectCloudKitSchema.recordName(for: id)`, currently
  `project:<id>`.
- `ProjectEntity.area` is a string area ID.
- Project records are independent top-level records in the same custom zone.

Current area records:

- `AreaEntity.id` is a short ID.
- CloudKit record name is `area:<id>`.
- Area records are independent top-level records.

Current sync engine:

- `CKEngine` is configured against `container.privateCloudDatabase`.
- It has one `CKSyncEngine`.
- It uses one custom zone: `septena-v1`.
- `applyFetchedRecord` and `recordProvider` dispatch by record type.
- There is no shared database sync path yet.

Implication: the app currently has a private-record sync engine, not a
multi-database sharing engine.

---

## 4. CloudKit Sharing Model

Native CloudKit sharing should use:

- `Project` record as the share root.
- `CKShare(rootRecord:)` for the project.
- Task records under that project included in the shared record hierarchy.
- Participant access through `container.sharedCloudDatabase`.

The shared graph should be:

```text
Project record (share root)
  Task records where task.project == project.id
```

Tasks should remain first-class `Task` records. Do not invent a separate shared
task type for native sharing.

Important: the existing string field `Task.project` is not enough to define a
CloudKit share graph. It is app-level identity. Native sharing also needs
CloudKit-level containment/membership semantics so CloudKit knows which records
belong to the project share.

The likely migration is to add CloudKit parent/reference semantics:

- A project-shared task record should have its CloudKit parent set to the
  project root record, or otherwise be explicitly included in the project's
  share-compatible record hierarchy.
- The string `project` field stays as the app-level join key because the UI,
  caches, MCP tools, import/export, and existing data already depend on it.

Do not remove or reinterpret `Task.project` during this migration.

---

## 5. Identity Namespace Problem

This is the first hard migration issue.

Today `ProjectEntity.id`, `AreaEntity.id`, and `TaskEntity.project` assume one
private account namespace. With shared CloudKit, a participant can receive a
project owned by another iCloud user whose project ID collides with one of their
private IDs.

Example:

```text
My private project:       id = "ab9k"
Friend's shared project:  id = "ab9k"
```

Current SwiftData models cannot represent both because `ProjectEntity.id` is
unique and tasks reference projects by that bare ID.

### Required Decision

Before implementing `CKShare`, add a local namespace strategy for shared task
identity.

Recommended approach:

- Keep user-facing/domain IDs stable (`id` as authored by owner) for export and
  CloudKit record naming.
- Add local mirror namespace fields to task/project/area entities:
  - `cloudOwnerName` or equivalent owner identifier.
  - `cloudDatabaseScope` / `isShared`.
  - `localKey` or a derived unique key for SwiftData uniqueness.
- Join tasks to projects by the namespaced key in local UI, while preserving
  the owner-authored `project` string for CloudKit payload compatibility.

Possible local key format:

```text
private:<projectID>
shared:<ownerName>:<projectID>
```

For tasks:

```text
private:<taskID>
shared:<ownerName>:<taskID>
```

The exact implementation depends on SwiftData constraints. If changing the
existing unique `id` field is too invasive, add a separate shared wrapper layer
or mirror entity. Do not assume short IDs are globally unique across iCloud
owners.

This identity namespace work is a prerequisite for production-ready sharing.

---

## 6. Database Scope And Sync Architecture

Current `CKEngine` only syncs `privateCloudDatabase`. Native sharing requires
reading and writing `sharedCloudDatabase` too.

Add an explicit database-scope concept:

```swift
enum CloudScope {
  case privateOwned
  case shared(ownerName: String)
}
```

The implementation may use:

- one `CKEngine` generalized to own two `CKSyncEngine` instances, or
- a separate `SharedCKEngine` for `container.sharedCloudDatabase`.

Prefer the least invasive implementation that keeps private sync behavior
unchanged.

Requirements:

- Private records continue syncing exactly as they do now.
- Shared records are fetched from `sharedCloudDatabase`.
- Shared writes go back to `sharedCloudDatabase`.
- UI reads a merged task/project view from the local mirror.
- Record providers must know whether a pending change is private or shared.
- Deletions from private and shared scopes must not collide.
- State serialization files must be separate per database scope. Do not reuse
  `CKEngineState.json` for shared DB tokens.

Suggested state files:

```text
CKEngineState.private.json
CKEngineState.shared.json
```

---

## 7. Record Encoding Changes

### Project Records

Add sharing metadata to local `ProjectEntity`:

- `isShared` or `cloudScope`.
- `cloudOwnerName` for shared records.
- `shareRecordName` or share URL metadata if useful for owner UI.
- `sharedPermission` if CloudKit exposes enough local participant info.
- `cloudKitSystemFields` must remain per actual CKRecord, so shared/private
  collisions cannot share one field blob.

CloudKit project record:

- Keep record type `Project`.
- Keep record name `project:<id>` for owner-authored identity.
- When shared, project is the `CKShare` root.
- Preserve existing fields: title/status/area/created/completedAt/notes/context.

### Task Records

Add sharing metadata to local `TaskEntity`:

- `isShared` or `cloudScope`.
- `cloudOwnerName`.
- namespaced local identity if needed.
- parent/share membership metadata if useful for debugging.

CloudKit task record:

- Keep record type `Task`.
- Keep existing app fields.
- Preserve `project` string as owner-authored project ID.
- For tasks inside a shared project, set CloudKit parent/membership so the task
  is included in the project share graph.

### Area Records

Do not share areas in v1.

For a shared project that belongs to an owner area:

- Participant may receive the project's `area` string.
- If the area record itself is not shared, participant UI must tolerate missing
  area metadata.
- Display shared project under a "Shared" group or "Shared Projects" section if
  the participant lacks the area row.

This avoids expanding the v1 share graph to broader personal structure.

---

## 8. Mutator Rules

All shared edits must still go through mutators.

Add scope-aware variants internally:

- `TaskMutator.create(..., scope:)`
- `TaskMutator.complete(id:, scope:)`
- `TaskMutator.update(id:, scope:)`
- `ProjectsMutator.rename(id:, scope:)`
- etc.

Public view code should not patch CloudKit records directly.

For v1 project sharing:

- Owner and read/write participants can:
  - add tasks to shared project
  - edit shared task title/notes/dates/status
  - complete/uncomplete shared tasks
  - reorder tasks within shared project if position sync is included
- Owner can:
  - rename project
  - complete/cancel project
  - manage share
  - revoke participants
- Participants should not:
  - move shared tasks into private projects/areas without an explicit copy/move
    model
  - expose owner's area structure
  - delete the whole shared project unless CloudKit permission and product copy
    make that clearly intentional

Deletion policy:

- Task soft-delete should work inside shared projects if permission allows.
- Hard purge should probably be owner-only until proven safe.
- Project deletion by owner should remove/revoke the shared graph.

---

## 9. UI Model

Add visible shared-state affordances without making the app feel like a team
tool.

Project list:

- Show shared projects in normal project list with a subtle shared glyph.
- If area metadata is missing, group under "Shared" or "Shared Projects."
- Avoid exposing owner iCloud identifiers unless Apple-provided display names
  are available and privacy-safe.

Project detail:

- "Share Project" action for private owned projects.
- "Manage Sharing" action for owned shared projects.
- "Shared with you" label for participant projects.
- Permission-aware controls: disable owner-only actions for participants.

Task rows:

- No noisy collaboration chrome by default.
- Consider subtle "shared project" context in project header, not every row.

Settings:

- Sharing controls belong in project detail first.
- A global "Shared Projects" settings pane can come later.

---

## 10. Migration Plan

### Phase 0 - Dev Spike, No Product UI

Goal: prove CloudKit sharing mechanics in Development before changing the main
task UI.

1. Add a debug-only sharing spike screen or command.
2. Create a test project record.
3. Create a `CKShare` with that project as root.
4. Add 2-3 task records to the share-compatible graph.
5. Present/trigger the native CloudKit sharing flow.
6. Accept invitation on a second iCloud account.
7. Fetch shared records from `sharedCloudDatabase`.
8. Edit/complete a task as participant.
9. Confirm owner sees the change.
10. Revoke participant and confirm access disappears.

Exit criteria:

- Owner and participant can both see the same project/tasks.
- Participant edits round-trip.
- Revocation works.
- We understand whether parent references are sufficient for project->task
  inclusion.
- We know the required local identity namespace changes.

### Phase 1 - Local Identity Namespace

Implement whatever local model changes Phase 0 proves necessary.

Must preserve existing private data:

- Existing private tasks/projects keep rendering.
- Existing `Task.project` joins still work.
- Existing import/export/MCP behavior stays stable.
- No production schema rewrite that loses current IDs.

Add migration/backfill for new local namespace fields.

### Phase 2 - Shared Database Sync

- Add shared DB engine/path.
- Add separate sync state serialization.
- Apply shared fetched records into local mirror with scope metadata.
- Route shared pending writes to shared DB.
- Merge private + shared projects in task UI.

### Phase 3 - Project Share UI

- Add "Share Project" / "Manage Sharing".
- Present native sharing UI.
- Add shared project badges/grouping.
- Add permission-aware UI gates.

### Phase 4 - Mutator Scope Hardening

- Audit every task/project mutation from context menus, composer, shortcuts, MCP,
  and keyboard commands.
- Ensure shared records never accidentally enqueue private DB writes.
- Ensure private-only actions are hidden or copied when invoked on shared data.

### Phase 5 - Septask Integration

- Expose the same project sharing controls in Septask.
- Confirm Septena and Septask both handle shared projects.
- Confirm side-by-side apps do not duplicate or collide shared/local records.

### Phase 6 - Production Schema Deploy

Only after dev sharing is proven:

- Update `docs/CloudKitSchema.md`.
- Deploy additive schema changes.
- Verify production private users without shared projects are unaffected.

---

## 11. Area Sharing Later

Area sharing is intentionally out of v1.

If added later, evaluate two models:

### Option A - Area As Share Root

```text
Area share root
  Project records in area
  Task records directly in area
  Task records in area's projects
```

Pros:

- Natural "share this whole area" mental model.
- Good for family/home/work spaces.

Cons:

- Broader privacy risk.
- Larger record graph.
- Harder revocation/move semantics.
- Participant sees more personal structure.

### Option B - Area Share As A Collection Of Project Shares

Area UI can bulk-share projects, but each project remains its own share root.

Pros:

- Keeps project sharing primitive.
- Easier to revoke per project.
- Less schema complexity.

Cons:

- Area direct tasks need a home.
- Participant's UI may not see a true shared area.

Recommendation: do not design this until project sharing is real in dev.

---

## 12. Open Questions

- Does CloudKit parent hierarchy work cleanly with the current custom zone and
  `CKSyncEngine` flow, or do shared descendants require a different save order?
- Should shared tasks preserve owner-authored short IDs, or should the
  participant mirror always use a namespaced local key?
- How should shared projects appear when the participant has no matching area?
- Are project notes/context shared with participants in v1?
- Can participants reorder tasks, and does `position` remain stable across
  private/shared writers?
- Are task conversations shared with collaborators by default? For v1, probably
  yes if the conversation lives on the task, but the UI copy must make that
  clear.
- Should MCP tools see shared projects? If yes, they need scope-aware IDs and
  must not confuse private and shared records.
- How does Recently Deleted behave for shared tasks when owner and participant
  disagree?
- What is the minimum macOS sharing UI that feels native if
  `UICloudSharingController` is iOS-only?

---

## 13. Key Files

- Task record mapping: `SeptenaCore/CloudKit/TaskRecord.swift`
- Project record mapping: `SeptenaCore/CloudKit/ProjectRecord.swift`
- Area record mapping: `SeptenaCore/CloudKit/AreaRecord.swift`
- Private sync engine: `SeptenaCore/CloudKit/CKEngine.swift`
- Apply/fetch dispatch: `SeptenaCore/SeptenaServices.swift`
- Task mutator/backend: `SeptenaCore/Outbox.swift`,
  `SeptenaCore/CloudKit/TasksBackend.swift`
- Project mutator/backend: `SeptenaCore/CloudKit/ProjectsBackend.swift`
- Area mutator/backend: `SeptenaCore/CloudKit/AreasBackend.swift`
- Task UI/project detail paths: `Septena/Shell/Tasks/*`,
  `Septena/Shell/Sidebar/*`
