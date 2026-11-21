import Foundation
import SwiftData

// CloudKit task store — CloudKit is the only path for task mutations.
//
// CKSyncEngine *is* the outbox — local mutation + `engine.noteTaskChange(id:)`
// is the whole story; the engine batches, retries, and resolves
// conflicts on its own.

// MARK: - CloudKit store

/// Seconds-precision timestamp for task completion state. Kept local because
/// task records intentionally use a display-friendly, stable string shape.
private let ckTimestampFormatter: DateFormatter = {
  let f = DateFormatter()
  f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
  f.locale = Locale(identifier: "en_US_POSIX")
  return f
}()
private func ckServerTimestamp() -> String { ckTimestampFormatter.string(from: Date()) }

/// Parse a `deletedAt` / `completedAt` stamp. Current writers use
/// `ckTimestampFormatter` (no zone); older rows and gateway writes may carry a
/// full ISO-8601 stamp, so that is the fallback.
private func parseTaskTimestamp(_ stamp: String) -> Date? {
  if let date = ckTimestampFormatter.date(from: stamp) { return date }
  let iso = ISO8601DateFormatter()
  if let date = iso.date(from: stamp) { return date }
  iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return iso.date(from: stamp)
}

/// Completion stamp on the app's clock rather than the system's. `complete`
/// computes the next occurrence from `DayClock.appToday`, and `uncomplete`
/// recomputes that occurrence's id from this stamp — if the two disagreed
/// under time travel, undo would look for a task that was never created.
/// Identical to `ckServerTimestamp()` in Release.
@MainActor
private func ckCompletionTimestamp() -> String {
  ckTimestampFormatter.string(from: DayClock.appNow)
}

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
final class CloudKitTasksBackend {
  private let engine: CKEngine
  private let context: ModelContext
  /// The `position` each recurring occurrence got when this process spawned
  /// it, keyed by occurrence id. `retractSpawnedOccurrence` reads it to tell a
  /// pristine occurrence from one the user dragged. In memory only: after a
  /// relaunch the position check is skipped and the other checks decide.
  private var spawnedPositions: [String: Double] = [:]

  init(engine: CKEngine, context: ModelContext) {
    self.engine = engine
    self.context = context
  }

  // MARK: Local helpers

  private func fetch(id: String) -> TaskEntity? {
    var descriptor = FetchDescriptor<TaskEntity>(
      predicate: #Predicate { $0.id == id }
    )
    descriptor.fetchLimit = 1   // point-lookup: stop at the first match, never materialize the whole table
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
  /// so views repaint. A save failure stops the push: `StoreHealth.save` rolls
  /// the context back, so the change no longer exists locally and must not be
  /// sent to CloudKit as if it did. The posted `TaskChange` makes the affected
  /// list reload and drop the phantom row.
  ///
  /// **Returns false when the write was rolled back**, and callers that then
  /// DESTROY something on the strength of the write having landed must check
  /// it. The inline-create flow is exactly that: a new row is born with an
  /// empty title, and the fold purges it when the store still shows no title.
  /// With the result discarded, a rolled-back title write made the row look
  /// untitled and the purge deleted the task the user had just typed — the
  /// "it sometimes just doesn't save" report. Most callers are plain field
  /// writes with nothing to undo, hence `@discardableResult`.
  @discardableResult
  private func commitAndPush(_ entity: TaskEntity, op: String, deletion: Bool = false) -> Bool {
    let id = entity.id
    let title = entity.title
    // An open task that left Today gives up its Today slot (#66), whichever
    // write moved it out, so it comes back at its list position next time
    // instead of at a stale slot. Done / cancelled rows keep it: reopening
    // puts the row back where it stood.
    if !deletion, entity.todayPosition != nil, entity.status == .open, !entity.isOnToday {
      entity.todayPosition = nil
    }
    // Read id/title BEFORE the save: on the purge path `entity` is already
    // marked deleted, and a deleted model's properties are only readable while
    // the deletion is still pending in the context.
    guard StoreHealth.save(context, op: op) else {
      SeptenaLog.error("[CK] \(op) id=\(id) NOT pushed — local save failed and rolled back")
      TaskChange.post(id)
      return false
    }
    if deletion {
      engine.noteTaskDeletion(id: id)
      SeptenaLog.info("[CK] \(op) id=\(id) title=\"\(title)\" → engine.noteTaskDeletion")
    } else {
      engine.noteTaskChange(id: id)
      SeptenaLog.info("[CK] \(op) id=\(id) title=\"\(title)\" → engine.noteTaskChange")
    }
    TaskChange.post(id)
    return true
  }

  /// Inserts the next instance as a complete, recurring TaskEntity in one
  /// local save. The deterministic id makes this safe when two surfaces
  /// complete the same source row close together.
  @discardableResult
  private func createRecurringOccurrence(from entity: TaskEntity,
                                         recurrence: Recurrence,
                                         scheduled: String) -> Bool {
    let id = Recurrence.occurrenceID(sourceTaskID: entity.id, scheduled: scheduled)
    guard fetch(id: id) == nil else {
      SeptenaLog.info("[CK] recurrence.create id=\(id) already exists — idempotent no-op")
      return false
    }

    let next = TaskEntity(
      id: id,
      title: entity.title,
      statusRaw: TaskStatus.open.rawValue,
      created: DayClock.appToday,
      scheduled: scheduled,
      // A deadline belongs to the completed occurrence. The generated task
      // gets its next scheduled date instead of inheriting an expired deadline.
      deadline: nil,
      today: false,
      todaySetOn: nil,
      completedAt: nil,
      area: entity.area,
      project: entity.project,
      notes: entity.notes,
      // Conversation turns belong to the completed occurrence; the new
      // occurrence starts with a clean thread.
      conversationJSON: nil,
      recurrenceUnit: recurrence.unit.rawValue,
      recurrenceInterval: recurrence.interval,
      recurrenceAfterCompletion: recurrence.afterCompletion,
      recurrencePaused: false,
      recurrenceSeriesID: entity.recurrenceSeriesID ?? entity.id,
      recurrenceAnchorDate: recurrence.afterCompletion ? nil : scheduled,
      position: TaskOrder.topPosition(in: context),
      pendingSync: true,
      source: entity.source,
      sourceClient: entity.sourceClient,
      // Completing an agent-authored row is engagement with the recurring
      // task, so the next occurrence should not immediately show a fresh cue.
      acknowledgedAt: entity.source == TaskSource.mcp ? Date() : entity.acknowledgedAt,
      createdAt: Date(),
      kind: entity.kind,
      heading: entity.heading
    )
    context.insert(next)
    spawnedPositions[id] = next.position
    commitAndPush(next, op: "recurrence.create")
    return true
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

  /// Stops (or resumes) agent work on a task. Resuming also hands the task
  /// back to Claude, since that is the only reason to resume.
  func setConvoStopped(id: String, _ stopped: Bool) {
    guard let entity = fetch(id: id) else { return }
    var convo = entity.conversation
    convo.stoppedAt = stopped ? Date() : nil
    if !stopped { convo.assignee = .claude }
    entity.conversation = convo
    commitAndPush(entity, op: stopped ? "convo.stop" : "convo.resume")
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
    // Recently-Deleted rows never count toward the pending-reasoning queue/badge.
    let pending = all.filter { $0.deletedAt == nil && !$0.pendingDeletion
                               && $0.conversationJSON != nil && $0.conversation.isPendingReasoning() }
    return Array(pending.prefix(limit))
  }

  // MARK: Mutations

  @discardableResult
  func create(title: String, area: String?, project: String?,
              scheduled: Date?, deadline: Date?, today: Bool,
              notes: String?, source: String = TaskSource.app,
              acknowledged: Bool = false,
              deferPush: Bool = false,
              atBottom: Bool = false) -> SeptenaTask {
    let id = uniqueTaskID()
    let todayIso = SeptenaDate.today
    let effectiveArea = project != nil ? nil : area
    // Trim at the write boundary so every caller (Siri dictation, MCP, Reminders
    // import — none of which trim) is self-defending against stray whitespace.
    // Trim-only, never reject empty: deferred inline-editor drafts are created
    // with an empty title on purpose and get their real title on first update.
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    // An explicit position (synced) rather than relying on the createdAt
    // fallback. App/MCP captures default to the top; the Tasks foot quick-add
    // passes `atBottom` so inline captures land above the "New task" row.
    let position = atBottom
      ? TaskOrder.bottomPosition(in: context)
      : TaskOrder.topPosition(in: context)
    // One instant for both stamps so a committed MCP create is a single
    // CloudKit write — a follow-up `acknowledge` would flash the row through
    // Inbox on sibling apps (Septask) before yanking it. Spec: solicited mcp
    // tasks are born already-acknowledged (`docs/TASK_ROW_LANGUAGE_SPEC.md`).
    let now = Date()
    let entity = TaskEntity(
      id: id,
      title: trimmedTitle,
      statusRaw: TaskStatus.open.rawValue,
      created: todayIso,
      scheduled: SeptenaDate.format(scheduled),
      deadline: SeptenaDate.format(deadline),
      today: today,
      todaySetOn: today ? todayIso : nil,
      area: effectiveArea,
      project: project,
      notes: (notes?.isEmpty == false) ? notes : nil,
      position: position,
      pendingSync: true,
      source: source,                    // "app" (native) or "mcp" (agent proposal)
      // Mirror the gateway's label for agent rows so MCP-authored tasks read as
      // "Claude" regardless of which surface (gateway / local server) wrote them.
      sourceClient: source == TaskSource.mcp ? "Claude" : currentAppClientLabel,
      acknowledgedAt: acknowledged ? now : nil,
      createdAt: now
    )
    context.insert(entity)
    // deferPush is used for inline-editor drafts: skip the engine push
    // here so other devices don't briefly see "New To-Do" before the
    // user commits the real title. The first push happens via the
    // update() path when the user commits.
    if deferPush {
      StoreHealth.save(context, op: "create(deferred)")
      SeptenaLog.info("[CK] create(deferred) id=\(id) title=\"\(trimmedTitle)\" — engine push held until first update")
      TaskChange.post(id)
    } else {
      commitAndPush(entity, op: "create")
    }
    return SeptenaTask(entity)
  }

  /// False when the title/notes write did NOT land — either the row is gone
  /// from the local store, or the save was rolled back. The inline-create fold
  /// reads this before purging an apparently-untitled new row.
  @discardableResult
  func update(id: String, title: String?, notes: String?) -> Bool {
    guard let entity = fetch(id: id) else {
      SeptenaLog.info("[CK] update id=\(id) → MISS (no local entity)")
      return false
    }
    if let title { entity.title = title }
    if let notes { entity.notes = notes.isEmpty ? nil : notes }
    entity.pendingSync = true
    return commitAndPush(entity, op: "update")
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

  /// Undo a peek/select ack — restore the proposal glow and (under the
  /// pre-fix band predicate) Inbox membership. No-op when there's nothing
  /// to clear.
  func unacknowledge(id: String) {
    guard let entity = fetch(id: id) else { return }
    guard entity.source == TaskSource.mcp, entity.acknowledgedAt != nil else { return }
    entity.acknowledgedAt = nil
    entity.pendingSync = true
    commitAndPush(entity, op: "unacknowledge")
  }

  func complete(id: String) {
    guard let entity = fetch(id: id) else { return }
    // Completion can arrive twice (e.g. an optimistic phone tap followed by a
    // watch write). Never spawn a second occurrence from an already-terminal
    // source row.
    guard entity.status == .open else { return }
    let recurrence = entity.recurrence
    // `appToday`, not `SeptenaDate.today`: the next occurrence must be computed
    // against the day the user is actually looking at, so time travel can
    // exercise a repeat rule. In Release the two are identical.
    let nextDate = entity.recurrencePaused ? nil : recurrence?.nextDate(
      completedOn: DayClock.appToday,
      scheduled: entity.scheduled,
      logicalScheduled: entity.recurrenceAnchorDate
    )
    entity.statusRaw = TaskStatus.done.rawValue
    entity.completedAt = ckCompletionTimestamp()
    // Do NOT clear `today` (or `scheduled`/`deadline`): every visibility test
    // (`isOnToday`, `isInTriageBand`) and every count site already gate on
    // `status == .open`, so a done task is invisible regardless of the pin.
    // Clearing it here was pure data loss — reopening (`uncomplete`) had no way
    // to restore the placement, so a completed-then-reopened task pinned to
    // Today (or filed only in a project) silently vanished from every surface.
    // Keeping the flag means uncomplete returns the task exactly where it was.
    entity.pendingSync = true
    commitAndPush(entity, op: "complete")
    if let recurrence, let nextDate {
      createRecurringOccurrence(from: entity, recurrence: recurrence, scheduled: nextDate)
    } else if recurrence != nil {
      SeptenaLog.error("[CK] complete id=\(id) could not calculate next recurrence", nil)
    }
  }

  func uncomplete(id: String) {
    guard let entity = fetch(id: id) else { return }
    // Completing a recurring task spawns the next occurrence, so undoing the
    // completion has to take that occurrence back — otherwise one mis-tap
    // (or the undo button right beside it) permanently leaves TWO open rows:
    // the restored source AND the generated instance, both recurring.
    if let recurrence = entity.recurrence,
       !entity.recurrencePaused,
       let completedAt = entity.completedAt {
      retractSpawnedOccurrence(source: entity,
                               recurrence: recurrence,
                               completedOn: String(completedAt.prefix(10)))
    }
    entity.statusRaw = TaskStatus.open.rawValue
    entity.completedAt = nil
    entity.pendingSync = true
    commitAndPush(entity, op: "uncomplete")
  }

  /// Removes the occurrence `complete` generated for this source — but only
  /// while it is still pristine. Once the generated instance has been edited,
  /// completed, or talked to, it is the user's data and an undo on the source
  /// must not destroy it; the deterministic id means we can find it exactly,
  /// so a skip here is a conscious no-op rather than a guess.
  private func retractSpawnedOccurrence(source: TaskEntity,
                                        recurrence: Recurrence,
                                        completedOn: String) {
    guard let scheduled = recurrence.nextDate(completedOn: completedOn,
                                              scheduled: source.scheduled,
                                              logicalScheduled: source.recurrenceAnchorDate) else { return }
    let spawnedID = Recurrence.occurrenceID(sourceTaskID: source.id, scheduled: scheduled)
    guard let spawned = fetch(id: spawnedID) else { return }
    // Every field `createRecurringOccurrence` set must still hold its spawned
    // value. A Today pin, a deadline, a move, a section or a drag is the user
    // working with the row, so the row is theirs and stays.
    let positionUntouched = spawnedPositions[spawnedID].map { $0 == spawned.position } ?? true
    let untouched = spawned.status == .open
      && spawned.completedAt == nil
      && spawned.deletedAt == nil
      && !spawned.pendingDeletion
      && spawned.conversationJSON == nil
      && spawned.scheduled == scheduled
      && spawned.title == source.title
      && spawned.notes == source.notes
      && !spawned.today
      && spawned.deadline == nil
      && spawned.area == source.area
      && spawned.project == source.project
      && spawned.heading == source.heading
      && positionUntouched
    guard untouched else {
      SeptenaLog.info("[CK] uncomplete id=\(source.id) — occurrence \(spawnedID) was touched, keeping it")
      return
    }
    spawnedPositions[spawnedID] = nil
    purge(id: spawnedID)
  }

  func cancel(id: String) {
    guard let entity = fetch(id: id) else { return }
    // Cancelling one instance of a repeat is "skip this one", not "end the
    // series", so an OPEN source spawns its next occurrence exactly like
    // `complete` does (same deterministic id, so a later complete or catch-up
    // no-ops). A row that is already done or cancelled spawned its successor
    // when it closed; it only changes status here.
    let wasOpen = entity.status == .open
    let recurrence = wasOpen ? entity.recurrence : nil
    let nextDate = (recurrence == nil || entity.recurrencePaused) ? nil : recurrence?.nextDate(
      completedOn: DayClock.appToday,
      scheduled: entity.scheduled,
      logicalScheduled: entity.recurrenceAnchorDate
    )
    entity.statusRaw = TaskStatus.cancelled.rawValue
    // The app's clock, same as `complete`: un-cancel goes through `uncomplete`,
    // which recomputes the spawned occurrence id from this stamp. A closed row
    // keeps its original stamp so that recomputation still finds its successor.
    if wasOpen || entity.completedAt == nil {
      entity.completedAt = ckCompletionTimestamp()
    }
    // Same as `complete`: the status guard hides a cancelled task everywhere, so
    // clearing the pin would only lose placement on a future un-cancel.
    entity.pendingSync = true
    commitAndPush(entity, op: "cancel")
    if let recurrence, let nextDate {
      createRecurringOccurrence(from: entity, recurrence: recurrence, scheduled: nextDate)
    } else if recurrence != nil, !entity.recurrencePaused {
      SeptenaLog.error("[CK] cancel id=\(id) could not calculate next recurrence", nil)
    }
  }

  /// Soft-delete: move the task to Recently Deleted (Apple Reminders model,
  /// docs/RECENTLY_DELETED_SPEC.md). We stamp `deletedAt` and push a record
  /// UPDATE — the CloudKit record survives, the row is hidden everywhere
  /// (every read path filters `deletedAt != nil`), and it stays recoverable via
  /// `restore` until `purge` (30-day auto-purge or "Delete Permanently") removes
  /// it for good. This replaces the old hard-delete, which destroyed the record
  /// with no confirmation and no undo.
  ///
  /// ALWAYS a soft delete, also for a row that never reached CloudKit: a
  /// hard purge here left `restore` (undo, Recently Deleted) nothing to bring
  /// back. A surface that wants a blank draft gone for good calls `purge`.
  /// A row with no server record and no queued save stays local: there is
  /// nothing on the server to mark, and `restore` queues it as a normal create.
  func delete(id: String) {
    guard let entity = fetch(id: id) else { return }
    // Deleting a heading dissolves it: members are re-parented to the un-headed
    // block first (their tasks survive), then the divider row itself trashes.
    if entity.isHeading {
      dissolveHeadingMembers(headingID: id)
    }
    entity.deletedAt = ckServerTimestamp()
    if engine.taskNeverSynced(id: id, systemFields: entity.cloudKitSystemFields), !engine.hasPendingTaskSave(id: id) {
      guard StoreHealth.save(context, op: "delete(soft, local-only)") else {
        SeptenaLog.error("[CK] delete(soft, local-only) id=\(id) — local save failed and rolled back")
        TaskChange.post(id)
        return
      }
      SeptenaLog.info("[CK] delete(soft, local-only) id=\(id) — never pushed, engine untouched")
      TaskChange.post(id)
      return
    }
    commitAndPush(entity, op: "delete(soft)")
  }

  /// Bring a task back from Recently Deleted: clear the marker, push the update.
  /// A row that `delete` kept local-only has no server record yet, so this
  /// push reaches CloudKit as an ordinary create.
  ///
  /// Never back to a dangling id: when its project / area no longer exists
  /// (deleted with the task, and not brought back), the task returns to the
  /// Inbox (`TaskInbox`); a `heading` whose row is gone or still in Recently
  /// Deleted is cleared. The delete undo revives the container (and the
  /// headings) BEFORE it restores the tasks, so it keeps their filing.
  func restore(id: String) {
    guard let entity = fetch(id: id) else { return }
    if let project = entity.project, !projectExists(project) {
      entity.project = nil
      entity.heading = nil
    }
    if let area = entity.area, !areaExists(area) {
      entity.area = nil
    }
    if let heading = entity.heading, !liveHeadingExists(heading) {
      entity.heading = nil
    }
    entity.deletedAt = nil
    entity.pendingSync = true
    commitAndPush(entity, op: "restore")
  }

  private func projectExists(_ id: String) -> Bool {
    ((try? context.fetchCount(FetchDescriptor<ProjectEntity>(
      predicate: #Predicate { $0.id == id }
    ))) ?? 0) > 0
  }

  private func areaExists(_ id: String) -> Bool {
    ((try? context.fetchCount(FetchDescriptor<AreaEntity>(
      predicate: #Predicate { $0.id == id }
    ))) ?? 0) > 0
  }

  private func liveHeadingExists(_ id: String) -> Bool {
    ((try? context.fetchCount(FetchDescriptor<TaskEntity>(
      predicate: #Predicate { $0.id == id && $0.deletedAt == nil }
    ))) ?? 0) > 0
  }

  /// Permanently destroy a task — the old hard-delete, now reachable only from
  /// "Delete Permanently" and the 30-day auto-purge. CKSyncEngine deletes are
  /// durable and retried until success; an offline purge drains on reconnect.
  func purge(id: String) {
    guard let entity = fetch(id: id) else { return }
    purgeAttachments(taskID: id)
    let neverPushed = engine.taskNeverSynced(id: id, systemFields: entity.cloudKitSystemFields)
    let staged = entity     // capture before we tell SwiftData to remove
    context.delete(entity)
    if neverPushed {
      StoreHealth.save(context, op: "purge(local-only)")
      SeptenaLog.info("[CK] purge(local-only) id=\(id) — was never pushed, skipping engine")
      TaskChange.post(id)
    } else {
      commitAndPush(staged, op: "purge", deletion: true)
    }
  }

  private func purgeAttachments(taskID: String) {
    let rows = ((try? context.fetch(FetchDescriptor<TaskAttachmentEntity>())) ?? [])
      .filter { $0.taskID == taskID }
    for attachment in rows {
      if let url = TaskAttachmentFiles.url(for: attachment) { try? FileManager.default.removeItem(at: url) }
      context.delete(attachment)
      engine.noteTaskAttachmentDeletion(id: attachment.id)
    }
  }

  /// 30-day auto-purge: permanently delete all Recently Deleted tasks whose
  /// `deletedAt` timestamp is older than `cutoff` (docs/RECENTLY_DELETED_SPEC.md).
  func purgeExpired(before cutoff: Date) {
    let rows = (try? context.fetch(FetchDescriptor<TaskEntity>(
      predicate: #Predicate { $0.deletedAt != nil }
    ))) ?? []
    // Collect ids first: `purge` deletes models, so the loop must not read a
    // row after an earlier purge in the same pass touched the context.
    let expired = rows.compactMap { e -> String? in
      guard let stamp = e.deletedAt,
            let date = parseTaskTimestamp(stamp),
            date < cutoff else { return nil }
      return e.id
    }
    var purged = 0
    for id in expired {
      purge(id: id)
      purged += 1
    }
    if purged > 0 {
      SeptenaLog.info("[CK] purgeExpired: removed \(purged) task(s) older than 30d")
    }
  }

  func moveToToday(id: String, today: Bool) {
    guard let entity = fetch(id: id) else { return }
    // Already in that state: change nothing. A re-pin used to re-stamp
    // `todaySetOn`, so undoing a move (`TaskUndo.restore`, which always
    // writes Today) reset the row's Today tenure to zero.
    if entity.today == today, !today || entity.todaySetOn != nil { return }
    entity.today = today
    entity.todaySetOn = today ? SeptenaDate.today : nil
    entity.pendingSync = true
    commitAndPush(entity, op: "moveToToday(\(today))")
  }

  /// Drop a task off Today — the single source of truth for "remove from
  /// Today," shared by the context menu, the Next section, the ⌘T toggle, and
  /// the quick-edit sheet. Today membership is a *union* (pin OR scheduled≤today
  /// OR deadline≤today), so clearing the `today` flag alone often isn't enough:
  /// a task still anchored by a date that has arrived would silently bounce
  /// right back into Today. So we also clear any `scheduled` or `deadline`
  /// date that's already landed — the user explicitly dismissed the row from
  /// Today, and the menu labels off `isOnToday`, not the raw pin.
  func removeFromToday(id: String) {
    guard let entity = fetch(id: id) else { return }
    entity.today = false
    entity.todaySetOn = nil
    if let s = entity.scheduled, s <= SeptenaDate.today {
      entity.scheduled = nil
    }
    if let d = entity.deadline, d <= SeptenaDate.today {
      entity.deadline = nil
    }
    entity.pendingSync = true
    commitAndPush(entity, op: "removeFromToday")
  }

  func schedule(id: String, date: Date?) {
    // The historical API remains a safe default for every caller that does
    // not present a Things-style fixed-rule choice: move only this visible
    // occurrence and preserve its logical cadence slot.
    reschedule(id: id, date: date, mode: .makeException)
  }

  /// Move a repeating task with an explicit fixed-schedule policy. Completion-
  /// based rules always behave like a normal move, so the mode is ignored for
  /// them. Keeping this decision in the backend makes iOS, macOS, and future
  /// watch editing paths converge on the same state transition.
  func reschedule(id: String, date: Date?, mode: RecurrenceRescheduleMode) {
    guard let entity = fetch(id: id) else { return }
    guard let rule = entity.recurrence, !rule.afterCompletion else {
      entity.scheduled = SeptenaDate.format(date)
      entity.pendingSync = true
      commitAndPush(entity, op: "reschedule(completion)")
      return
    }

    let displayed = SeptenaDate.format(date)
    guard mode == .updateRule else {
      // Keep recurrenceAnchorDate untouched. That is the entire exception
      // invariant: the row moves, but its next completion still advances from
      // the original series slot.
      entity.scheduled = displayed
      entity.pendingSync = true
      commitAndPush(entity, op: "reschedule(exception)")
      return
    }

    updateFixedSeries(from: entity, rule: rule, newDisplayedDate: displayed)
  }

  /// Rebase every open copy in a series in one deterministic order. Normally
  /// there is only one open copy, but the operation also handles early-created
  /// copies so updating a rule cannot leave a split-brain future schedule.
  private func updateFixedSeries(from entity: TaskEntity,
                                 rule: Recurrence,
                                 newDisplayedDate: String?) {
    let seriesID = entity.recurrenceSeriesID ?? entity.id
    let openMembers = seriesMembers(seriesID: seriesID)
      .filter { $0.status == .open }
      .sorted {
        let a = $0.recurrenceAnchorDate ?? $0.scheduled ?? "9999-12-31"
        let b = $1.recurrenceAnchorDate ?? $1.scheduled ?? "9999-12-31"
        return a != b ? a < b : $0.id < $1.id
      }

    let newAnchor = newDisplayedDate ?? DayClock.appToday
    var ordered = openMembers.filter { $0.id != entity.id }
    ordered.insert(entity, at: 0)

    var cursor = newAnchor
    for member in ordered {
      member.recurrenceSeriesID = seriesID
      member.recurrence = rule
      member.recurrenceAnchorDate = cursor
      member.scheduled = member.id == entity.id ? newDisplayedDate : cursor
      member.pendingSync = true
      commitAndPush(member, op: "reschedule(rule)")

      guard let next = rule.nextDate(completedOn: cursor,
                                     scheduled: cursor,
                                     logicalScheduled: cursor) else { break }
      cursor = next
    }
  }

  /// Create the next open copy without completing the current task. This is
  /// intentionally idempotent: completing the source later asks for the same
  /// deterministic occurrence id and becomes a no-op instead of duplicating.
  @discardableResult
  func createNextOccurrence(id: String) -> SeptenaTask? {
    guard let entity = fetch(id: id), entity.status == .open,
          let recurrence = entity.recurrence,
          let nextDate = recurrence.nextDate(
            completedOn: DayClock.appToday,
            scheduled: entity.scheduled,
            logicalScheduled: entity.recurrenceAnchorDate
          ) else { return nil }
    createRecurringOccurrence(from: entity, recurrence: recurrence, scheduled: nextDate)
    return fetch(id: Recurrence.occurrenceID(sourceTaskID: entity.id,
                                             scheduled: nextDate)).map(SeptenaTask.init)
  }

  // MARK: Fixed-schedule catch-up

  /// How many missed occurrences ONE run will materialize for a single
  /// series. Past this the series is dormant rather than merely late, and
  /// back-filling it is noise: a weekly task untouched since spring should
  /// put *this* week's copy on the list, not forty stale ones.
  private static let maxCatchUp = 8

  /// Guard rail on the cadence walk — a corrupt anchor date must not spin.
  /// Ten years of a daily rule still fits well inside it.
  private static let catchUpWalkLimit = 5_000

  /// Materialize the fixed-schedule occurrences whose day has already come.
  ///
  /// A completion-based rule genuinely has nothing to do until you tick the
  /// box — its next date is anchored to the tick. A FIXED one is a promise
  /// about dates: "every Friday" means a Friday task exists on Friday whether
  /// or not last Friday's got done. Until this ran, `complete` was the only
  /// thing in the app that ever advanced a series, so an uncompleted fixed
  /// repeat froze on ONE perpetually-overdue row and looked like a repeat
  /// that had stopped working.
  ///
  /// The overdue rows are left exactly where they are — unfinished work is
  /// still the user's, and rescheduling it would erase the fact that it was
  /// missed. Catch-up only adds the copies that should already exist.
  ///
  /// Idempotent by construction: every occurrence id is derived from
  /// (source id, scheduled date), so a second run — or a second device, or a
  /// later `complete` on the same source — asks for ids that already exist
  /// and no-ops. Safe to call on every launch, foreground, and day rollover,
  /// which is exactly how it is wired.
  /// `today` defaults to `DayClock.appToday` — resolved in the body, not as a
  /// default argument, because a default-argument expression is evaluated
  /// nonisolated and `appToday` is main-actor state.
  @discardableResult
  func catchUpFixedSchedules(today explicitToday: String? = nil) -> Int {
    let today = explicitToday ?? DayClock.appToday
    let descriptor = FetchDescriptor<TaskEntity>(
      predicate: #Predicate { $0.recurrenceUnit != nil }
    )
    let candidates = ((try? context.fetch(descriptor)) ?? []).filter {
      $0.status == .open
        && !$0.recurrencePaused
        && !$0.isHeading
        && $0.deletedAt == nil
        && !$0.pendingDeletion
        && $0.recurrence?.afterCompletion == false
    }
    guard !candidates.isEmpty else { return 0 }

    // One head per series: the open copy holding the LATEST logical slot.
    // Walking from anywhere else would re-create copies the series already
    // has. Ties break on id so two devices pick the same head and therefore
    // derive the same occurrence ids.
    var heads: [String: TaskEntity] = [:]
    for task in candidates {
      guard let slot = task.recurrenceAnchorDate ?? task.scheduled else { continue }
      let seriesID = task.recurrenceSeriesID ?? task.id
      guard let held = heads[seriesID] else { heads[seriesID] = task; continue }
      let heldSlot = held.recurrenceAnchorDate ?? held.scheduled ?? ""
      if slot > heldSlot || (slot == heldSlot && task.id > held.id) { heads[seriesID] = task }
    }

    var created = 0
    for head in heads.values.sorted(by: { $0.id < $1.id }) {
      created += catchUp(head: head, today: today)
    }
    if created > 0 {
      SeptenaLog.info("[CK] recurrence.catchUp created \(created) occurrence(s) through \(today)")
    }
    return created
  }

  /// Walk one series' cadence from its head to today, creating what is
  /// missing. Every copy is made FROM THE HEAD rather than chained off the
  /// previous copy: the ids stay deterministic either way, but deriving them
  /// all from one row means a device that starts the walk late lands on the
  /// same ids as one that ran every day.
  private func catchUp(head: TaskEntity, today: String) -> Int {
    guard let rule = head.recurrence,
          // The series' LOGICAL slot, not the visible date — a one-off
          // exception moved the row, it did not move the cadence.
          let start = head.recurrenceAnchorDate ?? head.scheduled,
          start < today else { return 0 }

    var slots: [String] = []
    var cursor = start
    var steps = 0
    while steps < Self.catchUpWalkLimit {
      steps += 1
      guard let next = rule.nextDate(completedOn: cursor, scheduled: cursor,
                                     logicalScheduled: cursor),
            next > cursor else { break }
      if next > today { break }
      slots.append(next)
      cursor = next
    }
    guard let latest = slots.last else { return 0 }

    if slots.count > Self.maxCatchUp {
      // Say what was dropped. A silent truncation here reads as "the repeat
      // is broken again" the next time someone counts the rows.
      SeptenaLog.info("""
        [CK] recurrence.catchUp id=\(head.id) dormant since \(start) — \
        materializing \(latest) only, skipping \(slots.count - 1) missed slot(s)
        """)
      slots = [latest]
    }

    var created = 0
    for slot in slots where createRecurringOccurrence(from: head, recurrence: rule,
                                                      scheduled: slot) {
      created += 1
    }
    return created
  }

  func setDeadline(id: String, date: Date?) {
    guard let entity = fetch(id: id) else { return }
    // Deadline is rendering-only (Things-style): the Today filter unions
    // `due <= today` rows at view time, so a deadline-today task already shows
    // in Today without mutating `today`. We do NOT auto-pin merely because a
    // deadline lands *on* Today — the deadline itself carries it there, and
    // pinning made inclusion sticky (a later push-out then stranded the row).
    //
    // But a row already living on Today must not silently vanish just because
    // you *change* its deadline. If the task is in Today *only* because of its
    // (old) deadline — not pinned, no scheduled date holding it there — and the
    // new deadline no longer places it on Today (cleared, or moved to a future
    // day), pin it so it stays. Re-dating a due-today row to tomorrow keeps it
    // in Today; the user can still un-Today it explicitly. See
    // `LocalCache.tasks(.today)`.
    let heldByScheduled = entity.scheduled.map { $0 <= SeptenaDate.today } ?? false
    let newDeadlineOnToday = SeptenaDate.format(date).map { $0 <= SeptenaDate.today } ?? false
    if !entity.today, entity.isOnToday, !heldByScheduled, !newDeadlineOnToday {
      entity.today = true
      entity.todaySetOn = SeptenaDate.today
    }
    entity.deadline = SeptenaDate.format(date)
    entity.pendingSync = true
    commitAndPush(entity, op: "setDeadline")
  }

  func setRecurrence(id: String, recurrence: Recurrence?) {
    guard let entity = fetch(id: id) else { return }
    let seriesID = entity.recurrenceSeriesID ?? entity.id
    let members = seriesMembers(seriesID: seriesID)

    guard let recurrence else {
      // Stopping repetition is a series operation. Clear every member,
      // including completed sources, so reopening an old copy cannot resurrect
      // a recurrence after the user explicitly chose "Don't Repeat".
      let targets = members.isEmpty ? [entity] : members
      for member in targets {
        member.recurrence = nil
        member.recurrencePaused = false
        member.pendingSync = true
        commitAndPush(member, op: "setRecurrence(nil)")
      }
      return
    }

    // The addressed row is ALWAYS a target. `members` filtered to open rows
    // alone, so setting a rule on a series whose only rows are finished — a
    // task edited from the Logbook, or the occurrence you just ticked — wrote
    // nothing at all and reported success.
    let targets = seriesTargets(entity: entity, members: members)
    for member in targets {
      member.recurrenceSeriesID = seriesID
      member.recurrence = recurrence
      member.recurrencePaused = false
      if recurrence.afterCompletion {
        member.recurrenceAnchorDate = nil
      } else if member.recurrenceAnchorDate == nil {
        member.recurrenceAnchorDate = member.scheduled
      }
      member.pendingSync = true
      commitAndPush(member, op: "setRecurrence")
    }
  }

  /// Pause or resume every open copy in a repeating series. The rule remains
  /// intact while paused, so resuming does not lose the cadence or create an
  /// immediate copy; the next completion advances normally.
  func setRecurrencePaused(id: String, paused: Bool) {
    guard let entity = fetch(id: id), entity.recurrence != nil else { return }
    let seriesID = entity.recurrenceSeriesID ?? entity.id
    let members = seriesMembers(seriesID: seriesID)
    let targets = seriesTargets(entity: entity, members: members)
    for member in targets {
      member.recurrencePaused = paused
      member.pendingSync = true
      commitAndPush(member, op: paused ? "recurrence.pause" : "recurrence.resume")
    }
  }

  /// The rows a series-wide rule edit writes to: every OPEN copy, plus the
  /// row the caller actually named — which may itself be finished. Editing a
  /// rule is a statement about the series, so it must never silently write to
  /// nothing.
  private func seriesTargets(entity: TaskEntity, members: [TaskEntity]) -> [TaskEntity] {
    var targets = members.filter { $0.status == .open && $0.id != entity.id }
    targets.insert(entity, at: 0)
    return targets
  }

  private func seriesMembers(seriesID: String) -> [TaskEntity] {
    let descriptor = FetchDescriptor<TaskEntity>(
      predicate: #Predicate { $0.recurrenceSeriesID == seriesID }
    )
    return (try? context.fetch(descriptor)) ?? []
  }

  func moveToArea(id: String, area: String?) {
    guard let entity = fetch(id: id) else { return }
    // Filing a triage-band row ratifies it — pin Today so it lands in the
    // committed list instead of vanishing off the Today surface (see
    // `TaskEntity.isInTriageBand`, docs/TRIAGE_BAND_SPEC.md).
    let ratifying = area != nil && entity.isInTriageBand
    // A re-home into a new home resets both order + membership axes together
    // (docs/DRAG_AND_DROP.md §4): entering an area clears the old project *and
    // its section FK*, and lands the row at the top of the destination — so
    // every re-home path (sidebar drag, "Move…" sheet, composer, MCP, which all
    // funnel through here) agrees, instead of leaving a stale `heading` and an
    // arbitrary sort spot. "New home" also covers leaving a project into an
    // area whose denormalized label already matched (hence the `project != nil`
    // clause); a bare re-drop onto the area a row already lives in is a no-op.
    let entersNewHome = area != nil && (entity.area != area || entity.project != nil)
    entity.area = area
    if area != nil { entity.project = nil }
    if entersNewHome, !entity.isHeading {
      entity.heading = nil
      entity.position = TaskOrder.topPosition(in: context)
    }
    if ratifying {
      entity.today = true
      entity.todaySetOn = SeptenaDate.today
    }
    entity.pendingSync = true
    commitAndPush(entity, op: "moveToArea")
  }

  /// Apply the final area/project placement as one mutation. The AppKit shell
  /// uses this for drag/menu moves so clearing the old axis and setting the new
  /// one do not become two saves and two app-wide notifications.
  func moveToList(id: String, area: String?, project: String?) {
    guard let entity = fetch(id: id) else { return }
    let targetArea = project == nil ? area : nil
    let ratifying = (targetArea != nil || project != nil) && entity.isInTriageBand
    // Any real change of list is a new home, the Inbox included: a task that
    // leaves a project for the Inbox must not keep that project's section FK.
    let entersNewHome = entity.area != targetArea || entity.project != project

    entity.area = targetArea
    entity.project = project
    if entersNewHome, !entity.isHeading {
      entity.heading = nil
      entity.position = TaskOrder.topPosition(in: context)
    }
    if ratifying {
      entity.today = true
      entity.todaySetOn = SeptenaDate.today
    }
    entity.pendingSync = true
    commitAndPush(entity, op: "moveToList")

    if entity.isHeading {
      rehomeHeadingMembers(headingID: id, toProject: project)
    }
  }

  func moveToProject(id: String, project: String?) {
    guard let entity = fetch(id: id) else { return }
    let ratifying = project != nil && entity.isInTriageBand
    // Ordinary tasks entering a project drop any stale section FK and land at
    // the top of the destination (docs/DRAG_AND_DROP.md §4) — headings are
    // exempt: they keep their own order and carry their section via
    // `rehomeHeadingMembers` below.
    let entersNewHome = project != nil && (entity.project != project || entity.area != nil)
    // Leaving a project (to the Inbox, or as the first half of an area move)
    // also leaves its sections: a heading FK only means something inside its
    // own project.
    let leavesProject = project == nil && entity.project != nil
    entity.project = project
    if project != nil { entity.area = nil }
    if entersNewHome, !entity.isHeading {
      entity.heading = nil
      entity.position = TaskOrder.topPosition(in: context)
    } else if leavesProject, !entity.isHeading {
      entity.heading = nil
    }
    if ratifying {
      entity.today = true
      entity.todaySetOn = SeptenaDate.today
    }
    entity.pendingSync = true
    commitAndPush(entity, op: "moveToProject")
    // A heading takes its section with it — re-home the members so they don't
    // strand in the old project (see `rehomeHeadingMembers`).
    if entity.isHeading {
      rehomeHeadingMembers(headingID: id, toProject: project)
    }
  }

  func reorder(id: String, toPosition position: Double) {
    guard let entity = fetch(id: id) else { return }
    entity.position = position
    entity.pendingSync = true
    commitAndPush(entity, op: "reorder")
  }

  /// Today's own order (#66). Writes `todayPosition` only, never `position`,
  /// so the task keeps its place in its area / project list. nil clears the
  /// slot (undo back to "never ordered on Today").
  func reorderToday(id: String, toPosition position: Double?) {
    guard let entity = fetch(id: id), entity.todayPosition != position else { return }
    entity.todayPosition = position
    entity.pendingSync = true
    commitAndPush(entity, op: "reorderToday")
  }

  // MARK: Fade clock (docs/TASK_FADE_SPEC.md §3)

  /// The ONE place `touchedAt` / `deferCount` are written. A user gesture
  /// stamps `touchedAt`; a defer also adds 1 to `deferCount`, and any other
  /// gesture resets it to 0. Local save only: the task backend has no column
  /// for these fields until the cutover, so there is nothing to push and no
  /// list to repaint (P1 has no UI). A failed save is logged by `StoreHealth`
  /// and loses only the stamp.
  func touch(ids: [String], deferredIDs: Set<String> = []) {
    var changed = false
    let now = Date()
    for id in ids {
      guard let entity = fetch(id: id), entity.deletedAt == nil else { continue }
      entity.touchedAt = now
      entity.deferCount = deferredIDs.contains(id) ? entity.deferCount + 1 : 0
      changed = true
    }
    if changed { StoreHealth.save(context, op: "touch") }
  }

  // MARK: Headings (project section dividers — docs/ORDERING_AND_HEADINGS_PLAN.md)

  /// Create a section-divider row inside a project. Modelled as a `TaskEntity`
  /// with `kind == "heading"` so it inherits sync / `position` order / drag for
  /// free, but it's excluded from every task feed, count, and badge (see
  /// `TaskEntity.isHeading`). Appends to the foot of the project by default —
  /// "New heading" adds a fresh section at the bottom; pass `atTop` to prepend.
  @discardableResult
  func createHeading(title: String, project: String, atTop: Bool = false) -> SeptenaTask {
    let id = uniqueTaskID()
    let position = atTop
      ? TaskOrder.topPosition(in: context)
      : TaskOrder.bottomPosition(in: context)
    let entity = TaskEntity(
      id: id,
      title: title,
      statusRaw: TaskStatus.open.rawValue,
      created: SeptenaDate.today,
      project: project,
      position: position,
      pendingSync: true,
      source: TaskSource.app,
      sourceClient: currentAppClientLabel,
      createdAt: Date(),
      kind: TaskKind.heading
    )
    context.insert(entity)
    commitAndPush(entity, op: "createHeading")
    return SeptenaTask(entity)
  }

  /// File a task under a heading (`heading = headingID`) or out of one (`nil`).
  /// Membership is a plain FK — dragging the heading later moves only its own
  /// row; its members render beneath it wherever it lands, by construction.
  func setHeading(id: String, heading: String?) {
    guard let entity = fetch(id: id) else { return }
    entity.heading = heading
    entity.pendingSync = true
    commitAndPush(entity, op: "setHeading")
  }

  /// Re-parent every task filed under `headingID` back to the un-headed block
  /// (`heading = nil`). Used when a heading is deleted — the divider goes, the
  /// tasks stay (section-invariant spirit: deleting structure never deletes
  /// user data).
  private func dissolveHeadingMembers(headingID: String) {
    let members = (try? context.fetch(FetchDescriptor<TaskEntity>(
      predicate: #Predicate { $0.heading == headingID && $0.deletedAt == nil }
    ))) ?? []
    for m in members {
      m.heading = nil
      m.pendingSync = true
      commitAndPush(m, op: "dissolveHeading.member")
    }
  }

  /// A heading carries its section with it — when it moves to another project,
  /// re-home its members' `project` (and clear their `area`) so they stay
  /// beneath it in the new home.
  private func rehomeHeadingMembers(headingID: String, toProject project: String?) {
    let members = (try? context.fetch(FetchDescriptor<TaskEntity>(
      predicate: #Predicate { $0.heading == headingID && $0.deletedAt == nil }
    ))) ?? []
    for m in members {
      m.project = project
      if project != nil { m.area = nil }
      m.pendingSync = true
      commitAndPush(m, op: "moveHeading.member")
    }
  }
}
