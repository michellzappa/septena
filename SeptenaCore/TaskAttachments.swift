import Foundation
import SwiftData
import UniformTypeIdentifiers

// Task attachments: the SwiftData model, the on-disk file store and the
// mutator-style store the task UI calls. Split out of
// CloudKit/TaskAttachmentRecord.swift (#42) so Septask compiles the model
// without the CKRecord mapping. `cloudKitSystemFields` stays on the model:
// it is part of the shared SwiftData schema.

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

enum TaskAttachmentFiles {
  static let maxBytes: Int64 = 25 * 1_024 * 1_024

  static var directory: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask).first!
    let url = base.appendingPathComponent("TaskAttachments", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Session-scoped stash for recently-deleted attachment files so ⌘Z undo
  /// restores both the metadata row and file bytes cleanly (docs/ATTACHMENTS_MAC_PARITY_SPEC.md §6).
  static var trashDirectory: URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("SeptenaDeletedAttachments", isDirectory: true)
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

  @discardableResult
  static func writeIntoStore(data: Data, id: String, original: String) throws -> String {
    let name = ownedFilename(id: id, original: original)
    let destination = directory.appendingPathComponent(name)
    try data.write(to: destination, options: .atomic)
    return name
  }

  static func stashForUndo(from entity: TaskAttachmentEntity) -> URL? {
    guard let source = url(for: entity),
          FileManager.default.fileExists(atPath: source.path) else { return nil }
    let destName = entity.localFilename ?? ownedFilename(id: entity.id, original: entity.filename)
    let dest = trashDirectory.appendingPathComponent("\(UUID().uuidString.lowercased())-\(destName)")
    do {
      try FileManager.default.moveItem(at: source, to: dest)
      return dest
    } catch {
      return nil
    }
  }
}

/// Immutable snapshot returned by `TaskAttachmentStore.removeForUndo(_:)` so
/// `TaskUndo` can restore both the SwiftData row and the stashed file bytes.
struct TaskAttachmentSnapshot: Sendable {
  let id: String
  let taskID: String
  let filename: String
  let contentType: String
  let byteCount: Int64
  let createdAt: Date
  let position: Double
  let stashedURL: URL?
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

  /// Single-fetch count map for collapsed task lists (avoids per-row SwiftData
  /// fetches during table reloads).
  func attachmentCountsByTask() -> [String: Int] {
    let rows = (try? context.fetch(FetchDescriptor<TaskAttachmentEntity>())) ?? []
    var out: [String: Int] = [:]
    for row in rows { out[row.taskID, default: 0] += 1 }
    return out
  }

  func add(taskID: String, sourceURL: URL) throws {
    let access = sourceURL.startAccessingSecurityScopedResource()
    defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }
    let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .nameKey, .isDirectoryKey])
    if values.isDirectory == true {
      throw CocoaError(.fileReadUnsupportedScheme,
                       userInfo: [NSLocalizedDescriptionKey: "Folders cannot be attached directly. Compress the folder first."])
    }
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

  /// Attach raw bytes (e.g. an image pasted from the macOS clipboard).
  func add(taskID: String, data: Data, filename: String, contentType: String) throws {
    let bytes = Int64(data.count)
    guard bytes <= TaskAttachmentFiles.maxBytes else {
      throw CocoaError(.fileReadTooLarge, userInfo: [NSLocalizedDescriptionKey: "Attachments must be 25 MB or smaller."])
    }
    let id = UUID().uuidString.lowercased()
    let stored = try TaskAttachmentFiles.writeIntoStore(data: data, id: id, original: filename)
    let entity = TaskAttachmentEntity(id: id, taskID: taskID, filename: filename,
      contentType: contentType, byteCount: bytes,
      position: Double(attachments(taskID: taskID).count), localFilename: stored)
    context.insert(entity)
    try StoreHealth.saveOrThrow(context, op: "TaskAttachmentRecord.addData")
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

  /// Remove an attachment while stashing its file bytes in the session trash
  /// directory so `TaskUndo` can restore it cleanly.
  @discardableResult
  func removeForUndo(_ entity: TaskAttachmentEntity) -> TaskAttachmentSnapshot {
    let stashed = TaskAttachmentFiles.stashForUndo(from: entity)
    let snapshot = TaskAttachmentSnapshot(
      id: entity.id,
      taskID: entity.taskID,
      filename: entity.filename,
      contentType: entity.contentType,
      byteCount: entity.byteCount,
      createdAt: entity.createdAt,
      position: entity.position,
      stashedURL: stashed
    )
    context.delete(entity)
    StoreHealth.save(context, op: "TaskAttachmentRecord.removeForUndo")
    engine.noteTaskAttachmentDeletion(id: snapshot.id)
    TaskChange.post(snapshot.taskID)
    return snapshot
  }

  /// Remove an attachment by ID (used by redo after an undone delete).
  @discardableResult
  func removeForUndo(id: String) -> TaskAttachmentSnapshot? {
    var d = FetchDescriptor<TaskAttachmentEntity>(predicate: #Predicate { $0.id == id })
    d.fetchLimit = 1
    guard let entity = (try? context.fetch(d))?.first else { return nil }
    return removeForUndo(entity)
  }

  /// Restore an attachment from a prior `removeForUndo` snapshot.
  @discardableResult
  func restore(_ snapshot: TaskAttachmentSnapshot) -> TaskAttachmentSnapshot? {
    let id = TaskSyncEngine.shared.canRevive(.attachment, snapshot.id)
      ? snapshot.id
      : UUID().uuidString.lowercased()
    var storedFilename: String? = nil
    if let stashed = snapshot.stashedURL, FileManager.default.fileExists(atPath: stashed.path) {
      storedFilename = try? TaskAttachmentFiles.copyIntoStore(source: stashed, id: id, original: snapshot.filename)
    }
    let entity = TaskAttachmentEntity(
      id: id,
      taskID: snapshot.taskID,
      filename: snapshot.filename,
      contentType: snapshot.contentType,
      byteCount: snapshot.byteCount,
      createdAt: snapshot.createdAt,
      position: snapshot.position,
      localFilename: storedFilename
    )
    context.insert(entity)
    guard StoreHealth.save(context, op: "TaskAttachmentRecord.restore") else { return nil }
    engine.noteTaskAttachmentChange(id: id)
    TaskChange.post(snapshot.taskID)
    return TaskAttachmentSnapshot(
      id: id,
      taskID: snapshot.taskID,
      filename: snapshot.filename,
      contentType: snapshot.contentType,
      byteCount: snapshot.byteCount,
      createdAt: snapshot.createdAt,
      position: snapshot.position,
      stashedURL: snapshot.stashedURL
    )
  }

  var storageSummary: (count: Int, bytes: Int64) {
    let rows = (try? context.fetch(FetchDescriptor<TaskAttachmentEntity>())) ?? []
    return (rows.count, rows.reduce(0) { $0 + $1.byteCount })
  }
}
