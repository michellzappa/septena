import Foundation
import SwiftData

// ProjectsBackend — mutation seam for projects, paralleling AreasBackend.
// On FastAPI side projects have per-row create/update/delete endpoints, so
// the impl is a thin pass-through. On the CloudKit side mutations are
// applied locally and the engine is notified.

@MainActor
protocol ProjectsBackend: AnyObject {
  func create(title: String, area: String?) async throws -> Project
  func rename(id: String, to title: String) async throws
  func setNotes(id: String, notes: String?) async throws
  func setStatus(id: String, status: ProjectStatus) async throws
  func setArea(id: String, area: String?) async throws
  func setGithubRepo(id: String, repo: String?) async throws
  func delete(id: String) async throws
}

// MARK: - Facade

@MainActor
@Observable
final class ProjectsMutator: ProjectsBackend {
  private let client: SeptenaClient
  private let context: ModelContext
  private var ckBackend: CloudKitProjectsBackend?
  @ObservationIgnored private let fastBackend: FastAPIProjectsBackend

  init(client: SeptenaClient, context: ModelContext) {
    self.client = client
    self.context = context
    self.fastBackend = FastAPIProjectsBackend(client: client)
  }

  func bind(ckEngine: CKEngine) {
    self.ckBackend = CloudKitProjectsBackend(engine: ckEngine, context: context)
  }

  private var current: ProjectsBackend {
    if let ck = ckBackend { return ck }
    return fastBackend
  }

  func create(title: String, area: String? = nil) async throws -> Project {
    try await current.create(title: title, area: area)
  }
  func rename(id: String, to title: String) async throws {
    try await current.rename(id: id, to: title)
  }
  func setNotes(id: String, notes: String?) async throws {
    try await current.setNotes(id: id, notes: notes)
  }
  func setStatus(id: String, status: ProjectStatus) async throws {
    try await current.setStatus(id: id, status: status)
  }
  func setArea(id: String, area: String?) async throws {
    try await current.setArea(id: id, area: area)
  }
  func setGithubRepo(id: String, repo: String?) async throws {
    try await current.setGithubRepo(id: id, repo: repo)
  }
  func delete(id: String) async throws {
    try await current.delete(id: id)
  }
}

// MARK: - FastAPI impl

@MainActor
private final class FastAPIProjectsBackend: ProjectsBackend {
  private let client: SeptenaClient
  init(client: SeptenaClient) { self.client = client }

  func create(title: String, area: String?) async throws -> Project {
    try await client.createProject(title: title, area: area)
  }
  func rename(id: String, to title: String) async throws {
    _ = try await client.updateProject(id: id, title: title)
  }
  func setNotes(id: String, notes: String?) async throws {
    _ = try await client.updateProject(id: id, notes: notes ?? "")
  }
  func setStatus(id: String, status: ProjectStatus) async throws {
    _ = try await client.updateProject(id: id, status: status.rawValue)
  }
  func setArea(id: String, area: String?) async throws {
    _ = try await client.updateProject(id: id, area: .some(area))
  }
  func setGithubRepo(id: String, repo: String?) async throws {
    let payload: String?? = .some(repo?.isEmpty == false ? repo : nil)
    _ = try await client.updateProject(id: id, githubRepo: payload)
  }
  func delete(id: String) async throws {
    try await client.deleteProject(id: id)
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

  /// Dedup a candidate slug against other live projects. See AreasBackend.
  private func uniqueSlug(for name: String, excluding ownId: String?) -> String {
    let base = IDSlug.from(name)
    let descriptor = FetchDescriptor<ProjectEntity>()
    let all = (try? context.fetch(descriptor)) ?? []
    let taken = Set(all.compactMap { $0.id == ownId ? nil : $0.slug })
    if !taken.contains(base) { return base }
    var i = 2
    while taken.contains("\(base)-\(i)") { i += 1 }
    return "\(base)-\(i)"
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
    NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
  }

  func create(title: String, area: String?) async throws -> Project {
    // Opaque shortid for stable identity; slug derived from title for
    // natural-name lookup. See IDENTIFIERS.md.
    let newId = uniqueShortcode()
    let newSlug = uniqueSlug(for: title, excluding: nil)
    let entity = ProjectEntity(id: newId, title: title, area: area,
                               slug: newSlug)
    context.insert(entity)
    commitAndPush(entity, op: "create slug=\(newSlug)")
    return Project(entity)
  }

  func rename(id: String, to title: String) async throws {
    guard let entity = fetch(id: id) else { return }
    let oldSlug = entity.slug ?? entity.id
    let newSlug = uniqueSlug(for: title, excluding: id)
    entity.title = title
    if newSlug != oldSlug {
      var history = [oldSlug] + entity.previousSlugs.filter { $0 != oldSlug }
      if history.count > 3 { history = Array(history.prefix(3)) }
      entity.previousSlugs = history
      entity.slug = newSlug
    }
    commitAndPush(entity, op: "rename slug=\(newSlug)")
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

  func delete(id: String) async throws {
    guard let entity = fetch(id: id) else { return }
    let staged = entity
    context.delete(entity)
    commitAndPush(staged, op: "delete", deletion: true)
  }
}
