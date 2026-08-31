import Foundation
import SwiftData

// TaskMutator — the direct CloudKit write boundary for tasks.
//
// CloudKit (via CKSyncEngine) is the only backend for tasks. There is no
// HTTP outbox or transport fallback; every write lands in SwiftData then is
// queued through CKSyncEngine.

// MARK: - TaskMutator

/// The single entry point for any code path that mutates a task. Its local
/// store is bound to CKSyncEngine before use; callers must await
/// `SeptenaServices.shared.start()` first.
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

  /// CKSyncEngine owns its own persisted send queue. Task-specific outbox
  /// counts no longer exist, so this compatibility surface is always zero.
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
              deadline: Date? = nil,
              today: Bool = false,
              notes: String? = nil,
              source: String = TaskSource.app,
              acknowledged: Bool = false,
              deferPush: Bool = false,
              atBottom: Bool = false) -> SeptenaTask {
    guard let cloudBackend else {
      preconditionFailure("TaskMutator.create called before SeptenaServices.shared.start()")
    }
    SeptenaLog.info("[TaskMutator] route=cloudKit op=create title=\"\(title)\" source=\(source) acknowledged=\(acknowledged) deferPush=\(deferPush) atBottom=\(atBottom)")
    return cloudBackend.create(title: title, area: area, project: project,
                               scheduled: scheduled, deadline: deadline, today: today,
                               notes: notes, source: source, acknowledged: acknowledged,
                               deferPush: deferPush, atBottom: atBottom)
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

  /// Soft-delete → Recently Deleted (recoverable; docs/RECENTLY_DELETED_SPEC.md).
  func delete(id: String) {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] delete called before CK bound — dropping", nil)
      return
    }
    cloudBackend.delete(id: id)
  }

  /// Restore a task from Recently Deleted.
  func restore(id: String) {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] restore called before CK bound — dropping", nil)
      return
    }
    cloudBackend.restore(id: id)
  }

  /// Permanently destroy a task (Delete Permanently / auto-purge).
  func purge(id: String) {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] purge called before CK bound — dropping", nil)
      return
    }
    cloudBackend.purge(id: id)
  }

  /// 30-day auto-purge: permanently destroy all Recently Deleted tasks older than `cutoff`.
  func purgeExpired(before cutoff: Date) {
    guard let cloudBackend else { return }
    cloudBackend.purgeExpired(before: cutoff)
  }

  // MARK: - Conversation (Task Conversations — docs/TASK_CONVERSATIONS_PHASE0.md)

  func conversation(id: String) -> TaskConvo? {
    cloudBackend?.conversation(id: id)
  }

  @discardableResult
  func appendConvoTurn(id: String, _ turn: ConvoTurn) -> Int {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] appendConvoTurn called before CK bound — dropping", nil)
      return 0
    }
    return cloudBackend.appendConvoTurn(id: id, turn)
  }

  func setConvoAcceptance(id: String, _ line: String) {
    cloudBackend?.setConvoAcceptance(id: id, line)
  }

  func setConvoEndState(id: String, _ state: ConvoEndState, note: String?) {
    cloudBackend?.setConvoEndState(id: id, state, note: note)
  }

  func setConvoAssignee(id: String, _ assignee: ConvoAssignee?) {
    cloudBackend?.setConvoAssignee(id: id, assignee)
  }

  func setConvoArtifact(id: String, _ artifact: ConvoArtifact) {
    cloudBackend?.setConvoArtifact(id: id, artifact)
  }

  func setConvoHandoff(id: String, _ handoff: ConvoHandoff) {
    cloudBackend?.setConvoHandoff(id: id, handoff)
  }

  func pendingReasoning(limit: Int) -> [TaskEntity] {
    cloudBackend?.pendingReasoning(limit: limit) ?? []
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

  func schedule(id: String, date: Date?) {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] schedule called before CK bound — dropping", nil)
      return
    }
    cloudBackend.schedule(id: id, date: date)
  }

  func reschedule(id: String, date: Date?, mode: RecurrenceRescheduleMode) {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] reschedule called before CK bound — dropping", nil)
      return
    }
    cloudBackend.reschedule(id: id, date: date, mode: mode)
  }

  func setDeadline(id: String, date: Date?) {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] setDeadline called before CK bound — dropping", nil)
      return
    }
    cloudBackend.setDeadline(id: id, date: date)
  }

  func setRecurrence(id: String, recurrence: Recurrence?) {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] setRecurrence called before CK bound — dropping", nil)
      return
    }
    cloudBackend.setRecurrence(id: id, recurrence: recurrence)
  }

  func setRecurrencePaused(id: String, paused: Bool) {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] setRecurrencePaused called before CK bound — dropping", nil)
      return
    }
    cloudBackend.setRecurrencePaused(id: id, paused: paused)
  }

  @discardableResult
  func createNextOccurrence(id: String) -> SeptenaTask? {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] createNextOccurrence called before CK bound — dropping", nil)
      return nil
    }
    return cloudBackend.createNextOccurrence(id: id)
  }

  /// Materialize the fixed-schedule occurrences whose day has already come.
  /// Idempotent and cheap to repeat — see `TasksBackend.catchUpFixedSchedules`
  /// for why it is safe on every launch, foreground, and day rollover.
  @discardableResult
  func catchUpFixedSchedules() -> Int {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] catchUpFixedSchedules called before CK bound — dropping", nil)
      return 0
    }
    return cloudBackend.catchUpFixedSchedules()
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

  /// Create a project section-divider "heading" (docs/ORDERING_AND_HEADINGS_PLAN.md).
  @discardableResult
  func createHeading(title: String, project: String, atTop: Bool = false) -> SeptenaTask? {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] createHeading called before CK bound — dropping", nil)
      return nil
    }
    return cloudBackend.createHeading(title: title, project: project, atTop: atTop)
  }

  /// File a task under a heading (or clear it with `nil`).
  func setHeading(id: String, heading: String?) {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] setHeading called before CK bound — dropping", nil)
      return
    }
    cloudBackend.setHeading(id: id, heading: heading)
  }

  /// Clone a task into a brand-new one (new id) carrying the same fields —
  /// area/project/heading placement, schedule, deadline, Today, notes, and
  /// recurrence. Today membership is a *fresh* pin (`todaySetOn` = today via
  /// `create`); the clone does not inherit the source's gold tenure fill
  /// because `daysOnToday` cannot predate `created`. The clone-field list lives
  /// HERE, beside `create`, so a new task field can't be silently dropped by a
  /// duplicate path (heading membership was, in two divergent view-layer
  /// copies of this).
  @discardableResult
  func duplicate(_ task: SeptenaTask, source: String = TaskSource.app) -> SeptenaTask {
    let copy = create(
      title: task.title,
      area: task.area,
      project: task.project,
      scheduled: SeptenaDate.parse(task.scheduled),
      deadline: SeptenaDate.parse(task.deadline),
      today: task.today,
      notes: task.notes,
      source: source
    )
    if let heading = task.heading { setHeading(id: copy.id, heading: heading) }
    if let rule = task.recurrence { setRecurrence(id: copy.id, recurrence: rule) }
    return copy
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
  /// Callers must only invoke this on a real disposition (file / when /
  /// today / complete) — never on peek/select. Stack is logged so a stray
  /// call that still evacuates a row is diagnosable in Console.
  func acknowledge(id: String) {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] acknowledge called before CK bound — dropping", nil)
      return
    }
    let stack = Thread.callStackSymbols.prefix(8).joined(separator: " ← ")
    SeptenaLog.info("[TaskMutator] acknowledge id=\(id) via \(stack)")
    cloudBackend.acknowledge(id: id)
  }

  /// Restore an accidentally peek-acked MCP proposal (clears `acknowledgedAt`).
  func unacknowledge(id: String) {
    guard let cloudBackend else {
      SeptenaLog.error("[TaskMutator] unacknowledge called before CK bound — dropping", nil)
      return
    }
    cloudBackend.unacknowledge(id: id)
  }
}

// MARK: - Title text

/// A task title is ALWAYS one line — every task surface (row, widget, watch,
/// AppKit cell) lays out one line and truncates. So a pasted multi-line string
/// must never reach the store, and must never even *render* as a break inside
/// the editor. Title editors call this on every change; the field then shows
/// exactly what will be saved.
enum TaskTitleText {

  /// Flatten a pasted block: each line is trimmed, empty lines drop, and the
  /// lines join with ONE space. "buy milk\n\n  buy eggs" → "buy milk buy eggs".
  static func singleLine(_ raw: String) -> String {
    guard raw.contains(where: \.isNewline) else { return raw }
    return raw.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  /// Remove line breaks with NOTHING in their place — the Return-to-save path,
  /// where the break is a keystroke the user meant as "commit", not text. A
  /// space here would leave a stray gap wherever the caret sat mid-title.
  static func withoutLineBreaks(_ raw: String) -> String {
    String(raw.filter { !$0.isNewline })
  }
}
