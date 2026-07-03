import Foundation

/// Maps a parsed Things snapshot into a Septena import plan with collision detection.
enum ThingsToSeptenaMapper {

  struct ExistingState: Sendable {
    var areas: [(id: String, title: String)]
    var projects: [(id: String, title: String, areaID: String?)]
    /// Septena task ids that still exist (for mapping idempotency).
    var liveTaskSeptenaIDs: Set<String>
    /// Things task uuids whose mapped Septena row was deleted.
    var deletedMappedThingsTaskIDs: Set<String>
  }

  static func buildPlan(
    snapshot: ThingsDatabaseSnapshot,
    existing: ExistingState,
    options: ThingsImportOptions,
    collisionOverrides: [String: ThingsCollisionAction] = [:],
    idGenerator: () -> String = { ThingsImportID.generate() }
  ) -> ThingsImportPlan {
    var collisions: [ThingsCollision] = []
    var areaMap: [String: String] = [:]   // things area uuid → septena id
    var projectMap: [String: String] = [:]
    var areasToCreate: [ThingsPlannedArea] = []
    var projectsToCreate: [ThingsPlannedProject] = []
    var usedAreaIDs = Set(existing.areas.map(\.id))
    var usedProjectIDs = Set(existing.projects.map(\.id))

    let areasByTitle = Dictionary(
      grouping: existing.areas,
      by: { $0.title.normalizedForThingsMatch }
    )
    let projectsByKey = Dictionary(
      grouping: existing.projects,
      by: { projectMatchKey(title: $0.title, areaID: $0.areaID) }
    )

    // Areas
    for area in snapshot.areas {
      if let mapped = ThingsImportMapping.areaSeptenaID(for: area.id) {
        areaMap[area.id] = mapped
        continue
      }
      let action = collisionOverrides[area.id]
        ?? defaultAreaAction(title: area.title, existing: areasByTitle, merge: options.mergeMatchingTitles)

      switch resolveAreaAction(action, title: area.title, existing: areasByTitle) {
      case .merge(let septenaID):
        areaMap[area.id] = septenaID
        if let match = existing.areas.first(where: { $0.id == septenaID }), match.title != area.title {
          collisions.append(ThingsCollision(
            kind: .area, thingsID: area.id, thingsTitle: area.title,
            existingSeptenaID: septenaID, existingSeptenaTitle: match.title,
            action: .merge))
        }
      case .skip:
        collisions.append(ThingsCollision(
          kind: .area, thingsID: area.id, thingsTitle: area.title,
          existingSeptenaID: nil, existingSeptenaTitle: nil, action: .skip))
      case .create(let title):
        let newID = uniqueID(generator: idGenerator, used: &usedAreaIDs)
        areaMap[area.id] = newID
        let isMerge = false
        areasToCreate.append(ThingsPlannedArea(
          thingsID: area.id, title: title, septenaID: newID, isMerge: isMerge))
        if let match = areasByTitle[area.title.normalizedForThingsMatch]?.first, options.mergeMatchingTitles {
          collisions.append(ThingsCollision(
            kind: .area, thingsID: area.id, thingsTitle: area.title,
            existingSeptenaID: match.id, existingSeptenaTitle: match.title,
            action: .createNew))
        }
      }
    }

    // Projects
    for project in snapshot.projects {
      if let mapped = ThingsImportMapping.projectSeptenaID(for: project.id) {
        projectMap[project.id] = mapped
        continue
      }
      let parentAreaSeptena = project.areaID.flatMap { areaMap[$0] }
      let key = projectMatchKey(title: project.title, areaID: parentAreaSeptena)
      let action = collisionOverrides[project.id]
        ?? defaultProjectAction(key: key, existing: projectsByKey, merge: options.mergeMatchingTitles)

      switch resolveProjectAction(action, title: project.title, key: key, existing: projectsByKey) {
      case .merge(let septenaID):
        projectMap[project.id] = septenaID
      case .skip:
        collisions.append(ThingsCollision(
          kind: .project, thingsID: project.id, thingsTitle: project.title,
          existingSeptenaID: nil, existingSeptenaTitle: nil, action: .skip))
      case .create(let title):
        let newID = uniqueID(generator: idGenerator, used: &usedProjectIDs)
        projectMap[project.id] = newID
        let status: ThingsMappedProjectStatus = {
          switch project.status {
          case .completed: return .done
          case .cancelled: return .cancelled
          case .open: return .active
          }
        }()
        projectsToCreate.append(ThingsPlannedProject(
          thingsID: project.id,
          title: title,
          septenaID: newID,
          areaSeptenaID: parentAreaSeptena,
          notes: project.notes,
          status: status,
          isMerge: false))
      }
    }

    // Headings (Things `type = 2` section dividers). A heading is a task-shaped
    // row, so it reuses the task id-mapping table for idempotency. We only mark
    // a heading resolvable (its members can point at it) when it maps to a live
    // Septena row or is scheduled for creation this run.
    var headingsToCreate: [ThingsPlannedHeading] = []
    var resolvableHeadingIDs = Set<String>()   // Things heading uuids we can file under
    for heading in snapshot.headings {
      // A heading without a resolvable project can't be created — its members
      // fall back to the project's un-headed block (or Inbox). No data lost.
      guard let projectSeptena = heading.projectID.flatMap({ projectMap[$0] }) else { continue }

      if let mapped = ThingsImportMapping.taskSeptenaID(for: heading.id) {
        if existing.liveTaskSeptenaIDs.contains(mapped) {
          resolvableHeadingIDs.insert(heading.id)   // already imported & live — reuse
          continue
        }
        if existing.deletedMappedThingsTaskIDs.contains(heading.id), !options.reimportDeleted {
          continue   // deleted since last import and not re-importing — skip
        }
      }

      headingsToCreate.append(ThingsPlannedHeading(
        thingsID: heading.id,
        title: heading.title,
        projectSeptenaID: projectSeptena,
        position: heading.sortIndex))
      resolvableHeadingIDs.insert(heading.id)
    }

    // Tasks
    var tasksToImport: [ThingsPlannedTask] = []
    var skippedDuplicates = 0
    var viewCounts = ThingsSeptenaViewCounts()

    for task in snapshot.tasks {
      if let mappedSeptena = ThingsImportMapping.taskSeptenaID(for: task.id) {
        if existing.liveTaskSeptenaIDs.contains(mappedSeptena) {
          skippedDuplicates += 1
          continue
        }
        if existing.deletedMappedThingsTaskIDs.contains(task.id), !options.reimportDeleted {
          skippedDuplicates += 1
          continue
        }
      }

      let areaSeptena = task.projectID == nil ? task.areaID.flatMap { areaMap[$0] } : nil
      let projectSeptena = task.projectID.flatMap { projectMap[$0] }
      // File under a heading only when the project resolved (a heading always
      // lives in a project) and the heading itself is resolvable this run.
      let headingThingsID = (projectSeptena != nil)
        ? task.headingID.flatMap { resolvableHeadingIDs.contains($0) ? $0 : nil }
        : nil

      var notes = task.notes
      if options.appendTagsToNotes, !task.tags.isEmpty {
        let tagBlock = task.tags.map { "#\($0)" }.joined(separator: " ")
        notes = [notes, tagBlock].compactMap { $0 }.joined(separator: "\n\n")
      }
      if options.appendChecklistToNotes, !task.checklistLines.isEmpty {
        let list = task.checklistLines.joined(separator: "\n")
        notes = [notes, list].compactMap { $0 }.joined(separator: "\n\n")
      }

      let septenaStatus: ThingsMappedTaskStatus = {
        switch task.status {
        case .completed: return .done
        case .cancelled: return .cancelled
        case .open: return .open
        }
      }()

      let planned = ThingsPlannedTask(
        thingsID: task.id,
        title: task.title,
        notes: notes,
        areaSeptenaID: areaSeptena,
        projectSeptenaID: projectSeptena,
        headingThingsID: headingThingsID,
        today: task.today,
        scheduled: task.scheduled,
        deadline: task.deadline,
        position: task.sortIndex,
        status: septenaStatus,
        trashed: task.trashed,
        skipBecauseMapped: false
      )
      tasksToImport.append(planned)
      accumulateViewCounts(&viewCounts, task: planned)
    }

    return ThingsImportPlan(
      areasToCreate: areasToCreate,
      projectsToCreate: projectsToCreate,
      tasksToImport: tasksToImport,
      collisions: collisions,
      skippedDuplicates: skippedDuplicates,
      viewCounts: viewCounts,
      areaIDByThingsID: areaMap,
      projectIDByThingsID: projectMap,
      headingsToCreate: headingsToCreate
    )
  }

  // MARK: - Private

  private enum ResolveAction {
    case merge(String)
    case create(String)
    case skip
  }

  private static func defaultAreaAction(
    title: String,
    existing: [String: [(id: String, title: String)]],
    merge: Bool
  ) -> ThingsCollisionAction {
    guard merge, let matches = existing[title.normalizedForThingsMatch], let first = matches.first else {
      return .createNew
    }
    return matches.count > 1 ? .createNew : .merge
  }

  private static func defaultProjectAction(
    key: String,
    existing: [String: [(id: String, title: String, areaID: String?)]],
    merge: Bool
  ) -> ThingsCollisionAction {
    guard merge, let matches = existing[key], let first = matches.first else {
      return .createNew
    }
    return matches.count > 1 ? .createNew : .merge
  }

  private static func resolveAreaAction(
    _ action: ThingsCollisionAction,
    title: String,
    existing: [String: [(id: String, title: String)]]
  ) -> ResolveAction {
    switch action {
    case .merge:
      if let match = existing[title.normalizedForThingsMatch]?.first {
        return .merge(match.id)
      }
      return .create(title)
    case .createNew:
      let newTitle = existing[title.normalizedForThingsMatch] != nil
        ? "\(title) (Things)" : title
      return .create(newTitle)
    case .skip:
      return .skip
    }
  }

  private static func resolveProjectAction(
    _ action: ThingsCollisionAction,
    title: String,
    key: String,
    existing: [String: [(id: String, title: String, areaID: String?)]]
  ) -> ResolveAction {
    switch action {
    case .merge:
      if let match = existing[key]?.first { return .merge(match.id) }
      return .create(title)
    case .createNew:
      let newTitle = existing[key] != nil ? "\(title) (Things)" : title
      return .create(newTitle)
    case .skip:
      return .skip
    }
  }

  private static func projectMatchKey(title: String, areaID: String?) -> String {
    "\(title.normalizedForThingsMatch)|\(areaID ?? "")"
  }

  private static func uniqueID(generator: () -> String, used: inout Set<String>) -> String {
    var id = generator()
    while used.contains(id) { id = generator() }
    used.insert(id)
    return id
  }

  private static func accumulateViewCounts(_ counts: inout ThingsSeptenaViewCounts, task: ThingsPlannedTask) {
    if task.trashed {
      counts.recentlyDeleted += 1
      return
    }
    if task.status == .done || task.status == .cancelled {
      counts.logbook += 1
      return
    }
    let scheduledStr = ThingsDateDecoder.formatISODate(task.scheduled)
    let deadlineStr = ThingsDateDecoder.formatISODate(task.deadline)
    let today = ThingsDateDecoder.todayISO

    let isTriage = scheduledStr == nil && deadlineStr == nil
      && task.projectSeptenaID == nil && task.areaSeptenaID == nil && !task.today
    if isTriage {
      counts.inbox += 1
      return
    }

    let onToday = task.today
      || (scheduledStr.map { $0 <= today } ?? false)
      || (deadlineStr.map { $0 <= today } ?? false)
    if onToday {
      counts.today += 1
      return
    }
    if let s = scheduledStr, s > today {
      counts.upcoming += 1
      return
    }
    counts.anytime += 1
  }

}

private extension String {
  var normalizedForThingsMatch: String {
    trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}

enum ThingsImportID {
  private static let alphabet: [Character] =
    Array("abcdefghjkmnpqrstuvwxyz23456789")

  static func generate(length: Int = 4) -> String {
    String((0..<length).map { _ in alphabet.randomElement()! })
  }
}
