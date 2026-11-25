import Foundation

// Things 3 → ImportBundle. Reads the local Things database through the
// existing parser (`SeptenaCore/ThingsImport/`), read-only, from a scratch
// copy. Reads everything: what to leave out is the engine's call.

struct ThingsImportSource: ImportSource {
  static let id = "things"

  var id: String { Self.id }

  let coverage: [ImportCoverage] = [
    ImportCoverage("areas", .mapped),
    ImportCoverage("projects", .mapped),
    ImportCoverage("headings", .mapped),
    ImportCoverage("notes", .mapped),
    ImportCoverage("today", .mapped),
    ImportCoverage("startDate", .mapped, "Becomes the scheduled day."),
    ImportCoverage("deadline", .mapped),
    ImportCoverage("order", .mapped),
    ImportCoverage("status", .mapped),
    ImportCoverage("checklist", .preserved),
    ImportCoverage("tags", .preserved),
    ImportCoverage("completionDate", .transformed, "Completed tasks show the import day."),
    ImportCoverage("someday", .unsupported, "Someday tasks arrive unscheduled."),
    ImportCoverage("reminderTime", .unsupported, "Not read from the database yet."),
    ImportCoverage("repeating", .unsupported, "Repeat rules are not read yet; their next copy imports as a task."),
    ImportCoverage("trashedAreasProjects", .unsupported, "Trashed areas and projects are left out."),
  ]

  func read(_ request: ImportReadRequest) async throws -> ImportBundle {
    guard let url = request.fileURL else { throw ThingsImportError.databaseNotFound }
    let everything = ThingsImportOptions(includeCompleted: true, includeCancelled: true, includeTrashed: true)
    let snapshot = try ThingsImportParser.parse(databaseURL: url, options: everything)
    return Self.bundle(from: snapshot, fileName: url.lastPathComponent)
  }

  static func bundle(from snapshot: ThingsDatabaseSnapshot, fileName: String?, now: Date = Date()) -> ImportBundle {
    let liveAreas = snapshot.areas.filter { !$0.trashed }
    let liveProjects = snapshot.projects.filter { !$0.trashed }
    var unsupported: [ImportUnsupported] = []
    let trashedContainers = (snapshot.areas.count - liveAreas.count) + (snapshot.projects.count - liveProjects.count)
    if trashedContainers > 0 {
      unsupported.append(ImportUnsupported(entity: "project", field: "trashed", count: trashedContainers,
                                           note: "Trashed areas and projects are left out."))
    }

    return ImportBundle(
      source: ImportBundleSource(app: id, adapter: "things@1", account: nil, exportedAt: now),
      areas: liveAreas.enumerated().map { index, area in
        ImportArea(sourceId: area.id, title: area.title, position: Double(index))
      },
      projects: liveProjects.enumerated().map { index, project in
        ImportProject(sourceId: project.id, title: project.title, area: project.areaID,
                      notes: project.notes, status: projectStatus(project.status), position: Double(index))
      },
      headings: snapshot.headings.compactMap { heading in
        guard let project = heading.projectID else { return nil }
        return ImportHeading(sourceId: heading.id, title: heading.title, project: project,
                             position: heading.sortIndex)
      },
      tasks: snapshot.tasks.map { task in
        ImportTask(
          sourceId: task.id,
          title: task.title,
          notes: task.notes,
          area: task.areaID,
          project: task.projectID,
          heading: task.headingID,
          status: taskStatus(task.status),
          trashed: task.trashed,
          today: task.today,
          scheduled: task.scheduled.map(ImportPlanner.dayString),
          deadline: task.deadline.map(ImportPlanner.dayString),
          completedAt: task.completedAt,
          createdAt: task.created,
          position: task.sortIndex,
          checklist: task.checklistLines.isEmpty ? nil : task.checklistLines.map(checklistItem),
          tags: task.tags.isEmpty ? nil : task.tags)
      },
      unsupported: unsupported)
  }

  private static func projectStatus(_ s: ThingsItemStatus) -> ImportProjectStatus {
    switch s {
    case .open: .active
    case .completed: .done
    case .cancelled: .cancelled
    }
  }

  private static func taskStatus(_ s: ThingsItemStatus) -> ImportTaskStatus {
    switch s {
    case .open: .open
    case .completed: .done
    case .cancelled: .cancelled
    }
  }

  /// The parser renders steps as `- [x] title` / `- [ ] title`.
  private static func checklistItem(_ line: String) -> ImportChecklistItem {
    if line.hasPrefix("- [x] ") { return ImportChecklistItem(title: String(line.dropFirst(6)), done: true) }
    if line.hasPrefix("- [ ] ") { return ImportChecklistItem(title: String(line.dropFirst(6)), done: false) }
    return ImportChecklistItem(title: line, done: false)
  }
}
