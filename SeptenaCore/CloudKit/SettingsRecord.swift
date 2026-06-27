import Foundation
import CloudKit
import SwiftData

enum SettingsCloudKitSchema {
  static let recordType = "Settings"
  static let singletonID = "app"

  enum Field {
    static let payloadJSON = "payloadJSON"
    static let updatedAt = "updatedAt"
    static let reservedString1 = "reservedString1"
    static let reservedInt1 = "reservedInt1"
  }
}

extension SettingsEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: SettingsCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: id, zoneID: SeptenaCloudKit.zoneID)
    )
    record[SettingsCloudKitSchema.Field.payloadJSON] =
      String(data: payloadData, encoding: .utf8)
    record[SettingsCloudKitSchema.Field.updatedAt] = updatedAt.ISO8601Format()
    return record
  }

  func apply(_ record: CKRecord) {
    if let json = record[SettingsCloudKitSchema.Field.payloadJSON] as? String,
       let data = json.data(using: .utf8) {
      payloadData = data
    }
    if let rawUpdatedAt = record[SettingsCloudKitSchema.Field.updatedAt] as? String,
       let parsed = ISO8601DateFormatter().date(from: rawUpdatedAt) {
      updatedAt = parsed
    }
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    let json = (record[SettingsCloudKitSchema.Field.payloadJSON] as? String) ?? "{}"
    self.init(id: record.recordID.recordName,
              payloadData: json.data(using: .utf8) ?? Data("{}".utf8))
    apply(record)
  }
}
