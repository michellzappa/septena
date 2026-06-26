import Foundation
import SwiftData

@MainActor
enum ThingsImportApply {

  static func apply(
    plan: ThingsImportPlan,
    taskMutator: TaskMutator,
    areasMutator: AreasMutator,
    projectsMutator: ProjectsMutator,
    onProgress: ((Double) -> Void)? = nil
  ) async throws -> ThingsImportApplyResult {
    var result = ThingsImportApplyResult()
    let createdAreaThings = Set(plan.areasToCreate.map(\.thingsID))
    let createdProjectThings = Set(plan.projectsToCreate.map(\.thingsID))

    for (thingsID, septenaID) in plan.areaIDByThingsID {
      ThingsImportMapping.setArea(thingsID: thingsID, septenaID: septenaID)
      if !createdAreaThings.contains(thingsID) { result.areasMerged += 1 }
    }
    for (thingsID, septenaID) in plan.projectIDByThingsID {
      ThingsImportMapping.setProject(thingsID: thingsID, septenaID: septenaID)
      if !createdProjectThings.contains(thingsID) { result.projectsMerged += 1 }
    }

    let total = Double(
      plan.areasToCreate.count + plan.projectsToCreate.count + plan.tasksToImport.count
    )
    var done = 0.0
    func tick() {
      done += 1
      if total > 0 { onProgress?(done / total) }
    }

    for area in plan.areasToCreate {
      _ = try await areasMutator.createWithExplicitID(id: area.septenaID, title: area.title)
      ThingsImportMapping.setArea(thingsID: area.thingsID, septenaID: area.septenaID)
      result.areasCreated += 1
      tick()
    }

    for project in plan.projectsToCreate {
      _ = try await projectsMutator.createWithExplicitID(
        id: project.septenaID, title: project.title, area: project.areaSeptenaID)
      if let notes = project.notes {
        try await projectsMutator.setNotes(id: project.septenaID, notes: notes)
      }
      if project.status != .active {
        let ckStatus: ProjectStatus = switch project.status {
        case .active: .active
        case .done: .done
        case .cancelled: .cancelled
        }
        try await projectsMutator.setStatus(id: project.septenaID, status: ckStatus)
      }
      ThingsImportMapping.setProject(thingsID: project.thingsID, septenaID: project.septenaID)
      result.projectsCreated += 1
      tick()
    }

    for task in plan.tasksToImport {
      let created = taskMutator.create(
        title: task.title,
        area: task.projectSeptenaID == nil ? task.areaSeptenaID : nil,
        project: task.projectSeptenaID,
        scheduled: task.scheduled,
        deadline: task.deadline,
        today: task.today,
        notes: task.notes,
        source: TaskSource.things
      )

      if task.position != 0 {
        taskMutator.reorder(id: created.id, toPosition: task.position)
      }

      switch task.status {
      case .done:
        taskMutator.complete(id: created.id)
      case .cancelled:
        taskMutator.cancel(id: created.id)
      case .open:
        break
      }

      if task.trashed {
        taskMutator.delete(id: created.id)
      }

      ThingsImportMapping.setTask(thingsID: task.thingsID, septenaID: created.id)
      result.tasksImported += 1
      tick()
    }

    result.tasksSkipped = plan.skippedDuplicates
    return result
  }
}
