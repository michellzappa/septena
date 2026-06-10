import Foundation
import CloudKit
import SwiftData

private func optionalMilestoneString(_ value: CKRecordValue?) -> String? {
  guard let string = value as? String else { return nil }
  return string.isEmpty ? nil : string
}

// GoalMilestoneRecord — GoalMilestoneEntity ↔ CKRecord mapping.
// A milestone is a latched achievement event (see MilestoneEngine). The
// record type is "GoalMilestone"; the recordName is "gms:{id}" where the
// entity id is already deterministic ("<scope>|<rungKey>"), so the same
// crossing detected on two devices produces the same recordName — a benign
// same-content conflict rather than a duplicate celebration.

enum GoalMilestoneCloudKitSchema {
  static let recordType = "GoalMilestone"

  static func recordName(for id: String) -> String { "gms:\(id)" }
  static func entityID(from recordName: String) -> String {
    recordName.hasPrefix("gms:") ? String(recordName.dropFirst("gms:".count)) : recordName
  }

  enum Field {
    static let goalID = "goalID"
    static let scope = "scope"
    static let kind = "kind"
    static let rungKey = "rungKey"
    static let label = "label"
    static let value = "value"
    static let occurredAt = "occurredAt"
    static let celebrated = "celebrated"     // Int 0/1
    static let presentedAt = "presentedAt"

    // Reserved for foreseeable additions without bumping the record type.
    static let reservedString1 = "reservedString1"
    static let reservedDate1 = "reservedDate1"
    static let reservedInt1 = "reservedInt1"
  }
}

// MARK: - Encode

extension GoalMilestoneEntity {
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
      recordType: GoalMilestoneCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: GoalMilestoneCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[GoalMilestoneCloudKitSchema.Field.goalID] = goalID
    record[GoalMilestoneCloudKitSchema.Field.scope] = scope
    record[GoalMilestoneCloudKitSchema.Field.kind] = kind
    record[GoalMilestoneCloudKitSchema.Field.rungKey] = rungKey
    record[GoalMilestoneCloudKitSchema.Field.label] = label
    record[GoalMilestoneCloudKitSchema.Field.value] = value
    record[GoalMilestoneCloudKitSchema.Field.occurredAt] = occurredAt
    record[GoalMilestoneCloudKitSchema.Field.celebrated] = celebrated ? 1 : 0
    record[GoalMilestoneCloudKitSchema.Field.presentedAt] = presentedAt
    return record
  }
}

// MARK: - Decode

extension GoalMilestoneEntity {
  func apply(_ record: CKRecord) {
    goalID = optionalMilestoneString(record[GoalMilestoneCloudKitSchema.Field.goalID])
    if let v = optionalMilestoneString(record[GoalMilestoneCloudKitSchema.Field.scope]) { scope = v }
    if let v = optionalMilestoneString(record[GoalMilestoneCloudKitSchema.Field.kind]) { kind = v }
    if let v = optionalMilestoneString(record[GoalMilestoneCloudKitSchema.Field.rungKey]) { rungKey = v }
    if let v = record[GoalMilestoneCloudKitSchema.Field.label] as? String { label = v }
    if let v = record[GoalMilestoneCloudKitSchema.Field.value] as? Double { value = v }
    if let v = record[GoalMilestoneCloudKitSchema.Field.occurredAt] as? Date { occurredAt = v }
    if let v = record[GoalMilestoneCloudKitSchema.Field.celebrated] as? Int { celebrated = v != 0 }
    presentedAt = record[GoalMilestoneCloudKitSchema.Field.presentedAt] as? Date
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: GoalMilestoneCloudKitSchema.entityID(from: record.recordID.recordName),
              scope: "",
              kind: "",
              rungKey: "",
              label: "",
              value: 0,
              occurredAt: .now,
              celebrated: false)
    apply(record)
  }
}
