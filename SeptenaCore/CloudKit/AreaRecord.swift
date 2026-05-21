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
  static func recordName(for id: String) -> String { "area:\(id)" }
  static func entityID(from recordName: String) -> String {
    recordName.hasPrefix("area:") ? String(recordName.dropFirst(5)) : recordName
  }

  enum Field {
    static let title = "title"
    static let context = "context"

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
      recordID: CKRecord.ID(recordName: AreaCloudKitSchema.recordName(for: id), zoneID: SeptenaCloudKit.zoneID)
    )
    record[AreaCloudKitSchema.Field.title] = title
    record[AreaCloudKitSchema.Field.context] = context
    return record
  }
}

// MARK: - Decode

extension AreaEntity {
  func apply(_ record: CKRecord) {
    if let v = record[AreaCloudKitSchema.Field.title] as? String { title = v }
    context = record[AreaCloudKitSchema.Field.context] as? String
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: AreaCloudKitSchema.entityID(from: record.recordID.recordName), title: "")
    apply(record)
  }
}
