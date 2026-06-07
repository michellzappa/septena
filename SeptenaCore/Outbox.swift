import Foundation
import SwiftData

// TaskMutator — the write side of the task cache.
//
// CloudKit (via CKSyncEngine) is the only backend for tasks. TaskMutator
// is a thin pass-through to `CloudKitTasksBackend`; the legacy FastAPI
// outbox path (and its OutboxEntity model) has been removed.

// MARK: - TaskMutator

/// The single entry point for any code path that mutates a task. Routes
/// every operation through `CloudKitTasksBackend` (CKSyncEngine). The
/// backend must be bound via `bind(ckEngine:)` before any mutation is
/// invoked — callers must await `SeptenaServices.shared.start()` first.
@MainActor
@Observable
final class TaskMutator {
  private let context: ModelContext

  /// CloudKit dependency. Held as optional because App.swift can't
  /// reference its own `@State var ckEngine` from another `@State`
  /// initializer — wiring happens once in `.task` at launch via
  /// `bind(ckEngine:)`. Once bound the backend is always available.
  private var ckEngine: CKEngine?
  private var _cloudBackend: CloudKitTasksBackend?

  /// The CloudKit backend, lazily constructed once the engine is bound.
  /// Every mutation method below routes through this.
  private var cloudBackend: CloudKitTasksBackend? {
    guard let engine = ckEngine else { return nil }
    if _cloudBackend == nil {
      _cloudBackend = CloudKitTasksBackend(engine: engine, context: context)
    }
    return _cloudBackend
  }

  /// Outbox has been retired for tasks. Kept as a property so Settings
  /// UI ("N pending mutations") keeps compiling; always reports zero.
  var pendingCount: Int { 0 }

  init(context: ModelContext, ckEngine: CKEngine? = nil) {
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

  // MARK: - Mutations

  @discardableResult
  func create(title: String,
              area: String? = nil,
              project: String? = nil,
              scheduled: Date? = nil,
              due: Date? = nil,
              today: Bool = false,
              notes: String? = nil,
              status: String? = nil,
              deferPush: Bool = false) -> SeptenaTask {
    guard let cloudBackend else {
      preconditionFailure("TaskMutator.create called before SeptenaServices.shared.start()")
    }
    SeptenaLog.info("[TaskMutator] route=cloudKit op=create title=\"\(title)\" deferPush=\(deferPush)")
    return cloudBackend.create(title: title, area: area, project: project,
                               scheduled: scheduled, due: due, today: today,
                               notes: notes, status: status,
                               deferPush: deferPush)
  }

  func complete(id: String) {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] complete called before CK bound — dropping", nil)
      return
    }
    cloudBackend.complete(id: id)
  }

  func uncomplete(id: String) {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] uncomplete called before CK bound — dropping", nil)
      return
    }
    cloudBackend.uncomplete(id: id)
  }

  func cancel(id: String) {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] cancel called before CK bound — dropping", nil)
      return
    }
    cloudBackend.cancel(id: id)
  }

  func delete(id: String) {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] delete called before CK bound — dropping", nil)
      return
    }
    cloudBackend.delete(id: id)
  }

  func moveToToday(id: String, today: Bool = true) {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] moveToToday called before CK bound — dropping", nil)
      return
    }
    cloudBackend.moveToToday(id: id, today: today)
  }

  func removeFromToday(id: String) {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] removeFromToday called before CK bound — dropping", nil)
      return
    }
    cloudBackend.removeFromToday(id: id)
  }

  func moveToSomeday(id: String) {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] moveToSomeday called before CK bound — dropping", nil)
      return
    }
    cloudBackend.moveToSomeday(id: id)
  }

  func schedule(id: String, date: Date?) {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] schedule called before CK bound — dropping", nil)
      return
    }
    cloudBackend.schedule(id: id, date: date)
  }

  func setDue(id: String, date: Date?) {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] setDue called before CK bound — dropping", nil)
      return
    }
    cloudBackend.setDue(id: id, date: date)
  }

  func setRecurrence(id: String, recurrence: Recurrence?) {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] setRecurrence called before CK bound — dropping", nil)
      return
    }
    cloudBackend.setRecurrence(id: id, recurrence: recurrence)
  }

  func moveToArea(id: String, area: String?) {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] moveToArea called before CK bound — dropping", nil)
      return
    }
    cloudBackend.moveToArea(id: id, area: area)
  }

  func moveToProject(id: String, project: String?) {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] moveToProject called before CK bound — dropping", nil)
      return
    }
    cloudBackend.moveToProject(id: id, project: project)
  }

  func reorder(id: String, toPosition position: Double) {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] reorder called before CK bound — dropping", nil)
      return
    }
    cloudBackend.reorder(id: id, toPosition: position)
  }

  func update(id: String, title: String? = nil, notes: String? = nil) {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] update called before CK bound — dropping", nil)
      return
    }
    cloudBackend.update(id: id, title: title, notes: notes)
  }

  /// Clear the agent-created freshness cue on engagement. Idempotent and
  /// cheap — the backend no-ops for non-agent or already-seen rows.
  func acknowledge(id: String) {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] acknowledge called before CK bound — dropping", nil)
      return
    }
    cloudBackend.acknowledge(id: id)
  }
}
