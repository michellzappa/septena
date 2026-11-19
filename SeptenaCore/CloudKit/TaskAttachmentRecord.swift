import CloudKit
import Foundation
import SwiftData

// TaskAttachmentEntity ↔ CKRecord mapping (Septena Life only; Septask
// excludes this file). The model and store live in TaskAttachments.swift,
// the record name in TaskRecordNames.swift.

extension TaskAttachmentCloudKitSchema {
  enum Field {
    static let taskID = "taskID"
    static let filename = "filename"
    static let contentType = "contentType"
    static let byteCount = "byteCount"
    static let createdAt = "createdAt"
    static let position = "position"
    static let asset = "asset"
  }
}

extension TaskAttachmentEntity: CloudKitSystemFieldsBacked {
  func toCloudKitRecord() -> CKRecord {
    let record = decodedCloudKitRecord() ?? CKRecord(
      recordType: TaskAttachmentCloudKitSchema.recordType,
      recordID: CKRecord.ID(recordName: TaskAttachmentCloudKitSchema.recordName(for: id),
                            zoneID: SeptenaCloudKit.zoneID))
    record[TaskAttachmentCloudKitSchema.Field.taskID] = taskID
    record[TaskAttachmentCloudKitSchema.Field.filename] = filename
    record[TaskAttachmentCloudKitSchema.Field.contentType] = contentType
    record[TaskAttachmentCloudKitSchema.Field.byteCount] = byteCount
    record[TaskAttachmentCloudKitSchema.Field.createdAt] = createdAt as NSDate
    record[TaskAttachmentCloudKitSchema.Field.position] = position
    if let url = TaskAttachmentFiles.url(for: self), FileManager.default.fileExists(atPath: url.path) {
      record[TaskAttachmentCloudKitSchema.Field.asset] = CKAsset(fileURL: url)
    }
    return record
  }

  func apply(_ record: CKRecord) {
    if let value = record[TaskAttachmentCloudKitSchema.Field.taskID] as? String { taskID = value }
    if let value = record[TaskAttachmentCloudKitSchema.Field.filename] as? String { filename = value }
    if let value = record[TaskAttachmentCloudKitSchema.Field.contentType] as? String { contentType = value }
    if let value = record[TaskAttachmentCloudKitSchema.Field.byteCount] as? Int64 { byteCount = value }
    if let value = record[TaskAttachmentCloudKitSchema.Field.createdAt] as? Date { createdAt = value }
    if let value = record[TaskAttachmentCloudKitSchema.Field.position] as? Double { position = value }
    if let asset = record[TaskAttachmentCloudKitSchema.Field.asset] as? CKAsset,
       let source = asset.fileURL,
       let stored = try? TaskAttachmentFiles.copyIntoStore(source: source, id: id, original: filename) {
      localFilename = stored
    }
    captureCloudKitSystemFields(from: record)
  }

  convenience init(cloudKit record: CKRecord) {
    self.init(id: TaskAttachmentCloudKitSchema.entityID(from: record.recordID.recordName),
              taskID: "", filename: "Attachment", contentType: "application/octet-stream",
              byteCount: 0)
    apply(record)
  }
}
