import Foundation
import CloudKit
import SwiftData

private func optionalGoalString(_ value: CKRecordValue?) -> String? {
  guard let string = value as? String else { return nil }
  return string.isEmpty ? nil : string
}

// GoalRecord — GoalEntity ↔ CKRecord mapping.
// Goals are free-text intentions tagged with section keys. The record type
// is "Goal"; the recordName is "goal:{id}" to avoid natural-id collisions
// with Task records which use a bare id. Fields follow the Area/Project
// pattern: required string fields up front, reserved slots for schema
// evolution without a breaking recordType bump.

enum GoalCloudKitSchema {
  static let recordType = "Goal"

  static func recordName(for id: String) -> String { "goal:\(id)" }
  static func entityID(from recordName: String) -> String {
    recordName.hasPrefix("goal:") ? String(recordName.dropFirst("goal:".count)) : recordName
  }

  enum Field {
    static let text = "text"
    static let sections = "sections"   // [String] stored as NSArray<NSString>
    static let created = "created"     // YYYY-MM-DD
    static let sortIndex = "sortIndex"

    // Optional measurement attachment. Nil on free-text goals; set together
    // when the goal becomes measurable. Schema is CK auto-managed so adding
    // these here is sufficient — no Dashboard touch required.
    static let metricKey = "metricKey"
    static let metricWindow = "metricWindow"
    static let metricComparator = "metricComparator"
    static let metricTarget = "metricTarget"
    static let metricBaseline = "metricBaseline"

    // Reserved for foreseeable additions without bumping the record type.
    static let reservedString1 = "reservedString1"
    static let reservedString2 = "reservedString2"
    static let reservedDate1 = "reservedDate1"
    static let reservedInt1 = "reservedInt1"
  }
}

// MARK: - Encode

extension GoalEntity {
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
      recordType: GoalCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: GoalCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[GoalCloudKitSchema.Field.text] = text
    record[GoalCloudKitSchema.Field.sections] = sections as NSArray
    record[GoalCloudKitSchema.Field.created] = created
    record[GoalCloudKitSchema.Field.sortIndex] = sortIndex
    record[GoalCloudKitSchema.Field.metricKey] = metricKey
    record[GoalCloudKitSchema.Field.metricWindow] = metricWindow
    record[GoalCloudKitSchema.Field.metricComparator] = metricComparator
    record[GoalCloudKitSchema.Field.metricTarget] = metricTarget
    record[GoalCloudKitSchema.Field.metricBaseline] = metricBaseline
    return record
  }
}

// MARK: - Decode

extension GoalEntity {
  func apply(_ record: CKRecord) {
    if let v = record[GoalCloudKitSchema.Field.text] as? String { text = v }
    sections = record[GoalCloudKitSchema.Field.sections] as? [String] ?? []
    if let v = optionalGoalString(record[GoalCloudKitSchema.Field.created]) { created = v }
    if let v = record[GoalCloudKitSchema.Field.sortIndex] as? Int { sortIndex = v }
    metricKey = optionalGoalString(record[GoalCloudKitSchema.Field.metricKey])
    metricWindow = optionalGoalString(record[GoalCloudKitSchema.Field.metricWindow])
    metricComparator = optionalGoalString(record[GoalCloudKitSchema.Field.metricComparator])
    metricTarget = record[GoalCloudKitSchema.Field.metricTarget] as? Double
    metricBaseline = record[GoalCloudKitSchema.Field.metricBaseline] as? Double
    updatedAt = .now
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: GoalCloudKitSchema.entityID(from: record.recordID.recordName),
              text: "",
              created: SeptenaDate.today)
    apply(record)
  }
}
