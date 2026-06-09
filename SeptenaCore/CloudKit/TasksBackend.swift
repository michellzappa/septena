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
              status: String?,
              deferPush: Bool) -> SeptenaTask

  func update(id: String, title: String?, notes: String?)
  /// Mark an agent-created row as seen (clears the freshness cue). Idempotent.
  func acknowledge(id: String)
  func complete(id: String)
  func uncomplete(id: String)
  func cancel(id: String)
  func delete(id: String)
  func moveToToday(id: String, today: Bool)
  func removeFromToday(id: String)
  func moveToSomeday(id: String)
  func schedule(id: String, date: Date?)
  func setDue(id: String, date: Date?)
  func setRecurrence(id: String, recurrence: Recurrence?)
  func moveToArea(id: String, area: String?)
  func moveToProject(id: String, project: String?)
  /// Set a task's manual order position (Things-style drag-to-reorder). The
  /// caller computes the value as the midpoint of the new neighbours' order
  /// keys; we just persist + sync it.
  func reorder(id: String, toPosition position: Double)
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

/// Friendly `sourceClient` label for app-authored writes — the native
/// counterpart to the gateway's "Claude". Identifies which surface created
/// the row; also the value that registers the `sourceClient` CloudKit field
/// in dev via a native write.
private var currentAppClientLabel: String {
  #if os(macOS)
  return "Septena Mac"
  #elseif os(watchOS)
  return "Septena Watch"
  #else
  return "Septena iOS"
  #endif
}

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

  /// Tasks are content, not label entities, but new CloudKit-authored task
  /// ids still use the same unambiguous base32 alphabet for compactness.
  private func uniqueTaskID() -> String {
    let first = IDShortcode.generate(length: 6)
    if fetch(id: first) == nil { return first }
    let second = IDShortcode.generate(length: 8)
    if fetch(id: second) == nil { return second }
    return String(UUID().uuidString.prefix(12)).lowercased()
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

  // MARK: Conversation (Task Conversations — docs/TASK_CONVERSATIONS_PHASE0.md)

  /// Decoded conversation for a task; nil if the task is unknown.
  func conversation(id: String) -> TaskConvo? {
    fetch(id: id).map(\.conversation)
  }

  /// Append a turn (assigning its `seq`) and persist + sync. A `confirm`-step
  /// turn carrying a `chosen` also caches `confirmedIntent` in the SAME save —
  /// the richer `note` wins over the bare button label. Returns the seq.
  @discardableResult
  func appendConvoTurn(id: String, _ turn: ConvoTurn) -> Int {
    guard let entity = fetch(id: id) else { return 0 }
    var convo = entity.conversation
    var t = turn
    t.seq = convo.nextSeq
    convo.thread.append(t)
    if t.step == .confirm, let chosen = t.chosen {
      convo.confirmedIntent = t.note ?? chosen
    }
    entity.conversation = convo
    commitAndPush(entity, op: "convo.append")
    return t.seq
  }

  func setConvoAcceptance(id: String, _ line: String) {
    guard let entity = fetch(id: id) else { return }
    var convo = entity.conversation
    convo.acceptance = line
    entity.conversation = convo
    commitAndPush(entity, op: "convo.acceptance")
  }

  func setConvoEndState(id: String, _ state: ConvoEndState, note: String?) {
    guard let entity = fetch(id: id) else { return }
    var convo = entity.conversation
    convo.endState = state
    convo.endStateNote = note
    entity.conversation = convo
    commitAndPush(entity, op: "convo.endState")
  }

  func setConvoAssignee(id: String, _ assignee: ConvoAssignee?) {
    guard let entity = fetch(id: id) else { return }
    var convo = entity.conversation
    convo.assignee = assignee
    entity.conversation = convo
    commitAndPush(entity, op: "convo.assignee")
  }

  func setConvoArtifact(id: String, _ artifact: ConvoArtifact) {
    guard let entity = fetch(id: id) else { return }
    var convo = entity.conversation
    convo.artifact = artifact
    entity.conversation = convo
    commitAndPush(entity, op: "convo.artifact")
  }

  func setConvoHandoff(id: String, _ handoff: ConvoHandoff) {
    guard let entity = fetch(id: id) else { return }
    var convo = entity.conversation
    convo.handoff = handoff
    entity.conversation = convo
    commitAndPush(entity, op: "convo.handoff")
  }

  /// Tasks awaiting reasoning: explicitly marked for Claude, OR whose last
  /// provider turn was low-confidence — and not yet terminal. Client-side
  /// filter (the CK schema is auto-managed; no server query on the blob).
  func pendingReasoning(limit: Int) -> [TaskEntity] {
    let all = (try? context.fetch(FetchDescriptor<TaskEntity>())) ?? []
    // Shared rule with the badge (deriveConvo) — see TaskConvo.isPendingReasoning().
    let pending = all.filter { $0.conversationJSON != nil && $0.conversation.isPendingReasoning() }
    return Array(pending.prefix(limit))
  }

  // MARK: Mutations

  @discardableResult
  func create(title: String, area: String?, project: String?,
              scheduled: Date?, due: Date?, today: Bool,
              notes: String?, status: String?,
              deferPush: Bool = false) -> SeptenaTask {
    let id = uniqueTaskID()
    let todayIso = SeptenaDate.today
    let effectiveArea = project != nil ? nil : area
    // New tasks land at the top of the list. An explicit position (synced)
    // rather than relying on the createdAt fallback, so other devices place
    // it at the top too instead of at the bottom (newest createdAt).
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
      position: TaskOrder.topPosition(in: context),
      pendingSync: true,
      source: TaskSource.app,            // positive provenance for app-authored rows
      sourceClient: currentAppClientLabel,
      createdAt: Date()
    )
    context.insert(entity)
    // deferPush is used for inline-editor drafts: skip the engine push
    // here so other devices don't briefly see "New To-Do" before the
    // user commits the real title. The first push happens via the
    // update() path when the user commits.
    if deferPush {
      do { try context.save() } catch { SeptenaLog.error("CK backend: context.save failed", error) }
      SeptenaLog.info("[CK] create(deferred) id=\(id) title=\"\(title)\" — engine push held until first update")
      NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    } else {
      commitAndPush(entity, op: "create")
    }
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

  /// Stamp `acknowledgedAt` so the agent-cue clears (and stays cleared on
  /// other devices via sync). No-op when there's nothing to acknowledge —
  /// not an agent row, or already seen — so engagement never churns writes.
  func acknowledge(id: String) {
    guard let entity = fetch(id: id) else { return }
    guard entity.source == TaskSource.mcp, entity.acknowledgedAt == nil else { return }
    entity.acknowledgedAt = Date()
    entity.pendingSync = true
    commitAndPush(entity, op: "acknowledge")
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
    // If this entity never made it to CloudKit (deferred-push draft
    // that the user cancelled), skip the engine call — there's no
    // server-side record to delete.
    let neverPushed = entity.cloudKitSystemFields == nil
    let staged = entity     // capture before we tell SwiftData to remove
    context.delete(entity)
    if neverPushed {
      do { try context.save() } catch { SeptenaLog.error("CK backend: context.save failed", error) }
      SeptenaLog.info("[CK] delete(local-only) id=\(id) — was never pushed, skipping engine")
      NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    } else {
      commitAndPush(staged, op: "delete", deletion: true)
    }
  }

  func moveToToday(id: String, today: Bool) {
    guard let entity = fetch(id: id) else { return }
    entity.today = today
    entity.todaySetOn = today ? SeptenaDate.today : nil
    entity.pendingSync = true
    commitAndPush(entity, op: "moveToToday(\(today))")
  }

  /// Drop a task off Today — the single source of truth for "remove from
  /// Today," shared by the context menu, the Next section, the ⌘T toggle, and
  /// the quick-edit sheet. Today membership is a *union* (pin OR scheduled≤today
  /// OR deadline≤today), so clearing the `today` flag alone often isn't enough:
  /// a task still anchored by a "When" date that has arrived would silently
  /// bounce right back into Today. So we also clear a `scheduled` date that's
  /// already landed — the soft planning signal the user is dismissing.
  ///
  /// A live deadline (`due ≤ today`) is intentionally left intact: it's a real
  /// commitment, so such a task stays in Today until the deadline itself is
  /// changed (same principle as `setDue`'s clear-pin behavior). Callers should
  /// label the affordance off `isOnToday`, not the raw `today` flag.
  func removeFromToday(id: String) {
    guard let entity = fetch(id: id) else { return }
    entity.today = false
    entity.todaySetOn = nil
    if let s = entity.scheduled, s <= SeptenaDate.today {
      entity.scheduled = nil
    }
    entity.pendingSync = true
    commitAndPush(entity, op: "removeFromToday")
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
    // Deadline is rendering-only (Things-style): the Today filter unions
    // `due <= today` rows at view time, so a deadline-today task already shows
    // in Today without mutating `today`. We intentionally do NOT auto-pin when
    // *setting* a deadline — pinning made inclusion sticky, so pushing the
    // deadline back out later left a stale row stranded in Today.
    //
    // Clearing the deadline is the exception. A due/overdue task that lived in
    // Today solely because of its deadline would silently vanish when you strip
    // the due date — which isn't what removing a date implies. So if the task
    // is in Today *only* because of this deadline (not pinned, no scheduled
    // date holding it there), pin it so it stays. The user can still un-Today
    // it explicitly. See `LocalCache.tasks(.today)`.
    if date == nil, !entity.today, entity.isOnToday,
       !(entity.scheduled.map { $0 <= SeptenaDate.today } ?? false) {
      entity.today = true
      entity.todaySetOn = SeptenaDate.today
    }
    entity.due = SeptenaDate.format(date)
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

  func reorder(id: String, toPosition position: Double) {
    guard let entity = fetch(id: id) else { return }
    entity.position = position
    entity.pendingSync = true
    commitAndPush(entity, op: "reorder")
  }
}
