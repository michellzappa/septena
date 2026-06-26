import Foundation
import SwiftData

enum ThingsImportSupport {

  @MainActor
  static func existingState(context: ModelContext) -> ThingsToSeptenaMapper.ExistingState {
    let areas = (try? context.fetch(FetchDescriptor<AreaEntity>())) ?? []
    let projects = (try? context.fetch(FetchDescriptor<ProjectEntity>())) ?? []
    let tasks = (try? context.fetch(FetchDescriptor<TaskEntity>())) ?? []

    let liveIDs = Set(tasks.filter { $0.deletedAt == nil }.map(\.id))
    let allMappedThings = Set(ThingsImportMapping.allMappedTaskThingsIDs())
    let deletedMapped = allMappedThings.filter { thingsID in
      guard let septena = ThingsImportMapping.taskSeptenaID(for: thingsID) else { return false }
      return !liveIDs.contains(septena)
    }

    return ThingsToSeptenaMapper.ExistingState(
      areas: areas.map { ($0.id, $0.title) },
      projects: projects.map { ($0.id, $0.title, $0.area) },
      liveTaskSeptenaIDs: liveIDs,
      deletedMappedThingsTaskIDs: Set(deletedMapped)
    )
  }
}
