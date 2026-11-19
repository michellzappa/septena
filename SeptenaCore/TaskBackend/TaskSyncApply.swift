import Foundation
import SwiftData

// Pull side of `TaskSyncEngine` (docs/SEPTASK_BACKEND.md §6.2, §6.4, §6.5):
// writes backend rows into SwiftData directly. Nothing here calls CKEngine or
// a mutator, so an applied row queues no echo op. Rules:
//
//   - A field with a queued local upsert is not overwritten: local wins until
//     its push lands, and the next pull then carries the merged result.
//   - A row with a queued local delete is not touched.
//   - A tombstone soft-deletes a task (it goes to Recently Deleted, as a
//     CloudKit soft delete from another device does) and hard-deletes an
//     area, project or attachment (as a CloudKit record deletion does). Queued
//     ops for that row are dropped and reported: deleted stays deleted.
//   - Turns are append-only and ordered by the backend's `seq`.
//   - Attachment rows arrive without bytes; `TaskAttachmentStore.localFile`
//     downloads them when the attachment is opened.
//   - `todayPosition` is ignored on pull: the local model has no Today order
//     yet (§12).
//   - A `setting` row writes Septask's synced-settings blob
//     (TaskSyncSettings.swift), unless that key has a queued local upsert.

extension TaskSyncEngine {

  // MARK: - Pull

  func pull(store: TaskSyncStore) async throws {
    var cursor = since
    var pages = 0
    while isRunning {
      let page = try await client.pull(since: cursor)
      if page.resetRequired == true {
        try await resetAndRepull(store: store)
        return
      }
      guard applyPulled(page.changes, store: store) else {
        // The local save failed and rolled back: keep `since`, read the page again.
        throw TaskBackendError.badResponse("the local store could not save pulled rows")
      }
      if page.hasMore, page.nextSince <= cursor {
        throw TaskBackendError.badResponse("pull did not advance")
      }
      cursor = page.nextSince
      since = cursor   // only after the page was saved
      pages += 1
      if !page.hasMore { break }
      guard pages < 10_000 else { throw TaskBackendError.badResponse("pull did not finish") }
    }
    lastPull = Date()
  }

  /// `resetRequired`: this device's `since` is older than the backend's
  /// tombstone purge. Capture local edits not yet queued, wipe the task
  /// types here, pull from 0, then lay the queued ops back on top.
  private func resetAndRepull(store: TaskSyncStore) async throws {
    SeptenaLog.info("[TaskSync] resetRequired: wiping local task data and pulling from 0")
    reconcile(store: store)
    let context = main
    for t in (try? context.fetch(FetchDescriptor<TaskEntity>())) ?? [] { context.delete(t) }
    for a in (try? context.fetch(FetchDescriptor<AreaEntity>())) ?? [] { context.delete(a) }
    for p in (try? context.fetch(FetchDescriptor<ProjectEntity>())) ?? [] { context.delete(p) }
    // Attachment FILES stay on disk: re-pulled rows relink to them by id.
    for a in (try? context.fetch(FetchDescriptor<TaskAttachmentEntity>())) ?? [] { context.delete(a) }
    _ = StoreHealth.save(context, op: "taskSync.reset")
    store.deleteAllShadows()
    since = 0
    try await pull(store: store)   // from 0 the backend never asks for a reset
    overlayPendingOps(store: store)
    reconcile(store: store)
    NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    NotificationCenter.default.post(name: .septenaStructureChanged, object: nil)
  }

  /// After a reset: apply every queued upsert and turn to SwiftData, so the
  /// local state is again "backend + what this device has not sent yet".
  private func overlayPendingOps(store: TaskSyncStore) {
    var turnsByTask: [String: [[String: BackendJSON]]] = [:]
    for op in store.allOps() {
      let fields = TaskSyncJSON.decode(op.payload)
      switch (op.kind, BackendEntity(rawValue: op.opEntity)) {
      case (TaskSyncOpKind.upsert, .task?):
        let t = fetchTask(op.rowID) ?? { let n = TaskEntity(id: op.rowID, title: ""); main.insert(n); return n }()
        applyTaskFields(t, fields, skip: [])
      case (TaskSyncOpKind.upsert, .convo?):
        if let t = fetchTask(op.rowID) { applyConvoFields(t, fields, skip: []) }
      case (TaskSyncOpKind.upsert, .area?):
        let a = fetchArea(op.rowID) ?? { let n = AreaEntity(id: op.rowID, title: ""); main.insert(n); return n }()
        applyAreaFields(a, fields, skip: [])
      case (TaskSyncOpKind.upsert, .project?):
        let p = fetchProject(op.rowID) ?? { let n = ProjectEntity(id: op.rowID, title: ""); main.insert(n); return n }()
        applyProjectFields(p, fields, skip: [])
      case (TaskSyncOpKind.upsert, .attachment?):
        if let a = fetchAttachment(op.rowID) { applyAttachmentFields(a, fields, skip: []) }
        else if let taskID = fields["taskId"]?.stringValue {
          let n = TaskAttachmentEntity(id: op.rowID, taskID: taskID, filename: "Attachment",
                                       contentType: "application/octet-stream", byteCount: 0)
          main.insert(n)
          applyAttachmentFields(n, fields, skip: [])
        }
      case (TaskSyncOpKind.delete, .task?):
        if let t = fetchTask(op.rowID), t.deletedAt == nil { t.deletedAt = Self.localStamp(Date()) }
      case (TaskSyncOpKind.appendTurn, _):
        turnsByTask[op.rowID, default: []].append(fields)
      default:
        break
      }
    }
    for (taskID, turns) in turnsByTask {
      guard let t = fetchTask(taskID) else { continue }
      var convo = t.conversation
      for row in turns {
        if var turn = Self.convoTurn(from: row) {
          turn.seq = convo.nextSeq
          convo.thread.append(turn)
        }
      }
      t.conversation = convo
      let key = "turns:\(taskID)"
      let shadow = store.shadow(key)
      let old = shadow.map { TaskSyncJSON.decode($0.fields) } ?? Self.emptyTurnsShadow
      var new = old
      new["local"] = .int(Int64(convo.thread.count))
      writeShadow(shadow, key, old: old, new: new, store: store)
    }
    _ = StoreHealth.save(main, op: "taskSync.overlay")
  }

  // MARK: - Apply a page

  /// False when SwiftData could not save the page (it rolled back).
  @discardableResult
  func applyPulled(_ changes: [BackendPullChange], store: TaskSyncStore) -> Bool {
    guard !changes.isEmpty else { return true }

    // What this device still has queued.
    var pendingFields: [String: Set<String>] = [:]
    var pendingDelete: Set<String> = []
    for op in store.allOps() {
      let key = "\(op.opEntity):\(op.rowID)"
      switch op.kind {
      case TaskSyncOpKind.upsert: pendingFields[key, default: []].formUnion(TaskSyncJSON.decode(op.payload).keys)
      case TaskSyncOpKind.delete: pendingDelete.insert(key)
      default: break
      }
    }
    let shadows = store.allShadows()
    var touchedTasks = false
    var touchedStructure = false
    var deletedAreas = false
    var turnsByTask: [String: [[String: BackendJSON]]] = [:]
    var settings: AppSettings?

    for change in changes {
      if change.entity == .turn {
        if let taskID = change.row["taskId"]?.stringValue { turnsByTask[taskID, default: []].append(change.row) }
        continue
      }
      guard let id = change.row["id"]?.stringValue else {
        SeptenaLog.error("[TaskSync] pulled \(change.entity.rawValue) row without id; skipped")
        continue
      }
      let key = "\(change.entity.rawValue):\(id)"
      let tombstone = !(change.row["deletedAt"] ?? .null).isNull
      let skip = pendingFields[key] ?? []
      switch change.entity {
      case .task:
        applyTaskRow(id, change.row, tombstone: tombstone, skip: skip, pendingDelete: pendingDelete.contains(key),
                     shadow: shadows[key], store: store)
        touchedTasks = true
      case .convo:
        guard !tombstone, let t = fetchTask(id) else { continue }  // a convo dies with its task
        let applied = applyConvoFields(t, change.row, skip: skip)
        if case .success(.some(let (row, _))) = TaskBackendMapping.convo(taskID: id, json: t.conversationJSON) {
          recordApplied(key, applied: applied, mapped: row.fields, raw: change.row, shadow: shadows[key], store: store)
        }
        touchedTasks = true
      case .area:
        if tombstone {
          if let a = fetchArea(id) { main.delete(a) }
          DeletedAreaLedger.record(id)
          deletedAreas = true
          markGone(.area, id, shadow: shadows[key], store: store)
        } else if !pendingDelete.contains(key) {
          let a = fetchArea(id) ?? { let n = AreaEntity(id: id, title: ""); main.insert(n); return n }()
          let applied = applyAreaFields(a, change.row, skip: skip)
          let mapped = (try? TaskBackendMapping.area(a).get())?.fields ?? [:]
          recordApplied(key, applied: applied, mapped: mapped, raw: change.row, shadow: shadows[key], store: store)
        }
        touchedStructure = true
      case .project:
        if tombstone {
          if let p = fetchProject(id) { main.delete(p) }
          markGone(.project, id, shadow: shadows[key], store: store)
        } else if !pendingDelete.contains(key) {
          let p = fetchProject(id) ?? { let n = ProjectEntity(id: id, title: ""); main.insert(n); return n }()
          let applied = applyProjectFields(p, change.row, skip: skip)
          let mapped = (try? TaskBackendMapping.project(p).get())?.fields ?? [:]
          recordApplied(key, applied: applied, mapped: mapped, raw: change.row, shadow: shadows[key], store: store)
        }
        touchedStructure = true
      case .attachment:
        if tombstone {
          if let a = fetchAttachment(id) {
            if let url = TaskAttachmentFiles.url(for: a) { try? FileManager.default.removeItem(at: url) }
            main.delete(a)
          }
          markGone(.attachment, id, shadow: shadows[key], store: store)
        } else if !pendingDelete.contains(key) {
          let a = fetchAttachment(id) ?? {
            let n = TaskAttachmentEntity(id: id, taskID: change.row["taskId"]?.stringValue ?? "",
                                         filename: "Attachment", contentType: "application/octet-stream",
                                         byteCount: 0)
            main.insert(n)
            return n
          }()
          let applied = applyAttachmentFields(a, change.row, skip: skip)
          if a.localFilename == nil {
            // A file kept on disk through a reset: link it again.
            let name = TaskAttachmentFiles.ownedFilename(id: id, original: a.filename)
            if FileManager.default.fileExists(atPath: TaskAttachmentFiles.directory.appendingPathComponent(name).path) {
              a.localFilename = name
            }
          }
          let mapped = (try? TaskBackendMapping.attachment(a).get())?.row.fields ?? [:]
          recordApplied(key, applied: applied, mapped: mapped, raw: change.row, shadow: shadows[key], store: store)
        }
        touchedTasks = true
      case .setting:
        // Never deleted on the backend; a tombstone is ignored. Unknown keys
        // (a newer server) are ignored too.
        guard !tombstone, SeptaskSyncedSettings.keys.contains(id), !skip.contains("value"),
              let value = change.row["value"] else { continue }
        var s = settings ?? SeptaskSyncedSettings.current()
        guard SeptaskSyncedSettings.apply(id, value, to: &s) else {
          SeptenaLog.error("[TaskSync] pulled setting \(id) has the wrong shape; skipped")
          continue
        }
        settings = s
        recordApplied(key, applied: ["value"], mapped: ["value": value], raw: change.row,
                      shadow: shadows[key], store: store)
      case .turn:
        break
      }
    }
    for (taskID, rows) in turnsByTask {
      applyTurns(taskID: taskID, rows: rows, store: store)
      touchedTasks = true
    }

    guard StoreHealth.save(main, op: "taskSync.pull") else { return false }
    store.saveNow()
    if let settings {
      SeptaskSyncedSettings.write(settings)
      NotificationCenter.default.post(name: .septaskSettingsPulled, object: nil)
    }
    if touchedTasks { NotificationCenter.default.post(name: .septenaTasksChanged, object: nil) }
    if touchedStructure { NotificationCenter.default.post(name: .septenaStructureChanged, object: nil) }
    if deletedAreas {
      // Same follow-up as a CloudKit area deletion: detach tasks / projects
      // that still point at it. Those writes go through the mutators, so
      // they are queued like any edit.
      Task { @MainActor in await SeptenaServices.shared.areasMutator.repairDeletedAreaReferences() }
    }
    return true
  }

  private func applyTaskRow(_ id: String, _ row: [String: BackendJSON], tombstone: Bool, skip: Set<String>,
                            pendingDelete: Bool, shadow: TaskSyncShadow?, store: TaskSyncStore) {
    let key = "task:\(id)"
    let old = shadow.map { TaskSyncJSON.decode($0.fields) } ?? [:]
    if tombstone {
      if let t = fetchTask(id), t.deletedAt == nil {
        t.deletedAt = Self.localStamp(Self.parseStamp(row["deletedAt"]?.stringValue) ?? Date())
      }
      dropQueuedOps(taskFamily: id, reason: "deleted on the backend", store: store)
      var new = old
      new["_deleted"] = .bool(true)
      new["_remote"] = .bool(true)
      writeShadow(shadow, key, old: old, new: new, gone: true, store: store)
      return
    }
    if pendingDelete { return }
    let t = fetchTask(id) ?? { let n = TaskEntity(id: id, title: ""); main.insert(n); return n }()
    let applied = applyTaskFields(t, row, skip: skip)
    var new = old
    if let mapped = try? TaskBackendMapping.task(t).get().fields {
      for k in applied { new[k] = mapped[k] ?? row[k] ?? .null }
    } else {
      for k in applied { new[k] = row[k] ?? .null }
    }
    new["_remote"] = .bool(true)
    // The backend holds the row live. A local soft delete it has not seen
    // stays local and the next reconcile queues its delete.
    new["_deleted"] = .bool(false)
    writeShadow(shadow, key, old: old, new: new, gone: false, store: store)
  }

  /// Shadow = the mapped local value for every field the pull applied (so an
  /// unchanged field never diffs because of a format difference).
  private func recordApplied(_ key: String, applied: [String], mapped: [String: BackendJSON],
                             raw: [String: BackendJSON], shadow: TaskSyncShadow?, store: TaskSyncStore) {
    let old = shadow.map { TaskSyncJSON.decode($0.fields) } ?? [:]
    var new = old
    for k in applied { new[k] = mapped[k] ?? raw[k] ?? .null }
    writeShadow(shadow, key, old: old, new: new, gone: false, store: store)
  }

  private func markGone(_ entity: BackendEntity, _ id: String, shadow: TaskSyncShadow?, store: TaskSyncStore) {
    for op in store.ops(entity: entity.rawValue, rowID: id) {
      store.remove(op)
      if op.kind != TaskSyncOpKind.delete {
        addIssue(entity, id, "local \(op.kind) dropped: deleted on the backend")
      }
    }
    let old = shadow.map { TaskSyncJSON.decode($0.fields) } ?? [:]
    writeShadow(shadow, "\(entity.rawValue):\(id)", old: old, new: old, gone: true, store: store)
  }

  /// Removes every queued op of a task, its conversation and its turns, and
  /// reports the ones that carried edits.
  private func dropQueuedOps(taskFamily id: String, reason: String, store: TaskSyncStore) {
    var lost = 0
    for entity in [BackendEntity.task, .convo, .turn] {
      for op in store.ops(entity: entity.rawValue, rowID: id) {
        store.remove(op)
        if op.kind != TaskSyncOpKind.delete { lost += 1 }
      }
    }
    if lost > 0 { addIssue(.task, id, "\(lost) local change(s) dropped: \(reason)") }
  }

  /// A push answered `dropped`: the row is deleted on the backend (§6.4).
  func handleDropped(_ entity: BackendEntity, _ id: String, store: TaskSyncStore) {
    switch entity {
    case .task, .convo, .turn:
      if let t = fetchTask(id), t.deletedAt == nil {
        t.deletedAt = Self.localStamp(Date())
        TaskChange.post(id)
      }
      dropQueuedOps(taskFamily: id, reason: "deleted on the backend", store: store)
      addIssue(.task, id, "change refused: the task is deleted on the backend; it stays in Recently Deleted")
      let key = "task:\(id)"
      let shadow = store.shadow(key)
      let old = shadow.map { TaskSyncJSON.decode($0.fields) } ?? [:]
      var new = old
      new["_deleted"] = .bool(true)
      new["_remote"] = .bool(true)
      writeShadow(shadow, key, old: old, new: new, gone: true, store: store)
    case .area:
      if let a = fetchArea(id) { main.delete(a) }
      DeletedAreaLedger.record(id)
      markGone(.area, id, shadow: store.shadow("area:\(id)"), store: store)
      addIssue(.area, id, "change refused: the area is deleted on the backend")
      NotificationCenter.default.post(name: .septenaStructureChanged, object: nil)
      Task { @MainActor in await SeptenaServices.shared.areasMutator.repairDeletedAreaReferences() }
    case .project:
      if let p = fetchProject(id) { main.delete(p) }
      markGone(.project, id, shadow: store.shadow("project:\(id)"), store: store)
      addIssue(.project, id, "change refused: the project is deleted on the backend")
      NotificationCenter.default.post(name: .septenaStructureChanged, object: nil)
    case .attachment:
      if let a = fetchAttachment(id) {
        if let url = TaskAttachmentFiles.url(for: a) { try? FileManager.default.removeItem(at: url) }
        main.delete(a)
      }
      markGone(.attachment, id, shadow: store.shadow("attachment:\(id)"), store: store)
      addIssue(.attachment, id, "change refused: the attachment is deleted on the backend")
      NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    case .setting:
      // Settings are never deleted on the backend; nothing to undo.
      break
    }
    _ = StoreHealth.save(main, op: "taskSync.dropped")
  }

  // MARK: - Turns

  /// Thread = turns the backend confirmed, in `seq` order, then the turns
  /// this device appended and has not seen come back yet. A turn this device
  /// pushed is recognised by the seq the push returned.
  private func applyTurns(taskID: String, rows: [[String: BackendJSON]], store: TaskSyncStore) {
    guard let t = fetchTask(taskID) else { return }
    let key = "turns:\(taskID)"
    let shadow = store.shadow(key)
    // No turns shadow: this thread was never synced on this device (the first
    // pull after the switch). The local turns that line up with the backend's
    // are the same turns (the import sent them); the backend's version wins,
    // and local turns past its count are queued as appends by the next
    // capture.
    let firstSync = shadow == nil
    let old = shadow.map { TaskSyncJSON.decode($0.fields) } ?? Self.emptyTurnsShadow
    let serverCount = Self.int(old["server"]) ?? 0
    var pushed: [Int] = []
    if case .array(let list) = old["pushed"] ?? .array([]) { pushed = list.compactMap { Self.int($0) } }

    let incoming = rows
      .compactMap { row -> (Int, ConvoTurn)? in
        guard let seq = Self.int(row["seq"]), seq > serverCount, var turn = Self.convoTurn(from: row) else { return nil }
        turn.seq = seq
        return (seq, turn)
      }
      .sorted { $0.0 < $1.0 }
    guard !incoming.isEmpty else { return }

    var convo = t.conversation
    let thread = convo.thread.sorted { $0.seq < $1.seq }
    let confirmed = Array(thread.prefix(serverCount))
    var extras = Array(thread.dropFirst(firstSync ? incoming.count : serverCount))
    let maxSeq = incoming.last!.0
    let covered = pushed.filter { $0 <= maxSeq }.count
    extras.removeFirst(min(covered, extras.count))
    pushed = pushed.filter { $0 > maxSeq }

    var merged = confirmed
    var seen = Set(confirmed.map(\.seq))
    for (seq, turn) in incoming where !seen.contains(seq) {
      merged.append(turn)
      seen.insert(seq)
    }
    let serverTotal = merged.count
    var next = (merged.map(\.seq).max() ?? 0) + 1
    for var turn in extras {
      turn.seq = next
      next += 1
      merged.append(turn)
    }
    convo.thread = merged
    t.conversation = convo

    var new = old
    new["server"] = .int(Int64(serverTotal))
    new["pushed"] = .array(pushed.map { .int(Int64($0)) })
    new["local"] = .int(Int64(firstSync ? serverTotal : merged.count))
    writeShadow(shadow, key, old: old, new: new, store: store)
  }

  static func convoTurn(from row: [String: BackendJSON]) -> ConvoTurn? {
    guard let roleRaw = row["role"]?.stringValue, let role = ConvoTurn.Role(rawValue: roleRaw),
          let stepRaw = row["step"]?.stringValue, let step = ConvoTurn.Step(rawValue: stepRaw) else { return nil }
    var options: [String]?
    if case .array(let list)? = row["options"] { options = list.compactMap(\.stringValue) }
    return ConvoTurn(
      seq: int(row["seq"]) ?? 0,
      role: role,
      step: step,
      provider: row["provider"]?.stringValue.map { ConvoTurn.Provider(rawValue: $0) ?? .unknown },
      confidence: double(row["confidence"]),
      question: row["question"]?.stringValue,
      options: options,
      chosen: row["chosen"]?.stringValue,
      otherText: row["otherText"]?.stringValue,
      inReplyTo: int(row["inReplyTo"]),
      note: row["note"]?.stringValue,
      ts: parseStamp(row["ts"]?.stringValue) ?? Date())
  }

  // MARK: - Field writers
  //
  // Each writes only the fields present in `fields` and not in `skip`, and
  // returns the names it wrote.

  @discardableResult
  func applyTaskFields(_ t: TaskEntity, _ fields: [String: BackendJSON], skip: Set<String>) -> [String] {
    var applied: [String] = []
    func take(_ name: String, _ write: (BackendJSON) -> Void) {
      guard !skip.contains(name), let v = fields[name] else { return }
      write(v)
      applied.append(name)
    }
    take("title") { t.title = $0.stringValue ?? t.title }
    take("status") { t.statusRaw = $0.stringValue ?? t.statusRaw }
    take("kind") { t.kind = $0.stringValue ?? "" }
    take("heading") { t.heading = $0.stringValue }
    take("area") { t.area = $0.stringValue }
    take("project") { t.project = $0.stringValue }
    take("created") { t.created = $0.stringValue }
    take("scheduled") { t.scheduled = $0.stringValue }
    take("deadline") { t.deadline = $0.stringValue }
    take("today") { t.today = Self.bool($0) ?? false }
    take("todaySetOn") { t.todaySetOn = $0.stringValue }
    take("completedAt") { t.completedAt = $0.stringValue }
    take("notes") { t.notes = $0.stringValue }
    take("position") { t.position = Self.double($0) ?? 0 }
    take("recurrenceUnit") { t.recurrenceUnit = $0.stringValue }
    take("recurrenceInterval") { t.recurrenceInterval = Self.int($0) ?? 1 }
    take("recurrenceAfterCompletion") { t.recurrenceAfterCompletion = Self.bool($0) ?? false }
    take("recurrencePaused") { t.recurrencePaused = Self.bool($0) ?? false }
    take("recurrenceSeriesID") { t.recurrenceSeriesID = $0.stringValue }
    take("recurrenceAnchorDate") { t.recurrenceAnchorDate = $0.stringValue }
    take("source") { t.source = $0.stringValue }
    take("sourceClient") { t.sourceClient = $0.stringValue }
    take("acknowledgedAt") { t.acknowledgedAt = Self.parseStamp($0.stringValue) }
    take("createdAt") { t.createdAt = Self.parseStamp($0.stringValue) ?? .distantPast }
    // `todayPosition` is not stored locally (see the header).
    return applied
  }

  @discardableResult
  func applyConvoFields(_ t: TaskEntity, _ fields: [String: BackendJSON], skip: Set<String>) -> [String] {
    var convo = t.conversation
    var applied: [String] = []
    func take(_ name: String, _ write: (BackendJSON) -> Void) {
      guard !skip.contains(name), let v = fields[name] else { return }
      write(v)
      applied.append(name)
    }
    take("confirmedIntent") { convo.confirmedIntent = $0.stringValue }
    take("acceptance") { convo.acceptance = $0.stringValue }
    take("subtasks") { v in
      if case .array(let list) = v { convo.subtasks = list.compactMap(\.stringValue) } else { convo.subtasks = [] }
    }
    take("endState") { convo.endState = $0.stringValue.flatMap(ConvoEndState.init(rawValue:)) }
    take("endStateNote") { convo.endStateNote = $0.stringValue }
    take("assignee") { convo.assignee = $0.stringValue.flatMap(ConvoAssignee.init(rawValue:)) }
    take("artifact") { v in
      guard case .object(let o) = v, let kind = o["kind"]?.stringValue, let title = o["title"]?.stringValue,
            let body = o["body"]?.stringValue else { convo.artifact = nil; return }
      var refs: [String]?
      if case .array(let list)? = o["refs"] { refs = list.compactMap(\.stringValue) }
      convo.artifact = ConvoArtifact(kind: kind, title: title, body: body, refs: refs)
    }
    take("handoff") { v in
      guard case .object(let o) = v, let instruction = o["instruction"]?.stringValue,
            let action = o["actionType"]?.stringValue.flatMap(ConvoHandoff.ActionType.init(rawValue:)) else {
        convo.handoff = nil
        return
      }
      convo.handoff = ConvoHandoff(instruction: instruction, actionType: action, payload: o["payload"]?.stringValue)
    }
    if !applied.isEmpty { t.conversation = convo }
    return applied
  }

  @discardableResult
  func applyAreaFields(_ a: AreaEntity, _ fields: [String: BackendJSON], skip: Set<String>) -> [String] {
    var applied: [String] = []
    func take(_ name: String, _ write: (BackendJSON) -> Void) {
      guard !skip.contains(name), let v = fields[name] else { return }
      write(v)
      applied.append(name)
    }
    take("title") { a.title = $0.stringValue ?? a.title }
    take("context") { a.context = $0.stringValue }
    take("emoji") { a.emoji = $0.stringValue }
    take("attachment") { a.attachmentJSON = Self.jsonText($0) }
    take("position") { a.position = Self.int($0) ?? 0 }
    return applied
  }

  @discardableResult
  func applyProjectFields(_ p: ProjectEntity, _ fields: [String: BackendJSON], skip: Set<String>) -> [String] {
    var applied: [String] = []
    func take(_ name: String, _ write: (BackendJSON) -> Void) {
      guard !skip.contains(name), let v = fields[name] else { return }
      write(v)
      applied.append(name)
    }
    take("title") { p.title = $0.stringValue ?? p.title }
    take("status") { p.statusRaw = $0.stringValue ?? p.statusRaw }
    take("area") { p.area = $0.stringValue }
    take("created") { p.created = $0.stringValue }
    take("completedAt") { p.completedAt = $0.stringValue }
    take("notes") { p.notes = $0.stringValue }
    take("context") { p.context = $0.stringValue }
    take("githubRepo") { p.githubRepo = $0.stringValue }
    take("attachment") { p.attachmentJSON = Self.jsonText($0) }
    take("position") { p.position = Self.int($0) ?? 0 }
    return applied
  }

  @discardableResult
  func applyAttachmentFields(_ a: TaskAttachmentEntity, _ fields: [String: BackendJSON], skip: Set<String>) -> [String] {
    var applied: [String] = []
    func take(_ name: String, _ write: (BackendJSON) -> Void) {
      guard !skip.contains(name), let v = fields[name] else { return }
      write(v)
      applied.append(name)
    }
    take("taskId") { a.taskID = $0.stringValue ?? a.taskID }
    take("filename") { a.filename = $0.stringValue ?? a.filename }
    take("contentType") { a.contentType = $0.stringValue ?? a.contentType }
    take("byteCount") { a.byteCount = Int64(Self.int($0) ?? Int(a.byteCount)) }
    take("position") { a.position = Self.double($0) ?? 0 }
    take("createdAt") { a.createdAt = Self.parseStamp($0.stringValue) ?? a.createdAt }
    return applied
  }

  // MARK: - Value helpers

  static func bool(_ v: BackendJSON) -> Bool? {
    switch v {
    case .bool(let b): return b
    case .int(let i): return i != 0
    default: return nil
    }
  }

  static func double(_ v: BackendJSON?) -> Double? {
    switch v {
    case .double(let d): return d
    case .int(let i): return Double(i)
    default: return nil
    }
  }

  /// An `AreaAttachment` object back to the JSON text the entity stores.
  static func jsonText(_ v: BackendJSON) -> String? {
    guard case .object = v, let data = try? JSONEncoder().encode(v) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// ISO-8601 with or without fractions, or the app's zone-less
  /// `yyyy-MM-dd'T'HH:mm:ss` (local time).
  static func parseStamp(_ s: String?) -> Date? {
    guard let s else { return nil }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = iso.date(from: s) { return d }
    iso.formatOptions = [.withInternetDateTime]
    if let d = iso.date(from: s) { return d }
    let local = DateFormatter()
    local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    local.locale = Locale(identifier: "en_US_POSIX")
    return local.date(from: String(s.prefix(19)))
  }

  /// The shape `TasksBackend` writes into `deletedAt`.
  static func localStamp(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: date)
  }
}
