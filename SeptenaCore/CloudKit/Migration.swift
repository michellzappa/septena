import Foundation
import SwiftData
import CloudKit
import OSLog

// TasksMigrator — Phase 2. The one-shot, reversible move of every local
// task from the FastAPI/Outbox path into CloudKit.
//
// Safety contract:
//   1. Migration ALWAYS writes a JSON snapshot to Application Support
//      BEFORE touching CloudKit. If anything later goes wrong, the
//      snapshot path is the recovery seed.
//   2. The `tasks.backend` flag is NOT flipped here — caller flips it
//      only after `migrateToCloudKit()` returns success. Failure leaves
//      the user on FastAPI with their data intact.
//   3. Identity is preserved: each TaskEntity's `id` becomes the CKRecord
//      `recordName`. Re-running the migration is idempotent (same ids,
//      CKSyncEngine merges via change tag).

// MARK: - Snapshot codable

/// What we serialize to disk. A flat capture of every field on TaskEntity
/// — wider than `SeptenaTask` because the snapshot is the recovery seed
/// for SwiftData, not for the wire format.
struct TaskSnapshot: Codable {
  var id: String
  var title: String
  var statusRaw: String
  var created: String?
  var scheduled: String?
  var due: String?
  var today: Bool
  var todaySetOn: String?
  var completedAt: String?
  var area: String?
  var project: String?
  var notes: String?
  var recurrenceUnit: String?
  var recurrenceInterval: Int
  var recurrenceAfterCompletion: Bool
  var updatedAt: String?
  var deletedAt: String?

  init(_ e: TaskEntity) {
    self.id = e.id
    self.title = e.title
    self.statusRaw = e.statusRaw
    self.created = e.created
    self.scheduled = e.scheduled
    self.due = e.due
    self.today = e.today
    self.todaySetOn = e.todaySetOn
    self.completedAt = e.completedAt
    self.area = e.area
    self.project = e.project
    self.notes = e.notes
    self.recurrenceUnit = e.recurrenceUnit
    self.recurrenceInterval = e.recurrenceInterval
    self.recurrenceAfterCompletion = e.recurrenceAfterCompletion
    self.updatedAt = e.updatedAt
    self.deletedAt = e.deletedAt
  }
}

struct AreaSnapshot: Codable {
  var id: String
  var title: String
  var context: String?
  var updatedAt: String?

  init(_ e: AreaEntity) {
    self.id = e.id
    self.title = e.title
    self.context = e.context
    self.updatedAt = e.updatedAt
  }
}

struct ProjectSnapshot: Codable {
  var id: String
  var title: String
  var statusRaw: String
  var area: String?
  var created: String?
  var completedAt: String?
  var notes: String?
  var context: String?
  var githubRepo: String?
  var updatedAt: String?
  var deletedAt: String?

  init(_ e: ProjectEntity) {
    self.id = e.id
    self.title = e.title
    self.statusRaw = e.statusRaw
    self.area = e.area
    self.created = e.created
    self.completedAt = e.completedAt
    self.notes = e.notes
    self.context = e.context
    self.githubRepo = e.githubRepo
    self.updatedAt = e.updatedAt
    self.deletedAt = e.deletedAt
  }
}

struct TasksSnapshotFile: Codable {
  /// 1 = tasks only (legacy). 2 = tasks + areas + projects.
  var schemaVersion: Int
  var createdAt: Date
  var sourceBackend: String   // "fastAPI" at the moment of snapshot
  var tasks: [TaskSnapshot]
  /// v2+. Decoded as empty when reading a v1 snapshot.
  var areas: [AreaSnapshot]?
  var projects: [ProjectSnapshot]?
}

// MARK: - Errors

enum MigrationError: LocalizedError {
  case noEntities
  case engineSendFailed(underlying: Error)
  case engineFetchFailed(underlying: Error)
  case countMismatch(local: Int, afterPull: Int)

  var errorDescription: String? {
    switch self {
    case .noEntities:
      return "Nothing to migrate — local task store is empty."
    case .engineSendFailed(let e):
      return "Failed to send local tasks to CloudKit: \(e.localizedDescription)"
    case .engineFetchFailed(let e):
      return "Failed to read CloudKit state back for verification: \(e.localizedDescription)"
    case .countMismatch(let local, let after):
      return "Verification failed: had \(local) local tasks, only \(after) after sync. CloudKit flag NOT flipped — your data is unchanged."
    }
  }
}

// MARK: - Migrator

@MainActor
final class TasksMigrator {
  private let logger = Logger(subsystem: "com.septena.cloud", category: "TasksMigrator")
  private let context: ModelContext
  private let engine: CKEngine
  /// Optional — when present, the migrator hydrates local Area/Project
  /// entities from FastAPI before pushing them to CloudKit. Skipped when
  /// nil (used by tests / dry-run flows).
  private let client: SeptenaClient?

  init(context: ModelContext, engine: CKEngine, client: SeptenaClient? = nil) {
    self.context = context
    self.engine = engine
    self.client = client
  }

  // MARK: Snapshot file location

  /// Standard location for snapshots. Application Support survives app
  /// updates but is wiped on uninstall, which matches "this is a backup
  /// of THIS install's tasks, not user-cloud data." Files visible in
  /// Files.app on iOS via the per-app Documents path are reserved for
  /// Phase 3 "Export to anywhere" UX.
  static func snapshotsDirectory() throws -> URL {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true
    )
    let dir = base.appendingPathComponent("TaskSnapshots", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  // MARK: Export (snapshot)

  /// Write every local TaskEntity, AreaEntity, and ProjectEntity to a
  /// JSON file (schema v2). Returns the URL.
  @discardableResult
  func exportToJSON(reason: String = "manual") throws -> URL {
    let tasks = try context.fetch(FetchDescriptor<TaskEntity>())
    let areas = try context.fetch(FetchDescriptor<AreaEntity>())
    let projects = try context.fetch(FetchDescriptor<ProjectEntity>())
    let snapshot = TasksSnapshotFile(
      schemaVersion: 2,
      createdAt: Date(),
      sourceBackend: TasksBackendDefaults.current.rawValue,
      tasks: tasks.map(TaskSnapshot.init),
      areas: areas.map(AreaSnapshot.init),
      projects: projects.map(ProjectSnapshot.init)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(snapshot)
    let ts = ISO8601DateFormatter().string(from: Date())
      .replacingOccurrences(of: ":", with: "-")
    let url = try Self.snapshotsDirectory()
      .appendingPathComponent("tasks-\(reason)-\(ts).json")
    try data.write(to: url, options: .atomic)
    logger.info("Exported \(tasks.count, privacy: .public) tasks, \(areas.count, privacy: .public) areas, \(projects.count, privacy: .public) projects → \(url.lastPathComponent, privacy: .public)")
    return url
  }

  // MARK: Import (restore)

  /// Apply a snapshot back into SwiftData. Existing rows with matching
  /// `id` are overwritten field-by-field (preserves any system fields
  /// already captured); rows in the snapshot but missing locally are
  /// inserted. Rows that exist locally but aren't in the snapshot are
  /// left alone — this is "restore from backup," not "wipe and replace."
  func importFromJSON(url: URL) throws -> Int {
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let file = try decoder.decode(TasksSnapshotFile.self, from: data)
    for s in file.tasks {
      let descriptor = FetchDescriptor<TaskEntity>(
        predicate: #Predicate { $0.id == s.id }
      )
      let entity = (try? context.fetch(descriptor).first)
        ?? TaskEntity(id: s.id, title: s.title)
      entity.title = s.title
      entity.statusRaw = s.statusRaw
      entity.created = s.created
      entity.scheduled = s.scheduled
      entity.due = s.due
      entity.today = s.today
      entity.todaySetOn = s.todaySetOn
      entity.completedAt = s.completedAt
      entity.area = s.area
      entity.project = s.project
      entity.notes = s.notes
      entity.recurrenceUnit = s.recurrenceUnit
      entity.recurrenceInterval = s.recurrenceInterval
      entity.recurrenceAfterCompletion = s.recurrenceAfterCompletion
      entity.updatedAt = s.updatedAt
      entity.deletedAt = s.deletedAt
      if entity.modelContext == nil {
        context.insert(entity)
      }
    }
    // v2 also carries areas + projects. Older v1 snapshots leave both
    // nil, so the loops are a no-op for those.
    for s in file.areas ?? [] {
      let id = s.id
      let descriptor = FetchDescriptor<AreaEntity>(
        predicate: #Predicate { $0.id == id }
      )
      let entity = (try? context.fetch(descriptor).first)
        ?? AreaEntity(id: id, title: s.title)
      entity.title = s.title
      entity.context = s.context
      entity.updatedAt = s.updatedAt
      if entity.modelContext == nil { context.insert(entity) }
    }
    for s in file.projects ?? [] {
      let id = s.id
      let descriptor = FetchDescriptor<ProjectEntity>(
        predicate: #Predicate { $0.id == id }
      )
      let entity = (try? context.fetch(descriptor).first)
        ?? ProjectEntity(id: id, title: s.title)
      entity.title = s.title
      entity.statusRaw = s.statusRaw
      entity.area = s.area
      entity.created = s.created
      entity.completedAt = s.completedAt
      entity.notes = s.notes
      entity.context = s.context
      entity.githubRepo = s.githubRepo
      entity.updatedAt = s.updatedAt
      entity.deletedAt = s.deletedAt
      if entity.modelContext == nil { context.insert(entity) }
    }
    try context.save()
    NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    let areaCount = file.areas?.count ?? 0
    let projectCount = file.projects?.count ?? 0
    logger.info("Imported \(file.tasks.count, privacy: .public) tasks, \(areaCount, privacy: .public) areas, \(projectCount, privacy: .public) projects from \(url.lastPathComponent, privacy: .public)")
    return file.tasks.count + areaCount + projectCount
  }

  // MARK: Migrate to CloudKit

  /// Push every local task, area, and project into CloudKit, wait for the
  /// engine to drain, and verify the count round-trips. Throws on failure
  /// WITHOUT flipping the backend flag — caller flips on success.
  func migrateToCloudKit() async throws -> MigrationResult {
    // 0. Pull canonical areas + projects from FastAPI into SwiftData if
    //    they aren't already mirrored. Tasks are kept in sync by `Syncer`
    //    in normal operation, but the bulk areas endpoint and per-row
    //    project records don't always land in the cache before the user
    //    hits Migrate. Without this, an empty AreaEntity table would
    //    push nothing to CloudKit and any task.area links would dangle
    //    once the cutover lands.
    if let client {
      do {
        let areas = try await client.areas()
        let projects = try await client.projects()
        seedAreaProjectMirror(areas: areas, projects: projects)
      } catch {
        // Non-fatal: if the network is unreachable we proceed with
        // whatever's locally cached. A subsequent migration retry will
        // reconcile when the server is reachable.
        logger.error("Pre-migration areas/projects pull failed: \(error.localizedDescription, privacy: .public)")
      }
    }

    // 1. Safety snapshot first. If anything below blows up, the user
    //    still has a JSON they can re-import.
    let snapshotURL = try exportToJSON(reason: "pre-migration")

    // 2. Pull every live (non-tombstoned, non-pendingDeletion) task,
    //    plus every area and project.
    let taskDescriptor = FetchDescriptor<TaskEntity>(
      predicate: #Predicate { $0.pendingDeletion == false && $0.deletedAt == nil }
    )
    let tasks = try context.fetch(taskDescriptor)
    let areas = try context.fetch(FetchDescriptor<AreaEntity>())
    let projectDescriptor = FetchDescriptor<ProjectEntity>(
      predicate: #Predicate { $0.deletedAt == nil }
    )
    let projects = try context.fetch(projectDescriptor)
    guard !tasks.isEmpty || !areas.isEmpty || !projects.isEmpty else {
      throw MigrationError.noEntities
    }

    // 3. Engine must be running.
    engine.start()

    // 4. Mark every record for save and drain.
    for entity in tasks { engine.noteTaskChange(id: entity.id) }
    for entity in areas { engine.noteAreaChange(id: entity.id) }
    for entity in projects { engine.noteProjectChange(id: entity.id) }
    do {
      try await engine.sendChanges()
    } catch {
      logger.error("sendChanges failed: \(error.localizedDescription, privacy: .public)")
      throw MigrationError.engineSendFailed(underlying: error)
    }

    // 5. Pull back to confirm. The fetched-record closures fold incoming
    //    records into SwiftData and capture system fields for future
    //    saves.
    do {
      try await engine.fetchChanges()
    } catch {
      logger.error("fetchChanges failed: \(error.localizedDescription, privacy: .public)")
      throw MigrationError.engineFetchFailed(underlying: error)
    }

    // 6. Verify counts haven't dropped.
    let afterTasks = try context.fetch(taskDescriptor)
    let afterAreas = try context.fetch(FetchDescriptor<AreaEntity>())
    let afterProjects = try context.fetch(projectDescriptor)
    let before = tasks.count + areas.count + projects.count
    let after = afterTasks.count + afterAreas.count + afterProjects.count
    guard after >= before else {
      throw MigrationError.countMismatch(local: before, afterPull: after)
    }

    logger.info("Migration verified: \(tasks.count, privacy: .public) tasks, \(areas.count, privacy: .public) areas, \(projects.count, privacy: .public) projects now in CloudKit")
    return MigrationResult(
      snapshotURL: snapshotURL,
      migratedCount: before,
      verifiedCount: after,
      tasksCount: tasks.count,
      areasCount: areas.count,
      projectsCount: projects.count
    )
  }

  /// Insert-or-update local AreaEntity / ProjectEntity rows from the
  /// FastAPI snapshot. Keeps existing `cloudKitSystemFields` intact (any
  /// row that's already round-tripped through CK stays linked to its
  /// server record). Called from `migrateToCloudKit` so the migration
  /// always starts with a fresh mirror.
  private func seedAreaProjectMirror(areas: [Area], projects: [Project]) {
    let now = Date()
    for dto in areas {
      let id = dto.id
      let descriptor = FetchDescriptor<AreaEntity>(
        predicate: #Predicate { $0.id == id }
      )
      let entity = (try? context.fetch(descriptor).first)
        ?? AreaEntity(id: id, title: dto.title)
      entity.title = dto.title
      entity.context = dto.context
      entity.updatedAt = dto.updatedAt
      entity.lastSyncedAt = now
      if entity.modelContext == nil { context.insert(entity) }
    }
    for dto in projects {
      let id = dto.id
      let descriptor = FetchDescriptor<ProjectEntity>(
        predicate: #Predicate { $0.id == id }
      )
      let entity = (try? context.fetch(descriptor).first)
        ?? ProjectEntity(id: id, title: dto.title)
      entity.title = dto.title
      entity.statusRaw = dto.status.rawValue
      entity.area = dto.area
      entity.created = dto.created
      entity.completedAt = dto.completedAt
      entity.notes = dto.notes
      entity.context = dto.context
      entity.githubRepo = dto.githubRepo
      entity.updatedAt = dto.updatedAt
      entity.deletedAt = dto.deletedAt
      entity.lastSyncedAt = now
      if entity.modelContext == nil { context.insert(entity) }
    }
    try? context.save()
  }
}

struct MigrationResult {
  let snapshotURL: URL
  let migratedCount: Int
  let verifiedCount: Int
  let tasksCount: Int
  let areasCount: Int
  let projectsCount: Int
}
