import Foundation
import CloudKit
import SwiftData

private func optionalAreaString(_ value: CKRecordValue?) -> String? {
  guard let string = value as? String else { return nil }
  return string.isEmpty ? nil : string
}

// AreaRecord — AreaEntity ↔ CKRecord mapping. Mirrors TaskRecord one-for-one
// so the engine treats areas the same way it treats tasks: a uniformly
// shaped record with a `recordType` discriminator and an `id` that doubles
// as `recordName`. See [TaskRecord.swift] for the over-provisioning
// rationale — once a schema is promoted to Production, fields can be added
// but not renamed or retyped, so we reserve a few slots up front.

enum AreaCloudKitSchema {
  static let recordType = "Area"
  static func recordName(for id: String) -> String { "area:\(id)" }
  static func entityID(from recordName: String) -> String {
    recordName.hasPrefix("area:") ? String(recordName.dropFirst(5)) : recordName
  }

  enum Field {
    static let title = "title"
    static let context = "context"
    // Optional user-assigned glyph. Rides the first reserved string slot so
    // the record type isn't bumped — an additive promotion in Prod.
    static let emoji = "reservedString1"
    /// JSON-encoded `AreaAttachment`. Rides the second reserved string slot —
    /// additive in Prod, no record-type bump. See [AreaAttachment.swift].
    static let attachment = "reservedString2"

    // Reserved for foreseeable additions without bumping the record type.
    static let reservedDate1 = "reservedDate1"
    static let reservedInt1 = "reservedInt1"
  }
}

// MARK: - Encode

extension AreaEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: AreaCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: AreaCloudKitSchema.recordName(for: id), zoneID: SeptenaCloudKit.zoneID)
    )
    record[AreaCloudKitSchema.Field.title] = title
    record[AreaCloudKitSchema.Field.context] = context
    record[AreaCloudKitSchema.Field.emoji] = emoji
    record[AreaCloudKitSchema.Field.attachment] = attachmentJSON
    return record
  }
}

// MARK: - Decode

extension AreaEntity {
  func apply(_ record: CKRecord) {
    if let v = record[AreaCloudKitSchema.Field.title] as? String { title = v }
    context = optionalAreaString(record[AreaCloudKitSchema.Field.context])
    emoji = optionalAreaString(record[AreaCloudKitSchema.Field.emoji])
    attachmentJSON = optionalAreaString(record[AreaCloudKitSchema.Field.attachment])
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: AreaCloudKitSchema.entityID(from: record.recordID.recordName), title: "")
    apply(record)
  }
}
