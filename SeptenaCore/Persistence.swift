import Foundation
import SwiftData

// Local SwiftData mirror of the Septena server. Server stays authoritative;
// this is a cache so the UI can render and accept input without a round-trip.
// Wire DTOs in Models.swift remain unchanged — we convert at the boundary.

// MARK: - Entities

@Model
final class TaskEntity {
  @Attribute(.unique) var id: String
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
  /// Bumped every time we apply a server payload. Lets the syncer detect
  /// rows that the latest pull didn't touch (= server-side deletions).
  var lastSyncedAt: Date
  /// Position in the most recent server response. Cache reads sort by this
  /// so the painted-from-cache order matches what the network refresh will
  /// produce — otherwise rows visibly reshuffle on every cold open.
  var sortIndex: Int
  /// True while one or more `OutboxEntity` rows reference this task. The
  /// Syncer will not overwrite local fields on a row with `pendingSync ==
  /// true` — we don't want a server snapshot taken before the user's
  /// optimistic write to clobber the local state. Cleared by TaskMutator
  /// once the queue for this id is empty.
  var pendingSync: Bool = false
  /// True between the moment `TaskMutator.delete(id:)` is called and the
  /// drainer confirming the server-side delete. `LocalCache` filters rows
  /// with `pendingDeletion == true` so the UI hides them immediately. If
  /// the network call ultimately fails the flag is cleared and the row
  /// resurrects in the list.
  var pendingDeletion: Bool = false
  /// Server-stamped `updated_at` (mirrored from the DTO). Used by the
  /// delta-sync watermark — `Syncer.pullChanges()` sends the max
  /// updatedAt back as `since` on the next call.
  var updatedAt: String?
  /// Server-stamped tombstone. When set, the row is logically deleted
  /// — Syncer purges it locally during the next apply.
  var deletedAt: String?

  init(id: String,
       title: String,
       statusRaw: String = TaskStatus.open.rawValue,
       created: String? = nil,
       scheduled: String? = nil,
       due: String? = nil,
       today: Bool = false,
       todaySetOn: String? = nil,
       completedAt: String? = nil,
       area: String? = nil,
       project: String? = nil,
       notes: String? = nil,
       recurrenceUnit: String? = nil,
       recurrenceInterval: Int = 1,
       recurrenceAfterCompletion: Bool = true,
       lastSyncedAt: Date = .distantPast,
       sortIndex: Int = 0,
       pendingSync: Bool = false,
       pendingDeletion: Bool = false,
       updatedAt: String? = nil,
       deletedAt: String? = nil) {
    self.id = id
    self.title = title
    self.statusRaw = statusRaw
    self.created = created
    self.scheduled = scheduled
    self.due = due
    self.today = today
    self.todaySetOn = todaySetOn
    self.completedAt = completedAt
    self.area = area
    self.project = project
    self.notes = notes
    self.recurrenceUnit = recurrenceUnit
    self.recurrenceInterval = recurrenceInterval
    self.recurrenceAfterCompletion = recurrenceAfterCompletion
    self.lastSyncedAt = lastSyncedAt
    self.sortIndex = sortIndex
    self.pendingSync = pendingSync
    self.pendingDeletion = pendingDeletion
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
  }

  var status: TaskStatus {
    get { TaskStatus(rawValue: statusRaw) ?? .open }
    set { statusRaw = newValue.rawValue }
  }

  var recurrence: Recurrence? {
    get {
      guard let unit = recurrenceUnit.flatMap(Recurrence.Unit.init(rawValue:)) else { return nil }
      return Recurrence(unit: unit,
                        interval: recurrenceInterval,
                        afterCompletion: recurrenceAfterCompletion)
    }
    set {
      recurrenceUnit = newValue?.unit.rawValue
      recurrenceInterval = newValue?.interval ?? 1
      recurrenceAfterCompletion = newValue?.afterCompletion ?? true
    }
  }
}

@Model
final class ProjectEntity {
  @Attribute(.unique) var id: String
  var title: String
  var statusRaw: String
  var area: String?
  var created: String?
  var completedAt: String?
  var notes: String?
  var context: String?
  var githubRepo: String?
  var lastSyncedAt: Date
  var updatedAt: String?
  var deletedAt: String?

  init(id: String,
       title: String,
       statusRaw: String = ProjectStatus.active.rawValue,
       area: String? = nil,
       created: String? = nil,
       completedAt: String? = nil,
       notes: String? = nil,
       context: String? = nil,
       githubRepo: String? = nil,
       lastSyncedAt: Date = .distantPast,
       updatedAt: String? = nil,
       deletedAt: String? = nil) {
    self.id = id
    self.title = title
    self.statusRaw = statusRaw
    self.area = area
    self.created = created
    self.completedAt = completedAt
    self.notes = notes
    self.context = context
    self.githubRepo = githubRepo
    self.lastSyncedAt = lastSyncedAt
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
  }

  var status: ProjectStatus {
    get { ProjectStatus(rawValue: statusRaw) ?? .active }
    set { statusRaw = newValue.rawValue }
  }
}

@Model
final class AreaEntity {
  @Attribute(.unique) var id: String
  var title: String
  var context: String?
  var lastSyncedAt: Date
  var updatedAt: String?

  init(id: String, title: String, context: String? = nil,
       lastSyncedAt: Date = .distantPast, updatedAt: String? = nil) {
    self.id = id
    self.title = title
    self.context = context
    self.lastSyncedAt = lastSyncedAt
    self.updatedAt = updatedAt
  }
}

// MARK: - DTO ↔ Entity bridging

extension SeptenaTask {
  init(_ e: TaskEntity) {
    // Decode through the existing decoder so we exercise the same code path
    // as the network layer. Cheaper than maintaining a second initializer.
    let payload: [String: Any?] = [
      "id": e.id,
      "title": e.title,
      "status": e.statusRaw,
      "created": e.created,
      "scheduled": e.scheduled,
      "due": e.due,
      "today": e.today,
      "today_set_on": e.todaySetOn,
      "completed_at": e.completedAt,
      "area": e.area,
      "project": e.project,
      "notes": e.notes,
      "recurrence": e.recurrenceUnit.map { unit -> [String: Any] in
        ["unit": unit,
         "interval": e.recurrenceInterval,
         "after_completion": e.recurrenceAfterCompletion]
      } as Any?,
      "updated_at": e.updatedAt,
      "deleted_at": e.deletedAt,
    ]
    let data = try! JSONSerialization.data(withJSONObject: payload.compactMapValues { $0 })
    self = try! JSONDecoder().decode(SeptenaTask.self, from: data)
  }
}

extension Project {
  init(_ e: ProjectEntity) {
    self.init(id: e.id,
              title: e.title,
              status: e.status,
              area: e.area,
              created: e.created,
              completedAt: e.completedAt,
              notes: e.notes,
              context: e.context,
              githubRepo: e.githubRepo,
              updatedAt: e.updatedAt,
              deletedAt: e.deletedAt)
  }
}

extension Area {
  init(_ e: AreaEntity) {
    self.init(id: e.id, title: e.title, context: e.context, updatedAt: e.updatedAt)
  }
}

// MARK: - LocalStore

@MainActor
final class LocalStore {
  static let shared = LocalStore()

  let container: ModelContainer

  private init() {
    let schema = Schema([TaskEntity.self, ProjectEntity.self, AreaEntity.self,
                         OutboxEntity.self, HTTPOutboxEntity.self])
    let config = ModelConfiguration("Septena", schema: schema)
    do {
      container = try ModelContainer(for: schema, configurations: [config])
    } catch {
      // Schema drift between releases: wipe and re-pull from the server.
      // Server is the source of truth so local data is safe to drop.
      SeptenaLog.error("ModelContainer init failed — wiping local store", error)
      try? Self.deleteStore(name: "Septena")
      container = try! ModelContainer(for: schema, configurations: [config])
    }
  }

  private static func deleteStore(name: String) throws {
    let url = URL.applicationSupportDirectory.appending(path: "\(name).store")
    let fm = FileManager.default
    for suffix in ["", "-shm", "-wal"] {
      let f = URL(fileURLWithPath: url.path + suffix)
      if fm.fileExists(atPath: f.path) { try fm.removeItem(at: f) }
    }
  }
}

// MARK: - LocalCache (synchronous reads for instant render)

/// Snapshot reads from the local store. Views call these at the top of
/// their `load()` to paint instantly, then kick off the network refresh.
/// Filter semantics roughly mirror the server's `view=` parameter; they're
/// approximations — the network response always wins on the next render.
enum LocalCache {
  @MainActor
  static func tasks(in context: ModelContext,
                    filter: TaskFilter) -> [SeptenaTask] {
    let descriptor = FetchDescriptor<TaskEntity>(
      sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.id)]
    )
    guard let rows = try? context.fetch(descriptor) else { return [] }
    let today = SeptenaDate.today
    return rows.compactMap { e -> SeptenaTask? in
      // Hide rows the user has deleted locally; the outbox drainer will
      // either confirm the deletion (row removed) or resurrect them if
      // the server rejects.
      if e.pendingDeletion { return nil }
      switch filter {
      case .today:
        guard e.status == .open else { return nil }
        if e.today { return SeptenaTask(e) }
        if let s = e.scheduled, s <= today { return SeptenaTask(e) }
        if let d = e.due, d <= today { return SeptenaTask(e) }
        return nil
      case .inbox:
        guard e.status == .open,
              e.project == nil, e.area == nil,
              e.scheduled == nil, e.due == nil, !e.today else { return nil }
        return SeptenaTask(e)
      case .upcoming:
        guard e.status == .open, !e.today else { return nil }
        if let s = e.scheduled, s > today { return SeptenaTask(e) }
        if let d = e.due, d > today { return SeptenaTask(e) }
        return nil
      case .unscheduled:
        guard e.status == .open, !e.today,
              e.scheduled == nil, e.due == nil else { return nil }
        return SeptenaTask(e)
      case .someday:
        guard e.status == .someday else { return nil }
        return SeptenaTask(e)
      case .logbook:
        guard e.status == .done else { return nil }
        return SeptenaTask(e)
      case .project(let pid):
        guard e.project == pid else { return nil }
        return SeptenaTask(e)
      case .area(let aid):
        guard e.area == aid else { return nil }
        return SeptenaTask(e)
      }
    }
  }

  @MainActor
  static func allTasks(in context: ModelContext) -> [SeptenaTask] {
    (try? context.fetch(FetchDescriptor<TaskEntity>()))?.map(SeptenaTask.init) ?? []
  }

  /// Count of open tasks whose hard deadline is today or in the past.
  /// Drives the Today sidebar's red badge — matches the in-list red date
  /// treatment exactly (only `due ≤ today` counts as overdue; scheduled-past
  /// is residence, not lateness).
  @MainActor
  static func overdueCount(in context: ModelContext) -> Int {
    let today = SeptenaDate.today
    let rows = (try? context.fetch(FetchDescriptor<TaskEntity>())) ?? []
    return rows.reduce(0) { acc, e in
      guard e.status == .open, let d = e.due, d <= today else { return acc }
      return acc + 1
    }
  }

  @MainActor
  static func areas(in context: ModelContext) -> [Area] {
    let descriptor = FetchDescriptor<AreaEntity>(sortBy: [SortDescriptor(\.title)])
    return (try? context.fetch(descriptor))?.map(Area.init) ?? []
  }

  @MainActor
  static func projects(in context: ModelContext) -> [Project] {
    let descriptor = FetchDescriptor<ProjectEntity>(sortBy: [SortDescriptor(\.title)])
    return (try? context.fetch(descriptor))?.map(Project.init) ?? []
  }
}

// MARK: - Syncer

/// Pulls the authoritative state from the server and folds it into SwiftData.
/// Call `pullAll()` on app foreground and after mutations. The mutation
/// outbox (write path) is a separate slice — TaskMutator handles those.
///
/// Implementation: a single `GET /api/tasks/changes?since=<watermark>` call
/// returns everything (tasks, projects, areas) that changed since the last
/// successful sync, including tombstones. The watermark is the server's
/// `server_time` from the previous response, persisted in UserDefaults so
/// it survives relaunches. Shape mirrors `CKSyncEngine.fetchChanges`.
@MainActor
final class Syncer {
  private let client: SeptenaClient
  private let context: ModelContext

  /// Watermark key — the server-returned `serverTime` from the previous
  /// `/changes` call. Nil on first launch (or after a deliberate reset),
  /// which triggers a full snapshot from the server.
  private static let watermarkKey = "septena.sync.serverTime"

  init(client: SeptenaClient, context: ModelContext) {
    self.client = client
    self.context = context
  }

  func pullAll() async {
    do {
      let since = UserDefaults.standard.string(forKey: Self.watermarkKey)
      let response = try await client.changes(since: since)
      apply(response)
      try context.save()
      // Persist the server's clock — next call sends this back as `since`.
      UserDefaults.standard.set(response.serverTime, forKey: Self.watermarkKey)
      // Surfaced by the Sync pane as "Last sync: 2m ago".
      UserDefaults.standard.set(Date().timeIntervalSince1970,
                                forKey: "septena.sync.lastSucceededAt")
    } catch is CancellationError {
      // Foreground re-trigger; silent.
    } catch {
      SeptenaLog.error("Syncer.pullAll failed", error)
    }
  }

  /// Fold a `/changes` response into the local store. Tombstones (rows
  /// with `deletedAt` set) purge the local entity unless the outbox has
  /// pending writes for that id — those rows wait for the drainer to
  /// reconcile rather than getting yanked out from under it.
  private func apply(_ response: ChangesResponse) {
    let now = Date()
    for (index, dto) in response.tasks.enumerated() {
      if dto.deletedAt != nil {
        applyTombstoneTask(id: dto.id)
      } else {
        upsert(dto, syncedAt: now, sortIndex: index)
      }
    }
    for dto in response.projects {
      if dto.deletedAt != nil {
        applyTombstoneProject(id: dto.id)
      } else {
        upsert(dto, syncedAt: now)
      }
    }
    // Areas use delete-by-omission on the server (wholesale-replace via
    // PUT, no per-row tombstone), so delta sync can't detect removals.
    // A removed area would only purge after a full resync (clear the
    // watermark). Acceptable: areas rarely change and the next cold
    // launch will trigger a fresh `/changes` with stale-but-non-nil
    // `since`, missing the deletion. To force reconciliation, clear
    // `septena.sync.serverTime` in Settings.
    for dto in response.areas {
      upsert(dto, syncedAt: now)
    }
  }

  private func applyTombstoneTask(id: String) {
    let descriptor = FetchDescriptor<TaskEntity>(
      predicate: #Predicate { $0.id == id }
    )
    guard let entity = try? context.fetch(descriptor).first else { return }
    // Don't yank a row the outbox is still pushing for — let the drainer
    // finish (or fail with 404, which it treats as success and drops).
    if entity.pendingSync { return }
    context.delete(entity)
  }

  private func applyTombstoneProject(id: String) {
    let descriptor = FetchDescriptor<ProjectEntity>(
      predicate: #Predicate { $0.id == id }
    )
    guard let entity = try? context.fetch(descriptor).first else { return }
    context.delete(entity)
  }

  // MARK: Apply (fold an already-fetched response back into the cache)

  /// Fold a list response into the cache. `scope` controls how deletions
  /// are detected: `.all` removes any task not in the payload; `.area` /
  /// `.project` only prune within that scope; `.filter` doesn't prune at
  /// all (the server's view filter excludes tasks that still exist).
  enum TaskScope {
    case all
    case area(String)
    case project(String)
    case filter(TaskFilter)
  }

  func applyTasks(_ items: [SeptenaTask], scope: TaskScope) {
    let now = Date()
    var seen = Set<String>()
    for (index, dto) in items.enumerated() {
      seen.insert(dto.id)
      upsert(dto, syncedAt: now, sortIndex: index)
    }
    do {
      switch scope {
      case .all:
        try context.delete(model: TaskEntity.self,
                           where: #Predicate { $0.lastSyncedAt < now })
      case .area(let aid):
        try context.delete(model: TaskEntity.self,
                           where: #Predicate { $0.area == aid && $0.lastSyncedAt < now })
      case .project(let pid):
        try context.delete(model: TaskEntity.self,
                           where: #Predicate { $0.project == pid && $0.lastSyncedAt < now })
      case .filter:
        break
      }
      try context.save()
    } catch {
      SeptenaLog.error("applyTasks save failed", error)
    }
  }

  func applyAreas(_ dtos: [Area]) {
    let now = Date()
    for dto in dtos { upsert(dto, syncedAt: now) }
    do {
      try context.delete(model: AreaEntity.self,
                         where: #Predicate { $0.lastSyncedAt < now })
      try context.save()
    } catch {
      SeptenaLog.error("applyAreas save failed", error)
    }
  }

  func applyProjects(_ dtos: [Project]) {
    let now = Date()
    for dto in dtos { upsert(dto, syncedAt: now) }
    do {
      try context.delete(model: ProjectEntity.self,
                         where: #Predicate { $0.lastSyncedAt < now })
      try context.save()
    } catch {
      SeptenaLog.error("applyProjects save failed", error)
    }
  }

  // MARK: Upserts

  private func upsert(_ dto: SeptenaTask, syncedAt: Date, sortIndex: Int) {
    let id = dto.id
    let existing = try? context.fetch(
      FetchDescriptor<TaskEntity>(predicate: #Predicate { $0.id == id })
    ).first
    // Local outbox in flight: don't overwrite the optimistic state with a
    // stale server snapshot. Bump lastSyncedAt + sortIndex so the prune
    // pass doesn't treat the row as orphaned.
    if let existing, existing.pendingSync {
      existing.lastSyncedAt = syncedAt
      existing.sortIndex = sortIndex
      return
    }
    let entity = existing ?? TaskEntity(id: id, title: dto.title)
    entity.title = dto.title
    entity.statusRaw = dto.status.rawValue
    entity.created = dto.created
    entity.scheduled = dto.scheduled
    entity.due = dto.due
    entity.today = dto.today
    entity.todaySetOn = dto.todaySetOn
    entity.completedAt = dto.completedAt
    entity.area = dto.area
    entity.project = dto.project
    entity.notes = dto.notes
    entity.recurrence = dto.recurrence
    entity.updatedAt = dto.updatedAt
    entity.deletedAt = dto.deletedAt
    entity.lastSyncedAt = syncedAt
    entity.sortIndex = sortIndex
    if existing == nil { context.insert(entity) }
  }

  private func upsert(_ dto: Project, syncedAt: Date) {
    let id = dto.id
    let existing = try? context.fetch(
      FetchDescriptor<ProjectEntity>(predicate: #Predicate { $0.id == id })
    ).first
    let entity = existing ?? ProjectEntity(id: id, title: dto.title)
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
    entity.lastSyncedAt = syncedAt
    if existing == nil { context.insert(entity) }
  }

  private func upsert(_ dto: Area, syncedAt: Date) {
    let id = dto.id
    let existing = try? context.fetch(
      FetchDescriptor<AreaEntity>(predicate: #Predicate { $0.id == id })
    ).first
    let entity = existing ?? AreaEntity(id: id, title: dto.title)
    entity.title = dto.title
    entity.context = dto.context
    entity.updatedAt = dto.updatedAt
    entity.lastSyncedAt = syncedAt
    if existing == nil { context.insert(entity) }
  }
}
