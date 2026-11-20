import Foundation
import SwiftData

// ProjectsBackend — mutation seam for projects, paralleling AreasBackend.
// Mutations are applied locally to SwiftData and the CKEngine is notified;
// the engine batches the upload to CloudKit.

@MainActor
protocol ProjectsBackend: AnyObject {
  func create(title: String, area: String?) async throws -> Project
  func rename(id: String, to title: String) async throws
  func setNotes(id: String, notes: String?) async throws
  func setStatus(id: String, status: ProjectStatus) async throws
  func setArea(id: String, area: String?) async throws
  func setGithubRepo(id: String, repo: String?) async throws
  func setAttachment(id: String, attachment: AreaAttachment?) async throws
  func delete(id: String) async throws
  /// Renumber projects to match `orderedIDs` (synced sidebar order — the
  /// caller passes one parent group's ids). See `docs/DRAG_AND_DROP.md` §5.
  func reorder(orderedIDs: [String]) async throws
}

// MARK: - Facade

@MainActor
@Observable
final class ProjectsMutator: ProjectsBackend {
  private let context: ModelContext
  private var ckBackend: CloudKitProjectsBackend?
  /// Set once at startup so `delete` can move the project's tasks to Recently
  /// Deleted through the task write boundary. No retain cycle — `TaskMutator`
  /// does not reference back. See `delete(id:)`.
  weak var taskMutator: TaskMutator?

  init(context: ModelContext) {
    self.context = context
  }

  func bind(ckEngine: CKEngine) {
    self.ckBackend = CloudKitProjectsBackend(engine: ckEngine, context: context)
  }

  private func requireBackend() throws -> CloudKitProjectsBackend {
    guard let ck = ckBackend else {
      throw NSError(
        domain: "ProjectsMutator", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "ProjectsMutator used before CloudKit bind()"]
      )
    }
    return ck
  }

  func create(title: String, area: String? = nil) async throws -> Project {
    try await requireBackend().create(title: title, area: area)
  }
  func rename(id: String, to title: String) async throws {
    try await requireBackend().rename(id: id, to: title)
  }
  func setNotes(id: String, notes: String?) async throws {
    try await requireBackend().setNotes(id: id, notes: notes)
  }
  func setStatus(id: String, status: ProjectStatus) async throws {
    try await requireBackend().setStatus(id: id, status: status)
  }
  func setArea(id: String, area: String?) async throws {
    try await requireBackend().setArea(id: id, area: area)
  }
  func setGithubRepo(id: String, repo: String?) async throws {
    try await requireBackend().setGithubRepo(id: id, repo: repo)
  }
  func setAttachment(id: String, attachment: AreaAttachment?) async throws {
    try await requireBackend().setAttachment(id: id, attachment: attachment)
  }
  /// Delete a project and everything in it: every task (open AND done) and
  /// every section heading goes to Recently Deleted — the same soft delete as
  /// deleting a task — then the project row goes. Nothing lands in the Inbox
  /// (`TaskInbox`). Undo is recorded at the gesture
  /// (`TaskUndo.recordProjectDelete`), never here.
  func delete(id: String) async throws {
    let backend = try requireBackend()
    DeletedContainerLedger.record(.project, id)
    let trashed = trashTasks(inProject: id)
    if trashed > 0 {
      SeptenaLog.info("[CK] project \(id) delete: \(trashed) task(s) → Recently Deleted")
    }
    try await backend.delete(id: id)
  }

  /// Soft-delete every live row filed in `projectID`, through the task write
  /// boundary. Tasks go first, headings last: deleting a heading dissolves
  /// its LIVE members (`heading = nil`), so trashing the members first keeps
  /// their `heading` link for the undo / restore. Returns how many went.
  @discardableResult
  func trashTasks(inProject projectID: String) -> Int {
    let rows = (try? context.fetch(FetchDescriptor<TaskEntity>(
      predicate: #Predicate { $0.project == projectID && $0.deletedAt == nil }
    ))) ?? []
    let members = rows.filter { !$0.isHeading }.map(\.id)
    let headings = rows.filter(\.isHeading).map(\.id)
    for task in members + headings { taskMutator?.delete(id: task) }
    return rows.count
  }
  func reorder(orderedIDs: [String]) async throws {
    try await requireBackend().reorder(orderedIDs: orderedIDs)
  }

  // MARK: Undo support

  /// Every stored field of a project, captured before a delete so an undo can
  /// put the row back exactly — sidebar position and sync metadata included.
  /// Capture it at the user gesture, BEFORE `delete(id:)`; the undo is
  /// recorded by the caller (`TaskUndo.recordProjectDelete`), never here.
  struct DeletedProject {
    let id: String
    let title: String
    let statusRaw: String
    /// `var` so an area-delete undo can re-file the project under a revived
    /// area's new id (`TaskUndo.recordAreaDelete`).
    var area: String?
    let created: String?
    let completedAt: String?
    let notes: String?
    let context: String?
    let githubRepo: String?
    let attachmentJSON: String?
    let position: Int
    let cloudKitSystemFields: Data?
  }

  func snapshotForDelete(id: String) -> DeletedProject? {
    let descriptor = FetchDescriptor<ProjectEntity>(predicate: #Predicate { $0.id == id })
    guard let e = try? context.fetch(descriptor).first else { return nil }
    return DeletedProject(id: e.id, title: e.title, statusRaw: e.statusRaw, area: e.area,
                          created: e.created, completedAt: e.completedAt, notes: e.notes,
                          context: e.context, githubRepo: e.githubRepo,
                          attachmentJSON: e.attachmentJSON, position: e.position,
                          cloudKitSystemFields: e.cloudKitSystemFields)
  }

  /// Bring a deleted project back. Uses its old id when the sync store still
  /// allows it (always on CloudKit; on the task backend only while the delete
  /// waits in the outbox), otherwise a fresh id. Returns the id it used, so
  /// the caller re-files the tasks under it. Nil when not bound yet.
  @discardableResult
  func revive(_ snapshot: DeletedProject) -> String? {
    guard let backend = ckBackend else { return nil }
    return backend.revive(snapshot)
  }

  /// Forensic — create a record with a specific id.
  @discardableResult
  func createWithExplicitID(id: String, title: String, area: String? = nil) async throws -> Project {
    try await requireBackend().createWithExplicitID(id: id, title: title, area: area)
  }
}

// MARK: - CloudKit impl

@MainActor
final class CloudKitProjectsBackend: ProjectsBackend {
  private let engine: CKEngine
  private let context: ModelContext

  init(engine: CKEngine, context: ModelContext) {
    self.engine = engine
    self.context = context
  }

  private func fetch(id: String) -> ProjectEntity? {
    let descriptor = FetchDescriptor<ProjectEntity>(
      predicate: #Predicate { $0.id == id }
    )
    return try? context.fetch(descriptor).first
  }

  private func uniqueShortcode() -> String {
    let first = IDShortcode.generate(length: 4)
    if fetch(id: first) == nil { return first }
    let second = IDShortcode.generate(length: 6)
    if fetch(id: second) == nil { return second }
    return String(UUID().uuidString.prefix(8)).lowercased()
  }

  private func commitAndPush(_ entity: ProjectEntity, op: String, deletion: Bool = false) {
    let id = entity.id
    let title = entity.title
    // A rolled-back save means the change no longer exists locally, so it
    // must not be pushed to CloudKit as if it did. Same rule as
    // `CloudKitTasksBackend.commitAndPush`.
    guard StoreHealth.save(context, op: "project.\(op)") else {
      SeptenaLog.error("[CK] project \(op) id=\(id) NOT pushed — local save failed and rolled back")
      NotificationCenter.default.post(name: .septenaStructureChanged, object: nil)
      return
    }
    if deletion {
      engine.noteProjectDeletion(id: id)
      SeptenaLog.info("[CK] project \(op) id=\(id) title=\"\(title)\" → engine.noteProjectDeletion")
    } else {
      engine.noteProjectChange(id: id)
      SeptenaLog.info("[CK] project \(op) id=\(id) title=\"\(title)\" → engine.noteProjectChange")
    }
    NotificationCenter.default.post(name: .septenaStructureChanged, object: nil)
  }

  func create(title: String, area: String?) async throws -> Project {
    let newId = uniqueShortcode()
    let entity = ProjectEntity(id: newId, title: title, area: area)
    context.insert(entity)
    commitAndPush(entity, op: "create")
    return Project(entity)
  }

  /// Forensic create: caller supplies the entity id. Used to rebuild a
  /// missing record so dangling task references resolve.
  @discardableResult
  func createWithExplicitID(id: String, title: String, area: String? = nil) async throws -> Project {
    if let existing = fetch(id: id) {
      return Project(existing)
    }
    let entity = ProjectEntity(id: id, title: title, area: area)
    context.insert(entity)
    DeletedContainerLedger.forget(.project, id)
    commitAndPush(entity, op: "create(explicit-id)")
    return Project(entity)
  }

  func revive(_ s: ProjectsMutator.DeletedProject) -> String {
    if let existing = fetch(id: s.id) { return existing.id }
    let sameID = engine.canReviveContainer(.project, id: s.id)
    let id = sameID ? s.id : uniqueShortcode()
    // CloudKit: a delete that never went out leaves the record in place, so
    // the save is an update and needs the old change tag. Otherwise the row
    // is new to CloudKit and must carry no system fields.
    let keepSystemFields = sameID && engine.cancelPendingContainerDeletion(.project, id: s.id)
    let entity = ProjectEntity(id: id, title: s.title, statusRaw: s.statusRaw, area: s.area,
                               created: s.created, completedAt: s.completedAt, notes: s.notes,
                               context: s.context, githubRepo: s.githubRepo,
                               attachmentJSON: s.attachmentJSON, position: s.position,
                               cloudKitSystemFields: keepSystemFields ? s.cloudKitSystemFields : nil)
    context.insert(entity)
    DeletedContainerLedger.forget(.project, id)
    commitAndPush(entity, op: sameID ? "revive" : "revive(new-id)")
    return id
  }

  func rename(id: String, to title: String) async throws {
    guard let entity = fetch(id: id) else { return }
    entity.title = title
    commitAndPush(entity, op: "rename")
  }

  func setNotes(id: String, notes: String?) async throws {
    guard let entity = fetch(id: id) else { return }
    entity.notes = (notes?.isEmpty == true) ? nil : notes
    commitAndPush(entity, op: "setNotes")
  }

  func setStatus(id: String, status: ProjectStatus) async throws {
    guard let entity = fetch(id: id) else { return }
    entity.status = status
    if status == .done || status == .cancelled {
      entity.completedAt = ISO8601DateFormatter().string(from: Date())
    } else {
      entity.completedAt = nil
    }
    commitAndPush(entity, op: "setStatus(\(status.rawValue))")
  }

  func setArea(id: String, area: String?) async throws {
    guard let entity = fetch(id: id) else { return }
    entity.area = area
    commitAndPush(entity, op: "setArea")
  }

  func setGithubRepo(id: String, repo: String?) async throws {
    guard let entity = fetch(id: id) else { return }
    entity.githubRepo = (repo?.isEmpty == true) ? nil : repo
    commitAndPush(entity, op: "setGithubRepo")
  }

  func setAttachment(id: String, attachment: AreaAttachment?) async throws {
    guard let entity = fetch(id: id) else { return }
    let normalized = attachment?.normalized
    entity.attachmentJSON = normalized?.encodedString()
    // Keep the legacy `githubRepo` pointer mirrored while agentic tooling
    // still reads it: populate it for a `.git` attachment, clear it otherwise
    // so the entity-level read-fallback can't resurrect a stale repo after the
    // user switches kinds or detaches.
    entity.githubRepo = (normalized?.kind == .git) ? normalized?.ref : nil
    commitAndPush(entity, op: "setAttachment")
  }

  func delete(id: String) async throws {
    guard let entity = fetch(id: id) else { return }
    let staged = entity
    context.delete(entity)
    commitAndPush(staged, op: "delete", deletion: true)
  }

  /// Renumber the given projects to `orderedIDs` (positions 1…N) and sync. The
  /// caller passes one parent group's ids, so positions are per-group; that's
  /// fine because projects are always sorted within their group. Only changed
  /// rows push; one save + one structure-changed post. See `docs/DRAG_AND_DROP.md`.
  func reorder(orderedIDs: [String]) async throws {
    var changed: [String] = []
    for (index, id) in orderedIDs.enumerated() {
      guard let entity = fetch(id: id) else { continue }
      let newPos = index + 1
      if entity.position != newPos { entity.position = newPos; changed.append(id) }
    }
    guard !changed.isEmpty else { return }
    guard StoreHealth.save(context, op: "project.reorder") else { return }
    for id in changed { engine.noteProjectChange(id: id) }
    SeptenaLog.info("[CK] project reorder → \(changed.count) repositioned")
    NotificationCenter.default.post(name: .septenaStructureChanged, object: nil)
  }
}
