import Foundation
import SwiftData

// MARK: - Shared id helpers
//
// ⚠️  IDENTIFIER MODEL — applies to ALL label-style entities project-wide.
//     Read [IDENTIFIERS.md](docs/IDENTIFIERS.md) before adding a new entity type.
//     Do not invent a per-type id scheme.
//
//   • `id`   — frozen at creation, base32 shortid. Internal stable key,
//              CKRecord.recordName, FK target. Invisible to users.
//   • `title`— freely editable display string. The only user-facing name.

/// Generate opaque, immutable identifiers for new records. base32-style
/// alphabet (no `0/o/1/l/i` — characters that are easy to misread in
/// logs or hand-copy). 4 chars = 32^4 ≈ 1M combos — comfortable for the
/// dozens-of-records-per-type scale we're at. Collision handling lives
/// at the call site (try-once-then-retry).
enum IDShortcode {
  /// 32-character alphabet without ambiguous glyphs.
  static let alphabet: [Character] =
    Array("abcdefghjkmnpqrstuvwxyz23456789")

  /// 4-char shortid for label-style entities (areas, projects, and
  /// eventually chores/habits/sections etc).
  static func generate(length: Int = 4) -> String {
    String((0..<length).map { _ in alphabet.randomElement()! })
  }
}

// AreasBackend — the mutation seam for areas. Views call `AreasMutator`
// without caring how the write reaches the CloudKit mirror.

@MainActor
protocol AreasBackend: AnyObject {
  func create(title: String, context: String?) async throws -> Area
  func rename(id: String, to title: String) async throws
  func setContext(id: String, context: String?) async throws
  func setEmoji(id: String, emoji: String?) async throws
  func setAttachment(id: String, attachment: AreaAttachment?) async throws
  func delete(id: String) async throws
  /// Renumber areas to match `orderedIDs` (synced sidebar order). See
  /// `docs/DRAG_AND_DROP.md` §5 gap #2.
  func reorder(orderedIDs: [String]) async throws
}

// MARK: - Facade

@MainActor
@Observable
final class AreasMutator: AreasBackend {
  private let context: ModelContext
  private var ckBackend: CloudKitAreasBackend?
  /// Set once at startup so `delete` can cascade into the area's projects and
  /// tasks through their own write boundaries. Weak: neither points back here.
  weak var taskMutator: TaskMutator?
  weak var projectsMutator: ProjectsMutator?

  init(context: ModelContext) {
    self.context = context
  }

  func bind(ckEngine: CKEngine) {
    self.ckBackend = CloudKitAreasBackend(engine: ckEngine, context: context)
  }

  private func requireBackend() throws -> CloudKitAreasBackend {
    guard let ck = ckBackend else {
      throw NSError(
        domain: "AreasMutator", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "AreasMutator used before CloudKit bind()"]
      )
    }
    return ck
  }

  func create(title: String, context ctx: String? = nil) async throws -> Area {
    try await requireBackend().create(title: title, context: ctx)
  }
  func rename(id: String, to title: String) async throws {
    try await requireBackend().rename(id: id, to: title)
  }
  func setContext(id: String, context ctx: String?) async throws {
    try await requireBackend().setContext(id: id, context: ctx)
  }
  func setEmoji(id: String, emoji: String?) async throws {
    try await requireBackend().setEmoji(id: id, emoji: emoji)
  }
  func setAttachment(id: String, attachment: AreaAttachment?) async throws {
    try await requireBackend().setAttachment(id: id, attachment: attachment)
  }
  /// Delete an area and everything filed in it: each of its projects is
  /// deleted the way `ProjectsMutator.delete` deletes one (its tasks go to
  /// Recently Deleted), then every task filed directly in the area goes to
  /// Recently Deleted, then the area row goes. Nothing lands in the Inbox
  /// (`TaskInbox`). Undo is recorded at the gesture (`TaskUndo.recordAreaDelete`).
  func delete(id: String) async throws {
    let backend = try requireBackend()
    DeletedContainerLedger.record(.area, id)
    let projects = (try? context.fetch(FetchDescriptor<ProjectEntity>(
      predicate: #Predicate { $0.area == id }
    ))) ?? []
    for project in projects.map(\.id) {
      try? await projectsMutator?.delete(id: project)
    }
    let trashed = trashTasks(inArea: id)
    if !projects.isEmpty || trashed > 0 {
      SeptenaLog.info("[CK] area \(id) delete: \(projects.count) project(s), \(trashed) direct task(s) → Recently Deleted")
    }
    try await backend.delete(id: id)
  }
  func reorder(orderedIDs: [String]) async throws {
    try await requireBackend().reorder(orderedIDs: orderedIDs)
  }

  /// Soft-delete every live task (any status) filed directly in `areaID`,
  /// through the task write boundary. Returns how many went.
  @discardableResult
  private func trashTasks(inArea areaID: String) -> Int {
    let ids = ((try? context.fetch(FetchDescriptor<TaskEntity>(
      predicate: #Predicate { $0.area == areaID && $0.deletedAt == nil }
    ))) ?? []).map(\.id)
    for task in ids { taskMutator?.delete(id: task) }
    return ids.count
  }

  /// The receiver half of the delete cascade. The device that deletes an
  /// area or project also sends every task delete; a device that pulls the
  /// container delete first holds tasks that still point at a dead id. The
  /// reads hide those (`DeletedContainerLedger.hides`), and this sweep, run
  /// after a full pull, moves any that are still live to Recently Deleted —
  /// never to the Inbox. Projects still filed in a deleted area are deleted
  /// with their tasks. Only ids the ledger knows were deleted, never "any
  /// unknown id": a container that is merely not fetched yet keeps its tasks.
  /// Skips an id whose container exists again (undo, forensic re-create).
  /// Idempotent; returns at once while the ledger is empty.
  func sweepDeletedContainerOrphans() async {
    let ledger = DeletedContainerLedger.snapshot()
    guard !ledger.areas.isEmpty || !ledger.projects.isEmpty else { return }
    let liveAreas = Set(((try? context.fetch(FetchDescriptor<AreaEntity>())) ?? []).map(\.id))
    let projects = (try? context.fetch(FetchDescriptor<ProjectEntity>())) ?? []
    let liveProjects = Set(projects.map(\.id))
    let deadAreas = Array(ledger.areas.subtracting(liveAreas))
    let deadProjects = Array(ledger.projects.subtracting(liveProjects))
    guard !deadAreas.isEmpty || !deadProjects.isEmpty else { return }

    // Projects still filed in a deleted area go with their tasks.
    let doomedProjects = projects.filter { $0.area.map(deadAreas.contains) == true }.map(\.id)
    for project in doomedProjects {
      try? await projectsMutator?.delete(id: project)
    }
    // Then every live task (any status, headings included) still pointing at
    // a dead id. One fetch; tasks first, headings last, as in
    // `ProjectsMutator.trashTasks`.
    let rows = (try? context.fetch(FetchDescriptor<TaskEntity>(
      predicate: #Predicate { e in
        e.deletedAt == nil
          && (deadProjects.contains(e.project ?? "") || deadAreas.contains(e.area ?? ""))
      }
    ))) ?? []
    let ids = rows.filter { !$0.isHeading }.map(\.id) + rows.filter(\.isHeading).map(\.id)
    for task in ids { taskMutator?.delete(id: task) }
    if !doomedProjects.isEmpty || !ids.isEmpty {
      SeptenaLog.info("[CK] sweep: \(doomedProjects.count) project(s), \(ids.count) task(s) of deleted containers → Recently Deleted")
    }
  }

  // MARK: Undo support

  /// Every stored field of an area, captured before a delete so an undo can
  /// put the row back exactly. Capture it at the user gesture, BEFORE
  /// `delete(id:)`; the undo is recorded by the caller
  /// (`TaskUndo.recordAreaDelete`), never here.
  struct DeletedArea {
    let id: String
    let title: String
    let context: String?
    let emoji: String?
    let attachmentJSON: String?
    let position: Int
    let cloudKitSystemFields: Data?
  }

  func snapshotForDelete(id: String) -> DeletedArea? {
    let descriptor = FetchDescriptor<AreaEntity>(predicate: #Predicate { $0.id == id })
    guard let e = try? context.fetch(descriptor).first else { return nil }
    return DeletedArea(id: e.id, title: e.title, context: e.context, emoji: e.emoji,
                       attachmentJSON: e.attachmentJSON, position: e.position,
                       cloudKitSystemFields: e.cloudKitSystemFields)
  }

  /// Bring a deleted area back — same id when the sync store allows it, else
  /// a fresh one (`ProjectsMutator.revive` is the twin). Returns the id used.
  @discardableResult
  func revive(_ snapshot: DeletedArea) -> String? {
    guard let backend = ckBackend else { return nil }
    return backend.revive(snapshot)
  }

  /// Forensic — create a record with a specific id.
  @discardableResult
  func createWithExplicitID(id: String, title: String, context ctx: String? = nil) async throws -> Area {
    try await requireBackend().createWithExplicitID(id: id, title: title, context: ctx)
  }
}

// MARK: - CloudKit impl

@MainActor
final class CloudKitAreasBackend: AreasBackend {
  private let engine: CKEngine
  private let context: ModelContext

  init(engine: CKEngine, context: ModelContext) {
    self.engine = engine
    self.context = context
  }

  private func fetch(id: String) -> AreaEntity? {
    let descriptor = FetchDescriptor<AreaEntity>(
      predicate: #Predicate { $0.id == id }
    )
    return try? context.fetch(descriptor).first
  }

  /// Generate a fresh opaque `id` for a new area. Try once; on the
  /// (statistically improbable) double collision, fall to 6 chars. Past
  /// that, panic to a UUID prefix — the panic branch never fires in
  /// practice at this scale.
  private func uniqueShortcode() -> String {
    let first = IDShortcode.generate(length: 4)
    if fetch(id: first) == nil { return first }
    let second = IDShortcode.generate(length: 6)
    if fetch(id: second) == nil { return second }
    return String(UUID().uuidString.prefix(8)).lowercased()
  }

  private func commitAndPush(_ entity: AreaEntity, op: String, deletion: Bool = false) {
    let id = entity.id
    let title = entity.title
    // A rolled-back save means the change no longer exists locally, so it
    // must not be pushed to CloudKit as if it did. Same rule as
    // `CloudKitTasksBackend.commitAndPush`.
    guard StoreHealth.save(context, op: "area.\(op)") else {
      SeptenaLog.error("[CK] area \(op) id=\(id) NOT pushed — local save failed and rolled back")
      NotificationCenter.default.post(name: .septenaStructureChanged, object: nil)
      return
    }
    if deletion {
      engine.noteAreaDeletion(id: id)
      SeptenaLog.info("[CK] area \(op) id=\(id) title=\"\(title)\" → engine.noteAreaDeletion")
    } else {
      engine.noteAreaChange(id: id)
      SeptenaLog.info("[CK] area \(op) id=\(id) title=\"\(title)\" → engine.noteAreaChange")
    }
    NotificationCenter.default.post(name: .septenaStructureChanged, object: nil)
  }

  func create(title: String, context ctx: String?) async throws -> Area {
    let newId = uniqueShortcode()
    let entity = AreaEntity(id: newId, title: title, context: ctx)
    context.insert(entity)
    commitAndPush(entity, op: "create")
    return Area(entity)
  }

  /// Forensic create: caller supplies the entity id (becomes CKRecord
  /// recordName `area:<id>`). Used to rebuild a missing record so that
  /// existing dangling task/project references (which match on entity id)
  /// resolve. Skips uniqueShortcode because the caller is asserting a
  /// specific identity.
  @discardableResult
  func createWithExplicitID(id: String, title: String, context ctx: String? = nil) async throws -> Area {
    if let existing = fetch(id: id) {
      return Area(existing)
    }
    let entity = AreaEntity(id: id, title: title, context: ctx)
    context.insert(entity)
    DeletedContainerLedger.forget(.area, id)
    commitAndPush(entity, op: "create(explicit-id)")
    return Area(entity)
  }

  func revive(_ s: AreasMutator.DeletedArea) -> String {
    if let existing = fetch(id: s.id) { return existing.id }
    let sameID = engine.canReviveContainer(.area, id: s.id)
    let id = sameID ? s.id : uniqueShortcode()
    // Same rule as `CloudKitProjectsBackend.revive`: a CloudKit delete that
    // never went out leaves the record in place, so the save is an update
    // and keeps the old change tag; otherwise the row is new to CloudKit.
    let keepSystemFields = sameID && engine.cancelPendingContainerDeletion(.area, id: s.id)
    let entity = AreaEntity(id: id, title: s.title, context: s.context, emoji: s.emoji,
                            attachmentJSON: s.attachmentJSON, position: s.position,
                            cloudKitSystemFields: keepSystemFields ? s.cloudKitSystemFields : nil)
    context.insert(entity)
    DeletedContainerLedger.forget(.area, id)
    commitAndPush(entity, op: sameID ? "revive" : "revive(new-id)")
    return id
  }

  func rename(id: String, to title: String) async throws {
    guard let entity = fetch(id: id) else { return }
    entity.title = title
    commitAndPush(entity, op: "rename")
  }

  func setContext(id: String, context ctx: String?) async throws {
    guard let entity = fetch(id: id) else { return }
    entity.context = (ctx?.isEmpty == true) ? nil : ctx
    commitAndPush(entity, op: "setContext")
  }

  func setEmoji(id: String, emoji: String?) async throws {
    guard let entity = fetch(id: id) else { return }
    entity.emoji = (emoji?.isEmpty == true) ? nil : emoji
    commitAndPush(entity, op: "setEmoji")
  }

  func setAttachment(id: String, attachment: AreaAttachment?) async throws {
    guard let entity = fetch(id: id) else { return }
    entity.attachmentJSON = attachment?.normalized?.encodedString()
    commitAndPush(entity, op: "setAttachment")
  }

  func delete(id: String) async throws {
    guard let entity = fetch(id: id) else { return }
    let staged = entity
    context.delete(entity)
    commitAndPush(staged, op: "delete", deletion: true)
  }

  /// Renumber areas to `orderedIDs` (positions 1…N) and sync. The set is tiny,
  /// so we rewrite the whole order on each reorder rather than midpoint-insert;
  /// only rows whose position actually changed are pushed, with a single save +
  /// one structure-changed post for the batch. See `docs/DRAG_AND_DROP.md` §5.
  func reorder(orderedIDs: [String]) async throws {
    var changed: [String] = []
    for (index, id) in orderedIDs.enumerated() {
      guard let entity = fetch(id: id) else { continue }
      let newPos = index + 1
      if entity.position != newPos { entity.position = newPos; changed.append(id) }
    }
    guard !changed.isEmpty else { return }
    guard StoreHealth.save(context, op: "area.reorder") else { return }
    for id in changed { engine.noteAreaChange(id: id) }
    SeptenaLog.info("[CK] area reorder → \(changed.count) repositioned")
    NotificationCenter.default.post(name: .septenaStructureChanged, object: nil)
  }
}

// MARK: - Deleted-container ledger

/// Area and project ids this device knows were deleted — locally, or by a
/// delete pulled from another device (CloudKit or the task backend). Two
/// readers:
///   • the task reads hide a live task that still points at one of these
///     (`hides`): its own delete is on the way, so it is "orphaned, awaiting
///     delete", never Inbox (`TaskInbox`);
///   • `AreasMutator.sweepDeletedContainerOrphans` moves such tasks to
///     Recently Deleted after a full pull.
/// An id leaves the ledger when its container exists again (undo revive, a
/// forensic re-create, a pulled upsert). Device-local `UserDefaults`, capped
/// per kind. Thread-safe: the CloudKit apply path records ids off the main
/// actor, so the in-memory copy sits behind a lock.
enum DeletedContainerLedger {
  enum Kind: String, Sendable {
    case area, project
    /// `area` keeps the key of the old area-only ledger, so ids it recorded
    /// stay known.
    fileprivate var key: String {
      switch self {
      case .area: return "septena.deletedAreaIDs"
      case .project: return "septena.deletedProjectIDs"
      }
    }
  }

  private static let cap = 200
  private static let lock = NSLock()
  nonisolated(unsafe) private static var cache: [Kind: [String]] = [:]

  private static func load(_ kind: Kind) -> [String] {
    if let list = cache[kind] { return list }
    let list = UserDefaults.standard.stringArray(forKey: kind.key) ?? []
    cache[kind] = list
    return list
  }

  static func record(_ kind: Kind, _ id: String) {
    lock.lock(); defer { lock.unlock() }
    var list = load(kind)
    guard !list.contains(id) else { return }
    list.append(id)
    if list.count > cap { list.removeFirst(list.count - cap) }
    cache[kind] = list
    UserDefaults.standard.set(list, forKey: kind.key)
  }

  static func forget(_ kind: Kind, _ id: String) {
    lock.lock(); defer { lock.unlock() }
    var list = load(kind)
    guard let index = list.firstIndex(of: id) else { return }
    list.remove(at: index)
    cache[kind] = list
    UserDefaults.standard.set(list, forKey: kind.key)
  }

  static func ids(_ kind: Kind) -> [String] {
    lock.lock(); defer { lock.unlock() }
    return load(kind)
  }

  /// Both kinds as sets, for a read that checks many rows.
  static func snapshot() -> (areas: Set<String>, projects: Set<String>) {
    lock.lock(); defer { lock.unlock() }
    return (Set(load(.area)), Set(load(.project)))
  }

  /// True when a live task's area or project was deleted and the task is only
  /// waiting for its own delete. Pass a `snapshot()` when checking many rows.
  static func hides(area: String?, project: String?,
                    in dead: (areas: Set<String>, projects: Set<String>)) -> Bool {
    if let project, dead.projects.contains(project) { return true }
    if let area, dead.areas.contains(area) { return true }
    return false
  }
}
