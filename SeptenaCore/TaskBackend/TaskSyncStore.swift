import Foundation
import SwiftData

// The task-sync client's own persistent state (docs/SEPTASK_BACKEND.md §6.5):
//
//   - the OUTBOX: ops not yet confirmed by the backend, in enqueue order;
//   - the SHADOW: per row, the field values this device last sent or last
//     received from the backend. A local change is the difference between the
//     row in SwiftData and its shadow, so a push carries only changed fields
//     (§6.4, field-level last-writer-wins).
//
// Why a separate SwiftData store and not the main one or a JSON file:
//   - Not the main store: adding model types to the shared `LocalStore`
//     schema migrates the file Septena and Septask BOTH open. An older build
//     of the other app then cannot open it (`LocalStore` fatalErrors rather
//     than erase). This store belongs to Septask alone; deleting it loses no
//     user data, only the queue and the shadow.
//   - Not JSON: the shadow holds one entry per task, area, project and
//     attachment (thousands). A JSON file would be rewritten whole on every
//     edit; SQLite writes the one changed row, inside a transaction.
//
// The shadow is persisted (not rebuilt from SwiftData at launch) so that an
// edit that reached the store but not the outbox (a crash in between, or a
// write from Septena's process while the CloudKit task types are frozen) still
// shows up as a difference at the next reconcile, and is pushed.

/// One queued backend op.
@Model
final class TaskSyncOp {
  /// Minted once at enqueue ("s1-" + 32 hex) and kept for every retry, so a
  /// retried push dedupes on the server (`client_ops`). Not a content hash:
  /// setting a field back to an earlier value must not dedupe against the
  /// earlier op within the server's 30-day window.
  @Attribute(.unique) var clientOpId: String
  /// Enqueue order. Ops are pushed in this order.
  var seq: Int
  /// `upsert`, `delete`, `appendTurn`, or `upload` (attachment bytes, sent
  /// with `PUT /v1/attachments/:id`, never in a push batch).
  var kind: String
  /// `BackendEntity` raw value. `turn` for appendTurn. Named `opEntity`
  /// because `NSManagedObject` already answers both `entity` and
  /// `entityName`: a stored property with either name is shadowed by Core
  /// Data's own method once the object is saved, so fetch predicates failed
  /// and reads trapped (2026-11-19). Check new stored names against
  /// `NSManagedObject.instancesRespond(to:)`.
  var opEntity: String
  /// The row id. For appendTurn, the task id.
  var rowID: String
  /// appendTurn: the turn's index in the local thread. Unused otherwise.
  var turnIndex: Int
  /// JSON object: the upsert fields, or the turn. Empty object otherwise.
  var payload: Data
  /// True once the op went out in a request. A sealed op is never merged
  /// into: the server may already hold it under this clientOpId.
  var sent: Bool
  var attempts: Int
  /// Not pushed before this time: the soft-delete grace period, and upload
  /// retries.
  var notBefore: Date
  var createdAt: Date

  init(clientOpId: String, seq: Int, kind: String, entity: String, rowID: String,
       turnIndex: Int = 0, payload: Data, notBefore: Date = .distantPast) {
    self.clientOpId = clientOpId
    self.seq = seq
    self.kind = kind
    self.opEntity = entity
    self.rowID = rowID
    self.turnIndex = turnIndex
    self.payload = payload
    self.sent = false
    self.attempts = 0
    self.notBefore = notBefore
    self.createdAt = Date()
  }
}

/// The last known backend-side state of one row, as `TaskBackendMapping`
/// fields. Keys: `task:<id>`, `convo:<taskId>`, `turns:<taskId>`, `area:<id>`,
/// `project:<id>`, `attachment:<id>`, `setting:<key>` (fields `{ value }`).
@Model
final class TaskSyncShadow {
  @Attribute(.unique) var key: String
  /// JSON object of field values. Task shadows also carry `_deleted` (the row
  /// is in Recently Deleted here) and `_remote` (the row was ever sent or
  /// received). The turns shadow carries `server`, `pushed`, `local`.
  var fields: Data
  /// The row is deleted on the backend, or was hard-deleted here. Kept so a
  /// late local edit is not taken for a new row, and so the rollback writer
  /// knows which CloudKit records to delete.
  var gone: Bool

  init(key: String, fields: Data, gone: Bool = false) {
    self.key = key
    self.fields = fields
    self.gone = gone
  }
}

enum TaskSyncOpKind {
  static let upsert = "upsert"
  static let delete = "delete"
  static let appendTurn = "appendTurn"
  static let upload = "upload"
}

enum TaskSyncJSON {
  static func encode(_ object: [String: BackendJSON]) -> Data {
    (try? JSONEncoder().encode(object)) ?? Data("{}".utf8)
  }

  static func decode(_ data: Data) -> [String: BackendJSON] {
    (try? JSONDecoder().decode([String: BackendJSON].self, from: data)) ?? [:]
  }
}

@MainActor
final class TaskSyncStore {
  let container: ModelContainer
  let context: ModelContext
  private var saveScheduled = false

  /// Bumped when the store's schema changes incompatibly. A new version
  /// starts from an empty file and pulls from rev 0: the store only holds the
  /// outbox and shadows, which a full pull and reconcile rebuild.
  /// v5: the op's entity column is `opEntity` (see `TaskSyncOp.opEntity`).
  private static let version = 5
  private static let versionKey = "septena.taskSync.storeVersion"

  init() throws {
    if UserDefaults.standard.integer(forKey: Self.versionKey) != Self.version {
      UserDefaults.standard.set(0, forKey: TaskSyncEngine.sinceKey)
      UserDefaults.standard.set(Self.version, forKey: Self.versionKey)
    }
    let schema = Schema([TaskSyncOp.self, TaskSyncShadow.self])
    let config = ModelConfiguration("TaskSync", schema: schema, url: Self.url, cloudKitDatabase: .none)
    container = try ModelContainer(for: schema, configurations: [config])
    context = container.mainContext
    context.autosaveEnabled = false
  }

  /// Septask-only, next to (never inside) the main store. On the Mac that is
  /// `~/Library/Septena/`, the one place the App Data privacy prompt does not
  /// guard (see `MacStoreLocation`).
  static var url: URL {
    #if os(macOS)
    if let main = MacStoreLocation.url {
      let dir = main.deletingLastPathComponent()
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      return dir.appendingPathComponent("TaskSync-Septask-v\(version).store")
    }
    #endif
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base.appendingPathComponent("TaskSync-v\(version).store")
  }

  // MARK: Save

  /// Saves now. Use after a network result, where the next step depends on
  /// the queue being on disk.
  func saveNow() {
    saveScheduled = false
    guard context.hasChanges else { return }
    do { try context.save() } catch {
      SeptenaLog.error("[TaskSync] queue save failed", error)
    }
  }

  /// Saves at the end of this main-actor turn, so a bulk edit (a project
  /// delete detaching 200 tasks) writes the queue once.
  func saveSoon() {
    guard !saveScheduled else { return }
    saveScheduled = true
    Task { @MainActor [weak self] in self?.saveNow() }
  }

  // MARK: Ops

  func allOps() -> [TaskSyncOp] {
    live((try? context.fetch(FetchDescriptor<TaskSyncOp>(sortBy: [SortDescriptor(\.seq)]))) ?? [])
  }

  /// Drops ops that were deleted, or whose rows a reset removed underneath
  /// the context. Reading a stored property of such an op traps in SwiftData
  /// (a failed cast of its missing backing value), which crashed a push on
  /// 2026-11-19. Every op list handed out passes through here.
  private func live(_ ops: [TaskSyncOp]) -> [TaskSyncOp] {
    ops.filter { !$0.isDeleted && $0.modelContext != nil }
  }

  func opCount() -> Int {
    (try? context.fetchCount(FetchDescriptor<TaskSyncOp>())) ?? 0
  }

  func ops(entity: String, rowID: String) -> [TaskSyncOp] {
    let descriptor = FetchDescriptor<TaskSyncOp>(
      predicate: #Predicate { $0.opEntity == entity && $0.rowID == rowID },
      sortBy: [SortDescriptor(\.seq)])
    return live((try? context.fetch(descriptor)) ?? [])
  }

  /// The newest upsert or delete for a row (uploads and turns excluded).
  func lastRowOp(entity: String, rowID: String) -> TaskSyncOp? {
    ops(entity: entity, rowID: rowID).last {
      $0.kind == TaskSyncOpKind.upsert || $0.kind == TaskSyncOpKind.delete
    }
  }

  private var nextSeqValue: Int?

  private func nextSeq() -> Int {
    if nextSeqValue == nil {
      var d = FetchDescriptor<TaskSyncOp>(sortBy: [SortDescriptor(\.seq, order: .reverse)])
      d.fetchLimit = 1
      nextSeqValue = ((try? context.fetch(d).first?.seq) ?? 0) + 1
    }
    defer { nextSeqValue! += 1 }
    return nextSeqValue!
  }

  @discardableResult
  func append(kind: String, entity: String, rowID: String, turnIndex: Int = 0,
              payload: [String: BackendJSON], notBefore: Date = .distantPast) -> TaskSyncOp {
    let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let op = TaskSyncOp(clientOpId: "s1-" + hex, seq: nextSeq(), kind: kind, entity: entity,
                        rowID: rowID, turnIndex: turnIndex, payload: TaskSyncJSON.encode(payload),
                        notBefore: notBefore)
    context.insert(op)
    saveSoon()
    return op
  }

  func remove(_ op: TaskSyncOp) {
    context.delete(op)
    saveSoon()
  }

  // MARK: Shadow

  func shadow(_ key: String) -> TaskSyncShadow? {
    var d = FetchDescriptor<TaskSyncShadow>(predicate: #Predicate { $0.key == key })
    d.fetchLimit = 1
    return try? context.fetch(d).first
  }

  func allShadows() -> [String: TaskSyncShadow] {
    let rows = (try? context.fetch(FetchDescriptor<TaskSyncShadow>())) ?? []
    var out: [String: TaskSyncShadow] = [:]
    for row in rows { out[row.key] = row }
    return out
  }

  /// Creates the shadow when missing.
  func upsertShadow(_ key: String, fields: [String: BackendJSON], gone: Bool? = nil) {
    if let s = shadow(key) {
      s.fields = TaskSyncJSON.encode(fields)
      if let gone { s.gone = gone }
    } else {
      context.insert(TaskSyncShadow(key: key, fields: TaskSyncJSON.encode(fields), gone: gone ?? false))
    }
    saveSoon()
  }

  func removeShadow(_ key: String) {
    guard let s = shadow(key) else { return }
    context.delete(s)
    saveSoon()
  }

  // MARK: Reset

  // Deletes go object by object through the context, not as a batch delete:
  // `delete(model:)` removes rows in the store while objects the context
  // already holds stay registered, and the next read of one of them traps.

  func deleteAllShadows() {
    for row in (try? context.fetch(FetchDescriptor<TaskSyncShadow>())) ?? [] {
      context.delete(row)
    }
    saveNow()
  }

  func deleteEverything() {
    for op in (try? context.fetch(FetchDescriptor<TaskSyncOp>())) ?? [] {
      context.delete(op)
    }
    for row in (try? context.fetch(FetchDescriptor<TaskSyncShadow>())) ?? [] {
      context.delete(row)
    }
    nextSeqValue = nil
    saveNow()
  }
}
