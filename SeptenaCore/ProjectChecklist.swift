import Foundation
import SeptenaSharedCore

/// Presentation and mutations share the same rules on every platform.
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

    init(_ task: SeptenaTask) {
      id = task.id
      title = task.title
      status = task.status
      kind = task.kind
      heading = task.heading
    }
  }

  private struct Input: Encodable {
    let rows: [Row]
    let query: String?
    let groceries: Bool
  }

  static func layout(rows: [SeptenaTask], query: String? = nil) -> Self? {
    call("projectChecklist", Input(rows: rows.map(Row.init), query: query, groceries: query != nil))
  }

  static func patch(checked: Bool) -> [String: BackendJSON]? {
    call("checklistCheckPatch", ["checked": checked])
  }

  private static func call<Input: Encodable, Output: Decodable>(_ operation: String, _ input: Input) -> Output? {
    do {
      let data = try JSONEncoder().encode(input)
      let output = try invokeJson(function: operation, inputJson: String(decoding: data, as: UTF8.self))
      return try JSONDecoder().decode(Output.self, from: Data(output.utf8))
    } catch {
      SeptenaLog.error("[Checklist] \\(operation) failed", error)
      return nil
    }
  }
}

extension ProjectChecklist {
  @MainActor
  static func add(
    title: String, project: String, heading explicitHeading: String?,
    headings: [SeptenaTask], mutator: TaskMutator
  ) {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    var heading = explicitHeading
    if heading == nil, let key = layout(rows: [], query: title)?.suggestedGroup {
      if let name = RegistrySurfaces.checklistGroupTitle(key) {
        // A category created offline on two devices has the same row id.
        let id = Recurrence.occurrenceID(sourceTaskID: "checklist:\(project)", scheduled: key)
        heading = headings.first { $0.id == id || $0.title == name }?.id
          ?? mutator.createHeading(title: name, project: project, id: id)?.id
      }
    }
    let item = mutator.create(title: title, project: project)
    if let heading { mutator.setHeading(id: item.id, heading: heading) }
    TaskUndo.record(name: String(localized: "Add Checklist Item"),
                    undo: { mutator.delete(id: item.id) },
                    redo: { mutator.restore(id: item.id) })
  }
}
