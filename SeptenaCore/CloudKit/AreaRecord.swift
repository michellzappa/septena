import Foundation
import CloudKit
import SwiftData

// AreaRecord — AreaEntity ↔ CKRecord mapping. Mirrors TaskRecord one-for-one
// so the engine treats areas the same way it treats tasks: a uniformly
// shaped record with a `recordType` discriminator and an `id` that doubles
// as `recordName`. See [TaskRecord.swift] for the over-provisioning
// rationale — once a schema is promoted to Production, fields can be added
// but not renamed or retyped, so we reserve a few slots up front.

enum AreaCloudKitSchema {
  static let recordType = "Area"

  enum Field {
    static let title = "title"
    static let context = "context"
    /// Natural-name identifier. Mutable, deduped — see [IDENTIFIERS.md].
    static let slug = "slug"
    /// FIFO history of recent slugs (max 3). Lets a lookup for a recently
    /// renamed area still resolve. STRING_LIST on the CK side.
    static let previousSlugs = "previousSlugs"

    // Reserved for foreseeable additions without bumping the record type.
    static let reservedString1 = "reservedString1"
    static let reservedString2 = "reservedString2"
    static let reservedDate1 = "reservedDate1"
    static let reservedInt1 = "reservedInt1"
  }
}

// MARK: - Encode

extension AreaEntity {
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
      recordType: AreaCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: id, zoneID: SeptenaCloudKit.zoneID)
    )
    record[AreaCloudKitSchema.Field.title] = title
    record[AreaCloudKitSchema.Field.context] = context
    record[AreaCloudKitSchema.Field.slug] = slug
    // Don't write an empty list on first save — CloudKit can't infer the
    // element type from `[]` and rejects with INVALID_ARGUMENTS until the
    // field has been seeded with at least one non-empty value via the
    // schema editor. Skipping the assignment leaves the field absent
    // (effectively nil); decode tolerates that.
    if !previousSlugs.isEmpty {
      record[AreaCloudKitSchema.Field.previousSlugs] = previousSlugs
    }
    return record
  }
}

// MARK: - Decode

extension AreaEntity {
  func apply(_ record: CKRecord) {
    if let v = record[AreaCloudKitSchema.Field.title] as? String { title = v }
    context = record[AreaCloudKitSchema.Field.context] as? String
    slug = record[AreaCloudKitSchema.Field.slug] as? String
    previousSlugs = (record[AreaCloudKitSchema.Field.previousSlugs] as? [String]) ?? []
    // Lazy backfill: legacy records (pre-IDENTIFIERS.md) have nil slug.
    // Default to the id, which for those records is the historical slug
    // anyway ("septena", "obsidian", etc). The first rename will compute
    // a fresh slug and push it back to CK normally.
    if slug == nil, !id.isEmpty { slug = id }
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: record.recordID.recordName, title: "")
    apply(record)
  }
}
