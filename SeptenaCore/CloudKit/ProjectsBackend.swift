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
  /// Set once at startup so `delete` can cascade-clear the project link on
  /// referencing tasks through the task write boundary. No retain cycle —
  /// `TaskMutator` does not reference back. See `delete(id:)`.
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
  func delete(id: String) async throws {
    // Cascade: clear the project link on every task that referenced this
    // project, so they truly "lose their project link" (as the delete dialog
    // promises) instead of being left with a dangling id. A dangling id would
    // otherwise be re-stubbed by `SeptenaServices.reconcileProjectGraph()` on
    // the next launch — making the deletion reappear.
    let descriptor = FetchDescriptor<TaskEntity>(
      predicate: #Predicate { $0.project == id }
    )
    let referencing = (try? context.fetch(descriptor)) ?? []
    for task in referencing {
      taskMutator?.moveToProject(id: task.id, project: nil)
    }
    try await requireBackend().delete(id: id)
  }
  func reorder(orderedIDs: [String]) async throws {
    try await requireBackend().reorder(orderedIDs: orderedIDs)
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
    do { try context.save() } catch {
      SeptenaLog.error("CK projects: context.save failed", error)
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
    commitAndPush(entity, op: "create(explicit-id)")
    return Project(entity)
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
    do { try context.save() } catch {
      SeptenaLog.error("CK projects: reorder save failed", error)
    }
    for id in changed { engine.noteProjectChange(id: id) }
    SeptenaLog.info("[CK] project reorder → \(changed.count) repositioned")
    NotificationCenter.default.post(name: .septenaStructureChanged, object: nil)
  }
}
