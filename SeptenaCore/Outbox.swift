import Foundation
import SwiftData

// Outbox + TaskMutator — the write side of the local-first cache.
//
// Today every task mutation hits the FastAPI server directly and the view
// re-fetches to repaint. This file inverts that: the mutator applies the
// change to SwiftData synchronously (instant UI), enqueues the operation
// in an OutboxEntity row, then a background drainer pushes the queue to
// the server with retry. UI never blocks on the network.
//
// Shape mirrors what CKSyncEngine wants — operations are owned client-side
// and the server is just one of several possible push targets.

// MARK: - Outbox entity

@Model
final class OutboxEntity {
  /// Operation UUID. Unique per enqueued mutation.
  @Attribute(.unique) var id: String
  /// `OutboxKind.rawValue` — switched on by the drainer to dispatch.
  var kind: String
  /// Target task id. Lets us recompute `pendingSync` after each drain step
  /// and lets queries find "the next op for task X" cheaply.
  var taskId: String
  /// JSON-encoded operation arguments (e.g. the new title for an update).
  /// Empty `Data()` for argument-less ops (complete/uncomplete/cancel/delete).
  var payloadData: Data
  var createdAt: Date
  var attempts: Int
  var nextAttemptAt: Date
  /// Last error message — surfaced in the Sync pane for debugging.
  var lastError: String?

  init(id: String = UUID().uuidString,
       kind: String,
       taskId: String,
       payloadData: Data) {
    self.id = id
    self.kind = kind
    self.taskId = taskId
    self.payloadData = payloadData
    self.createdAt = Date()
    self.attempts = 0
    self.nextAttemptAt = Date()
    self.lastError = nil
  }
}

enum OutboxKind: String {
  case create
  case update
  case complete, uncomplete, cancel
  case delete
  case moveToToday
  case schedule, setDue
  case setRecurrence
  case moveToArea, moveToProject
}

// MARK: - Payload structs

/// Payload shapes are intentionally minimal — only the fields the
/// corresponding SeptenaClient method consumes, encoded as plain Codable.
/// The server is reached through SeptenaClient.* so we don't duplicate
/// JSON-body construction here.
private struct CreatePayload: Codable {
  var id: String
  var title: String
  var area: String?
  var project: String?
  var scheduled: String?
  var due: String?
  var today: Bool
  var notes: String?
  var status: String?
}
private struct UpdatePayload: Codable {
  var title: String?
  var notes: String?
}
private struct MoveToTodayPayload: Codable { var today: Bool }
private struct DatePayload: Codable { var date: String? }   // yyyy-MM-dd or nil
private struct RecurrencePayload: Codable { var recurrence: Recurrence? }
private struct AreaPayload: Codable { var area: String? }
private struct ProjectPayload: Codable { var project: String? }

private let outboxEncoder = JSONEncoder()
private let outboxDecoder = JSONDecoder()

// MARK: - Timestamp helpers

/// The server's `completed_at` format — naive seconds-precision ISO-8601.
/// Used when an optimistic write needs to stamp `completedAt` locally so
/// the LogRow renders correctly before the server response lands.
private let serverTimestampFormatter: DateFormatter = {
  let f = DateFormatter()
  f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
  f.locale = Locale(identifier: "en_US_POSIX")
  return f
}()

private func serverNow() -> String { serverTimestampFormatter.string(from: Date()) }

// MARK: - TaskMutator

/// The single entry point for any code path that mutates a task. Replaces
/// direct calls to `SeptenaClient.complete(...)` etc. throughout the views.
///
/// Each method:
///   1. Applies an optimistic change to the SwiftData mirror (instant).
///   2. Enqueues an OutboxEntity (durable until the server confirms).
///   3. Posts `.septenaTasksChanged` so observers repaint from cache.
///   4. Kicks the drainer so the network round-trip happens immediately
///      when online; otherwise it'll fire on the next `kickDrain()`.
@MainActor
@Observable
final class TaskMutator {
  private let client: SeptenaClient
  private let context: ModelContext

  /// CloudKit dependency. Held weakly-typed (optional) so the FastAPI
  /// path stays runnable on devices that haven't been migrated yet
  /// (CKEngine refuses to start without a signed-in iCloud account,
  /// so we don't force one until the user flips the backend flag).
  /// Settable post-init via `bind(ckEngine:)` because App.swift can't
  /// reference its own `@State var ckEngine` from another `@State`
  /// initializer — wiring happens once in `.task` at launch.
  private var ckEngine: CKEngine?
  private var _cloudBackend: CloudKitTasksBackend?

  /// The CloudKit backend, lazily constructed when the flag is on.
  /// Returns nil when the backend is FastAPI — that's how every mutation
  /// method below decides which path to take. Single point of truth for
  /// "are we on CloudKit?", avoids each method re-checking the flag.
  private var cloudBackend: CloudKitTasksBackend? {
    guard TasksBackendDefaults.current == .cloudKit, let engine = ckEngine else {
      return nil
    }
    if _cloudBackend == nil {
      _cloudBackend = CloudKitTasksBackend(engine: engine, context: context)
    }
    return _cloudBackend
  }

  /// Tracks the currently-running drain so multiple kicks coalesce into
  /// a single in-flight loop instead of fanning out into parallel pushers
  /// that would step on each other's ordering.
  private var drainTask: Task<Void, Never>?

  /// ID of the OutboxEntity the drain has started executing (payload already
  /// decoded, network call in flight). Set before `await execute(entry)`,
  /// cleared after the entry is finalized (deleted on success, persisted on
  /// failure). Used by `update` / `delete` to know whether a `pendingCreate`
  /// row can still be mutated in place, or whether the drain has already
  /// snapshotted its payload and a follow-up op must be enqueued.
  private var executingEntryId: String?

  /// Surfaced by the Sync pane: "N pending mutations." Useful while
  /// offline to confirm work is queued rather than silently dropped.
  var pendingCount: Int {
    (try? context.fetchCount(FetchDescriptor<OutboxEntity>())) ?? 0
  }

  init(client: SeptenaClient, context: ModelContext, ckEngine: CKEngine? = nil) {
    self.client = client
    self.context = context
    self.ckEngine = ckEngine
  }

  /// One-shot binding hook for App.swift. Subsequent calls replace the
  /// engine (and drop any lazy-built `_cloudBackend` so the next mutation
  /// rebuilds against the new engine).
  func bind(ckEngine: CKEngine) {
    self.ckEngine = ckEngine
    self._cloudBackend = nil
  }

  // MARK: - Mutations (optimistic + enqueue)

  /// Optimistic create. Mints a client UUID, inserts a fully-formed
  /// `TaskEntity` into SwiftData synchronously, and enqueues the server
  /// push. Returns the new task immediately so the caller can wire up
  /// inline-edit / selection without awaiting the network. The drainer
  /// pushes to FastAPI with the same id; the server honors it.
  @discardableResult
  func create(title: String,
              area: String? = nil,
              project: String? = nil,
              scheduled: Date? = nil,
              due: Date? = nil,
              today: Bool = false,
              notes: String? = nil,
              status: String? = nil) -> SeptenaTask {
    if let cloudBackend {
      SeptenaLog.info("[TaskMutator] route=cloudKit op=create title=\"\(title)\"")
      return cloudBackend.create(title: title, area: area, project: project,
                                 scheduled: scheduled, due: due, today: today,
                                 notes: notes, status: status)
    }
    SeptenaLog.info("[TaskMutator] route=fastAPI op=create title=\"\(title)\"")
    let id = UUID().uuidString.lowercased()
    let todayIso = SeptenaDate.today
    let scheduledIso = SeptenaDate.format(scheduled)
    let dueIso = SeptenaDate.format(due)
    // Server derives area from project on save — mirror that here so the
    // optimistic row matches what the server will return.
    let effectiveArea = project != nil ? nil : area
    let entity = TaskEntity(
      id: id,
      title: title,
      statusRaw: status ?? TaskStatus.open.rawValue,
      created: todayIso,
      scheduled: scheduledIso,
      due: dueIso,
      today: today,
      todaySetOn: today ? todayIso : nil,
      area: effectiveArea,
      project: project,
      notes: (notes?.isEmpty == false) ? notes : nil,
      pendingSync: true
    )
    context.insert(entity)
    let payload = CreatePayload(
      id: id, title: title, area: area, project: project,
      scheduled: scheduledIso, due: dueIso,
      today: today, notes: notes, status: status
    )
    let data = (try? outboxEncoder.encode(payload)) ?? Data()
    enqueue(kind: .create, taskId: id, payload: data)
    return SeptenaTask(entity)
  }

  func complete(id: String) {
    if let cloudBackend { cloudBackend.complete(id: id); return }
    guard let entity = fetch(id: id) else { return }
    entity.statusRaw = TaskStatus.done.rawValue
    entity.completedAt = serverNow()
    entity.today = false
    entity.pendingSync = true
    enqueue(kind: .complete, taskId: id, payload: Data())
  }

  func uncomplete(id: String) {
    if let cloudBackend { cloudBackend.uncomplete(id: id); return }
    guard let entity = fetch(id: id) else { return }
    entity.statusRaw = TaskStatus.open.rawValue
    entity.completedAt = nil
    // Mirror the server's "restore today flag if it was set" behavior so
    // the local row matches what the server response will return.
    if entity.todaySetOn != nil { entity.today = true }
    entity.pendingSync = true
    enqueue(kind: .uncomplete, taskId: id, payload: Data())
  }

  func cancel(id: String) {
    if let cloudBackend { cloudBackend.cancel(id: id); return }
    guard let entity = fetch(id: id) else { return }
    entity.statusRaw = TaskStatus.cancelled.rawValue
    entity.completedAt = serverNow()
    entity.today = false
    entity.todaySetOn = nil
    entity.pendingSync = true
    enqueue(kind: .cancel, taskId: id, payload: Data())
  }

  func delete(id: String) {
    if let cloudBackend { cloudBackend.delete(id: id); return }
    guard let entity = fetch(id: id) else { return }
    // If the CREATE for this task hasn't drained yet, the server never
    // knew the task existed — drop the CREATE entry and the local row
    // outright instead of round-tripping a DELETE that would 404. Skipped
    // when the drain is mid-flight on this CREATE: deleting the entry now
    // would pull the rug from under `execute`, and the server is about to
    // know about the task anyway. Fall through to enqueue a real DELETE.
    if let pending = pendingCreate(taskId: id),
       pending.id != executingEntryId {
      context.delete(pending)
      context.delete(entity)
      try? context.save()
      NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
      return
    }
    // Soft-hide locally — the row stays in SwiftData so we can resurrect
    // it if the network call fails. LocalCache filters pendingDeletion.
    entity.pendingDeletion = true
    entity.pendingSync = true
    enqueue(kind: .delete, taskId: id, payload: Data())
  }

  func moveToToday(id: String, today: Bool = true) {
    if let cloudBackend { cloudBackend.moveToToday(id: id, today: today); return }
    guard let entity = fetch(id: id) else { return }
    entity.today = today
    entity.todaySetOn = today ? SeptenaDate.today : nil
    entity.pendingSync = true
    let payload = try? outboxEncoder.encode(MoveToTodayPayload(today: today))
    enqueue(kind: .moveToToday, taskId: id, payload: payload ?? Data())
  }

  /// Demote a task to the Someday bucket. The server has no per-task
  /// status endpoint (only complete/cancel/uncomplete) so on FastAPI we
  /// can only update local state — the row stays "someday" until the
  /// next pull from the server overwrites it. Acceptable transitional
  /// behaviour: FastAPI is deprecated; CloudKit is the production path
  /// where this works end-to-end.
  func moveToSomeday(id: String) {
    if let cloudBackend { cloudBackend.moveToSomeday(id: id); return }
    guard let entity = fetch(id: id) else { return }
    entity.statusRaw = TaskStatus.someday.rawValue
    entity.today = false
    entity.todaySetOn = nil
    entity.scheduled = nil
    entity.due = nil
    entity.completedAt = nil
    try? context.save()
    NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    SeptenaLog.info("[TaskMutator] moveToSomeday id=\(id) — local-only on FastAPI (no server endpoint)")
  }

  func schedule(id: String, date: Date?) {
    if let cloudBackend { cloudBackend.schedule(id: id, date: date); return }
    guard let entity = fetch(id: id) else { return }
    entity.scheduled = SeptenaDate.format(date)
    entity.pendingSync = true
    let payload = try? outboxEncoder.encode(DatePayload(date: entity.scheduled))
    enqueue(kind: .schedule, taskId: id, payload: payload ?? Data())
  }

  func setDue(id: String, date: Date?) {
    if let cloudBackend { cloudBackend.setDue(id: id, date: date); return }
    guard let entity = fetch(id: id) else { return }
    let previousDue = entity.due
    entity.due = SeptenaDate.format(date)
    // Server auto-promotes a due-today task into Today. Mirror that so the
    // optimistic UI reflects the same state the server will return.
    if let d = entity.due, d <= SeptenaDate.today, !entity.today {
      entity.today = true
      entity.todaySetOn = SeptenaDate.today
    }
    // Things-style: clearing a deadline must not drop a task out of Today.
    // If the row was surfacing only via due<=today, pin it now so it stays.
    // The server has no such rule, so enqueue moveToToday explicitly.
    var pinAfterClear = false
    if entity.due == nil, !entity.today,
       let prev = previousDue, prev <= SeptenaDate.today {
      entity.today = true
      entity.todaySetOn = SeptenaDate.today
      pinAfterClear = true
    }
    entity.pendingSync = true
    let payload = try? outboxEncoder.encode(DatePayload(date: entity.due))
    enqueue(kind: .setDue, taskId: id, payload: payload ?? Data())
    if pinAfterClear {
      let movePayload = try? outboxEncoder.encode(MoveToTodayPayload(today: true))
      enqueue(kind: .moveToToday, taskId: id, payload: movePayload ?? Data())
    }
  }

  func setRecurrence(id: String, recurrence: Recurrence?) {
    if let cloudBackend { cloudBackend.setRecurrence(id: id, recurrence: recurrence); return }
    guard let entity = fetch(id: id) else { return }
    entity.recurrence = recurrence
    entity.pendingSync = true
    let payload = try? outboxEncoder.encode(RecurrencePayload(recurrence: recurrence))
    enqueue(kind: .setRecurrence, taskId: id, payload: payload ?? Data())
  }

  func moveToArea(id: String, area: String?) {
    if let cloudBackend { cloudBackend.moveToArea(id: id, area: area); return }
    guard let entity = fetch(id: id) else { return }
    entity.area = area
    if area != nil { entity.project = nil }   // server enforces; mirror it
    entity.pendingSync = true
    let payload = try? outboxEncoder.encode(AreaPayload(area: area))
    enqueue(kind: .moveToArea, taskId: id, payload: payload ?? Data())
  }

  func moveToProject(id: String, project: String?) {
    if let cloudBackend { cloudBackend.moveToProject(id: id, project: project); return }
    guard let entity = fetch(id: id) else { return }
    entity.project = project
    if project != nil { entity.area = nil }   // server derives area from project
    entity.pendingSync = true
    let payload = try? outboxEncoder.encode(ProjectPayload(project: project))
    enqueue(kind: .moveToProject, taskId: id, payload: payload ?? Data())
  }

  func update(id: String, title: String? = nil, notes: String? = nil) {
    if let cloudBackend { cloudBackend.update(id: id, title: title, notes: notes); return }
    guard let entity = fetch(id: id) else { return }
    if let title { entity.title = title }
    if let notes { entity.notes = notes.isEmpty ? nil : notes }
    entity.pendingSync = true
    // Merge into a not-yet-drained CREATE so the single POST /api/tasks/create
    // carries the user's real title. Only safe if the drain hasn't already
    // decoded the payload — once `execute` is mid-await, mutating payloadData
    // is wasted (the in-flight POST still carries the placeholder, and on
    // success the outbox row is deleted, so no UPDATE follows). When the
    // CREATE is in flight we fall through and enqueue a real UPDATE op; the
    // outbox is FIFO-ordered, so it drains right after the CREATE settles.
    if let pending = pendingCreate(taskId: id),
       pending.id != executingEntryId,
       var payload = try? outboxDecoder.decode(CreatePayload.self, from: pending.payloadData) {
      if let title { payload.title = title }
      if let notes { payload.notes = notes.isEmpty ? nil : notes }
      if let data = try? outboxEncoder.encode(payload) {
        pending.payloadData = data
        try? context.save()
        NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
        kickDrain()
        return
      }
    }
    let payload = try? outboxEncoder.encode(UpdatePayload(title: title, notes: notes))
    enqueue(kind: .update, taskId: id, payload: payload ?? Data())
  }

  // MARK: - Drain

  /// Run pending operations until the queue is empty or a transport failure
  /// asks us to stop. Safe to call repeatedly — coalesces into one loop.
  func kickDrain() {
    if drainTask != nil { return }
    drainTask = Task { @MainActor in
      await self.drain()
      self.drainTask = nil
    }
  }

  private func drain() async {
    while true {
      guard let entry = nextReadyEntry() else { break }
      // Mark this entry as in-flight BEFORE awaiting. `execute` decodes the
      // payload upfront, so any payloadData mutation that lands while we're
      // suspended on the network is wasted. `update` / `delete` consult this
      // to decide whether merging into a pending CREATE is still safe.
      executingEntryId = entry.id
      do {
        try await execute(entry)
        executingEntryId = nil
        // Success: drop the outbox row and refresh the task's pending flag.
        context.delete(entry)
        recomputePendingSync(taskId: entry.taskId, afterDeletingEntryId: entry.id)
        try context.save()
        NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
      } catch {
        executingEntryId = nil
        let isTransport = (error as? URLError) != nil
        entry.attempts += 1
        entry.lastError = error.localizedDescription
        // Exponential backoff capped at 32s. Transport failures retry
        // forever (the user is offline); HTTP errors give up after 5
        // attempts since the server has consistently rejected the op.
        let delay = min(32.0, pow(2.0, Double(entry.attempts)))
        entry.nextAttemptAt = Date().addingTimeInterval(delay)
        if !isTransport && entry.attempts >= 5 {
          SeptenaLog.error("outbox: dropping \(entry.kind) for \(entry.taskId) after \(entry.attempts) attempts", error)
          context.delete(entry)
          recomputePendingSync(taskId: entry.taskId, afterDeletingEntryId: entry.id)
        }
        try? context.save()
        // Stop the loop on transport failure — Syncer's online detection
        // will kick us again on the next foreground / successful request.
        if isTransport { break }
      }
    }
  }

  private func execute(_ entry: OutboxEntity) async throws {
    guard let kind = OutboxKind(rawValue: entry.kind) else {
      throw SeptenaError.decoding("unknown outbox kind: \(entry.kind)")
    }
    let id = entry.taskId
    switch kind {
    case .create:
      let p = (try? outboxDecoder.decode(CreatePayload.self, from: entry.payloadData))
      guard let p else {
        SeptenaLog.error("outbox: create payload missing for \(id)")
        return
      }
      do {
        _ = try await client.create(
          title: p.title, id: p.id, area: p.area, project: p.project,
          scheduled: SeptenaDate.parse(p.scheduled),
          due: SeptenaDate.parse(p.due),
          today: p.today, notes: p.notes, status: p.status
        )
      } catch SeptenaError.server(let code, _) where code == 409 {
        // Server already has this id — most likely a retry of a request
        // whose response we lost. Treat as success and drop the entry.
      }
    case .complete:
      try await client.complete(id: id)
    case .uncomplete:
      try await client.uncomplete(id: id)
    case .cancel:
      try await client.cancel(id: id)
    case .delete:
      do {
        try await client.delete(id: id)
      } catch SeptenaError.server(let code, _) where code == 404 {
        // Already gone server-side — treat as success so we drop the entry.
      }
      // Hard-remove the local row now that the server has acked the delete.
      if let entity = fetch(id: id) { context.delete(entity) }
    case .moveToToday:
      let p = (try? outboxDecoder.decode(MoveToTodayPayload.self, from: entry.payloadData))
        ?? MoveToTodayPayload(today: true)
      try await client.moveToToday(id: id, today: p.today)
    case .schedule:
      let p = (try? outboxDecoder.decode(DatePayload.self, from: entry.payloadData))
        ?? DatePayload(date: nil)
      try await client.schedule(id: id, date: SeptenaDate.parse(p.date))
    case .setDue:
      let p = (try? outboxDecoder.decode(DatePayload.self, from: entry.payloadData))
        ?? DatePayload(date: nil)
      try await client.setDue(id: id, date: SeptenaDate.parse(p.date))
    case .setRecurrence:
      let p = (try? outboxDecoder.decode(RecurrencePayload.self, from: entry.payloadData))
        ?? RecurrencePayload(recurrence: nil)
      _ = try await client.setRecurrence(id: id, recurrence: p.recurrence)
    case .moveToArea:
      let p = (try? outboxDecoder.decode(AreaPayload.self, from: entry.payloadData))
        ?? AreaPayload(area: nil)
      _ = try await client.moveToArea(id: id, area: p.area)
    case .moveToProject:
      let p = (try? outboxDecoder.decode(ProjectPayload.self, from: entry.payloadData))
        ?? ProjectPayload(project: nil)
      _ = try await client.moveToProject(id: id, project: p.project)
    case .update:
      let p = (try? outboxDecoder.decode(UpdatePayload.self, from: entry.payloadData))
        ?? UpdatePayload(title: nil, notes: nil)
      _ = try await client.update(id: id, title: p.title, notes: p.notes)
    }
  }

  // MARK: - Helpers

  private func fetch(id: String) -> TaskEntity? {
    let descriptor = FetchDescriptor<TaskEntity>(
      predicate: #Predicate { $0.id == id }
    )
    return try? context.fetch(descriptor).first
  }

  /// Returns the still-queued CREATE outbox row for `taskId`, if any. Used
  /// by `update` / `delete` to merge into a pending create instead of
  /// enqueueing a follow-up op that would race against the create's POST.
  private func pendingCreate(taskId: String) -> OutboxEntity? {
    let createKind = OutboxKind.create.rawValue
    let descriptor = FetchDescriptor<OutboxEntity>(
      predicate: #Predicate { $0.taskId == taskId && $0.kind == createKind }
    )
    return try? context.fetch(descriptor).first
  }

  private func enqueue(kind: OutboxKind, taskId: String, payload: Data) {
    let entry = OutboxEntity(kind: kind.rawValue, taskId: taskId, payloadData: payload)
    context.insert(entry)
    do {
      try context.save()
    } catch {
      SeptenaLog.error("outbox: enqueue save failed", error)
    }
    NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    kickDrain()
  }

  /// Returns the oldest outbox entry whose backoff has elapsed, ordered by
  /// (nextAttemptAt, createdAt) so successive ops on the same task drain
  /// in insertion order.
  private func nextReadyEntry() -> OutboxEntity? {
    let now = Date()
    let descriptor = FetchDescriptor<OutboxEntity>(
      predicate: #Predicate { $0.nextAttemptAt <= now },
      sortBy: [SortDescriptor(\.nextAttemptAt), SortDescriptor(\.createdAt)]
    )
    return try? context.fetch(descriptor).first
  }

  /// After draining (or dropping) an outbox row, clear the task's
  /// `pendingSync` flag iff no other outbox rows reference it.
  private func recomputePendingSync(taskId: String, afterDeletingEntryId: String) {
    let descriptor = FetchDescriptor<OutboxEntity>(
      predicate: #Predicate { $0.taskId == taskId && $0.id != afterDeletingEntryId }
    )
    let remaining = (try? context.fetchCount(descriptor)) ?? 0
    guard remaining == 0 else { return }
    if let entity = fetch(id: taskId) {
      entity.pendingSync = false
    }
  }
}
