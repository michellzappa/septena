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
//   - `todayPosition` (Today's own order, #66) is applied like any field, so
//     a queued local reorder wins until its push lands.
//   - A `setting` row writes Septask's synced-settings blob
//     (TaskSyncSettings.swift), unless that key has a queued local upsert.

extension TaskSyncEngine {

  // MARK: - Pull

  func pull(store: TaskSyncStore) async throws {
    try await pull(store: store, resetsSoFar: 0)
  }

  /// Each page's fate (apply, continue, reset once, fail) is the shared
  /// core's decision (`TaskSyncDecisions.pullStep`, sync-engine.json).
  private func pull(store: TaskSyncStore, resetsSoFar: Int) async throws {
    var cursor = since
    var pages = 0
    while isRunning {
      let page = try await client.pull(since: cursor)
      let step = TaskSyncDecisions.pullStep(
        cursor: cursor, resetRequired: page.resetRequired == true,
        nextSince: page.nextSince, hasMore: page.hasMore, resetsSoFar: resetsSoFar)
      switch step {
      case .reset:
        try await resetAndRepull(store: store, resetsSoFar: resetsSoFar + 1)
        return
      case .fail(let reason):
        throw TaskBackendError.badResponse(reason)
      case .apply, .applyAndContinue:
        guard applyPulled(page.changes, store: store) else {
          // The local save failed and rolled back: keep `since`, read the page again.
          throw TaskBackendError.badResponse("the local store could not save pulled rows")
        }
        cursor = page.nextSince
        since = cursor   // only after the page was saved
        pages += 1
      }
      if step == .apply { break }
      guard pages < 10_000 else { throw TaskBackendError.badResponse("pull did not finish") }
    }
    lastPull = Date()
  }

  /// `resetRequired`: this device's `since` is older than the backend's
  /// tombstone purge. Capture local edits not yet queued, wipe the task
  /// types here, pull from 0, then lay the queued ops back on top.
  private func resetAndRepull(store: TaskSyncStore, resetsSoFar: Int) async throws {
    SeptenaLog.info("[TaskSync] resetRequired: wiping local task data and pulling from 0")
    reconcile(store: store)
    let context = main
    for t in (try? context.fetch(FetchDescriptor<TaskEntity>())) ?? [] { context.delete(t) }
    for a in (try? context.fetch(FetchDescriptor<AreaEntity>())) ?? [] { context.delete(a) }
    for p in (try? context.fetch(FetchDescriptor<ProjectEntity>())) ?? [] { context.delete(p) }
    // Attachment FILES stay on disk: re-pulled rows relink to them by id.
    for a in (try? context.fetch(FetchDescriptor<TaskAttachmentEntity>())) ?? [] { context.delete(a) }
    for c in (try? context.fetch(FetchDescriptor<TaskChecklistItemEntity>())) ?? [] { context.delete(c) }
    // A reference without a shadow never reached the backend (it was refused,
    // see `taskRefsRefused`), so a pull cannot bring it back. Keep it.
    for r in (try? context.fetch(FetchDescriptor<TaskRefEntity>())) ?? [] where store.shadow("taskRef:\(r.id)") != nil {
      context.delete(r)
    }
    for s in (try? context.fetch(FetchDescriptor<DoSessionEntity>())) ?? [] where store.shadow("doSession:\(s.id)") != nil {
      context.delete(s)
    }
    _ = StoreHealth.save(context, op: "taskSync.reset")
    store.deleteAllShadows()
    since = 0
    try await pull(store: store, resetsSoFar: resetsSoFar)   // a second reset in one sync fails
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
      case (TaskSyncOpKind.upsert, .checklistItem?):
        if let item = fetchChecklistItem(op.rowID) { applyChecklistItemFields(item, fields, skip: []) }
        else if let taskID = fields["taskId"]?.stringValue {
          let n = TaskChecklistItemEntity(id: op.rowID, taskID: taskID, title: "")
          main.insert(n)
          applyChecklistItemFields(n, fields, skip: [])
        }
      case (TaskSyncOpKind.upsert, .taskRef?):
        if let ref = fetchTaskRef(op.rowID) { applyTaskRefFields(ref, fields, skip: []) }
        else if let taskID = fields["taskId"]?.stringValue, let key = fields["key"]?.stringValue {
          let n = TaskRefEntity(id: op.rowID, taskID: taskID, key: key,
                                kind: TaskRefCore.parse(key)?.kind ?? "")
          main.insert(n)
          applyTaskRefFields(n, fields, skip: [])
        }
      case (TaskSyncOpKind.upsert, .doSession?):
        if let s = fetchDoSession(op.rowID) { applyDoSessionFields(s, fields, skip: []) }
        else if let taskID = fields["taskId"]?.stringValue, let startedAt = fields["startedAt"]?.stringValue {
          let n = DoSessionEntity(id: op.rowID, taskID: taskID, startedAt: startedAt)
          main.insert(n)
          applyDoSessionFields(n, fields, skip: [])
        }
      case (TaskSyncOpKind.upsert, .tag?):
        if let tag = fetchTag(op.rowID) { applyTagFields(tag, fields, skip: []) }
        else if let name = fields["name"]?.stringValue, !name.isEmpty {
          let n = TagEntity(id: op.rowID, name: name)
          main.insert(n)
          applyTagFields(n, fields, skip: [])
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
          DeletedContainerLedger.record(.area, id)
          markGone(.area, id, shadow: shadows[key], store: store)
        } else if !pendingDelete.contains(key) {
          DeletedContainerLedger.forget(.area, id)
          let a = fetchArea(id) ?? { let n = AreaEntity(id: id, title: ""); main.insert(n); return n }()
          let applied = applyAreaFields(a, change.row, skip: skip)
          let mapped = (try? TaskBackendMapping.area(a).get())?.fields ?? [:]
          recordApplied(key, applied: applied, mapped: mapped, raw: change.row, shadow: shadows[key], store: store)
        }
        touchedStructure = true
      case .project:
        if tombstone {
          if let p = fetchProject(id) { main.delete(p) }
          DeletedContainerLedger.record(.project, id)
          markGone(.project, id, shadow: shadows[key], store: store)
        } else if !pendingDelete.contains(key) {
          DeletedContainerLedger.forget(.project, id)
          let p = fetchProject(id) ?? { let n = ProjectEntity(id: id, title: ""); main.insert(n); return n }()
          let notesBefore = p.notes
          let applied = applyProjectFields(p, change.row, skip: skip)
          noteReplacedNotes(key, old: notesBefore, new: p.notes)
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
          clearAttachmentLimitState(id: id)
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
          let uploaded = change.row["uploadedAt"]?.stringValue != nil
          let mapped = (try? TaskBackendMapping.attachment(a).get())?.row.fields ?? [:]
          recordApplied(key, applied: applied, mapped: mapped, raw: change.row, shadow: shadows[key], store: store)
          recordAttachmentUploadState(id: id, uploaded: uploaded, hasLocalFile: a.localFilename != nil, store: store)
        }
        touchedTasks = true
      case .checklistItem:
        if tombstone {
          if let item = fetchChecklistItem(id) { main.delete(item) }
          markGone(.checklistItem, id, shadow: shadows[key], store: store)
        } else if !pendingDelete.contains(key) {
          let item = fetchChecklistItem(id) ?? {
            let n = TaskChecklistItemEntity(id: id, taskID: change.row["taskId"]?.stringValue ?? "", title: "")
            main.insert(n)
            return n
          }()
          let applied = applyChecklistItemFields(item, change.row, skip: skip)
          let mapped = (try? TaskBackendMapping.checklistItem(item).get())?.fields ?? [:]
          recordApplied(key, applied: applied, mapped: mapped, raw: change.row, shadow: shadows[key], store: store)
        }
        touchedTasks = true
      case .taskRef:
        if tombstone {
          if let ref = fetchTaskRef(id) { main.delete(ref) }
          // The task and key of a deleted row stay: they count towards the id
          // of a reference that is added again (`nextTaskRefID`).
          markGone(.taskRef, id, shadow: shadows[key],
                   seed: change.row.filter { $0.key == "taskId" || $0.key == "key" }, store: store)
        } else if !pendingDelete.contains(key) {
          let ref = fetchTaskRef(id) ?? {
            let n = TaskRefEntity(id: id, taskID: change.row["taskId"]?.stringValue ?? "",
                                  key: change.row["key"]?.stringValue ?? "",
                                  kind: change.row["kind"]?.stringValue ?? "")
            main.insert(n)
            return n
          }()
          let applied = applyTaskRefFields(ref, change.row, skip: skip)
          let mapped = (try? TaskBackendMapping.taskRef(ref).get())?.fields ?? [:]
          recordApplied(key, applied: applied, mapped: mapped, raw: change.row, shadow: shadows[key], store: store)
        }
        touchedTasks = true
      case .doSession:
        if tombstone {
          if let s = fetchDoSession(id) { main.delete(s) }
          markGone(.doSession, id, shadow: shadows[key], store: store)
        } else if !pendingDelete.contains(key) {
          let s = fetchDoSession(id) ?? {
            let n = DoSessionEntity(id: id, taskID: change.row["taskId"]?.stringValue ?? "",
                                    startedAt: change.row["startedAt"]?.stringValue ?? "")
            main.insert(n)
            return n
          }()
          let applied = applyDoSessionFields(s, change.row, skip: skip)
          let mapped = (try? TaskBackendMapping.doSession(s).get())?.fields ?? [:]
          recordApplied(key, applied: applied, mapped: mapped, raw: change.row, shadow: shadows[key], store: store)
        }
        touchedTasks = true
      case .tag:
        if tombstone {
          if let tag = fetchTag(id) { main.delete(tag) }
          markGone(.tag, id, shadow: shadows[key], store: store)
        } else if !pendingDelete.contains(key) {
          let tag = fetchTag(id) ?? {
            let n = TagEntity(id: id, name: change.row["name"]?.stringValue ?? "")
            main.insert(n)
            return n
          }()
          let applied = applyTagFields(tag, change.row, skip: skip)
          let mapped = (try? TaskBackendMapping.tag(tag).get())?.fields ?? [:]
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
    let notesBefore = t.notes
    let applied = applyTaskFields(t, row, skip: skip)
    noteReplacedNotes(key, old: notesBefore, new: t.notes)
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

  private func markGone(_ entity: BackendEntity, _ id: String, shadow: TaskSyncShadow?,
                        seed: [String: BackendJSON] = [:], store: TaskSyncStore) {
    for op in store.ops(entity: entity.rawValue, rowID: id) {
      store.remove(op)
      if op.kind != TaskSyncOpKind.delete {
        addIssue(entity, id, "local \(op.kind) dropped: deleted on the backend")
      }
    }
    let old = shadow.map { TaskSyncJSON.decode($0.fields) } ?? [:]
    writeShadow(shadow, "\(entity.rawValue):\(id)", old: old, new: old.merging(seed) { kept, _ in kept },
                gone: true, store: store)
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
      DeletedContainerLedger.record(.area, id)
      markGone(.area, id, shadow: store.shadow("area:\(id)"), store: store)
      addIssue(.area, id, "change refused: the area is deleted on the backend")
      NotificationCenter.default.post(name: .septenaStructureChanged, object: nil)
    case .project:
      if let p = fetchProject(id) { main.delete(p) }
      DeletedContainerLedger.record(.project, id)
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
    case .checklistItem:
      if let item = fetchChecklistItem(id) { main.delete(item) }
      markGone(.checklistItem, id, shadow: store.shadow("checklistItem:\(id)"), store: store)
      addIssue(.checklistItem, id, "change refused: the checklist item is deleted on the backend")
      NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    case .taskRef:
      if let ref = fetchTaskRef(id) { main.delete(ref) }
      markGone(.taskRef, id, shadow: store.shadow("taskRef:\(id)"), store: store)
      addIssue(.taskRef, id, "change refused: the reference is deleted on the backend")
      NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    case .doSession:
      if let s = fetchDoSession(id) { main.delete(s) }
      markGone(.doSession, id, shadow: store.shadow("doSession:\(id)"), store: store)
      NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    case .tag:
      if let tag = fetchTag(id) { main.delete(tag) }
      markGone(.tag, id, shadow: store.shadow("tag:\(id)"), store: store)
      addIssue(.tag, id, "change refused: the tag is deleted on the backend")
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
    take("startTime") { t.startTime = $0.stringValue }
    take("durationMinutes") { t.durationMinutes = Self.int($0) }
    take("timeZone") { t.timeZone = $0.stringValue }
    take("deadline") { t.deadline = $0.stringValue }
    take("deferredDeadline") { t.deferredDeadline = $0.stringValue }
    take("waitingOn") { t.waitingOn = $0.stringValue }
    take("waitingSince") { t.waitingSince = $0.stringValue }
    take("today") { t.today = Self.bool($0) ?? false }
    take("starred") { t.starred = Self.bool($0) ?? false }
    take("tags") { v in
      if case .array(let arr) = v {
        t.tagIDs = arr.compactMap(\.stringValue)
      } else {
        t.tagIDs = []
      }
    }
    take("todaySetOn") { t.todaySetOn = $0.stringValue }
    take("completedAt") { t.completedAt = $0.stringValue }
    take("notes") { t.notes = $0.stringValue }
    take("position") { t.position = Self.double($0) ?? 0 }
    take("todayPosition") { t.todayPosition = Self.double($0) }
    take("recurrenceUnit") { t.recurrenceUnit = $0.stringValue }
    take("recurrenceInterval") { t.recurrenceInterval = Self.int($0) ?? 1 }
    take("recurrenceAfterCompletion") { t.recurrenceAfterCompletion = Self.bool($0) ?? false }
    take("recurrencePaused") { t.recurrencePaused = Self.bool($0) ?? false }
    take("recurrenceSeriesID") { t.recurrenceSeriesID = $0.stringValue }
    take("recurrenceAnchorDate") { t.recurrenceAnchorDate = $0.stringValue }
    take("recurrenceMissed") { t.recurrenceMissed = $0.stringValue }
    take("recurrenceMissedFrom") { t.recurrenceMissedFrom = $0.stringValue }
    take("recurrenceWeekdays") { v in
      if case .array(let list) = v {
        let nums = list.compactMap(Self.int).filter { (1...7).contains($0) }
        if !nums.isEmpty,
           let data = try? JSONEncoder().encode(Array(Set(nums)).sorted()),
           let s = String(data: data, encoding: .utf8) {
          t.recurrenceWeekdaysJSON = s
        } else {
          t.recurrenceWeekdaysJSON = nil
        }
      } else {
        t.recurrenceWeekdaysJSON = nil
      }
    }
    take("recurrenceMonthDay") { t.recurrenceMonthDay = Self.int($0) }
    take("recurrenceOrdinalWeekday") { v in
      if case .object(let o) = v,
         let ord = o["ordinal"].flatMap(Self.int),
         let wd = o["weekday"].flatMap(Self.int),
         let data = try? JSONEncoder().encode(RecurrenceOrdinalWeekday(ordinal: ord, weekday: wd)),
         let s = String(data: data, encoding: .utf8) {
        t.recurrenceOrdinalWeekdayJSON = s
      } else {
        t.recurrenceOrdinalWeekdayJSON = nil
      }
    }
    take("reminderAt") { t.reminderAt = $0.stringValue }
    take("reminderMode") { t.reminderMode = $0.stringValue }
    take("reminderSnoozedUntil") { t.reminderSnoozedUntil = $0.stringValue }
    take("reminderDismissedAt") { t.reminderDismissedAt = $0.stringValue }
    take("source") { t.source = $0.stringValue }
    take("sourceClient") { t.sourceClient = $0.stringValue }
    take("acknowledgedAt") { t.acknowledgedAt = Self.parseStamp($0.stringValue) }
    take("createdAt") { t.createdAt = Self.parseStamp($0.stringValue) ?? .distantPast }
    // Fade (docs/TASK_FADE_SPEC.md §3). A pulled touch wins like any field,
    // so the newest device's fade clock holds everywhere.
    take("touchedAt") { t.touchedAt = Self.parseStamp($0.stringValue) }
    take("deferCount") { t.deferCount = max(0, Self.int($0) ?? 0) }
    take("fadedAt") { t.fadedAt = Self.parseStamp($0.stringValue) }
    take("dropReason") { t.dropReason = $0.stringValue }
    take("effort") { t.effort = $0.stringValue }
    take("assignedTo") { t.assignedTo = $0.stringValue }
    take("assignedBy") { t.assignedBy = $0.stringValue }
    take("assignedAt") { t.assignedAt = $0.stringValue }
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
    take("stoppedAt") { convo.stoppedAt = Self.parseStamp($0.stringValue) }
    take("claimedBy") { convo.claimedBy = $0.stringValue }
    take("claimUntil") { convo.claimUntil = Self.parseStamp($0.stringValue) }
    take("endStateAt") { convo.endStateAt = Self.parseStamp($0.stringValue) }
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
    take("noteRev") { a.noteRev = Self.int($0) ?? 0 }
    take("notesProposal") { a.notesProposal = Self.notesProposal(from: $0) }
    take("emoji") { a.emoji = $0.stringValue }
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
    take("checklistMode") { p.checklistModeRaw = $0.stringValue }
    take("area") { p.area = $0.stringValue }
    take("created") { p.created = $0.stringValue }
    take("completedAt") { p.completedAt = $0.stringValue }
    take("notes") { p.notes = $0.stringValue }
    take("context") { p.context = $0.stringValue }
    take("noteRev") { p.noteRev = Self.int($0) ?? 0 }
    take("notesProposal") { p.notesProposal = Self.notesProposal(from: $0) }
    take("githubRepo") { p.githubRepo = $0.stringValue }
    take("share") { p.shareJSON = $0.jsonText }
    take("position") { p.position = Self.int($0) ?? 0 }
    return applied
  }

  private static func notesProposal(from value: BackendJSON) -> NotesProposal? {
    guard case .object(let obj) = value,
          let body = obj["body"]?.stringValue,
          let agent = obj["agent"]?.stringValue,
          let at = obj["at"]?.stringValue else {
      return nil
    }
    return NotesProposal(body: body, agent: agent, at: at, why: obj["why"]?.stringValue)
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

  @discardableResult
  func applyChecklistItemFields(_ item: TaskChecklistItemEntity, _ fields: [String: BackendJSON], skip: Set<String>) -> [String] {
    var applied: [String] = []
    func take(_ name: String, _ write: (BackendJSON) -> Void) {
      guard !skip.contains(name), let v = fields[name] else { return }
      write(v)
      applied.append(name)
    }
    take("taskId") { item.taskID = $0.stringValue ?? item.taskID }
    take("title") { item.title = $0.stringValue ?? item.title }
    take("checked") { item.checked = Self.bool($0) ?? false }
    take("checkedAt") { item.checkedAt = Self.parseStamp($0.stringValue) }
    take("position") { item.position = Self.double($0) ?? 0 }
    take("createdAt") { item.createdAt = Self.parseStamp($0.stringValue) ?? item.createdAt }
    item.updatedAt = Date()
    return applied
  }

  @discardableResult
  func applyTaskRefFields(_ ref: TaskRefEntity, _ fields: [String: BackendJSON], skip: Set<String>) -> [String] {
    var applied: [String] = []
    func take(_ name: String, _ write: (BackendJSON) -> Void) {
      guard !skip.contains(name), let v = fields[name] else { return }
      write(v)
      applied.append(name)
    }
    take("taskId") { ref.taskID = $0.stringValue ?? ref.taskID }
    take("key") { ref.key = $0.stringValue ?? ref.key }
    take("kind") { ref.kind = $0.stringValue ?? ref.kind }
    take("role") { ref.role = $0.stringValue ?? ref.role }
    take("snapshot") { v in
      if case .object = v { ref.snapshotJSON = TaskRefSnapshot.json(v) } else { ref.snapshotJSON = nil }
    }
    take("position") { ref.position = Self.double($0) }
    take("createdBy") { ref.createdBy = $0.stringValue }
    take("lastSeenAt") { ref.lastSeenAt = $0.stringValue }
    take("createdAt") { ref.createdAt = Self.parseStamp($0.stringValue) ?? ref.createdAt }
    ref.updatedAt = Date()
    return applied
  }

  @discardableResult
  func applyDoSessionFields(_ s: DoSessionEntity, _ fields: [String: BackendJSON], skip: Set<String>) -> [String] {
    var applied: [String] = []
    func take(_ name: String, _ write: (BackendJSON) -> Void) {
      guard !skip.contains(name), let v = fields[name] else { return }
      write(v)
      applied.append(name)
    }
    take("taskId") { s.taskID = $0.stringValue ?? s.taskID }
    take("startedAt") { s.startedAt = $0.stringValue ?? s.startedAt }
    take("plannedMinutes") { s.plannedMinutes = Self.int($0) }
    take("confirmedAt") { s.confirmedAt = $0.stringValue }
    take("endedAt") { s.endedAt = $0.stringValue }
    take("exit") { s.exit = $0.stringValue }
    take("lapsed") { s.lapsed = Self.bool($0) ?? false }
    take("note") { s.note = $0.stringValue }
    take("sourceClient") { s.sourceClient = $0.stringValue }
    return applied
  }

  @discardableResult
  func applyTagFields(_ tag: TagEntity, _ fields: [String: BackendJSON], skip: Set<String>) -> [String] {
    var applied: [String] = []
    func take(_ name: String, _ write: (BackendJSON) -> Void) {
      guard !skip.contains(name), let v = fields[name] else { return }
      write(v)
      applied.append(name)
    }
    take("name") { tag.name = $0.stringValue ?? tag.name }
    take("color") { tag.color = $0.stringValue }
    take("position") { tag.position = Self.int($0) }
    tag.updatedAt = Date()
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
