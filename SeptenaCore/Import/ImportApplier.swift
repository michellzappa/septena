import Foundation
import SwiftData

// Apply and undo (docs/MOVING_IN_SPEC.md §4.3, §4.5). Every write goes through
// the mutators, so imported rows sync, notify and order like any other edit.
// The ledger is written before the first row and after every few, so a crash
// mid-import leaves a `partial` batch whose lineage makes a re-run resume
// instead of duplicating.

struct ImportUndoResult: Sendable, Hashable {
  var deleted = 0
  /// Created rows left in place because the user changed them since.
  var keptEdited = 0
  /// Imported areas/projects left because they now hold the user's own tasks.
  var keptNonEmpty = 0
}

@MainActor
enum ImportApplier {

  /// The snapshot `ImportPlanner.plan` needs.
  static func existing(context: ModelContext) -> ImportExisting {
    // Earlier Things imports must be in the lineage before any plan reads it.
    ImportLegacyThingsLineage.migrateIfNeeded(context: context)
    let areas = (try? context.fetch(FetchDescriptor<AreaEntity>())) ?? []
    let projects = ((try? context.fetch(FetchDescriptor<ProjectEntity>())) ?? []).filter { $0.deletedAt == nil }
    let tasks = (try? context.fetch(FetchDescriptor<TaskEntity>(
      predicate: #Predicate { $0.deletedAt == nil }))) ?? []
    return ImportExisting(
      areas: areas.map { ($0.id, $0.title) },
      projects: projects.map { ($0.id, $0.title, $0.area) },
      liveTaskIDs: Set(tasks.map(\.id)),
      liveAreaIDs: Set(areas.map(\.id)),
      liveProjectIDs: Set(projects.map(\.id)),
      lineage: ImportLedger.lineage())
  }

  static func apply(
    plan: ImportPlan,
    context: ModelContext,
    taskMutator: TaskMutator,
    areasMutator: AreasMutator,
    projectsMutator: ProjectsMutator,
    onProgress: ((Double) -> Void)? = nil
  ) async throws -> ImportLedgerBatch {
    let source = "import:\(plan.source.app)"
    var batch = ImportLedgerBatch(
      id: plan.batchID, source: plan.source, options: plan.options, state: .applying,
      startedAt: Date(), report: plan.report, items: [], bundle: plan.bundle)
    try ImportLedger.save(batch)

    let total = Double(plan.areas.count + plan.projects.count + plan.headings.count + plan.tasks.count)
    var done = 0.0
    func record(_ item: ImportLedgerItem) throws {
      batch.items.append(item)
      done += 1
      if total > 0 { onProgress?(done / total) }
      if batch.items.count % 50 == 0 { try ImportLedger.save(batch) }
    }

    do {
      for area in plan.areas {
        if area.action == .create {
          _ = try await areasMutator.createWithExplicitID(id: area.septenaID, title: area.title, context: area.notes)
          if let emoji = area.emoji { try await areasMutator.setEmoji(id: area.septenaID, emoji: emoji) }
        }
        try record(ImportLedgerItem(entity: .area, sourceId: area.sourceId, septenaID: area.septenaID,
                                    action: area.action, fingerprint: area.action == .create ? area.title : nil))
      }

      for project in plan.projects {
        if project.action == .create {
          _ = try await projectsMutator.createWithExplicitID(
            id: project.septenaID, title: project.title, area: project.areaSeptenaID)
          if let notes = project.notes { try await projectsMutator.setNotes(id: project.septenaID, notes: notes) }
          switch project.status {
          case .active: break
          case .done: try await projectsMutator.setStatus(id: project.septenaID, status: .done)
          case .cancelled: try await projectsMutator.setStatus(id: project.septenaID, status: .cancelled)
          }
        }
        try record(ImportLedgerItem(entity: .project, sourceId: project.sourceId, septenaID: project.septenaID,
                                    action: project.action, fingerprint: project.action == .create ? project.title : nil))
      }

      // Headings before their member tasks so the link resolves.
      var headingIDBySource: [String: String] = [:]
      for heading in plan.headings {
        guard let created = taskMutator.createHeading(title: heading.title, project: heading.projectSeptenaID)
        else { continue }
        taskMutator.reorder(id: created.id, toPosition: heading.position)
        headingIDBySource[heading.sourceId] = created.id
        try record(ImportLedgerItem(entity: .heading, sourceId: heading.sourceId, septenaID: created.id,
                                    action: .create, fingerprint: fingerprint(taskID: created.id, context: context)))
      }

      for task in plan.tasks {
        let created = taskMutator.create(
          title: task.title,
          area: task.areaSeptenaID,
          project: task.projectSeptenaID,
          scheduled: task.scheduled,
          deadline: task.deadline,
          today: task.today,
          notes: task.notes,
          source: source)
        taskMutator.reorder(id: created.id, toPosition: task.position)
        if let heading = task.headingSourceId.flatMap({ headingIDBySource[$0] }) ?? task.existingHeadingID {
          taskMutator.setHeading(id: created.id, heading: heading)
        }
        if let reminder = task.reminder {
          taskMutator.setReminder(id: created.id, reminder: TaskReminder(fireAt: reminder.fireAt, mode: reminder.mode))
        }
        if let recurrence = task.recurrence {
          taskMutator.setRecurrence(id: created.id, recurrence: recurrence.recurrence)
        }
        switch task.status {
        case .open: break
        case .done: taskMutator.complete(id: created.id)
        case .cancelled: taskMutator.cancel(id: created.id)
        }
        if task.trashed { taskMutator.delete(id: created.id) }
        try record(ImportLedgerItem(entity: .task, sourceId: task.sourceId, septenaID: created.id,
                                    action: .create, fingerprint: fingerprint(taskID: created.id, context: context)))
        // Task creation is synchronous; yield now and then so the progress
        // bar can draw during a large import.
        if batch.items.count % 25 == 0 { await Task.yield() }
      }
    } catch {
      batch.state = .partial
      batch.finishedAt = Date()
      batch.lastError = error.localizedDescription
      try? ImportLedger.save(batch)
      throw error
    }

    batch.state = .applied
    batch.finishedAt = Date()
    try ImportLedger.save(batch)
    return batch
  }

  /// Deletes (to Recently Deleted) what the batch created and the user has
  /// not touched. Never purges, never deletes a merged container, never
  /// deletes a container that now holds the user's own rows.
  static func undo(
    batchID: String,
    context: ModelContext,
    taskMutator: TaskMutator,
    areasMutator: AreasMutator,
    projectsMutator: ProjectsMutator
  ) async throws -> ImportUndoResult {
    var batch: ImportLedgerBatch
    do { batch = try ImportLedger.load(batchID) } catch { throw ImportError.batchNotFound }
    guard !batch.isLegacy else { throw ImportError.legacyBatchNotUndoable }
    guard batch.state != .undone else { return ImportUndoResult() }

    var result = ImportUndoResult()
    var kept: [String] = []
    let created = batch.items.filter { $0.action == .create }
    let createdIDs = Set(created.map(\.septenaID))

    // Tasks first, headings after (deleting a heading dissolves its members).
    for entity in [ImportEntity.task, .heading] {
      for item in created where item.entity == entity {
        guard let fp = fingerprint(taskID: item.septenaID, context: context) else { continue }
        if fp == item.fingerprint {
          taskMutator.delete(id: item.septenaID)
          result.deleted += 1
        } else {
          result.keptEdited += 1
          kept.append(item.septenaID)
        }
      }
    }

    let liveTasks = (try? context.fetch(FetchDescriptor<TaskEntity>(
      predicate: #Predicate { $0.deletedAt == nil }))) ?? []
    let projects = (try? context.fetch(FetchDescriptor<ProjectEntity>())) ?? []
    let areas = (try? context.fetch(FetchDescriptor<AreaEntity>())) ?? []

    for item in created where item.entity == .project {
      guard let project = projects.first(where: { $0.id == item.septenaID }), project.deletedAt == nil else { continue }
      if liveTasks.contains(where: { $0.project == item.septenaID && !createdIDs.contains($0.id) }) {
        result.keptNonEmpty += 1; kept.append(item.septenaID); continue
      }
      if project.title != item.fingerprint {
        result.keptEdited += 1; kept.append(item.septenaID); continue
      }
      try await projectsMutator.delete(id: item.septenaID)
      result.deleted += 1
    }

    for item in created where item.entity == .area {
      guard let area = areas.first(where: { $0.id == item.septenaID }) else { continue }
      let holdsTasks = liveTasks.contains { $0.area == item.septenaID && !createdIDs.contains($0.id) }
      // A project in the area survives undo when the user made it, or when
      // undo kept it above.
      let holdsProjects = projects.contains {
        $0.deletedAt == nil && $0.area == item.septenaID
          && (!createdIDs.contains($0.id) || kept.contains($0.id))
      }
      if holdsTasks || holdsProjects {
        result.keptNonEmpty += 1; kept.append(item.septenaID); continue
      }
      if area.title != item.fingerprint {
        result.keptEdited += 1; kept.append(item.septenaID); continue
      }
      try await areasMutator.delete(id: item.septenaID)
      result.deleted += 1
    }

    batch.state = .undone
    batch.keptOnUndo = kept
    try ImportLedger.save(batch)
    return result
  }

  /// The fields a user edit would change, as the store holds them now. Nil
  /// when the row is gone or already deleted.
  static func fingerprint(taskID: String, context: ModelContext) -> String? {
    let rows = (try? context.fetch(FetchDescriptor<TaskEntity>(predicate: #Predicate { $0.id == taskID }))) ?? []
    guard let row = rows.first, row.deletedAt == nil else { return nil }
    return [
      row.title, row.notes ?? "", row.statusRaw, row.scheduled ?? "", row.deadline ?? "",
      row.today ? "1" : "0", row.area ?? "", row.project ?? "", row.heading ?? "",
    ].joined(separator: "\u{1F}")
  }
}
