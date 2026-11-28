import Foundation
import SwiftData
import SeptenaSharedCore

/// Checklist projects (docs/PROJECT_CHECKLIST_SPEC.md, #860). A Checklist is a
/// regular project: the shells draw it with the standard project list, rows
/// and composer. This type only calls the shared core and reads registry copy;
/// it holds no rule of its own.
struct ProjectChecklist: Decodable {
  struct Group: Decodable {
    let id: String
    let items: [String]
  }

  let ungrouped: [String]
  let groups: [Group]
  let checked: [String]
  let matches: [String]
  let suggestedGroup: String?

  private struct Row: Encodable {
    let id: String
    let title: String
    let status: TaskStatus
    let kind: String?
    let heading: String?
    let project: String?
    let deletedAt: String?

    init(_ task: SeptenaTask) {
      id = task.id
      title = task.title
      status = task.status
      kind = task.kind
      heading = task.heading
      project = task.project
      deletedAt = nil
    }

    init(_ entity: TaskEntity) {
      id = entity.id
      title = entity.title
      status = entity.status
      kind = entity.kind
      heading = entity.heading
      project = entity.project
      deletedAt = entity.deletedAt ?? (entity.pendingDeletion ? "pending" : nil)
    }
  }

  private struct Input: Encodable {
    let rows: [Row]
    let query: String?
    let groceries: Bool
  }

  private struct HeadingInput: Encodable {
    let projectId: String
    let group: String
    let title: String
    let rows: [Row]
  }

  private struct HeadingDecision: Decodable {
    let heading: String?
    let create: Bool
  }

  /// The core layout of a Checklist project. `rows` are the project's rows,
  /// headings included, in project order. Grocery grouping applies to every
  /// Checklist (#860 decision 2).
  static func layout(rows: [SeptenaTask], query: String? = nil) -> Self? {
    call("projectChecklist", Input(rows: rows.map(Row.init), query: query, groceries: true))
  }

  static func patch(checked: Bool) -> [String: BackendJSON]? {
    call("checklistCheckPatch", ["checked": checked])
  }

  /// True for a project used as a Checklist; a legacy `groceries` value counts.
  static func isChecklist(_ project: Project?) -> Bool {
    project?.checklistMode != nil
  }

  /// One add-field suggestion: a checked row to reopen (with its saved group),
  /// or an active row that is already on the list.
  struct Suggestion: Identifiable {
    let task: SeptenaTask
    let group: String?
    var isChecked: Bool { task.status == .checklistChecked }
    var id: String { task.id }
    /// "Greek yogurt · Dairy" for a checked row, "Milk · On list" for an active one.
    var label: String {
      let detail = isChecked ? group : RegistrySurfaces.checklistOnList
      return detail.map { "\(task.title) · \($0)" } ?? task.title
    }
  }

  /// The add-field suggestions for `query` in one Checklist project, in core
  /// order (exact title first). Empty for a blank query.
  @MainActor
  static func suggestions(project: String, query: String, in context: ModelContext) -> [Suggestion] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let rows = LocalCache.headings(inProject: project, in: context)
      + LocalCache.tasks(in: context, filter: .project(project))
    guard let layout = layout(rows: rows, query: trimmed) else { return [] }
    let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return layout.matches.compactMap { id in
      guard let task = byID[id] else { return nil }
      return Suggestion(task: task, group: task.heading.flatMap { byID[$0]?.title })
    }
  }

  /// A new item that the user added with no heading open joins the core's
  /// suggested group, under one stable heading per project
  /// (`checklistHeading`). A heading the user deleted is not created again;
  /// an unknown item stays ungrouped. Call once, right after the create.
  @MainActor
  static func placeNewItem(id: String, title: String, project: String,
                           mutator: TaskMutator, in context: ModelContext) {
    guard let group = layout(rows: [], query: title)?.suggestedGroup,
          let groupTitle = RegistrySurfaces.checklistGroupTitle(group) else { return }
    // Deleted headings count, so the core can tell a removed group from a new one.
    let entities = StoreHealth.fetch(context, FetchDescriptor<TaskEntity>(
      predicate: #Predicate { $0.project == project && $0.kind == "heading" }
    ))
    let input = HeadingInput(projectId: project, group: group, title: groupTitle,
                             rows: entities.map(Row.init))
    guard let decision: HeadingDecision = call("checklistHeading", input),
          let heading = decision.heading else { return }
    if decision.create {
      guard mutator.createHeading(title: groupTitle, project: project, id: heading) != nil else { return }
    }
    mutator.setHeading(id: id, heading: heading)
  }

  private static func call<Input: Encodable, Output: Decodable>(_ operation: String, _ input: Input) -> Output? {
    do {
      let data = try JSONEncoder().encode(input)
      let output = try invokeJson(function: operation, inputJson: String(decoding: data, as: UTF8.self))
      return try JSONDecoder().decode(Output.self, from: Data(output.utf8))
    } catch {
      SeptenaLog.error("[Checklist] \(operation) failed", error)
      return nil
    }
  }
}
