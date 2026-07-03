import Foundation
import CloudKit
import SwiftData

private func optionalTaskString(_ value: CKRecordValue?) -> String? {
  guard let string = value as? String else { return nil }
  return string.isEmpty ? nil : string
}

// TaskRecord — TaskEntity ↔ CKRecord mapping. Phase 0 scaffolding.
//
// CloudKit record types are effectively frozen once a schema is deployed
// to the Production environment — fields can be added but not renamed
// or retyped. This file is the single seam for that mapping; over-
// provisioned fields are listed below with the rationale for each.

enum TaskCloudKitSchema {
  /// CKRecord type. Capitalized by CloudKit convention.
static let recordType = "Task"

  // MARK: - Field names

enum Field {
    // Core
static let title = "title"
static let status = "status"
static let created = "created"
static let scheduled = "scheduled"
static let deadline = "deadline"
static let today = "today"
static let todaySetOn = "todaySetOn"
static let completedAt = "completedAt"
static let area = "area"
static let project = "project"
    /// Legacy CloudKit schema field. Already typed as ENCRYPTED_STRING.
static let encryptedNotes = "notes"
    /// Plaintext replacement for cross-surface access. CloudKit field
    /// types are immutable, so this cannot reuse the legacy `notes` name.
static let notesText = "notesText"
    /// Task Conversations state (`TaskConvo` JSON). Plaintext STRING so the
    /// gateway's CloudKit Web Services can read/write it (encrypted fields are
    /// invisible there — same reason `notesText` exists). Additive; dev-only
    /// until the conversations feature ships.
static let conversationJSON = "conversationJSON"
static let recurrenceUnit = "recurrenceUnit"
static let recurrenceInterval = "recurrenceInterval"
static let recurrenceAfterCompletion = "recurrenceAfterCompletion"

    // Provenance + freshness cue. `source`/`sourceClient` are STRING and
    // permanent; the MCP gateway sets them at create (source="mcp"). The
    // app preserves them on re-save and never authors source="mcp" itself.
    // `createdAt`/`acknowledgedAt` are TIMESTAMP (NSDate), matching the
    // app-wide instant convention (occurredAt, loggedAt).
static let source = "source"
static let sourceClient = "sourceClient"
static let acknowledgedAt = "acknowledgedAt"
static let createdAt = "createdAt"
    /// User-controlled manual order (Things-style drag-to-reorder). DOUBLE.
    /// Only written once a task has been explicitly placed (dragged, or a new
    /// task's top placement); un-dragged rows order by `createdAt` and leave
    /// this absent. See `TaskOrder`.
static let position = "position"

    /// Row shape. STRING, additive. `"heading"` marks a project section
    /// divider; ordinary tasks leave it absent (never author an empty string).
    /// See `TaskKind` / `TaskEntity.isHeading`.
static let kind = "kind"
    /// FK to the owning heading's id for a task filed under one. STRING,
    /// additive. Absent for un-headed tasks and heading rows.
static let heading = "heading"

    // Over-provisioned for schema flexibility post-Production deploy.
    // Adding fields later is allowed but slow to roll out; renaming /
    // retyping is impossible. Reserve a few slots now so we can absorb
    // anticipated features without a v2 record type.
static let parentTaskId = "parentTaskId"     // future: subtasks
static let remindAt = "remindAt"             // future: time-of-day reminders
static let reservedDate1 = "reservedDate1"
static let reservedDate2 = "reservedDate2"
static let reservedString1 = "reservedString1"
static let reservedInt1 = "reservedInt1"
  }
}

// MARK: - Encode

extension TaskEntity: CloudKitSystemFieldsBacked {
  /// Build a CKRecord for upload. Reuses any previously-captured system
  /// fields so the recordChangeTag is preserved (avoids 409s on re-save).
  /// The CKRecord.ID's recordName is the entity's `id` so identity
  /// survives the migration from FastAPI.
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: TaskCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: id, zoneID: SeptenaCloudKit.zoneID)
    )

    record[TaskCloudKitSchema.Field.title] = title
    record[TaskCloudKitSchema.Field.status] = statusRaw
    record[TaskCloudKitSchema.Field.created] = created
    record[TaskCloudKitSchema.Field.scheduled] = scheduled
    record[TaskCloudKitSchema.Field.deadline] = deadline
    record[TaskCloudKitSchema.Field.today] = today ? 1 : 0
    record[TaskCloudKitSchema.Field.todaySetOn] = todaySetOn
    record[TaskCloudKitSchema.Field.completedAt] = completedAt
    record[TaskCloudKitSchema.Field.area] = area
    record[TaskCloudKitSchema.Field.project] = project
    record[TaskCloudKitSchema.Field.recurrenceUnit] = recurrenceUnit
    record[TaskCloudKitSchema.Field.recurrenceInterval] = recurrenceInterval
    record[TaskCloudKitSchema.Field.recurrenceAfterCompletion] = recurrenceAfterCompletion ? 1 : 0

    // Write plaintext under a new field name. The old `notes` field is
    // permanently ENCRYPTED_STRING in the CK schema, so attempting to
    // write a STRING there fails even after a zone reset.
    record[TaskCloudKitSchema.Field.notesText] = notes

    // Task Conversations blob (plaintext). Only written once a conversation
    // exists, so we don't author empty strings onto every task record.
    record[TaskCloudKitSchema.Field.conversationJSON] = conversationJSON

    // Provenance + cue. `source`/`sourceClient` round-trip the gateway's
    // stamp (nil for human-authored rows). `createdAt` only writes once it
    // holds a real value — never clobber a server timestamp with the
    // `.distantPast` migration sentinel before the backfill has run.
    record[TaskCloudKitSchema.Field.source] = source
    record[TaskCloudKitSchema.Field.sourceClient] = sourceClient
    record[TaskCloudKitSchema.Field.acknowledgedAt] = acknowledgedAt as NSDate?
    if createdAt != .distantPast {
      record[TaskCloudKitSchema.Field.createdAt] = createdAt as NSDate
    }

    // Manual order. Only write an explicit position (0 = never dragged, which
    // orders by createdAt instead) so we don't author a meaningless 0 onto
    // every record.
    if position != 0 {
      record[TaskCloudKitSchema.Field.position] = position
    }

    // Row shape + heading membership. Conditional so ordinary un-headed tasks
    // never author these fields — only headings and tasks filed under one do
    // (mirrors the `position`/`conversationJSON` conditional-write pattern, and
    // keeps the additive prod deploy clean).
    if kind == TaskKind.heading {
      record[TaskCloudKitSchema.Field.kind] = kind
    }
    record[TaskCloudKitSchema.Field.heading] = heading

    // Recently-Deleted marker. `deletedAt` rides the already-deployed
    // `reservedString1` field so soft-delete syncs across devices with no
    // schema deploy (docs/RECENTLY_DELETED_SPEC.md). A trashed task's record
    // SURVIVES in CloudKit (this is a record update); only `purge` deletes it.
    record[TaskCloudKitSchema.Field.reservedString1] = deletedAt

    return record
  }
}

// MARK: - Decode

extension TaskEntity {
  /// Updates this entity from a CKRecord pulled by the engine. Phase 1+
  /// will call this from the `applyFetchedRecord` closure on CKEngine.
func apply(_ record: CKRecord) {
    if let v = record[TaskCloudKitSchema.Field.title] as? String { title = v }
    if let v = record[TaskCloudKitSchema.Field.status] as? String { statusRaw = v }
    created = optionalTaskString(record[TaskCloudKitSchema.Field.created])
    scheduled = optionalTaskString(record[TaskCloudKitSchema.Field.scheduled])
    deadline = optionalTaskString(record[TaskCloudKitSchema.Field.deadline])
    if let v = record[TaskCloudKitSchema.Field.today] as? Int { today = v != 0 }
    todaySetOn = optionalTaskString(record[TaskCloudKitSchema.Field.todaySetOn])
    completedAt = optionalTaskString(record[TaskCloudKitSchema.Field.completedAt])
    area = optionalTaskString(record[TaskCloudKitSchema.Field.area])
    project = optionalTaskString(record[TaskCloudKitSchema.Field.project])
    recurrenceUnit = optionalTaskString(record[TaskCloudKitSchema.Field.recurrenceUnit])
    if let v = record[TaskCloudKitSchema.Field.recurrenceInterval] as? Int {
      recurrenceInterval = v
    }
    if let v = record[TaskCloudKitSchema.Field.recurrenceAfterCompletion] as? Int {
      recurrenceAfterCompletion = v != 0
    }
    // Read plain first, fall back to the legacy encrypted bag for records
    // that haven't been re-saved since the plaintext switch.
    notes = optionalTaskString(record[TaskCloudKitSchema.Field.notesText])
      ?? optionalTaskString(record.encryptedValues[TaskCloudKitSchema.Field.encryptedNotes])

    conversationJSON = optionalTaskString(record[TaskCloudKitSchema.Field.conversationJSON])

    // Provenance + cue. Tolerant of absence (records authored before the
    // schema learned these fields, or human rows that never set source).
    source = optionalTaskString(record[TaskCloudKitSchema.Field.source])
    sourceClient = optionalTaskString(record[TaskCloudKitSchema.Field.sourceClient])
    acknowledgedAt = record[TaskCloudKitSchema.Field.acknowledgedAt] as? Date
    if let v = record[TaskCloudKitSchema.Field.createdAt] as? Date { createdAt = v }
    // Manual order. Absent on un-dragged rows (and gateway-authored ones) →
    // leave at 0 so the createdAt fallback orders them.
    if let v = record[TaskCloudKitSchema.Field.position] as? Double { position = v }

    // Row shape + heading membership. Absent on ordinary tasks (and on rows
    // authored before the schema learned these fields) → default to task /
    // un-headed. Mirror `heading` directly (including clearing it when the
    // remote value is absent) so re-filing on another device propagates.
    kind = optionalTaskString(record[TaskCloudKitSchema.Field.kind]) ?? ""
    heading = optionalTaskString(record[TaskCloudKitSchema.Field.heading])

    // Recently-Deleted marker (rides `reservedString1`). Mirror it directly —
    // including clearing it on restore, when the remote value is absent — so a
    // restore on another device un-trashes the task here too.
    deletedAt = optionalTaskString(record[TaskCloudKitSchema.Field.reservedString1])

    captureCloudKitSystemFields(from: record)
  }

  /// Convenience: build a fresh entity from a CKRecord seen for the
  /// first time. Mirrors `init(_ dto: SeptenaTask)` on the FastAPI side.
convenience init(cloudKit record: CKRecord) {
    self.init(id: record.recordID.recordName, title: "")
    apply(record)
  }
}
