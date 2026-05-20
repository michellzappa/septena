import Foundation
import SwiftData

// TasksBackend — CloudKit is the only path for task mutations. The
// protocol survives as a seam for tests and future re-routing, but the
// runtime backend toggle has been removed.
//
// CKSyncEngine *is* the outbox — local mutation + `engine.noteTaskChange(id:)`
// is the whole story; the engine batches, retries, and resolves
// conflicts on its own.

// MARK: - Protocol

/// Mutation surface. `CloudKitTasksBackend` is the only conforming type
/// in production; `TaskMutator` is now a thin shim that forwards to it.
@MainActor
protocol TasksBackend: AnyObject {
  @discardableResult
  func create(title: String,
              area: String?,
              project: String?,
              scheduled: Date?,
              due: Date?,
              today: Bool,
              notes: String?,
              status: String?) -> SeptenaTask

  func update(id: String, title: String?, notes: String?)
  func complete(id: String)
  func uncomplete(id: String)
  func cancel(id: String)
  func delete(id: String)
  func moveToToday(id: String, today: Bool)
  func moveToSomeday(id: String)
  func schedule(id: String, date: Date?)
  func setDue(id: String, date: Date?)
  func setRecurrence(id: String, recurrence: Recurrence?)
  func moveToArea(id: String, area: String?)
  func moveToProject(id: String, project: String?)
}

// MARK: - CloudKit backend

/// Matches Outbox.swift's private `serverNow()` — naive seconds-precision
/// ISO-8601 so `completedAt` blends with FastAPI-authored rows. Kept
/// local here rather than promoted because the CK and FastAPI paths
/// diverge in Phase 6 anyway.
private let ckTimestampFormatter: DateFormatter = {
  let f = DateFormatter()
  f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
  f.locale = Locale(identifier: "en_US_POSIX")
  return f
}()
private func ckServerTimestamp() -> String { ckTimestampFormatter.string(from: Date()) }

@MainActor
final class CloudKitTasksBackend: TasksBackend {
  private let engine: CKEngine
  private let context: ModelContext

  init(engine: CKEngine, context: ModelContext) {
    self.engine = engine
    self.context = context
  }

  // MARK: Local helpers

  private func fetch(id: String) -> TaskEntity? {
    let descriptor = FetchDescriptor<TaskEntity>(
      predicate: #Predicate { $0.id == id }
    )
    return try? context.fetch(descriptor).first
  }

  /// Persists the local mutation, tells the engine, posts the notification
  /// so views repaint. Save errors are logged but not propagated — the
  /// FastAPI path swallows them too, and there's no caller that can act
  /// on the failure at this layer.
  private func commitAndPush(_ entity: TaskEntity, op: String, deletion: Bool = false) {
    let id = entity.id
    let title = entity.title
    do {
      try context.save()
    } catch {
      SeptenaLog.error("CK backend: context.save failed", error)
    }
    if deletion {
      engine.noteTaskDeletion(id: id)
      SeptenaLog.info("[CK] \(op) id=\(id) title=\"\(title)\" → engine.noteTaskDeletion")
    } else {
      engine.noteTaskChange(id: id)
      SeptenaLog.info("[CK] \(op) id=\(id) title=\"\(title)\" → engine.noteTaskChange")
    }
    NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
  }

  // MARK: Mutations

  @discardableResult
  func create(title: String, area: String?, project: String?,
              scheduled: Date?, due: Date?, today: Bool,
              notes: String?, status: String?) -> SeptenaTask {
    let id = UUID().uuidString.lowercased()
    let todayIso = SeptenaDate.today
    let effectiveArea = project != nil ? nil : area
    let entity = TaskEntity(
      id: id,
      title: title,
      statusRaw: status ?? TaskStatus.open.rawValue,
      created: todayIso,
      scheduled: SeptenaDate.format(scheduled),
      due: SeptenaDate.format(due),
      today: today,
      todaySetOn: today ? todayIso : nil,
      area: effectiveArea,
      project: project,
      notes: (notes?.isEmpty == false) ? notes : nil,
      pendingSync: true
    )
    context.insert(entity)
    commitAndPush(entity, op: "create")
    return SeptenaTask(entity)
  }

  func update(id: String, title: String?, notes: String?) {
    guard let entity = fetch(id: id) else {
      SeptenaLog.info("[CK] update id=\(id) → MISS (no local entity)")
      return
    }
    if let title { entity.title = title }
    if let notes { entity.notes = notes.isEmpty ? nil : notes }
    entity.pendingSync = true
    commitAndPush(entity, op: "update")
  }

  func complete(id: String) {
    guard let entity = fetch(id: id) else { return }
    entity.statusRaw = TaskStatus.done.rawValue
    entity.completedAt = ckServerTimestamp()
    entity.today = false
    entity.pendingSync = true
    commitAndPush(entity, op: "complete")
  }

  func uncomplete(id: String) {
    guard let entity = fetch(id: id) else { return }
    entity.statusRaw = TaskStatus.open.rawValue
    entity.completedAt = nil
    entity.pendingSync = true
    commitAndPush(entity, op: "uncomplete")
  }

  func cancel(id: String) {
    guard let entity = fetch(id: id) else { return }
    entity.statusRaw = TaskStatus.cancelled.rawValue
    entity.completedAt = ckServerTimestamp()
    entity.today = false
    entity.pendingSync = true
    commitAndPush(entity, op: "cancel")
  }

  func delete(id: String) {
    guard let entity = fetch(id: id) else { return }
    // CKSyncEngine deletes are durable and retried until success, so we
    // hard-delete locally. If the user is offline the deletion sits in
    // the engine's pendingRecordZoneChanges and drains on reconnect.
    let staged = entity     // capture before we tell SwiftData to remove
    context.delete(entity)
    commitAndPush(staged, op: "delete", deletion: true)
  }

  func moveToToday(id: String, today: Bool) {
    guard let entity = fetch(id: id) else { return }
    entity.today = today
    entity.todaySetOn = today ? SeptenaDate.today : nil
    entity.pendingSync = true
    commitAndPush(entity, op: "moveToToday(\(today))")
  }

  /// Demote a task to the Someday bucket. Clears today, scheduled, and due
  /// — Someday is "I'll get to it eventually," not a calendared commitment.
  /// Recurrence stays intact so the user can pull a recurring task into the
  /// Someday holding bay without losing the rule.
  func moveToSomeday(id: String) {
    guard let entity = fetch(id: id) else { return }
    entity.statusRaw = TaskStatus.someday.rawValue
    entity.today = false
    entity.todaySetOn = nil
    entity.scheduled = nil
    entity.due = nil
    entity.completedAt = nil
    entity.pendingSync = true
    commitAndPush(entity, op: "moveToSomeday")
  }

  func schedule(id: String, date: Date?) {
    guard let entity = fetch(id: id) else { return }
    entity.scheduled = SeptenaDate.format(date)
    entity.pendingSync = true
    commitAndPush(entity, op: "schedule")
  }

  func setDue(id: String, date: Date?) {
    guard let entity = fetch(id: id) else { return }
    entity.due = SeptenaDate.format(date)
    if let d = entity.due, d <= SeptenaDate.today, !entity.today {
      entity.today = true
      entity.todaySetOn = SeptenaDate.today
    }
    entity.pendingSync = true
    commitAndPush(entity, op: "setDue")
  }

  func setRecurrence(id: String, recurrence: Recurrence?) {
    guard let entity = fetch(id: id) else { return }
    entity.recurrence = recurrence
    entity.pendingSync = true
    commitAndPush(entity, op: "setRecurrence")
  }

  func moveToArea(id: String, area: String?) {
    guard let entity = fetch(id: id) else { return }
    entity.area = area
    if area != nil { entity.project = nil }
    entity.pendingSync = true
    commitAndPush(entity, op: "moveToArea")
  }

  func moveToProject(id: String, project: String?) {
    guard let entity = fetch(id: id) else { return }
    entity.project = project
    if project != nil { entity.area = nil }
    entity.pendingSync = true
    commitAndPush(entity, op: "moveToProject")
  }
}
