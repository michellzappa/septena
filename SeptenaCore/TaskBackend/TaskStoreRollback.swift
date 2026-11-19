import CloudKit
import Foundation
import SwiftData

// "Copy tasks back to iCloud" — the rollback writer for the task-store cutover
// (docs/SEPTASK_BACKEND.md §9, "Rollback after phase 3"). Rows created or
// changed on the backend after cutover are not in CloudKit, so this writes the
// local SwiftData state (which the backend sync kept current) back through the
// ordinary CKEngine path, then sets the mode to `cloudkit`.
//
// Order of one run:
//   1. Send what the outbox still holds to the backend (best effort), so the
//      backend copy left behind is current too.
//   2. Read the current CloudKit records of the four task types and copy
//      their system fields (change tags) onto the matching local rows. A
//      queued save then REPLACES the CloudKit record instead of failing the
//      change-tag check — which would make CKEngine fetch the CloudKit
//      version and apply it over the local row (a backend edit lost). A local
//      row with no CloudKit record gets its stale tag cleared, so it saves as
//      new.
//   3. Queue a CloudKit save for every local task, area, project and
//      attachment, and a delete for every record of a row deleted while on the
//      backend (the sync shadow's `gone` rows that are no longer local).
//      CloudKit records with no local row and no such mark are left alone and
//      counted: they may be real data from a device that stayed on CloudKit.
//   4. Send, with CloudKit's task types still frozen for INCOMING changes, so
//      a lagging device cannot overwrite a row between steps 2 and 4.
//   5. Set the mode to `cloudkit`, stop the backend sync, clear its queue.
//
// Idempotent: a second run re-reads the tags and queues the same saves.

@MainActor
enum TaskStoreRollback {
  struct Report: Sendable, Equatable {
    var saved = 0
    var deleted = 0
    /// CloudKit records of the task types with no local row, left in place.
    var cloudKitOnly = 0
    /// CKEngine's send-failure summary, if any record failed.
    var sendFailures: String?
  }

  static func copyBackToICloud() async throws -> Report {
    let ck = SeptenaServices.shared.ckEngine
    guard ck.isStarted else {
      throw TaskStoreSwitchError.cloudKitNotReady("iCloud sync has not started yet. Try again in a moment.")
    }
    let sync = TaskSyncEngine.shared
    let wasBackend = TaskStoreMode.current == .backend

    // 1.
    if wasBackend { await sync.flushBeforeRollback() }

    // 2.
    let remote: [CKRecord]
    do {
      remote = try await ck.fetchAllRecords(recordTypes: Array(TaskStoreMode.backendOwnedRecordTypes))
    } catch {
      throw TaskStoreSwitchError.rollbackFailed("reading iCloud: \(error.localizedDescription)")
    }
    var remoteByName: [String: CKRecord] = [:]
    for r in remote { remoteByName[r.recordID.recordName] = r }

    let context = LocalStore.shared.container.mainContext
    var saves: [String] = []
    func adopt<E: CloudKitSystemFieldsBacked>(_ entity: E, recordName: String) {
      if let r = remoteByName[recordName] {
        entity.captureCloudKitSystemFields(from: r)
      } else {
        entity.cloudKitSystemFields = nil
      }
      saves.append(recordName)
    }
    for a in (try? context.fetch(FetchDescriptor<AreaEntity>())) ?? [] {
      adopt(a, recordName: AreaCloudKitSchema.recordName(for: a.id))
    }
    for p in (try? context.fetch(FetchDescriptor<ProjectEntity>())) ?? [] {
      adopt(p, recordName: ProjectCloudKitSchema.recordName(for: p.id))
    }
    // Headings first, so a heading record exists before its members.
    let tasks = ((try? context.fetch(FetchDescriptor<TaskEntity>())) ?? [])
      .sorted { $0.isHeading && !$1.isHeading }
    for t in tasks { adopt(t, recordName: t.id) }
    for a in (try? context.fetch(FetchDescriptor<TaskAttachmentEntity>())) ?? [] {
      adopt(a, recordName: TaskAttachmentCloudKitSchema.recordName(for: a.id))
    }
    guard StoreHealth.save(context, op: "rollback.adoptTags") else {
      throw TaskStoreSwitchError.rollbackFailed("the local store could not be saved")
    }

    // 3.
    let local = Set(saves)
    let gone = sync.goneRecordNames()
    let deletes = remoteByName.keys.filter { gone.contains($0) && !local.contains($0) }.sorted()
    var report = Report()
    report.saved = saves.count
    report.deleted = deletes.count
    report.cloudKitOnly = remoteByName.keys.filter { !local.contains($0) && !gone.contains($0) }.count

    // 4.
    ck.taskRollbackSending = true
    defer { ck.taskRollbackSending = false }
    ck.queueTaskRollbackSaves(recordNames: saves)
    ck.queueTaskRollbackDeletions(recordNames: deletes)
    do {
      try await ck.sendChanges()
    } catch {
      throw TaskStoreSwitchError.rollbackFailed("sending to iCloud: \(error.localizedDescription)")
    }
    report.sendFailures = ck.consumeLastSendFailureSummary()
    if let failures = report.sendFailures {
      // Keep the backend mode: a re-run re-queues everything. Flipping now
      // would let incoming CloudKit changes overwrite rows not yet sent.
      throw TaskStoreSwitchError.rollbackFailed(failures)
    }

    // 5.
    #if SEPTASK
    TaskStoreMode.store(.cloudkit)
    #endif
    sync.didRollBack()
    SeptenaLog.info("[TaskSync] rollback done: saved=\(report.saved) deleted=\(report.deleted) cloudKitOnly=\(report.cloudKitOnly); mode → cloudkit")
    return report
  }
}
