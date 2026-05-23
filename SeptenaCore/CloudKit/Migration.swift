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
//   2. Identity is preserved: each TaskEntity's `id` becomes the CKRecord
//      `recordName`. Re-running is idempotent (same ids, CKSyncEngine
//      merges via change tag). This is now mostly a recovery/re-sync tool;
//      the original FastAPI→CK migration has already shipped.

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

struct SettingsSnapshot: Codable {
  var id: String
  var payloadJSON: String

  init?(_ e: SettingsEntity) {
    guard let json = String(data: e.payloadData, encoding: .utf8) else { return nil }
    self.id = e.id
    self.payloadJSON = json
  }
}

struct SectionSnapshot: Codable {
  var id: String
  var title: String
  var color: String

  init(_ e: SectionEntity) {
    self.id = e.id
    self.title = e.title
    self.color = e.color
  }
}

struct TasksSnapshotFile: Codable {
  /// 1 = tasks only (legacy). 2 = tasks + areas + projects.
  /// 3 = tasks + areas + projects + settings + sections.
  var schemaVersion: Int
  var createdAt: Date
  var sourceBackend: String   // "fastAPI" at the moment of snapshot
  var tasks: [TaskSnapshot]
  /// v2+. Decoded as empty when reading a v1 snapshot.
  var areas: [AreaSnapshot]?
  var projects: [ProjectSnapshot]?
  /// v3+.
  var settings: SettingsSnapshot?
  var sections: [SectionSnapshot]?
}

// MARK: - Errors

enum MigrationError: LocalizedError {
  case noEntities
  case engineSendFailed(underlying: Error, details: String?)
  case engineFetchFailed(underlying: Error)
  case countMismatch(local: Int, afterPull: Int)
  case repairFetchFailed(underlying: Error)

  var errorDescription: String? {
    switch self {
    case .noEntities:
      return "Nothing to migrate — local task store is empty."
    case .engineSendFailed(let e, let details):
      let base = "Failed to send local tasks to CloudKit: \(e.localizedDescription)"
      if let details, !details.isEmpty {
        return "\(base)\n\(details)"
      }
      return base
    case .engineFetchFailed(let e):
      return "Failed to read CloudKit state back for verification: \(e.localizedDescription)"
    case .countMismatch(let local, let after):
      return "Verification failed: had \(local) local tasks, only \(after) after sync. CloudKit flag NOT flipped — your data is unchanged."
    case .repairFetchFailed(let e):
      return "Failed to query all CloudKit records for repair: \(e.localizedDescription)"
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
    let settings = try context.fetch(FetchDescriptor<SettingsEntity>()).first
    let sections = try context.fetch(FetchDescriptor<SectionEntity>())
    let snapshot = TasksSnapshotFile(
      schemaVersion: 3,
      createdAt: Date(),
      sourceBackend: "cloudKit",
      tasks: tasks.map(TaskSnapshot.init),
      areas: areas.map(AreaSnapshot.init),
      projects: projects.map(ProjectSnapshot.init),
      settings: settings.flatMap(SettingsSnapshot.init),
      sections: sections.map(SectionSnapshot.init)
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
    logger.info("Exported \(tasks.count, privacy: .public) tasks, \(areas.count, privacy: .public) areas, \(projects.count, privacy: .public) projects, settings=\(settings != nil, privacy: .public), \(sections.count, privacy: .public) sections → \(url.lastPathComponent, privacy: .public)")
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
    if let s = file.settings,
       let data = s.payloadJSON.data(using: .utf8) {
      let singletonID = s.id
      let descriptor = FetchDescriptor<SettingsEntity>(
        predicate: #Predicate { $0.id == singletonID }
      )
      let entity = (try? context.fetch(descriptor).first)
        ?? SettingsEntity(id: singletonID, payloadData: data)
      entity.payloadData = data
      entity.updatedAt = .now
      if entity.modelContext == nil { context.insert(entity) }
    }
    for s in file.sections ?? [] {
      let id = s.id
      let descriptor = FetchDescriptor<SectionEntity>(
        predicate: #Predicate { $0.id == id }
      )
      let entity = (try? context.fetch(descriptor).first)
        ?? SectionEntity(id: id, title: s.title, color: s.color)
      entity.title = s.title
      entity.color = s.color
      entity.updatedAt = .now
      if entity.modelContext == nil { context.insert(entity) }
    }
    try context.save()
    NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    let areaCount = file.areas?.count ?? 0
    let projectCount = file.projects?.count ?? 0
    let sectionCount = file.sections?.count ?? 0
    let settingsCount = file.settings == nil ? 0 : 1
    logger.info("Imported \(file.tasks.count, privacy: .public) tasks, \(areaCount, privacy: .public) areas, \(projectCount, privacy: .public) projects, \(settingsCount, privacy: .public) settings, \(sectionCount, privacy: .public) sections from \(url.lastPathComponent, privacy: .public)")
    return file.tasks.count + areaCount + projectCount + settingsCount + sectionCount
  }

  // MARK: Repair merge

  /// Merge the full CloudKit zone into the local SwiftData mirror, then
  /// push the resulting local union back to CloudKit.
  ///
  /// This is intentionally non-destructive: it does not delete local-only
  /// rows that are absent from CloudKit, because during the cutover those
  /// rows may be the user's only copy. If two devices contain the same
  /// human task under different ids, this can preserve both and create
  /// duplicates. That is preferable for emergency repair because duplicate
  /// cleanup is recoverable; data loss is not.
  func repairMergeWithCloudKit() async throws -> RepairSyncResult {
    let snapshotURL = try exportToJSON(reason: "pre-repair")

    engine.start()

    do {
      try await engine.sendChanges()
      try await engine.fetchChanges()
    } catch {
      logger.error("pre-repair engine drain failed: \(error.localizedDescription, privacy: .public)")
      throw MigrationError.engineFetchFailed(underlying: error)
    }

    let cloudRecords: [CKRecord]
    do {
      cloudRecords = try await engine.fetchAllRecords(recordTypes: [
        TaskCloudKitSchema.recordType,
        AreaCloudKitSchema.recordType,
        ProjectCloudKitSchema.recordType,
        SettingsCloudKitSchema.recordType,
        SectionCloudKitSchema.recordType,
      ])
    } catch {
      logger.error("repair full-zone query failed: \(error.localizedDescription, privacy: .public)")
      throw MigrationError.repairFetchFailed(underlying: error)
    }

    var cloudTasks = 0
    var cloudAreas = 0
    var cloudProjects = 0
    var cloudSettings = 0
    var cloudSections = 0
    for record in cloudRecords {
      switch record.recordType {
      case TaskCloudKitSchema.recordType:
        cloudTasks += 1
        applyTask(record)
      case AreaCloudKitSchema.recordType:
        cloudAreas += 1
        applyArea(record)
      case ProjectCloudKitSchema.recordType:
        cloudProjects += 1
        applyProject(record)
      case SettingsCloudKitSchema.recordType:
        cloudSettings += 1
        applySettings(record)
      case SectionCloudKitSchema.recordType:
        cloudSections += 1
        applySection(record)
      default:
        logger.info("Repair ignored unknown CK record type \(record.recordType, privacy: .public)")
      }
    }
    try context.save()

    let taskDescriptor = FetchDescriptor<TaskEntity>(
      predicate: #Predicate { $0.pendingDeletion == false && $0.deletedAt == nil }
    )
    let tasks = try context.fetch(taskDescriptor)
    let areas = try context.fetch(FetchDescriptor<AreaEntity>())
    let settings = try context.fetch(FetchDescriptor<SettingsEntity>())
    let sections = try context.fetch(FetchDescriptor<SectionEntity>())
    let projectDescriptor = FetchDescriptor<ProjectEntity>(
      predicate: #Predicate { $0.deletedAt == nil }
    )
    let projects = try context.fetch(projectDescriptor)

    for entity in tasks { engine.noteTaskChange(id: entity.id) }
    for entity in areas { engine.noteAreaChange(id: entity.id) }
    for entity in projects { engine.noteProjectChange(id: entity.id) }
    for _ in settings { engine.noteSettingsChange() }
    for entity in sections { engine.noteSectionChange(id: entity.id) }

    do {
      try await engine.sendChanges()
      try await engine.fetchChanges()
    } catch {
      logger.error("repair send/fetch failed: \(error.localizedDescription, privacy: .public)")
      throw MigrationError.engineSendFailed(
        underlying: error,
        details: engine.consumeLastSendFailureSummary()
      )
    }

    NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    let localTotal = tasks.count + areas.count + projects.count + settings.count + sections.count
    logger.info("Repair merged cloud Task/Area/Project/Settings/Section \(cloudTasks, privacy: .public)/\(cloudAreas, privacy: .public)/\(cloudProjects, privacy: .public)/\(cloudSettings, privacy: .public)/\(cloudSections, privacy: .public); pushed local total \(localTotal, privacy: .public)")

    return RepairSyncResult(
      snapshotURL: snapshotURL,
      cloudTasksCount: cloudTasks,
      cloudAreasCount: cloudAreas,
      cloudProjectsCount: cloudProjects,
      localTasksCount: tasks.count,
      localAreasCount: areas.count,
      localProjectsCount: projects.count
    )
  }

  /// Replace this device's local SwiftData mirror with the current live
  /// records in CloudKit. This is the "one device is canonical" repair:
  /// it snapshots first, discards local CKSyncEngine state so stale
  /// pending changes cannot replay, deletes local Task/Area/Project rows,
  /// then applies the full CloudKit zone.
  func replaceLocalMirrorFromCloudKit() async throws -> ReplaceLocalMirrorResult {
    let snapshotURL = try exportToJSON(reason: "pre-replace-local")

    engine.discardLocalSyncState()

    let cloudRecords: [CKRecord]
    do {
      cloudRecords = try await engine.fetchAllRecords(recordTypes: [
        TaskCloudKitSchema.recordType,
        AreaCloudKitSchema.recordType,
        ProjectCloudKitSchema.recordType,
        SettingsCloudKitSchema.recordType,
        SectionCloudKitSchema.recordType,
      ])
    } catch {
      logger.error("replace-local full-zone query failed: \(error.localizedDescription, privacy: .public)")
      throw MigrationError.repairFetchFailed(underlying: error)
    }

    let existingTasks = try context.fetch(FetchDescriptor<TaskEntity>())
    let existingAreas = try context.fetch(FetchDescriptor<AreaEntity>())
    let existingProjects = try context.fetch(FetchDescriptor<ProjectEntity>())
    let existingSettings = try context.fetch(FetchDescriptor<SettingsEntity>())
    let existingSections = try context.fetch(FetchDescriptor<SectionEntity>())
    let deletedTasks = existingTasks.count
    let deletedAreas = existingAreas.count
    let deletedProjects = existingProjects.count
    let deletedSettings = existingSettings.count
    let deletedSections = existingSections.count

    for entity in existingTasks { context.delete(entity) }
    for entity in existingAreas { context.delete(entity) }
    for entity in existingProjects { context.delete(entity) }
    for entity in existingSettings { context.delete(entity) }
    for entity in existingSections { context.delete(entity) }
    try context.save()

    var cloudTasks = 0
    var cloudAreas = 0
    var cloudProjects = 0
    var cloudSettings = 0
    var cloudSections = 0
    for record in cloudRecords {
      switch record.recordType {
      case AreaCloudKitSchema.recordType:
        cloudAreas += 1
        applyArea(record)
      case ProjectCloudKitSchema.recordType:
        cloudProjects += 1
        applyProject(record)
      case TaskCloudKitSchema.recordType:
        cloudTasks += 1
        applyTask(record)
      case SettingsCloudKitSchema.recordType:
        cloudSettings += 1
        applySettings(record)
      case SectionCloudKitSchema.recordType:
        cloudSections += 1
        applySection(record)
      default:
        logger.info("Replace-local ignored unknown CK record type \(record.recordType, privacy: .public)")
      }
    }
    try context.save()

    engine.start()
    do {
      try await engine.sendChanges()
      try await engine.fetchChanges()
    } catch {
      logger.error("replace-local post-fetch failed: \(error.localizedDescription, privacy: .public)")
      throw MigrationError.engineFetchFailed(underlying: error)
    }

    NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    logger.info("Replaced local mirror from CloudKit. Deleted Task/Area/Project/Settings/Section \(deletedTasks, privacy: .public)/\(deletedAreas, privacy: .public)/\(deletedProjects, privacy: .public)/\(deletedSettings, privacy: .public)/\(deletedSections, privacy: .public); loaded \(cloudTasks, privacy: .public)/\(cloudAreas, privacy: .public)/\(cloudProjects, privacy: .public)/\(cloudSettings, privacy: .public)/\(cloudSections, privacy: .public)")

    return ReplaceLocalMirrorResult(
      snapshotURL: snapshotURL,
      deletedTasksCount: deletedTasks,
      deletedAreasCount: deletedAreas,
      deletedProjectsCount: deletedProjects,
      cloudTasksCount: cloudTasks,
      cloudAreasCount: cloudAreas,
      cloudProjectsCount: cloudProjects
    )
  }

  private func applyTask(_ record: CKRecord) {
    let id = record.recordID.recordName
    let descriptor = FetchDescriptor<TaskEntity>(
      predicate: #Predicate { $0.id == id }
    )
    if let entity = try? context.fetch(descriptor).first {
      entity.apply(record)
    } else {
      context.insert(TaskEntity(cloudKit: record))
    }
  }

  private func applyArea(_ record: CKRecord) {
    let id = AreaCloudKitSchema.entityID(from: record.recordID.recordName)
    let descriptor = FetchDescriptor<AreaEntity>(
      predicate: #Predicate { $0.id == id }
    )
    if let entity = try? context.fetch(descriptor).first {
      entity.apply(record)
    } else {
      context.insert(AreaEntity(cloudKit: record))
    }
  }

  private func applyProject(_ record: CKRecord) {
    let id = ProjectCloudKitSchema.entityID(from: record.recordID.recordName)
    let descriptor = FetchDescriptor<ProjectEntity>(
      predicate: #Predicate { $0.id == id }
    )
    if let entity = try? context.fetch(descriptor).first {
      entity.apply(record)
    } else {
      context.insert(ProjectEntity(cloudKit: record))
    }
  }

  private func applySettings(_ record: CKRecord) {
    let singletonID = SettingsCloudKitSchema.singletonID
    let descriptor = FetchDescriptor<SettingsEntity>(
      predicate: #Predicate { $0.id == singletonID }
    )
    if let entity = try? context.fetch(descriptor).first {
      entity.apply(record)
    } else {
      context.insert(SettingsEntity(cloudKit: record))
    }
  }

  private func applySection(_ record: CKRecord) {
    let id = SectionCloudKitSchema.entityID(from: record.recordID.recordName)
    let descriptor = FetchDescriptor<SectionEntity>(
      predicate: #Predicate { $0.id == id }
    )
    if let entity = try? context.fetch(descriptor).first {
      entity.apply(record)
    } else {
      context.insert(SectionEntity(cloudKit: record))
    }
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
        let settings = try await client.settings()
        let sections = try await client.sections()
        seedAreaProjectMirror(areas: areas, projects: projects)
        SettingsMirror.upsert(settings: settings, context: context)
        SettingsMirror.replaceSections(sections, context: context)
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
    let settings = try context.fetch(FetchDescriptor<SettingsEntity>())
    let sections = try context.fetch(FetchDescriptor<SectionEntity>())
    let projectDescriptor = FetchDescriptor<ProjectEntity>(
      predicate: #Predicate { $0.deletedAt == nil }
    )
    let projects = try context.fetch(projectDescriptor)
    guard !tasks.isEmpty || !areas.isEmpty || !projects.isEmpty || !settings.isEmpty || !sections.isEmpty else {
      throw MigrationError.noEntities
    }

    // 3. Engine must be running.
    engine.start()

    // 4. Mark every record for save and drain.
    for entity in tasks { engine.noteTaskChange(id: entity.id) }
    for entity in areas { engine.noteAreaChange(id: entity.id) }
    for entity in projects { engine.noteProjectChange(id: entity.id) }
    for _ in settings { engine.noteSettingsChange() }
    for entity in sections { engine.noteSectionChange(id: entity.id) }
    do {
      try await engine.sendChanges()
    } catch {
      logger.error("sendChanges failed: \(error.localizedDescription, privacy: .public)")
      throw MigrationError.engineSendFailed(
        underlying: error,
        details: engine.consumeLastSendFailureSummary()
      )
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
    let afterSettings = try context.fetch(FetchDescriptor<SettingsEntity>())
    let afterSections = try context.fetch(FetchDescriptor<SectionEntity>())
    let afterProjects = try context.fetch(projectDescriptor)
    let before = tasks.count + areas.count + projects.count + settings.count + sections.count
    let after = afterTasks.count + afterAreas.count + afterProjects.count + afterSettings.count + afterSections.count
    guard after >= before else {
      throw MigrationError.countMismatch(local: before, afterPull: after)
    }

    logger.info("Migration verified: \(tasks.count, privacy: .public) tasks, \(areas.count, privacy: .public) areas, \(projects.count, privacy: .public) projects, \(settings.count, privacy: .public) settings, \(sections.count, privacy: .public) sections now in CloudKit")
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

struct RepairSyncResult {
  let snapshotURL: URL
  let cloudTasksCount: Int
  let cloudAreasCount: Int
  let cloudProjectsCount: Int
  let localTasksCount: Int
  let localAreasCount: Int
  let localProjectsCount: Int
}

struct ReplaceLocalMirrorResult {
  let snapshotURL: URL
  let deletedTasksCount: Int
  let deletedAreasCount: Int
  let deletedProjectsCount: Int
  let cloudTasksCount: Int
  let cloudAreasCount: Int
  let cloudProjectsCount: Int
}

@MainActor
final class ChecklistCloudKitBootstrapper {
  private let context: ModelContext
  private let engine: CKEngine
  private let client: SeptenaClient

  init(context: ModelContext, engine: CKEngine, client: SeptenaClient) {
    self.context = context
    self.engine = engine
    self.client = client
  }

  // Per-install completion flags. The original `cloudKitSystemFields ==
  // nil` heuristic was fragile: as soon as the user toggled a single
  // habit/supplement/chore the corresponding record got CK system fields
  // stamped, after which the bootstrap permanently believed there was
  // nothing left to import — even though years of FastAPI history had
  // never been touched. UserDefaults gives us an unambiguous "this domain
  // has imported its FastAPI history" record that survives across launches
  // and isn't perturbed by ordinary mutations.
  private enum BootstrapKey {
    static let habits      = "septena.bootstrap.habits.v1"
    static let supplements = "septena.bootstrap.supplements.v1"
    static let chores      = "septena.bootstrap.chores.v1"
    static let goals       = "septena.bootstrap.goals.v1"
    static let gut         = "septena.bootstrap.gut.v1"
    static let caffeine    = "septena.bootstrap.caffeine.v1"
    static let cannabis    = "septena.bootstrap.cannabis.v1"
    static let groceries   = "septena.bootstrap.groceries.v1"
  }

  /// First-run bridge for habits/supplements/chores. Seeds the local
  /// canonical mirror from FastAPI range endpoints only when this domain
  /// has not yet been imported on this install. Idempotent — re-running
  /// after success is a no-op.
  func bootstrapIfNeeded(historyDays: Int = 30) async throws {
    try await bootstrap(historyDays: historyDays, force: false)
  }

  /// Manual "import history from FastAPI again" path for the Settings
  /// recovery button. Ignores the completion flags and re-pulls from the
  /// server, then queues everything for CloudKit upload. Use when:
  ///   - Bootstrap silently no-op'd because the old `cloudKitSystemFields`
  ///     heuristic was already poisoned by a single CK round-trip
  ///   - The user wants to re-sync from the source of truth after a wipe
  func forceBootstrap(historyDays: Int = 30) async throws {
    try await bootstrap(historyDays: historyDays, force: true)
  }

  private func bootstrap(historyDays: Int, force: Bool) async throws {
    var importedAny = false
    let defaults = UserDefaults.standard

    if force || !defaults.bool(forKey: BootstrapKey.habits) {
      if let habits = try? await client.habitsRange(days: historyDays) {
        ChecklistMirror.replaceAllHabitsHistory(habits, context: context)
        queueHabitMirrorForUpload()
        defaults.set(true, forKey: BootstrapKey.habits)
        importedAny = true
        SeptenaLog.info("[Bootstrap] habits imported: \(habits.days.count) days")
      }
    }

    if force || !defaults.bool(forKey: BootstrapKey.supplements) {
      if let supplements = try? await client.supplementsRange(days: historyDays) {
        ChecklistMirror.replaceAllSupplementsHistory(supplements, context: context)
        queueSupplementMirrorForUpload()
        defaults.set(true, forKey: BootstrapKey.supplements)
        importedAny = true
        SeptenaLog.info("[Bootstrap] supplements imported: \(supplements.days.count) days")
      }
    }

    if force || !defaults.bool(forKey: BootstrapKey.chores) {
      if let chores = try? await client.choresExport(days: historyDays) {
        ChecklistMirror.replaceAllChoresExport(chores, context: context)
        queueChoreMirrorForUpload()
        defaults.set(true, forKey: BootstrapKey.chores)
        importedAny = true
        SeptenaLog.info("[Bootstrap] chores imported: defs=\(chores.definitions.count) events=\(chores.events.count)")
      }
    }

    if force || !defaults.bool(forKey: BootstrapKey.goals) {
      if let goals = try? await client.goals() {
        importGoals(goals)
        queueGoalsForUpload()
        defaults.set(true, forKey: BootstrapKey.goals)
        importedAny = true
        SeptenaLog.info("[Bootstrap] goals imported: \(goals.count)")
      }
    }

    // Gut/caffeine/cannabis are event-log sections; FastAPI exports return
    // every record on disk (no days-window). User wants the complete history
    // imported — we trust the server export to contain only real data.
    if force || !defaults.bool(forKey: BootstrapKey.gut) {
      if let gut = try? await client.gutExport() {
        ChecklistMirror.replaceAllGutEntries(gut, context: context)
        queueGutMirrorForUpload()
        defaults.set(true, forKey: BootstrapKey.gut)
        importedAny = true
        SeptenaLog.info("[Bootstrap] gut imported: \(gut.entries.count) entries")
      }
    }

    if force || !defaults.bool(forKey: BootstrapKey.caffeine) {
      if let caffeine = try? await client.caffeineExport() {
        ChecklistMirror.replaceAllCaffeineExport(caffeine, context: context)
        queueCaffeineMirrorForUpload()
        defaults.set(true, forKey: BootstrapKey.caffeine)
        importedAny = true
        SeptenaLog.info("[Bootstrap] caffeine imported: entries=\(caffeine.entries.count) beans=\(caffeine.beans.count)")
      }
    }

    if force || !defaults.bool(forKey: BootstrapKey.cannabis) {
      if let cannabis = try? await client.cannabisExport() {
        ChecklistMirror.replaceAllCannabisExport(cannabis, context: context)
        queueCannabisMirrorForUpload()
        defaults.set(true, forKey: BootstrapKey.cannabis)
        importedAny = true
        SeptenaLog.info("[Bootstrap] cannabis imported: entries=\(cannabis.entries.count) strains=\(cannabis.strains.count)")
      }
    }

    // Groceries is a snapshot section — no history, just the current
    // pantry + category list. /api/groceries already returns both in one
    // call, so no /export endpoint is needed.
    if force || !defaults.bool(forKey: BootstrapKey.groceries) {
      if let groceries = try? await client.groceriesFull() {
        let categories = groceries.categories.isEmpty ? DEFAULT_GROCERY_CATEGORIES : groceries.categories
        ChecklistMirror.replaceAllGroceries(items: groceries.items,
                                            categories: categories,
                                            context: context)
        queueGroceryMirrorForUpload()
        defaults.set(true, forKey: BootstrapKey.groceries)
        importedAny = true
        SeptenaLog.info("[Bootstrap] groceries imported: items=\(groceries.items.count) cats=\(categories.count)")
      }
    }

    guard importedAny else { return }
    try? context.save()
    // sendChanges / fetchChanges can throw transient CloudKit errors
    // (CAS Op-Lock conflicts, zoneBusy, network blips). The engine has
    // already accepted the pending changes into its persistent state —
    // they'll drain on the next opportunity regardless of whether this
    // synchronous push succeeds. We `try?` so a transient failure during
    // the explicit flush doesn't bubble up as a user-visible bootstrap
    // error when the local import itself was successful.
    do {
      try await engine.sendChanges()
    } catch {
      SeptenaLog.info("[Bootstrap] sendChanges deferred: \(error.localizedDescription)")
    }
    do {
      try await engine.fetchChanges()
    } catch {
      SeptenaLog.info("[Bootstrap] fetchChanges deferred: \(error.localizedDescription)")
    }
  }

  private func importGoals(_ goals: [Goal]) {
    let existing = (try? context.fetch(FetchDescriptor<GoalEntity>())) ?? []
    let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
    var seenIDs = Set<String>()
    for (index, goal) in goals.enumerated() {
      seenIDs.insert(goal.id)
      let entity = existingByID[goal.id] ?? GoalEntity(
        id: goal.id,
        text: goal.text,
        sections: goal.sections,
        created: goal.created,
        sortIndex: index
      )
      entity.text = goal.text
      entity.sections = goal.sections
      entity.created = goal.created
      entity.sortIndex = index
      entity.updatedAt = .now
      if entity.modelContext == nil { context.insert(entity) }
    }
    // Don't delete locally-only goals — the user may have created them on
    // this device after bootstrap, and a forced re-import shouldn't wipe
    // those. FastAPI is the source of historical data, not the canonical
    // current state.
    _ = seenIDs
  }

  private func queueHabitMirrorForUpload() {
    let defs = (try? context.fetch(FetchDescriptor<HabitDefinitionEntity>())) ?? []
    let states = (try? context.fetch(FetchDescriptor<HabitDayStateEntity>())) ?? []
    for def in defs {
      engine.noteHabitDefinitionChange(id: def.id)
    }
    for state in states {
      engine.noteHabitEventChange(id: state.id)
    }
  }

  private func queueSupplementMirrorForUpload() {
    let defs = (try? context.fetch(FetchDescriptor<SupplementDefinitionEntity>())) ?? []
    let states = (try? context.fetch(FetchDescriptor<SupplementDayStateEntity>())) ?? []
    for def in defs {
      engine.noteSupplementDefinitionChange(id: def.id)
    }
    for state in states {
      engine.noteSupplementEventChange(id: state.id)
    }
  }

  private func queueGoalsForUpload() {
    let goals = (try? context.fetch(FetchDescriptor<GoalEntity>())) ?? []
    for goal in goals {
      engine.noteGoalChange(id: goal.id)
    }
  }

  private func queueChoreMirrorForUpload() {
    let defs = (try? context.fetch(FetchDescriptor<ChoreDefinitionEntity>())) ?? []
    let events = (try? context.fetch(FetchDescriptor<ChoreEventEntity>())) ?? []
    for def in defs {
      engine.noteChoreDefinitionChange(id: def.id)
    }
    for event in events {
      engine.noteChoreEventChange(id: event.id)
    }
  }

  private func queueGutMirrorForUpload() {
    let entries = (try? context.fetch(FetchDescriptor<GutEventEntity>())) ?? []
    for entry in entries {
      engine.noteGutEventChange(id: entry.id)
    }
  }

  private func queueCaffeineMirrorForUpload() {
    let entries = (try? context.fetch(FetchDescriptor<CaffeineEventEntity>())) ?? []
    let beans = (try? context.fetch(FetchDescriptor<CaffeineBeanEntity>())) ?? []
    for entry in entries {
      engine.noteCaffeineEventChange(id: entry.id)
    }
    for bean in beans {
      engine.noteCaffeineBeanChange(id: bean.id)
    }
  }

  private func queueCannabisMirrorForUpload() {
    let entries = (try? context.fetch(FetchDescriptor<CannabisEventEntity>())) ?? []
    let strains = (try? context.fetch(FetchDescriptor<CannabisStrainEntity>())) ?? []
    for entry in entries {
      engine.noteCannabisEventChange(id: entry.id)
    }
    for strain in strains {
      engine.noteCannabisStrainChange(id: strain.id)
    }
  }

  private func queueGroceryMirrorForUpload() {
    let items = (try? context.fetch(FetchDescriptor<GroceryItemEntity>())) ?? []
    let cats = (try? context.fetch(FetchDescriptor<GroceryCategoryEntity>())) ?? []
    for item in items {
      engine.noteGroceryItemChange(id: item.id)
    }
    for cat in cats {
      engine.noteGroceryCategoryChange(id: cat.id)
    }
  }
}
