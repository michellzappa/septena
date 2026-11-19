import Foundation
import Observation
import SwiftData

// Phase 1 of the task-backend migration (docs/SEPTASK_BACKEND.md §9): a
// one-shot "Copy tasks to backend" that reads the local SwiftData mirror and
// pushes every area, project, task, conversation, turn and attachment to
// api.septena.app with ids unchanged, then pulls everything back and compares.
//
// Order of one run:
//   1. Preflight: CloudKit must be started, done bootstrapping, and have no
//      unsent task / area / project / attachment change.
//   2. Read the mirror and map every row (TaskBackendMapping). Rows that fail
//      the server's limits are left out and reported.
//   3. Pull the backend's current state (the "baseline").
//   4. Push in batches of ≤500: areas, projects, tasks (headings first),
//      deletes for Recently Deleted tasks/projects, conversations, turns,
//      attachment rows. Then upload attachment bytes.
//   5. Pull everything again and compare field by field with what was sent.
//
// Re-running is safe:
//   - Upserts overwrite the whole row. Op ids are a hash of the content, so a
//     retried batch dedupes on the server.
//   - Turns are append-only on the server and it assigns `seq`, so appending
//     again would duplicate them. A task whose conversation already has turns
//     on the backend (per the baseline) gets no turns appended; the compare
//     step still checks them.
//   - An attachment row that exists on the backend only gets `filename` and
//     `position` (the server locks the rest). Bytes upload only when the
//     backend has none yet.
//   - The backend never revives a deleted row (§6.4). A row deleted there is
//     not sent again and is reported. Recently Deleted tasks and projects are
//     upserted then deleted, so their ids stay reserved; they can't be
//     restored on the backend afterwards.

@MainActor
@Observable
final class TaskBackendImporter {
  static let shared = TaskBackendImporter()

  enum Phase: Equatable { case idle, running, finished }

  private(set) var phase: Phase = .idle
  /// One line for the pane while a run is going.
  private(set) var progress = ""
  /// The final one-line result.
  private(set) var resultLine: String?
  /// Rows left out, rejected, or different on the backend. The pane shows
  /// the first 20.
  private(set) var issues: [TaskBackendIssue] = []
  private(set) var signedIn = TaskBackendClient.hasSession

  private let client = TaskBackendClient.shared
  private let batchSize = 500

  // MARK: - Session

  func signIn(identityToken: String, rawNonce: String) async throws {
    try await client.signIn(identityToken: identityToken, rawNonce: rawNonce)
    signedIn = TaskBackendClient.hasSession
  }

  func signOut() async {
    await client.signOut()
    signedIn = TaskBackendClient.hasSession
    resultLine = nil
    issues = []
  }

  // MARK: - Run

  func run() async {
    guard phase != .running else { return }
    phase = .running
    issues = []
    resultLine = nil
    defer {
      phase = .finished
      progress = ""
      signedIn = TaskBackendClient.hasSession
    }
    do {
      resultLine = try await runImport()
    } catch let error as TaskBackendError {
      resultLine = "Stopped. " + (error.errorDescription ?? "Unknown error.")
    } catch let stop as Refusal {
      resultLine = stop.message
    } catch {
      resultLine = "Stopped. \(error.localizedDescription)"
    }
  }

  private struct Refusal: Error { let message: String }

  /// Everything read from the mirror, mapped and validated.
  private struct LocalPlan {
    var areas: [BackendRowPlan] = []
    var projects: [BackendRowPlan] = []
    var tasks: [BackendRowPlan] = []
    var convos: [BackendRowPlan] = []
    var turns: [BackendTurnsPlan] = []
    var attachments: [BackendAttachmentPlan] = []
    var recordNames: Set<String> = []
  }

  private func runImport() async throws -> String {
    // 1–2. Preflight and read.
    progress = "Reading tasks on this Mac…"
    var plan = try readLocal()
    let engine = SeptenaServices.shared.ckEngine
    guard engine.isStarted else {
      throw Refusal(message: "iCloud sync has not started yet. Try again in a moment.")
    }
    guard !engine.isBootstrapping else {
      throw Refusal(message: "iCloud is still downloading your data. Try again when it finishes.")
    }
    let pending = engine.pendingChangeCount(recordNames: plan.recordNames)
    guard pending == 0 else {
      throw Refusal(message: "\(pending) task changes still wait to sync to iCloud. Try again when they are sent.")
    }

    // 3. Baseline.
    progress = "Reading the backend…"
    let baseline = try await pullAll()

    // 4. Build and push ops.
    let ops = buildOps(&plan, baseline: baseline)
    let rejected = try await pushAll(ops)
    try await uploadBytes(plan.attachments, baseline: baseline, rejected: rejected)

    // 5. Verify.
    progress = "Checking the copy…"
    let after = try await pullAll()
    return verify(plan, against: after)
  }

  // MARK: - Read the mirror

  private func readLocal() throws -> LocalPlan {
    let context = LocalStore.shared.container.mainContext
    let areas = try context.fetch(FetchDescriptor<AreaEntity>())
    let projects = try context.fetch(FetchDescriptor<ProjectEntity>())
    let tasks = try context.fetch(FetchDescriptor<TaskEntity>())
    let attachments = try context.fetch(FetchDescriptor<TaskAttachmentEntity>())

    var plan = LocalPlan()
    func take(_ r: Result<BackendRowPlan, TaskBackendIssue>, into list: inout [BackendRowPlan]) {
      switch r {
      case .success(let row): list.append(row)
      case .failure(let issue): issues.append(issue)
      }
    }

    for a in areas.sorted(by: { $0.id < $1.id }) {
      plan.recordNames.insert(AreaCloudKitSchema.recordName(for: a.id))
      take(TaskBackendMapping.area(a), into: &plan.areas)
    }
    for p in projects.sorted(by: { $0.id < $1.id }) {
      plan.recordNames.insert(ProjectCloudKitSchema.recordName(for: p.id))
      take(TaskBackendMapping.project(p), into: &plan.projects)
    }
    // Headings before their members. The server does not need it; it keeps
    // the op order, and so the op ids, the same from run to run.
    let orderedTasks = tasks.sorted {
      $0.isHeading != $1.isHeading ? $0.isHeading : $0.id < $1.id
    }
    var deletedTasks: Set<String> = []
    for t in orderedTasks {
      plan.recordNames.insert(t.id)
      take(TaskBackendMapping.task(t), into: &plan.tasks)
      if t.deletedAt != nil {
        deletedTasks.insert(t.id)
        continue  // the backend deletes a task's conversation with it
      }
      switch TaskBackendMapping.convo(taskID: t.id, json: t.conversationJSON) {
      case .success(.some(let (row, turns))):
        plan.convos.append(row)
        if !turns.turns.isEmpty { plan.turns.append(turns) }
      case .success(.none): break
      case .failure(let issue): issues.append(issue)
      }
    }
    let taskIDs = Set(tasks.map(\.id))
    for a in attachments.sorted(by: { $0.id < $1.id }) {
      plan.recordNames.insert(TaskAttachmentCloudKitSchema.recordName(for: a.id))
      // A deleted task's attachments go with it on the backend.
      if deletedTasks.contains(a.taskID) { continue }
      guard taskIDs.contains(a.taskID) else {
        issues.append(TaskBackendIssue(entity: .attachment, id: a.id, reason: "its task is not on this Mac"))
        continue
      }
      switch TaskBackendMapping.attachment(a) {
      case .success(let p): plan.attachments.append(p)
      case .failure(let issue): issues.append(issue)
      }
    }
    return plan
  }

  // MARK: - Backend state

  private struct ServerState {
    var rows: [BackendEntity: [String: [String: BackendJSON]]] = [:]
    var turns: [String: [[String: BackendJSON]]] = [:]

    func row(_ e: BackendEntity, _ id: String) -> [String: BackendJSON]? { rows[e]?[id] }
    func isDeleted(_ e: BackendEntity, _ id: String) -> Bool {
      guard let r = row(e, id), let d = r["deletedAt"] else { return false }
      return !d.isNull
    }
    func isLive(_ e: BackendEntity, _ id: String) -> Bool { row(e, id) != nil && !isDeleted(e, id) }
  }

  private func pullAll() async throws -> ServerState {
    var state = ServerState()
    var since = 0
    var pages = 0
    while true {
      let page = try await client.pull(since: since)
      if page.resetRequired == true { throw TaskBackendError.badResponse("pull asked for a reset") }
      for change in page.changes {
        if change.entity == .turn {
          guard let taskID = change.row["taskId"]?.stringValue else {
            throw TaskBackendError.badResponse("turn without taskId")
          }
          state.turns[taskID, default: []].append(change.row)
        } else {
          guard let id = change.row["id"]?.stringValue else { throw TaskBackendError.badResponse("row without id") }
          state.rows[change.entity, default: [:]][id] = change.row
        }
      }
      pages += 1
      guard page.hasMore else { break }
      guard page.nextSince > since, pages < 10_000 else { throw TaskBackendError.badResponse("pull did not advance") }
      since = page.nextSince
    }
    return state
  }

  // MARK: - Ops

  private func buildOps(_ plan: inout LocalPlan, baseline: ServerState) -> [BackendOp] {
    var ops: [BackendOp] = []
    var deletes: [BackendOp] = []

    func rows(_ list: [BackendRowPlan]) {
      for row in list {
        if baseline.isDeleted(row.entity, row.id) {
          // Deleted stays deleted (§6.4). Nothing to send for a row that is
          // deleted on both sides; report one that is live here.
          if !row.deleted {
            issues.append(TaskBackendIssue(entity: row.entity, id: row.id, reason: "deleted on the backend, not copied"))
          }
          continue
        }
        ops.append(.upsert(row.entity, id: row.id, fields: row.fields))
        if row.deleted { deletes.append(.delete(row.entity, id: row.id)) }
      }
    }
    rows(plan.areas)
    rows(plan.projects)
    rows(plan.tasks)
    ops += deletes

    for convo in plan.convos where !baseline.isDeleted(.task, convo.id) {
      ops.append(.upsert(.convo, id: convo.id, fields: convo.fields))
    }
    for thread in plan.turns where !baseline.isDeleted(.task, thread.taskID) {
      // Append-only on the server: never append to a thread that is there.
      guard (baseline.turns[thread.taskID] ?? []).isEmpty else { continue }
      for (i, turn) in thread.turns.enumerated() {
        ops.append(.appendTurn(taskID: thread.taskID, index: i, turn: turn))
      }
    }
    for att in plan.attachments {
      let id = att.row.id
      if baseline.isDeleted(.attachment, id) {
        issues.append(TaskBackendIssue(entity: .attachment, id: id, reason: "deleted on the backend, not copied"))
        continue
      }
      if baseline.isLive(.attachment, id) {
        // Only the display fields may change after insert.
        let fields = att.row.fields.filter { $0.key == "filename" || $0.key == "position" }
        ops.append(.upsert(.attachment, id: id, fields: fields))
      } else {
        ops.append(.upsert(.attachment, id: id, fields: att.row.fields))
      }
    }
    return ops
  }

  /// Pushes in batches. Returns the keys (`entity:id`) of ops the server did
  /// not apply, so the upload step can skip their bytes.
  private func pushAll(_ all: [BackendOp]) async throws -> Set<String> {
    var notApplied: Set<String> = []
    var done = 0
    var start = 0
    while start < all.count {
      var batch = Array(all[start..<min(start + batchSize, all.count)])
      start += batch.count
      progress = "Copying… \(done) of \(all.count)"
      var tries = 0
      while !batch.isEmpty {
        tries += 1
        switch try await client.push(batch) {
        case .ok(let response):
          for (op, result) in zip(batch, response.results) {
            switch result.status {
            case .applied, .noop:
              break
            case .dropped:
              notApplied.insert("\(op.entity.rawValue):\(op.id)")
              issues.append(TaskBackendIssue(entity: op.entity, id: op.id, reason: "dropped: deleted on the backend"))
            case .rejected:
              notApplied.insert("\(op.entity.rawValue):\(op.id)")
              issues.append(TaskBackendIssue(entity: op.entity, id: op.id,
                                             reason: "rejected: \(result.reason ?? "no reason")"))
            }
          }
          done += batch.count
          batch = []
        case .refused(let body):
          // The Worker validates the whole batch first. Take out the ops its
          // issues point at (`ops.<index>…`) and send the rest again.
          let bad = Set((body?.issues ?? []).compactMap { issue -> Int? in
            guard let path = issue.path, path.count >= 2, path[0] == .string("ops") else { return nil }
            if case .int(let i) = path[1], i >= 0, Int(i) < batch.count { return Int(i) }
            return nil
          })
          let message = body?.issues?.first?.message ?? body?.error ?? "refused"
          if bad.isEmpty || tries >= 3 {
            for op in batch {
              notApplied.insert("\(op.entity.rawValue):\(op.id)")
              issues.append(TaskBackendIssue(entity: op.entity, id: op.id, reason: "batch refused: \(message)"))
            }
            done += batch.count
            batch = []
          } else {
            for i in bad.sorted() {
              let op = batch[i]
              notApplied.insert("\(op.entity.rawValue):\(op.id)")
              let reason = body?.issues?.first(where: { $0.path?.count ?? 0 >= 2 && $0.path?[1] == .int(Int64(i)) })?.message
              issues.append(TaskBackendIssue(entity: op.entity, id: op.id, reason: "refused: \(reason ?? message)"))
            }
            done += bad.count
            batch = batch.enumerated().filter { !bad.contains($0.offset) }.map(\.element)
          }
        }
      }
    }
    return notApplied
  }

  private func uploadBytes(_ attachments: [BackendAttachmentPlan], baseline: ServerState,
                           rejected: Set<String>) async throws {
    let todo = attachments.filter { att in
      let id = att.row.id
      guard !rejected.contains("attachment:\(id)"), !baseline.isDeleted(.attachment, id) else { return false }
      let uploaded = baseline.row(.attachment, id)?["uploadedAt"] ?? .null
      return uploaded.isNull
    }
    for (i, att) in todo.enumerated() {
      progress = "Uploading attachments… \(i + 1) of \(todo.count)"
      let id = att.row.id
      guard let url = att.fileURL, FileManager.default.fileExists(atPath: url.path) else {
        issues.append(TaskBackendIssue(entity: .attachment, id: id, reason: "file is not on this Mac, bytes not copied"))
        continue
      }
      let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
      guard size == att.byteCount else {
        issues.append(TaskBackendIssue(entity: .attachment, id: id,
                                       reason: "file is \(size ?? -1) bytes, the row says \(att.byteCount); bytes not copied"))
        continue
      }
      do {
        try await client.uploadAttachment(id: id, fileURL: url, contentType: att.contentType)
      } catch let error as TaskBackendError {
        if error == .notSignedIn { throw error }
        issues.append(TaskBackendIssue(entity: .attachment, id: id,
                                       reason: "upload failed: \(error.errorDescription ?? "unknown")"))
      }
    }
  }

  // MARK: - Verify

  private func verify(_ plan: LocalPlan, against server: ServerState) -> String {
    var mismatches: [TaskBackendIssue] = []
    var matched: [BackendEntity: Int] = [:]
    // Rows already reported as not copied are not reported a second time.
    let reported = Set(issues.map { "\($0.entity.rawValue):\($0.id)" })

    func check(_ rows: [BackendRowPlan]) {
      for row in rows where !reported.contains("\(row.entity.rawValue):\(row.id)") {
        let live = server.isLive(row.entity, row.id)
        if row.deleted {
          if live { mismatches.append(.init(entity: row.entity, id: row.id, reason: "deleted here, live on the backend")) }
          continue
        }
        guard let serverRow = server.row(row.entity, row.id), live else {
          let why = server.row(row.entity, row.id) == nil ? "missing on the backend" : "deleted on the backend"
          mismatches.append(.init(entity: row.entity, id: row.id, reason: why))
          continue
        }
        let differing = row.fields.keys.sorted().filter {
          row.fields[$0]!.canonical != (serverRow[$0] ?? .null).canonical
        }
        if differing.isEmpty {
          matched[row.entity, default: 0] += 1
        } else {
          mismatches.append(.init(entity: row.entity, id: row.id, reason: "differs: " + differing.joined(separator: ", ")))
        }
      }
    }
    check(plan.areas)
    check(plan.projects)
    check(plan.tasks)
    check(plan.convos)
    check(plan.attachments.map(\.row))

    for att in plan.attachments where server.isLive(.attachment, att.row.id) {
      if (server.row(.attachment, att.row.id)?["uploadedAt"] ?? .null).isNull {
        mismatches.append(.init(entity: .attachment, id: att.row.id, reason: "no bytes on the backend"))
      }
    }

    // Turns: same count and same content, in order.
    var turnsMatched = 0
    let serverOnlyKeys: Set<String> = ["taskId", "seq", "rev", "updatedAt"]
    for thread in plan.turns {
      let remote = (server.turns[thread.taskID] ?? [])
        .sorted { ($0["seq"].flatMap(Self.intValue) ?? 0) < ($1["seq"].flatMap(Self.intValue) ?? 0) }
        .map { $0.filter { !serverOnlyKeys.contains($0.key) && !$0.value.isNull } }
      if remote.count != thread.turns.count {
        mismatches.append(.init(entity: .turn, id: thread.taskID,
                                reason: "\(thread.turns.count) turns here, \(remote.count) on the backend"))
        continue
      }
      let differs = zip(thread.turns, remote).contains {
        BackendJSON.object($0).canonical != BackendJSON.object($1).canonical
      }
      if differs {
        mismatches.append(.init(entity: .turn, id: thread.taskID, reason: "turn content differs"))
      } else {
        turnsMatched += thread.turns.count
      }
    }

    // Rows live on the backend that this Mac does not have.
    let local: [BackendEntity: Set<String>] = [
      .area: Set(plan.areas.map(\.id)), .project: Set(plan.projects.map(\.id)),
      .task: Set(plan.tasks.map(\.id)), .convo: Set(plan.convos.map(\.id)),
      .attachment: Set(plan.attachments.map(\.row.id)),
    ]
    for (entity, ids) in local {
      for id in (server.rows[entity] ?? [:]).keys.sorted() where server.isLive(entity, id) && !ids.contains(id) {
        mismatches.append(.init(entity: entity, id: id, reason: "on the backend only"))
      }
    }

    let notSent = issues.count
    issues += mismatches

    let copied = "\(matched[.task] ?? 0) tasks, \(matched[.area] ?? 0) areas, \(matched[.project] ?? 0) projects, "
      + "\(matched[.attachment] ?? 0) attachments, \(turnsMatched) turns copied."
    if notSent == 0, mismatches.isEmpty { return copied + " All match." }
    var parts: [String] = []
    if notSent > 0 { parts.append("\(notSent) not copied") }
    if !mismatches.isEmpty { parts.append("\(mismatches.count) differ") }
    return copied + " " + parts.joined(separator: ", ") + "."
  }

  nonisolated private static func intValue(_ v: BackendJSON) -> Int? {
    switch v {
    case .int(let i): return Int(i)
    case .double(let d): return Int(d)
    default: return nil
    }
  }
}
