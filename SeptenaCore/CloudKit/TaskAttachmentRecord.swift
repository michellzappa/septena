import CloudKit
import Foundation
import SwiftData
import UniformTypeIdentifiers

@Model
final class TaskAttachmentEntity {
  @Attribute(.unique) var id: String
  var taskID: String
  var filename: String
  var contentType: String
  var byteCount: Int64
  var createdAt: Date
  var position: Double
  var localFilename: String?
  var cloudKitSystemFields: Data?

  init(id: String, taskID: String, filename: String, contentType: String,
       byteCount: Int64, createdAt: Date = .now, position: Double = 0,
       localFilename: String? = nil, cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.taskID = taskID
    self.filename = filename
    self.contentType = contentType
    self.byteCount = byteCount
    self.createdAt = createdAt
    self.position = position
    self.localFilename = localFilename
    self.cloudKitSystemFields = cloudKitSystemFields
  }
}

enum TaskAttachmentCloudKitSchema {
  static let recordType = "TaskAttachment"
  static let prefix = "task-attachment:"
  static func recordName(for id: String) -> String { prefix + id }
  static func entityID(from recordName: String) -> String {
    recordName.hasPrefix(prefix) ? String(recordName.dropFirst(prefix.count)) : recordName
  }
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

enum TaskAttachmentFiles {
  static let maxBytes: Int64 = 25 * 1_024 * 1_024

  static var directory: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask).first!
    let url = base.appendingPathComponent("TaskAttachments", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static func url(for entity: TaskAttachmentEntity) -> URL? {
    entity.localFilename.map { directory.appendingPathComponent($0) }
  }

  static func ownedFilename(id: String, original: String) -> String {
    let ext = URL(fileURLWithPath: original).pathExtension
    return ext.isEmpty ? id : "\(id).\(ext)"
  }

  @discardableResult
  static func copyIntoStore(source: URL, id: String, original: String) throws -> String {
    let name = ownedFilename(id: id, original: original)
    let destination = directory.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.copyItem(at: source, to: destination)
    return name
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

@MainActor
final class TaskAttachmentStore {
  private let context: ModelContext
  private let engine: CKEngine

  init(context: ModelContext, engine: CKEngine) {
    self.context = context
    self.engine = engine
  }

  func attachments(taskID: String) -> [TaskAttachmentEntity] {
    // Filter and sort in the store. This used to materialize EVERY attachment
    // row in the database and filter in memory — from a view body, on every
    // composer render (see `attachmentCount` for the cheaper existence check).
    let descriptor = FetchDescriptor<TaskAttachmentEntity>(
      predicate: #Predicate { $0.taskID == taskID },
      sortBy: [SortDescriptor(\.position), SortDescriptor(\.createdAt)]
    )
    return (try? context.fetch(descriptor)) ?? []
  }

  /// How many attachments a task has, counted in the store without
  /// materializing them. For view bodies that only need "any?" or a badge
  /// number — the common case, and the one that was doing the most work.
  func attachmentCount(taskID: String) -> Int {
    let descriptor = FetchDescriptor<TaskAttachmentEntity>(
      predicate: #Predicate { $0.taskID == taskID }
    )
    return (try? context.fetchCount(descriptor)) ?? 0
  }

  func add(taskID: String, sourceURL: URL) throws {
    let access = sourceURL.startAccessingSecurityScopedResource()
    defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }
    let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .nameKey])
    let bytes = Int64(values.fileSize ?? 0)
    guard bytes <= TaskAttachmentFiles.maxBytes else {
      throw CocoaError(.fileReadTooLarge, userInfo: [NSLocalizedDescriptionKey: "Attachments must be 25 MB or smaller."])
    }
    let id = UUID().uuidString.lowercased()
    let filename = values.name ?? sourceURL.lastPathComponent
    let stored = try TaskAttachmentFiles.copyIntoStore(source: sourceURL, id: id, original: filename)
    let entity = TaskAttachmentEntity(id: id, taskID: taskID, filename: filename,
      contentType: values.contentType?.identifier ?? "application/octet-stream",
      byteCount: bytes, position: Double(attachments(taskID: taskID).count), localFilename: stored)
    context.insert(entity)
    try StoreHealth.saveOrThrow(context, op: "TaskAttachmentRecord.add")
    engine.noteTaskAttachmentChange(id: id)
    TaskChange.post(taskID)
  }

  func remove(_ entity: TaskAttachmentEntity) {
    let taskID = entity.taskID
    let id = entity.id
    if let url = TaskAttachmentFiles.url(for: entity) { try? FileManager.default.removeItem(at: url) }
    context.delete(entity)
    StoreHealth.save(context, op: "TaskAttachmentRecord.remove")
    engine.noteTaskAttachmentDeletion(id: id)
    TaskChange.post(taskID)
  }

  var storageSummary: (count: Int, bytes: Int64) {
    let rows = (try? context.fetch(FetchDescriptor<TaskAttachmentEntity>())) ?? []
    return (rows.count, rows.reduce(0) { $0 + $1.byteCount })
  }
}
