import Foundation
import CloudKit
import SwiftData

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
static let recurrenceUnit = "recurrenceUnit"
static let recurrenceInterval = "recurrenceInterval"
static let recurrenceAfterCompletion = "recurrenceAfterCompletion"

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

extension TaskEntity {
  /// Decode the stored CKRecord system fields blob into a bare CKRecord
  /// (recordID + change tag, no field values). Returns nil if we've never
  /// seen this row via CloudKit before — caller mints a fresh record.
  func decodedCloudKitRecord() -> CKRecord? {
    guard let data = cloudKitSystemFields else { return nil }
    let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data)
    unarchiver?.requiresSecureCoding = true
    return unarchiver.flatMap { CKRecord(coder: $0) }
  }

  /// Encode + store the system fields from `record`. Called after a save
  /// is acked or after the engine fetches a record from the server.
  func captureCloudKitSystemFields(from record: CKRecord) {
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: archiver)
    archiver.finishEncoding()
    cloudKitSystemFields = archiver.encodedData
  }

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
    record[TaskCloudKitSchema.Field.deadline] = due
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
    created = record[TaskCloudKitSchema.Field.created] as? String
    scheduled = record[TaskCloudKitSchema.Field.scheduled] as? String
    due = record[TaskCloudKitSchema.Field.deadline] as? String
    if let v = record[TaskCloudKitSchema.Field.today] as? Int { today = v != 0 }
    todaySetOn = record[TaskCloudKitSchema.Field.todaySetOn] as? String
    completedAt = record[TaskCloudKitSchema.Field.completedAt] as? String
    area = record[TaskCloudKitSchema.Field.area] as? String
    project = record[TaskCloudKitSchema.Field.project] as? String
    recurrenceUnit = record[TaskCloudKitSchema.Field.recurrenceUnit] as? String
    if let v = record[TaskCloudKitSchema.Field.recurrenceInterval] as? Int {
      recurrenceInterval = v
    }
    if let v = record[TaskCloudKitSchema.Field.recurrenceAfterCompletion] as? Int {
      recurrenceAfterCompletion = v != 0
    }
    // Read plain first, fall back to the legacy encrypted bag for records
    // that haven't been re-saved since the plaintext switch.
    notes = (record[TaskCloudKitSchema.Field.notesText] as? String)
      ?? (record.encryptedValues[TaskCloudKitSchema.Field.encryptedNotes] as? String)
    captureCloudKitSystemFields(from: record)
  }

  /// Convenience: build a fresh entity from a CKRecord seen for the
  /// first time. Mirrors `init(_ dto: SeptenaTask)` on the FastAPI side.
convenience init(cloudKit record: CKRecord) {
    self.init(id: record.recordID.recordName, title: "")
    apply(record)
  }
}
