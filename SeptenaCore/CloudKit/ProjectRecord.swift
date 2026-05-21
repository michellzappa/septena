import Foundation
import CloudKit
import SwiftData

// ProjectRecord — ProjectEntity ↔ CKRecord mapping. See [TaskRecord.swift]
// for the schema-rigidity background and field-reservation pattern.

enum ProjectCloudKitSchema {
  static let recordType = "Project"

  enum Field {
    static let title = "title"
    static let status = "status"
    static let area = "area"
    static let created = "created"
    static let completedAt = "completedAt"
    /// Plain field (was encrypted; switched for MCP-gateway access).
    static let notes = "notes"
    static let context = "context"
    static let githubRepo = "githubRepo"
    /// Natural-name identifier. Mutable, deduped — see [IDENTIFIERS.md].
    static let slug = "slug"
    /// FIFO history of the last 3 slugs (STRING_LIST on the CK side).
    static let previousSlugs = "previousSlugs"

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
      recordID: CKRecord.ID(recordName: id, zoneID: SeptenaCloudKit.zoneID)
    )
    record[ProjectCloudKitSchema.Field.title] = title
    record[ProjectCloudKitSchema.Field.status] = statusRaw
    record[ProjectCloudKitSchema.Field.area] = area
    record[ProjectCloudKitSchema.Field.created] = created
    record[ProjectCloudKitSchema.Field.completedAt] = completedAt
    record[ProjectCloudKitSchema.Field.context] = context
    record[ProjectCloudKitSchema.Field.githubRepo] = githubRepo
    record[ProjectCloudKitSchema.Field.slug] = slug
    // Skip empty arrays — see AreaRecord for the same workaround.
    if !previousSlugs.isEmpty {
      record[ProjectCloudKitSchema.Field.previousSlugs] = previousSlugs
    }
    // Plaintext for MCP-gateway compatibility — see TaskRecord for
    // rationale, including why we don't touch encryptedValues here.
    record[ProjectCloudKitSchema.Field.notes] = notes
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
    slug = record[ProjectCloudKitSchema.Field.slug] as? String
    previousSlugs = (record[ProjectCloudKitSchema.Field.previousSlugs] as? [String]) ?? []
    if slug == nil, !id.isEmpty { slug = id }
    notes = (record[ProjectCloudKitSchema.Field.notes] as? String)
      ?? (record.encryptedValues[ProjectCloudKitSchema.Field.notes] as? String)
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: record.recordID.recordName, title: "")
    apply(record)
  }
}
