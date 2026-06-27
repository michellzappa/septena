import Foundation
import CloudKit
import SwiftData

private func optionalSectionString(_ value: CKRecordValue?) -> String? {
  guard let string = value as? String else { return nil }
  return string.isEmpty ? nil : string
}

enum SectionCloudKitSchema {
  static let recordType = "Section"
  static func recordName(for id: String) -> String { "section:\(id)" }
  static func entityID(from recordName: String) -> String {
    recordName.hasPrefix("section:") ? String(recordName.dropFirst(8)) : recordName
  }

  enum Field {
    static let title = "title"
    static let color = "color"
    static let isEnabled = "isEnabled"
    static let showInToday = "showInToday"
    static let showInSpotlight = "showInSpotlight"
    static let hasOnboarded = "hasOnboarded"
    static let updatedAt = "updatedAt"
    static let reservedString1 = "reservedString1"
    static let reservedInt1 = "reservedInt1"
  }
}

extension SectionEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: SectionCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: SectionCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID)
    )
    record[SectionCloudKitSchema.Field.title] = title
    record[SectionCloudKitSchema.Field.color] = color
    record[SectionCloudKitSchema.Field.isEnabled] = (isEnabled ? 1 : 0) as NSNumber
    record[SectionCloudKitSchema.Field.showInToday] = (showInToday ? 1 : 0) as NSNumber
    record[SectionCloudKitSchema.Field.showInSpotlight] = (showInSpotlight ? 1 : 0) as NSNumber
    record[SectionCloudKitSchema.Field.hasOnboarded] = (hasOnboarded ? 1 : 0) as NSNumber
    record[SectionCloudKitSchema.Field.updatedAt] = updatedAt.ISO8601Format()
    return record
  }

  func apply(_ record: CKRecord) {
    if let v = record[SectionCloudKitSchema.Field.title] as? String { title = v }
    if let v = record[SectionCloudKitSchema.Field.color] as? String { color = v }
    if let v = record[SectionCloudKitSchema.Field.isEnabled] as? NSNumber {
      isEnabled = v.intValue != 0
    }
    if let v = record[SectionCloudKitSchema.Field.showInToday] as? NSNumber {
      showInToday = v.intValue != 0
    }
    // Absent on existing records → leaves the model default (true), so a
    // section the user never touched stays discoverable.
    if let v = record[SectionCloudKitSchema.Field.showInSpotlight] as? NSNumber {
      showInSpotlight = v.intValue != 0
    }
    if let v = record[SectionCloudKitSchema.Field.hasOnboarded] as? NSNumber {
      hasOnboarded = v.intValue != 0
    }
    if let rawUpdatedAt = optionalSectionString(record[SectionCloudKitSchema.Field.updatedAt]),
       let parsed = ISO8601DateFormatter().date(from: rawUpdatedAt) {
      updatedAt = parsed
    }
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: SectionCloudKitSchema.entityID(from: record.recordID.recordName),
              title: "",
              color: "")
    apply(record)
  }
}
