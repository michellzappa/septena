import AppIntents
import CoreSpotlight
import Foundation
import SwiftData
import UniformTypeIdentifiers

// Tasks — action intents for EXISTING tasks (complete / move-to-today / defer),
// the counterpart to `AddTaskIntent` (which creates). Together they bring the
// App Intents surface to parity with the MCP task tools (tasks_complete /
// tasks_move_to_today / tasks_defer). Each leans on `SectionLogIntent` for boot
// + the refuse-if-disabled gate; tasks is an `.always` section, so the gate
// always passes. The picker is backed by a `TaskChoice` AppEntity reading the
// live store. Mutator + entity types come from SeptenaCore (same module — no
// import needed).
//
// `TaskChoice` (not `TaskEntity`): the `@Model` already owns that name, so the
// pickable value type follows the `*Choice` convention (CaffeineBeanChoice,
// GroceryItemChoice). Its `id` is the stable task id the mutators take.

// MARK: - Catalog entity

/// One of the user's tasks, surfaced to Siri / Shortcuts / Spotlight as a
/// pickable value. Backed by `TaskEntity`; `id` is the stable task id passed
/// straight to the mutators.
struct TaskChoice: AppEntity, IndexedEntity {
  let id: String
  let title: String
  /// Notes ride along only to enrich the Spotlight `attributeSet`
  /// (`contentDescription`) — the picker shows just the title. Defaulted so the
  /// resolution/suggestion path (`TaskChoice(id:title:)`) is unaffected; only
  /// the indexer populates it.
  var notes: String? = nil

  static var typeDisplayRepresentation: TypeDisplayRepresentation { "Task" }

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(title)")
  }

  static var defaultQuery = TaskChoiceQuery()

  /// What lands in Spotlight's semantic index for this task — the surface
  /// Apple Intelligence reads (per Apple, `IndexedEntity` items are
  /// "discoverable by Apple Intelligence"). Title is the headline, notes the
  /// searchable body, keywords broaden recall. Donated by `SpotlightIndexer`;
  /// see docs/SPOTLIGHT_READABILITY_PLAN.md.
  var attributeSet: CSSearchableItemAttributeSet {
    let attrs = CSSearchableItemAttributeSet(contentType: .text)
    attrs.title = title
    attrs.displayName = title
    if let notes, !notes.isEmpty { attrs.contentDescription = notes }
    attrs.keywords = ["task", "to-do", "todo", "Septena"]
    return attrs
  }
}

/// Resolves task parameters and supplies the picker list. Suggestions are the
/// user's OPEN tasks, Today first (then upcoming, anytime, inbox), bounded so a
/// large backlog can't flood the picker. Reuses `LocalCache.tasks(in:filter:)`
/// — the same view logic the app sidebar and MCP `tasks_list` use.
struct TaskChoiceQuery: EntityQuery {
  /// Cap on suggested rows — the picker is for quick voice/Shortcut selection,
  /// not browsing the whole backlog.
  private static let suggestionLimit = 50

  @MainActor
  func entities(for ids: [String]) async throws -> [TaskChoice] {
    await SeptenaServices.shared.start()
    let context = LocalStore.shared.container.mainContext
    let wanted = Set(ids)
    let rows = (try? context.fetch(FetchDescriptor<TaskEntity>())) ?? []
    return rows.filter { wanted.contains($0.id) }
               .map { TaskChoice(id: $0.id, title: $0.title) }
  }

  @MainActor
  func suggestedEntities() async throws -> [TaskChoice] {
    await SeptenaServices.shared.start()
    let context = LocalStore.shared.container.mainContext
    var seen = Set<String>()
    var out: [TaskChoice] = []
    for filter in [TaskFilter.today, .upcoming, .unscheduled, .inbox] {
      for task in LocalCache.tasks(in: context, filter: filter) where !seen.contains(task.id) {
        seen.insert(task.id)
        out.append(TaskChoice(id: task.id, title: task.title))
        if out.count >= Self.suggestionLimit { return out }
      }
    }
    return out
  }
}

// MARK: - Intents

/// Mark a task done. Mirrors MCP `tasks_complete`.
struct CompleteTaskIntent: SectionLogIntent {
  static let sectionKey = "tasks"
  static let title: LocalizedStringResource = "Complete Task"
  static let description = IntentDescription("Mark a Septena task as done.")

  @Parameter(title: "Task")
  var task: TaskChoice

  static var parameterSummary: some ParameterSummary {
    Summary("Complete \(\.$task)")
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await requireSection()
    SeptenaServices.shared.taskMutator.complete(id: task.id)
    return .result(dialog: "Completed \(task.title).")
  }
}

/// Pin a task to Today. Mirrors MCP `tasks_move_to_today`: set today, then
/// clear any scheduled date so it surfaces now.
struct MoveTaskToTodayIntent: SectionLogIntent {
  static let sectionKey = "tasks"
  static let title: LocalizedStringResource = "Move Task to Today"
  static let description = IntentDescription("Pin a Septena task to Today.")

  @Parameter(title: "Task")
  var task: TaskChoice

  static var parameterSummary: some ParameterSummary {
    Summary("Move \(\.$task) to Today")
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await requireSection()
    let mutator = SeptenaServices.shared.taskMutator
    mutator.moveToToday(id: task.id)
    mutator.schedule(id: task.id, date: nil)
    return .result(dialog: "Moved \(task.title) to Today.")
  }
}

/// Defer a task to a future day. Mirrors MCP `tasks_defer`: set the scheduled
/// date and take it off Today.
struct DeferTaskIntent: SectionLogIntent {
  static let sectionKey = "tasks"
  static let title: LocalizedStringResource = "Defer Task"
  static let description = IntentDescription("Schedule a Septena task for a future day and take it off Today.")

  @Parameter(title: "Task")
  var task: TaskChoice

  @Parameter(title: "Until", requestValueDialog: "Defer until which day?")
  var until: Date

  static var parameterSummary: some ParameterSummary {
    Summary("Defer \(\.$task) until \(\.$until)")
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await requireSection()
    let mutator = SeptenaServices.shared.taskMutator
    mutator.schedule(id: task.id, date: until)
    mutator.removeFromToday(id: task.id)
    return .result(dialog: "Deferred \(task.title).")
  }
}
