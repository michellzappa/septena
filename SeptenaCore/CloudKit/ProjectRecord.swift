import Foundation
import CloudKit
import SwiftData

// ProjectRecord — ProjectEntity ↔ CKRecord mapping. See [TaskRecord.swift]
// for the schema-rigidity background and field-reservation pattern.

enum ProjectCloudKitSchema {
  static let recordType = "Project"
  static func recordName(for id: String) -> String { "project:\(id)" }
  static func entityID(from recordName: String) -> String {
    recordName.hasPrefix("project:") ? String(recordName.dropFirst(8)) : recordName
  }

  enum Field {
    static let title = "title"
    static let status = "status"
    static let area = "area"
    static let created = "created"
    static let completedAt = "completedAt"
    /// Legacy CloudKit schema field. Already typed as ENCRYPTED_STRING.
    static let encryptedNotes = "notes"
    /// Plaintext replacement for cross-surface access. CloudKit field
    /// types are immutable, so this cannot reuse the legacy `notes` name.
    static let notesText = "notesText"
    static let context = "context"
    static let githubRepo = "githubRepo"

    // Reserved.
    static let reservedString1 = "reservedString1"
    static let reservedString2 = "reservedString2"
    static let reservedDate1 = "reservedDate1"
    static let reservedInt1 = "reservedInt1"
  }
}

// MARK: - Encode

extension ProjectEntity {
  func decodedCloudKitRecord() -> CKRecord? {
    guard let data = cloudKitSystemFields else { return nil }
    let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data)
    unarchiver?.requiresSecureCoding = true
    return unarchiver.flatMap { CKRecord(coder: $0) }
  }

  func captureCloudKitSystemFields(from record: CKRecord) {
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: archiver)
    archiver.finishEncoding()
    cloudKitSystemFields = archiver.encodedData
  }

  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: ProjectCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: ProjectCloudKitSchema.recordName(for: id), zoneID: SeptenaCloudKit.zoneID)
    )
    record[ProjectCloudKitSchema.Field.title] = title
    record[ProjectCloudKitSchema.Field.status] = statusRaw
    record[ProjectCloudKitSchema.Field.area] = area
    record[ProjectCloudKitSchema.Field.created] = created
    record[ProjectCloudKitSchema.Field.completedAt] = completedAt
    record[ProjectCloudKitSchema.Field.context] = context
    record[ProjectCloudKitSchema.Field.githubRepo] = githubRepo
    // Write plaintext under a new field name. The old `notes` field is
    // permanently ENCRYPTED_STRING in the CK schema, so attempting to
    // write a STRING there fails even after a zone reset.
    record[ProjectCloudKitSchema.Field.notesText] = notes
    return record
  }
}

// MARK: - Decode

extension ProjectEntity {
  func apply(_ record: CKRecord) {
    if let v = record[ProjectCloudKitSchema.Field.title] as? String { title = v }
    if let v = record[ProjectCloudKitSchema.Field.status] as? String { statusRaw = v }
    area = record[ProjectCloudKitSchema.Field.area] as? String
    created = record[ProjectCloudKitSchema.Field.created] as? String
    completedAt = record[ProjectCloudKitSchema.Field.completedAt] as? String
    context = record[ProjectCloudKitSchema.Field.context] as? String
    githubRepo = record[ProjectCloudKitSchema.Field.githubRepo] as? String
    notes = (record[ProjectCloudKitSchema.Field.notesText] as? String)
      ?? (record.encryptedValues[ProjectCloudKitSchema.Field.encryptedNotes] as? String)
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: ProjectCloudKitSchema.entityID(from: record.recordID.recordName), title: "")
    apply(record)
  }
}
