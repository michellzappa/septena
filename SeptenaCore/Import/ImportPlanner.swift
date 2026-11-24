import Foundation

// The dry run (docs/MOVING_IN_SPEC.md §4.1). Pure: bundle + a snapshot of what
// the user already has + options → the plan the applier runs and the report
// the preview shows. No SwiftData, no mutators, no source knowledge, so the
// same rules hold for every adapter.

struct ImportOptions: Codable, Sendable, Hashable {
  var includeCompleted = false
  var includeCancelled = false
  var includeTrashed = false
  /// A source area/project whose title matches a live Septena one maps onto it.
  var mergeMatchingTitles = true
  /// Write checklist steps into notes as `- [ ]` lines until #76 ships.
  var checklistIntoNotes = false
  /// Write tags into notes as `#tag` until #96 ships.
  var tagsIntoNotes = false
  /// Re-create items imported before and deleted since.
  var reimportDeleted = false
}

/// What the user already has, read once by the caller (`ImportApplier.existing`).
struct ImportExisting: Sendable {
  var areas: [(id: String, title: String)] = []
  var projects: [(id: String, title: String, area: String?)] = []
  var liveTaskIDs: Set<String> = []
  var liveAreaIDs: Set<String> = []
  var liveProjectIDs: Set<String> = []
  /// Prior imports: lineage key → the Septena id that item became.
  var lineage: [ImportLineageKey: String] = [:]
}

/// Identifies one source item across batches. The account keeps two To Do
/// accounts (or two Things databases with reused ids) apart.
struct ImportLineageKey: Codable, Sendable, Hashable {
  var app: String
  var account: String?
  var entity: ImportEntity
  var sourceId: String
}

/// `CodingKeyRepresentable` so `[ImportEntity: …]` encodes as a JSON object.
enum ImportEntity: String, Codable, CodingKeyRepresentable, Sendable, Hashable, CaseIterable {
  case area, project, heading, task
}

enum ImportItemAction: String, Codable, Sendable, Hashable {
  case create
  case merge
}

struct ImportPlannedArea: Sendable, Hashable {
  var sourceId: String
  var title: String
  var notes: String?
  var emoji: String?
  var septenaID: String
  var action: ImportItemAction
}

struct ImportPlannedProject: Sendable, Hashable {
  var sourceId: String
  var title: String
  var notes: String?
  var status: ImportProjectStatus
  var areaSeptenaID: String?
  var septenaID: String
  var action: ImportItemAction
}

struct ImportPlannedHeading: Sendable, Hashable {
  var sourceId: String
  var title: String
  var projectSeptenaID: String
  var position: Double
}

struct ImportPlannedTask: Sendable, Hashable {
  var sourceId: String
  var title: String
  var notes: String?
  var areaSeptenaID: String?
  var projectSeptenaID: String?
  /// Resolved at apply time: headings get their ids from `createHeading`.
  var headingSourceId: String?
  /// A heading from an earlier batch, already in the store.
  var existingHeadingID: String?
  var status: ImportTaskStatus
  var trashed: Bool
  var today: Bool
  var scheduled: Date?
  var deadline: Date?
  var position: Double
  var reminder: ImportReminder?
  var recurrence: ImportRecurrence?
  var refs: [ImportTaskRef] = []
}

struct ImportEntityCounts: Codable, Sendable, Hashable {
  var inSource = 0
  var create = 0
  var merge = 0
  /// Imported in an earlier batch and still there.
  var alreadyImported = 0
  /// Left out by the options (completed, cancelled, trashed, deleted since).
  var filtered = 0
}

struct ImportFieldReport: Codable, Sendable, Hashable {
  var field: String
  var disposition: ImportFieldDisposition
  var count: Int
  var note: String?
}

struct ImportReport: Codable, Sendable, Hashable {
  var counts: [ImportEntity: ImportEntityCounts] = [:]
  var fields: [ImportFieldReport] = []
  /// Tasks whose project or heading is not in the bundle; they land in their
  /// area or the Inbox.
  var danglingReferences = 0
  /// Losses the adapter declared (bundle `unsupported`).
  var adapterUnsupported: [ImportUnsupported] = []

  var tasksToCreate: Int { counts[.task]?.create ?? 0 }
}

struct ImportPlan: Sendable {
  var batchID: String
  var source: ImportBundleSource
  var options: ImportOptions
  var areas: [ImportPlannedArea]
  var projects: [ImportPlannedProject]
  var headings: [ImportPlannedHeading]
  var tasks: [ImportPlannedTask]
  var report: ImportReport
  /// The bundle the plan came from, for the ledger's originals.
  var bundle: ImportBundle
}

enum ImportPlanner {

  static func plan(
    bundle: ImportBundle,
    existing: ImportExisting,
    options: ImportOptions,
    batchID: String = UUID().uuidString,
    idGenerator: () -> String = { IDShortcode.generate(length: 6) }
  ) throws -> ImportPlan {
    try bundle.validate()
    guard !bundle.isEmpty else { throw ImportError.emptySource }

    let app = bundle.source.app
    let account = bundle.source.account
    func key(_ entity: ImportEntity, _ sourceId: String) -> ImportLineageKey {
      ImportLineageKey(app: app, account: account, entity: entity, sourceId: sourceId)
    }

    var report = ImportReport()
    report.adapterUnsupported = bundle.unsupported
    var takenIDs = Set(existing.areas.map(\.id)).union(existing.projects.map(\.id))
    func freshID() -> String {
      var id = idGenerator()
      while takenIDs.contains(id) { id = idGenerator() }
      takenIDs.insert(id)
      return id
    }

    // MARK: Areas

    var areaCounts = ImportEntityCounts(inSource: bundle.areas.count)
    var areaIDBySource: [String: String] = [:]
    var plannedAreas: [ImportPlannedArea] = []
    let areasByTitle = Dictionary(existing.areas.map { (normalized($0.title), $0.id) },
                                  uniquingKeysWith: { first, _ in first })
    for area in ordered(bundle.areas) {
      if let prior = existing.lineage[key(.area, area.sourceId)] {
        if existing.liveAreaIDs.contains(prior) {
          areaIDBySource[area.sourceId] = prior
          areaCounts.alreadyImported += 1
          continue
        }
        if !options.reimportDeleted { areaCounts.filtered += 1; continue }
      }
      if options.mergeMatchingTitles, let match = areasByTitle[normalized(area.title)] {
        areaIDBySource[area.sourceId] = match
        plannedAreas.append(ImportPlannedArea(sourceId: area.sourceId, title: area.title, notes: nil,
                                              emoji: nil, septenaID: match, action: .merge))
        areaCounts.merge += 1
        continue
      }
      let id = freshID()
      areaIDBySource[area.sourceId] = id
      plannedAreas.append(ImportPlannedArea(sourceId: area.sourceId, title: area.title, notes: area.notes,
                                            emoji: area.emoji, septenaID: id, action: .create))
      areaCounts.create += 1
    }
    report.counts[.area] = areaCounts

    // MARK: Projects

    var projectCounts = ImportEntityCounts(inSource: bundle.projects.count)
    var projectIDBySource: [String: String] = [:]
    var plannedProjects: [ImportPlannedProject] = []
    for project in ordered(bundle.projects) {
      let areaID = project.area.flatMap { areaIDBySource[$0] }
      if let prior = existing.lineage[key(.project, project.sourceId)] {
        if existing.liveProjectIDs.contains(prior) {
          projectIDBySource[project.sourceId] = prior
          projectCounts.alreadyImported += 1
          continue
        }
        if !options.reimportDeleted { projectCounts.filtered += 1; continue }
      }
      if (project.status == .done && !options.includeCompleted)
          || (project.status == .cancelled && !options.includeCancelled) {
        projectCounts.filtered += 1
        continue
      }
      if options.mergeMatchingTitles,
         let match = existing.projects.first(where: {
           normalized($0.title) == normalized(project.title) && $0.area == areaID
         }) {
        projectIDBySource[project.sourceId] = match.id
        plannedProjects.append(ImportPlannedProject(
          sourceId: project.sourceId, title: project.title, notes: nil, status: .active,
          areaSeptenaID: match.area, septenaID: match.id, action: .merge))
        projectCounts.merge += 1
        continue
      }
      let id = freshID()
      projectIDBySource[project.sourceId] = id
      plannedProjects.append(ImportPlannedProject(
        sourceId: project.sourceId, title: project.title, notes: project.notes, status: project.status,
        areaSeptenaID: areaID, septenaID: id, action: .create))
      projectCounts.create += 1
    }
    report.counts[.project] = projectCounts

    // MARK: Headings

    var headingCounts = ImportEntityCounts(inSource: bundle.headings.count)
    var plannedHeadings: [ImportPlannedHeading] = []
    var newHeadingSources = Set<String>()
    var existingHeadingBySource: [String: String] = [:]
    for (index, heading) in ordered(bundle.headings).enumerated() {
      if let prior = existing.lineage[key(.heading, heading.sourceId)] {
        if existing.liveTaskIDs.contains(prior) {
          existingHeadingBySource[heading.sourceId] = prior
          headingCounts.alreadyImported += 1
          continue
        }
        if !options.reimportDeleted { headingCounts.filtered += 1; continue }
      }
      guard let projectID = projectIDBySource[heading.project] else {
        headingCounts.filtered += 1
        continue
      }
      plannedHeadings.append(ImportPlannedHeading(sourceId: heading.sourceId, title: heading.title,
                                                  projectSeptenaID: projectID,
                                                  position: heading.position ?? Double(index)))
      newHeadingSources.insert(heading.sourceId)
      headingCounts.create += 1
    }
    report.counts[.heading] = headingCounts

    // MARK: Tasks

    var taskCounts = ImportEntityCounts(inSource: bundle.tasks.count)
    var plannedTasks: [ImportPlannedTask] = []
    var fieldCounts: [String: Int] = [:]
    func saw(_ field: String) { fieldCounts[field, default: 0] += 1 }

    for (index, task) in ordered(bundle.tasks).enumerated() {
      if let prior = existing.lineage[key(.task, task.sourceId)] {
        if existing.liveTaskIDs.contains(prior) { taskCounts.alreadyImported += 1; continue }
        if !options.reimportDeleted { taskCounts.filtered += 1; continue }
      }
      if (task.status == .done && !options.includeCompleted)
          || (task.status == .cancelled && !options.includeCancelled)
          || (task.trashed && !options.includeTrashed) {
        taskCounts.filtered += 1
        continue
      }

      let projectID = task.project.flatMap { projectIDBySource[$0] }
      var areaID = task.area.flatMap { areaIDBySource[$0] }
      if task.project != nil, projectID == nil { report.danglingReferences += 1 }
      if projectID != nil { areaID = nil }

      var headingSource: String?
      var existingHeading: String?
      if let h = task.heading {
        if newHeadingSources.contains(h) { headingSource = h }
        else if let id = existingHeadingBySource[h] { existingHeading = id }
        else { report.danglingReferences += 1 }
      }

      var noteParts: [String] = []
      if let notes = task.notes, !notes.isEmpty { noteParts.append(notes) }
      if let checklist = task.checklist, !checklist.isEmpty {
        saw("checklist")
        if options.checklistIntoNotes {
          noteParts.append(checklist.map { "- [\($0.done ? "x" : " ")] \($0.title)" }.joined(separator: "\n"))
        }
      }
      if let tags = task.tags, !tags.isEmpty {
        saw("tags")
        if options.tagsIntoNotes { noteParts.append(tags.map { "#\($0)" }.joined(separator: " ")) }
      }
      if task.starred == true { saw("starred") }
      var refs = task.refs ?? []
      if let url = task.sourceURL, !url.isEmpty {
        if TaskRefCore.parse(url) != nil {
          refs.append(ImportTaskRef(key: url, role: .from))
        } else {
          saw("sourceURL")
          noteParts.append(url)
        }
      }
      if !refs.isEmpty { saw("refs") }
      if task.reminder != nil { saw("reminder") }
      if task.recurrence != nil { saw("recurrence") }
      if task.completedAt != nil, task.status == .done { saw("completedAt") }

      plannedTasks.append(ImportPlannedTask(
        sourceId: task.sourceId,
        title: task.title,
        notes: noteParts.isEmpty ? nil : noteParts.joined(separator: "\n\n"),
        areaSeptenaID: areaID,
        projectSeptenaID: projectID,
        headingSourceId: headingSource,
        existingHeadingID: existingHeading,
        status: task.status,
        trashed: task.trashed,
        today: task.today,
        scheduled: task.scheduled.flatMap(dayDate),
        deadline: task.deadline.flatMap(dayDate),
        position: task.position ?? Double(index),
        reminder: task.reminder,
        recurrence: task.recurrence,
        refs: refs))
      taskCounts.create += 1
    }
    report.counts[.task] = taskCounts

    report.fields = fieldCounts.sorted { $0.key < $1.key }.map { field, count in
      let (disposition, note) = disposition(of: field, options: options)
      return ImportFieldReport(field: field, disposition: disposition, count: count, note: note)
    }

    return ImportPlan(batchID: batchID, source: bundle.source, options: options,
                      areas: plannedAreas, projects: plannedProjects, headings: plannedHeadings,
                      tasks: plannedTasks, report: report, bundle: bundle)
  }

  /// The disposition table (docs/MOVING_IN_SPEC.md §4.2). When #76, #96 or
  /// #127 ship, their row moves to `.mapped` here and nowhere else.
  static func disposition(of field: String, options: ImportOptions) -> (ImportFieldDisposition, String?) {
    switch field {
    case "checklist":
      return options.checklistIntoNotes
        ? (.transformed, String(localized: "Written into notes as a checklist."))
        : (.preserved, String(localized: "Kept with the import. Checklists come to Septena later."))
    case "tags":
      return options.tagsIntoNotes
        ? (.transformed, String(localized: "Written into notes as #tags."))
        : (.preserved, String(localized: "Kept with the import. Tags come to Septena later."))
    case "starred":
      return (.preserved, String(localized: "Kept with the import. A star marker comes to Septena later."))
    case "sourceURL":
      return (.transformed, String(localized: "Added to notes as a link."))
    case "refs":
      return (TaskRefCore.isAvailable ? .mapped : .preserved, nil)
    case "completedAt":
      return (.transformed, String(localized: "Completed tasks show the import day in the Logbook."))
    default:
      return (.mapped, nil)
    }
  }

  // MARK: - Helpers

  private static func normalized(_ title: String) -> String {
    title.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
  }

  /// Source order: by `position`, unpositioned items last, ties kept in
  /// bundle order (`sorted` alone is not stable).
  private static func ordered<T: ImportPositioned>(_ items: [T]) -> [T] {
    items.enumerated().sorted { a, b in
      let pa = a.element.position ?? .greatestFiniteMagnitude
      let pb = b.element.position ?? .greatestFiniteMagnitude
      return pa == pb ? a.offset < b.offset : pa < pb
    }.map(\.element)
  }

  private static let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd"
    return f
  }()

  static func dayDate(_ day: String) -> Date? { dayFormatter.date(from: day) }
  static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }
}

protocol ImportPositioned { var position: Double? { get } }
extension ImportArea: ImportPositioned {}
extension ImportProject: ImportPositioned {}
extension ImportHeading: ImportPositioned {}
extension ImportTask: ImportPositioned {}
