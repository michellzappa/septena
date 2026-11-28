#if !WIDGET_EXTENSION
import AppIntents
import Foundation
import SwiftData

// App Intents, App Entities, and App Shortcuts for Septena (iOS & macOS, #89).
//
// Compiled into both `Septask` and `SeptaskMac` via the shared `SeptenaCore/`
// folder in `project.yml` (excluded from widget, watch, share, and unit-test
// targets). Every intent bootstraps `SeptenaServices.shared.start()` before
// reading or mutating so background-launched Siri/Shortcuts invocations bind
// `TaskMutator` and `TaskSyncEngine` safely, and every mutation flows through
// `TaskMutator` (never writing SwiftData entities directly).

// MARK: - Errors

enum SeptaskIntentError: Error, CustomLocalizedStringResourceConvertible {
  case emptyTitle
  case taskNotFound

  var localizedStringResource: LocalizedStringResource {
    switch self {
    case .emptyTitle:
      return "Please provide a task title."
    case .taskNotFound:
      return "That task could not be found in Septena."
    }
  }
}

// MARK: - App Entities

public struct SeptaskTaskEntity: AppEntity, Identifiable, Hashable, Sendable {
  public static var typeDisplayRepresentation: TypeDisplayRepresentation {
    TypeDisplayRepresentation(
      name: "Task",
      numericFormat: "\(placeholder: .int) tasks"
    )
  }

  public static var defaultQuery = SeptaskTaskEntityQuery()

  public let id: String

  @Property(title: "Title")
  public var title: String

  @Property(title: "Notes")
  public var notes: String?

  @Property(title: "Today")
  public var isToday: Bool

  @Property(title: "Completed")
  public var isCompleted: Bool

  @Property(title: "Assigned to Claude")
  public var isAssignedToClaude: Bool

  @Property(title: "Scheduled Date")
  public var scheduledDate: Date?

  @Property(title: "Project")
  public var projectName: String?

  @Property(title: "Area")
  public var areaName: String?

  private let subtitleText: String?
  private let symbolName: String

  public var displayRepresentation: DisplayRepresentation {
    if let subtitleText, !subtitleText.isEmpty {
      return DisplayRepresentation(
        title: "\(title)",
        subtitle: "\(subtitleText)",
        image: .init(systemName: symbolName)
      )
    }
    return DisplayRepresentation(
      title: "\(title)",
      image: .init(systemName: symbolName)
    )
  }

  public init(
    id: String,
    title: String,
    notes: String? = nil,
    isToday: Bool = false,
    isCompleted: Bool = false,
    isAssignedToClaude: Bool = false,
    scheduledDate: Date? = nil,
    projectName: String? = nil,
    areaName: String? = nil,
    subtitleText: String? = nil,
    symbolName: String = "circle"
  ) {
    self.id = id
    self.subtitleText = subtitleText
    self.symbolName = symbolName
    self.title = title
    self.notes = notes
    self.isToday = isToday
    self.isCompleted = isCompleted
    self.isAssignedToClaude = isAssignedToClaude
    self.scheduledDate = scheduledDate
    self.projectName = projectName
    self.areaName = areaName
  }

  @MainActor
  init(
    task: SeptenaTask,
    areaTitles: [String: String],
    projectTitles: [String: String]
  ) {
    let projectTitle = task.project.flatMap { projectTitles[$0] }
    let areaTitle = task.area.flatMap { areaTitles[$0] }
    let onToday = task.isOnToday
    let completed = task.status.isFinished
    let assignedToClaude = task.conversation.assignee == .claude && task.conversation.stoppedAt == nil

    var parts: [String] = []
    if let projectTitle, !projectTitle.isEmpty {
      parts.append(projectTitle)
    } else if let areaTitle, !areaTitle.isEmpty {
      parts.append(areaTitle)
    }
    if completed {
      parts.append("Completed")
    } else if assignedToClaude {
      parts.append("Claude")
    } else if onToday {
      parts.append("Today")
    } else if let scheduled = task.scheduled, !scheduled.isEmpty {
      parts.append(scheduled)
    }

    let symbol: String
    if completed {
      symbol = "checkmark.circle.fill"
    } else if assignedToClaude {
      symbol = "sparkles"
    } else if onToday {
      symbol = RegistryIcons.sfSymbol(for: "list.today")
    } else {
      symbol = "circle"
    }

    self.init(
      id: task.id,
      title: task.title,
      notes: task.notes,
      isToday: onToday,
      isCompleted: completed,
      isAssignedToClaude: assignedToClaude,
      scheduledDate: SeptenaDate.parse(task.scheduled),
      projectName: projectTitle,
      areaName: areaTitle,
      subtitleText: parts.isEmpty ? nil : parts.joined(separator: " · "),
      symbolName: symbol
    )
  }

  @MainActor
  static func from(task: SeptenaTask, in context: ModelContext) -> SeptaskTaskEntity {
    let structure = StructureCache.snapshot(in: context)
    let areaTitles = Dictionary(uniqueKeysWithValues: structure.areas.map { ($0.id, $0.title) })
    let projectTitles = Dictionary(uniqueKeysWithValues: structure.projects.map { ($0.id, $0.title) })
    return SeptaskTaskEntity(task: task, areaTitles: areaTitles, projectTitles: projectTitles)
  }

  public static func == (lhs: SeptaskTaskEntity, rhs: SeptaskTaskEntity) -> Bool {
    lhs.id == rhs.id
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

public struct SeptaskTaskEntityQuery: EntityStringQuery {
  private static let maxResults = 25

  public init() {}

  public func entities(for identifiers: [String]) async throws -> [SeptaskTaskEntity] {
    guard !identifiers.isEmpty else { return [] }
    return await MainActor.run {
      let context = LocalStore.shared.container.mainContext
      let structure = StructureCache.snapshot(in: context)
      let areaTitles = Dictionary(uniqueKeysWithValues: structure.areas.map { ($0.id, $0.title) })
      let projectTitles = Dictionary(uniqueKeysWithValues: structure.projects.map { ($0.id, $0.title) })
      let fetched = LocalCache.liveTasks(ids: identifiers, in: context)
      let byID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
      return identifiers.compactMap { id in
        byID[id].map { SeptaskTaskEntity(task: $0, areaTitles: areaTitles, projectTitles: projectTitles) }
      }
    }
  }

  public func entities(matching string: String) async throws -> [SeptaskTaskEntity] {
    let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return try await suggestedEntities() }
    return await MainActor.run {
      let context = LocalStore.shared.container.mainContext
      let structure = StructureCache.snapshot(in: context)
      let areaTitles = Dictionary(uniqueKeysWithValues: structure.areas.map { ($0.id, $0.title) })
      let projectTitles = Dictionary(uniqueKeysWithValues: structure.projects.map { ($0.id, $0.title) })
      let all = LocalCache.liveTasks(in: context)

      let matches = all.filter { task in
        task.title.localizedStandardContains(query)
          || (task.notes?.localizedStandardContains(query) ?? false)
      }

      let ranked = matches.sorted { lhs, rhs in
        let lhsOpen = lhs.status == .open
        let rhsOpen = rhs.status == .open
        if lhsOpen != rhsOpen { return lhsOpen }

        let lhsPrefix = lhs.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
        let rhsPrefix = rhs.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
        if lhsPrefix != rhsPrefix { return lhsPrefix }

        let lhsTitle = lhs.title.localizedStandardContains(query)
        let rhsTitle = rhs.title.localizedStandardContains(query)
        if lhsTitle != rhsTitle { return lhsTitle }

        if lhs.isOnToday != rhs.isOnToday { return lhs.isOnToday }
        return lhs.createdAt > rhs.createdAt
      }

      return ranked.prefix(Self.maxResults).map {
        SeptaskTaskEntity(task: $0, areaTitles: areaTitles, projectTitles: projectTitles)
      }
    }
  }

  public func suggestedEntities() async throws -> [SeptaskTaskEntity] {
    await MainActor.run {
      let context = LocalStore.shared.container.mainContext
      let structure = StructureCache.snapshot(in: context)
      let areaTitles = Dictionary(uniqueKeysWithValues: structure.areas.map { ($0.id, $0.title) })
      let projectTitles = Dictionary(uniqueKeysWithValues: structure.projects.map { ($0.id, $0.title) })

      let (todayTasks, triageTasks) = LocalCache.todayAndTriage(in: context)
      let upcomingTasks = LocalCache.tasks(in: context, filter: .upcoming)
      let anytimeTasks = LocalCache.tasks(in: context, filter: .unscheduled)

      var seen = Set<String>()
      var ordered: [SeptenaTask] = []
      for bucket in [todayTasks, triageTasks, upcomingTasks, anytimeTasks] {
        for task in bucket where !task.isHeading {
          if seen.insert(task.id).inserted {
            ordered.append(task)
            if ordered.count >= Self.maxResults { break }
          }
        }
        if ordered.count >= Self.maxResults { break }
      }

      return ordered.map {
        SeptaskTaskEntity(task: $0, areaTitles: areaTitles, projectTitles: projectTitles)
      }
    }
  }
}

public struct SeptaskAreaEntity: AppEntity, Identifiable, Hashable, Sendable {
  public static var typeDisplayRepresentation: TypeDisplayRepresentation {
    TypeDisplayRepresentation(
      name: "Area",
      numericFormat: "\(placeholder: .int) areas"
    )
  }

  public static var defaultQuery = SeptaskAreaEntityQuery()

  public let id: String

  @Property(title: "Title")
  public var title: String

  @Property(title: "Emoji")
  public var emoji: String?

  public var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: "\(title)",
      image: .init(systemName: RegistryIcons.sfSymbol(for: "place.area"))
    )
  }

  public init(id: String, title: String, emoji: String? = nil) {
    self.id = id
    self.title = title
    self.emoji = emoji
  }

  init(_ area: Area) {
    self.init(id: area.id, title: area.title, emoji: area.emoji)
  }

  public static func == (lhs: SeptaskAreaEntity, rhs: SeptaskAreaEntity) -> Bool {
    lhs.id == rhs.id
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

public struct SeptaskAreaEntityQuery: EntityStringQuery {
  public init() {}

  public func entities(for identifiers: [String]) async throws -> [SeptaskAreaEntity] {
    guard !identifiers.isEmpty else { return [] }
    return await MainActor.run {
      let areas = StructureCache.snapshot(in: LocalStore.shared.container.mainContext).areas
      let byID = Dictionary(uniqueKeysWithValues: areas.map { ($0.id, $0) })
      return identifiers.compactMap { byID[$0].map(SeptaskAreaEntity.init) }
    }
  }

  public func entities(matching string: String) async throws -> [SeptaskAreaEntity] {
    let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return try await suggestedEntities() }
    return await MainActor.run {
      StructureCache.snapshot(in: LocalStore.shared.container.mainContext).areas
        .filter { $0.title.localizedStandardContains(query) }
        .map(SeptaskAreaEntity.init)
    }
  }

  public func suggestedEntities() async throws -> [SeptaskAreaEntity] {
    await MainActor.run {
      StructureCache.snapshot(in: LocalStore.shared.container.mainContext).areas
        .map(SeptaskAreaEntity.init)
    }
  }
}

public struct SeptaskProjectEntity: AppEntity, Identifiable, Hashable, Sendable {
  public static var typeDisplayRepresentation: TypeDisplayRepresentation {
    TypeDisplayRepresentation(
      name: "Project",
      numericFormat: "\(placeholder: .int) projects"
    )
  }

  public static var defaultQuery = SeptaskProjectEntityQuery()

  public let id: String

  @Property(title: "Title")
  public var title: String

  @Property(title: "Area")
  public var areaName: String?

  public var displayRepresentation: DisplayRepresentation {
    if let areaName, !areaName.isEmpty {
      return DisplayRepresentation(
        title: "\(title)",
        subtitle: "\(areaName)",
        image: .init(systemName: RegistryIcons.sfSymbol(for: "place.project"))
      )
    }
    return DisplayRepresentation(
      title: "\(title)",
      image: .init(systemName: RegistryIcons.sfSymbol(for: "place.project"))
    )
  }

  public init(id: String, title: String, areaName: String? = nil) {
    self.id = id
    self.title = title
    self.areaName = areaName
  }

  init(_ project: Project, areaTitles: [String: String]) {
    self.init(
      id: project.id,
      title: project.title,
      areaName: project.area.flatMap { areaTitles[$0] }
    )
  }

  public static func == (lhs: SeptaskProjectEntity, rhs: SeptaskProjectEntity) -> Bool {
    lhs.id == rhs.id
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

public struct SeptaskProjectEntityQuery: EntityStringQuery {
  public init() {}

  public func entities(for identifiers: [String]) async throws -> [SeptaskProjectEntity] {
    guard !identifiers.isEmpty else { return [] }
    return await MainActor.run {
      let structure = StructureCache.snapshot(in: LocalStore.shared.container.mainContext)
      let areaTitles = Dictionary(uniqueKeysWithValues: structure.areas.map { ($0.id, $0.title) })
      let byID = Dictionary(uniqueKeysWithValues: structure.projects.map { ($0.id, $0) })
      return identifiers.compactMap { id in
        byID[id].map { SeptaskProjectEntity($0, areaTitles: areaTitles) }
      }
    }
  }

  public func entities(matching string: String) async throws -> [SeptaskProjectEntity] {
    let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return try await suggestedEntities() }
    return await MainActor.run {
      let structure = StructureCache.snapshot(in: LocalStore.shared.container.mainContext)
      let areaTitles = Dictionary(uniqueKeysWithValues: structure.areas.map { ($0.id, $0.title) })
      return structure.projects
        .filter { $0.deletedAt == nil && $0.title.localizedStandardContains(query) }
        .sorted { lhs, rhs in
          let lhsActive = lhs.status == .active
          let rhsActive = rhs.status == .active
          if lhsActive != rhsActive { return lhsActive }
          return lhs.position < rhs.position
        }
        .map { SeptaskProjectEntity($0, areaTitles: areaTitles) }
    }
  }

  public func suggestedEntities() async throws -> [SeptaskProjectEntity] {
    await MainActor.run {
      let structure = StructureCache.snapshot(in: LocalStore.shared.container.mainContext)
      let areaTitles = Dictionary(uniqueKeysWithValues: structure.areas.map { ($0.id, $0.title) })
      return structure.projects
        .filter { $0.status == .active && $0.deletedAt == nil }
        .map { SeptaskProjectEntity($0, areaTitles: areaTitles) }
    }
  }
}

// MARK: - App Intents

public struct AddTaskIntent: AppIntent {
  public static var title: LocalizedStringResource = "Add Task"
  public static var description = IntentDescription(
    "Creates a new task in Septena, optionally filed in an area or project and scheduled for Today or a specific date."
  )
  public static var openAppWhenRun: Bool = false

  @Parameter(title: "Title", requestValueDialog: "What's the task?")
  public var taskTitle: String

  @Parameter(title: "Today", default: false)
  public var addToToday: Bool

  @Parameter(title: "Scheduled Date")
  public var scheduledDate: Date?

  @Parameter(title: "Project")
  public var project: SeptaskProjectEntity?

  @Parameter(title: "Area")
  public var area: SeptaskAreaEntity?

  @Parameter(title: "Notes")
  public var notes: String?

  public static var parameterSummary: some ParameterSummary {
    Summary("Add \(\.$taskTitle)") {
      \.$addToToday
      \.$scheduledDate
      \.$project
      \.$area
      \.$notes
    }
  }

  public init() {}

  public init(
    taskTitle: String,
    addToToday: Bool = false,
    scheduledDate: Date? = nil,
    project: SeptaskProjectEntity? = nil,
    area: SeptaskAreaEntity? = nil,
    notes: String? = nil
  ) {
    self.taskTitle = taskTitle
    self.addToToday = addToToday
    self.scheduledDate = scheduledDate
    self.project = project
    self.area = area
    self.notes = notes
  }

  @MainActor
  public func perform() async throws -> some IntentResult & ReturnsValue<SeptaskTaskEntity> & ProvidesDialog {
    await SeptenaServices.shared.start()

    let cleanTitle = TaskTitleText.singleLine(taskTitle)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanTitle.isEmpty else { throw SeptaskIntentError.emptyTitle }

    let cleanNotes: String? = {
      let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return trimmed.isEmpty ? nil : trimmed
    }()

    // Invariant I1 (`docs/TASK_DATES_SPEC.md`): a Today pin or a When date
    // on or before today lands on Today with `scheduled = nil`.
    let scheduledDay = scheduledDate.flatMap { SeptenaDate.format($0) }
    let todayIso = SeptenaDate.today
    let effectiveToday = addToToday || (scheduledDay != nil && scheduledDay! <= todayIso)
    let effectiveScheduled: Date? = effectiveToday ? nil : scheduledDate

    let created = SeptenaServices.shared.taskMutator.create(
      title: cleanTitle,
      area: area?.id,
      project: project?.id,
      scheduled: effectiveScheduled,
      deadline: nil,
      today: effectiveToday,
      notes: cleanNotes,
      addedVia: .shortcut
    )

    TasksWidgetSnapshotPublisher.shared.publishNow()
    TaskSyncEngine.shared.scheduleSync(after: 0)

    let context = LocalStore.shared.container.mainContext
    let entity = SeptaskTaskEntity.from(task: created, in: context)

    let dialog: IntentDialog
    if let project {
      dialog = "Added “\(created.title)” to \(project.title)."
    } else if let area {
      dialog = "Added “\(created.title)” to \(area.title)."
    } else if effectiveToday {
      dialog = "Added “\(created.title)” to Today."
    } else {
      dialog = "Added “\(created.title)” to Septena."
    }

    return .result(value: entity, dialog: dialog)
  }
}

public struct CompleteTaskIntent: AppIntent {
  public static var title: LocalizedStringResource = "Complete Task"
  public static var description = IntentDescription("Marks a task as completed in Septena.")
  public static var openAppWhenRun: Bool = false

  @Parameter(title: "Task", requestValueDialog: "Which task would you like to complete?")
  public var task: SeptaskTaskEntity

  public static var parameterSummary: some ParameterSummary {
    Summary("Complete \(\.$task)")
  }

  public init() {}

  public init(task: SeptaskTaskEntity) {
    self.task = task
  }

  @MainActor
  public func perform() async throws -> some IntentResult & ReturnsValue<SeptaskTaskEntity> & ProvidesDialog {
    await SeptenaServices.shared.start()

    let context = LocalStore.shared.container.mainContext
    guard let current = LocalCache.liveTasks(ids: [task.id], in: context).first else {
      throw SeptaskIntentError.taskNotFound
    }

    // A checked Checklist row is finished too: completing it again is a no-op.
    if current.status.isFinished {
      let existing = SeptaskTaskEntity.from(task: current, in: context)
      return .result(value: existing, dialog: "“\(current.title)” is already completed.")
    }

    SeptenaServices.shared.taskMutator.complete(id: current.id)
    TasksWidgetSnapshotPublisher.shared.publishNow()
    TaskSyncEngine.shared.scheduleSync(after: 0)

    let updated = LocalCache.liveTasks(ids: [current.id], in: context).first ?? current
    let entity = SeptaskTaskEntity.from(task: updated, in: context)
    return .result(value: entity, dialog: "Completed “\(current.title)”.")
  }
}

public struct ShowTodayIntent: AppIntent {
  public static var title: LocalizedStringResource = "Show Today"
  public static var description = IntentDescription("Opens Septena to your Today task list.")
  public static var openAppWhenRun: Bool = true

  public init() {}

  @MainActor
  public func perform() async throws -> some IntentResult {
    await SeptenaServices.shared.start()
    SeptaskDeepLinkRouter.routeFromIntent(.showToday)
    return .result()
  }
}

public struct OpenTaskConversationIntent: AppIntent {
  public static var title: LocalizedStringResource = "Open Task Conversation"
  public static var description = IntentDescription("Opens a task and its conversation in Septena.")
  public static var openAppWhenRun: Bool = true

  @Parameter(title: "Task", requestValueDialog: "Which task conversation would you like to open?")
  public var task: SeptaskTaskEntity

  public static var parameterSummary: some ParameterSummary {
    Summary("Open conversation for \(\.$task)")
  }

  public init() {}

  public init(task: SeptaskTaskEntity) {
    self.task = task
  }

  @MainActor
  public func perform() async throws -> some IntentResult {
    await SeptenaServices.shared.start()

    let context = LocalStore.shared.container.mainContext
    guard LocalCache.liveTasks(ids: [task.id], in: context).first != nil else {
      throw SeptaskIntentError.taskNotFound
    }

    SeptaskDeepLinkRouter.routeFromIntent(.openTaskConversation(taskID: task.id))
    return .result()
  }
}

public struct AssignTaskToAgentIntent: AppIntent {
  public static var title: LocalizedStringResource = "Assign Task to Claude"
  public static var description = IntentDescription(
    "Assigns a task to Claude so your connected agent can pick it up."
  )
  public static var openAppWhenRun: Bool = false

  @Parameter(title: "Task", requestValueDialog: "Which task should be assigned to Claude?")
  public var task: SeptaskTaskEntity

  @Parameter(title: "Note")
  public var note: String?

  public static var parameterSummary: some ParameterSummary {
    Summary("Assign \(\.$task) to Claude") {
      \.$note
    }
  }

  public init() {}

  public init(task: SeptaskTaskEntity, note: String? = nil) {
    self.task = task
    self.note = note
  }

  @MainActor
  public func perform() async throws -> some IntentResult & ReturnsValue<SeptaskTaskEntity> & ProvidesDialog {
    await SeptenaServices.shared.start()

    let context = LocalStore.shared.container.mainContext
    guard let current = LocalCache.liveTasks(ids: [task.id], in: context).first else {
      throw SeptaskIntentError.taskNotFound
    }

    let mutator = SeptenaServices.shared.taskMutator
    let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !trimmedNote.isEmpty {
      // Appends the user note, reopens endState, clears stoppedAt, and assigns `.claude`.
      mutator.sendBackConvo(id: current.id, note: trimmedNote)
    } else {
      if current.conversation.stoppedAt != nil {
        mutator.setConvoStopped(id: current.id, false)
      }
      if current.conversation.isTerminal {
        mutator.setConvoEndState(id: current.id, .open, note: nil)
      }
      mutator.setConvoAssignee(id: current.id, .claude)
    }

    TasksWidgetSnapshotPublisher.shared.publishNow()
    TaskSyncEngine.shared.scheduleSync(after: 0)

    let updated = LocalCache.liveTasks(ids: [current.id], in: context).first ?? current
    let entity = SeptaskTaskEntity.from(task: updated, in: context)
    return .result(value: entity, dialog: "Assigned “\(current.title)” to Claude.")
  }
}

// MARK: - App Shortcuts Provider

/// The single `AppShortcutsProvider` for Septena (iOS & macOS).
/// Every phrase MUST include `\(.applicationName)` per Apple's AppIntents rules.
public struct SeptaskAppShortcuts: AppShortcutsProvider {
  public static var shortcutTileColor: ShortcutTileColor { .orange }

  public static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: AddTaskIntent(),
      phrases: [
        "Add a task in \(.applicationName)",
        "Add task to \(.applicationName)",
        "Create a task in \(.applicationName)",
      ],
      shortTitle: "Add Task",
      systemImageName: "plus.circle"
    )
    AppShortcut(
      intent: CompleteTaskIntent(),
      phrases: [
        "Complete a task in \(.applicationName)",
        "Mark a task done in \(.applicationName)",
        "Finish a task in \(.applicationName)",
      ],
      shortTitle: "Complete Task",
      systemImageName: "checkmark.circle"
    )
    AppShortcut(
      intent: ShowTodayIntent(),
      phrases: [
        "Show Today in \(.applicationName)",
        "Open Today in \(.applicationName)",
        "Show my tasks for today in \(.applicationName)",
      ],
      shortTitle: "Show Today",
      systemImageName: "star.fill"
    )
    AppShortcut(
      intent: OpenTaskConversationIntent(),
      phrases: [
        "Open a task conversation in \(.applicationName)",
        "Open task chat in \(.applicationName)",
      ],
      shortTitle: "Task Conversation",
      systemImageName: "bubble.left.and.text.bubble.right"
    )
    AppShortcut(
      intent: AssignTaskToAgentIntent(),
      phrases: [
        "Assign a task to Claude in \(.applicationName)",
        "Hand a task to Claude in \(.applicationName)",
        "Send a task to Claude in \(.applicationName)",
      ],
      shortTitle: "Assign to Claude",
      systemImageName: "sparkles"
    )
  }
}
#endif
