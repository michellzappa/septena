import Foundation
import CloudKit
import SwiftData

// CoachMessageRecord — CoachMessageEntity ↔ CKRecord mapping.
// One record per message; recordName "coachMsg:{id}". Fields are the coach
// key, role, text, timestamp, and order — additive, CK auto-managed in
// Development. The transcript for a coach is every record with that coachKey.

enum CoachMessageCloudKitSchema {
  static let recordType = "CoachMessage"

  static func recordName(for id: String) -> String { "coachMsg:\(id)" }
  static func entityID(from recordName: String) -> String {
    recordName.hasPrefix("coachMsg:") ? String(recordName.dropFirst("coachMsg:".count)) : recordName
  }

  enum Field {
    static let coachKey = "coachKey"
    static let role = "role"
    static let text = "text"
    static let createdAt = "createdAt"
    static let sortIndex = "sortIndex"
  }
}

// MARK: - Encode

extension CoachMessageEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: CoachMessageCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: CoachMessageCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[CoachMessageCloudKitSchema.Field.coachKey] = coachKey
    record[CoachMessageCloudKitSchema.Field.role] = role
    record[CoachMessageCloudKitSchema.Field.text] = text
    record[CoachMessageCloudKitSchema.Field.createdAt] = createdAt
    record[CoachMessageCloudKitSchema.Field.sortIndex] = sortIndex
    return record
  }
}

// MARK: - Decode

extension CoachMessageEntity {
  func apply(_ record: CKRecord) {
    if let v = record[CoachMessageCloudKitSchema.Field.coachKey] as? String { coachKey = v }
    if let v = record[CoachMessageCloudKitSchema.Field.role] as? String { role = v }
    if let v = record[CoachMessageCloudKitSchema.Field.text] as? String { text = v }
    if let v = record[CoachMessageCloudKitSchema.Field.createdAt] as? Date { createdAt = v }
    if let v = record[CoachMessageCloudKitSchema.Field.sortIndex] as? Int { sortIndex = v }
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: CoachMessageCloudKitSchema.entityID(from: record.recordID.recordName),
              coachKey: "", role: "coach", text: "")
    apply(record)
  }
}
