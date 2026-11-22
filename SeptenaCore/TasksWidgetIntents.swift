import AppIntents
import Foundation

// Widget configuration and interactive task completion AppIntents
// (docs/TASK_WIDGETS_SPEC.md §2 & §5, #160).
//
// Compiled into both the host apps (Septask / SeptaskMac) and the WidgetKit
// extensions (`WIDGET_EXTENSION`). Progressive disclosure: the default
// configuration has `list == nil` -> Today; long-pressing "Edit Widget" lets
// the user choose Today, Upcoming, Inbox, Starred, or any Project / Area.

public struct SeptaskWidgetListEntity: AppEntity, Identifiable, Hashable, Sendable {
  public static var typeDisplayRepresentation: TypeDisplayRepresentation {
    TypeDisplayRepresentation(name: "Task List")
  }

  public static var defaultQuery = SeptaskWidgetListQuery()

  public let id: String
  public let title: String
  public let symbol: String

  public var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: "\(title)",
      image: .init(systemName: symbol)
    )
  }

  public init(id: String, title: String, symbol: String) {
    self.id = id
    self.title = title
    self.symbol = symbol
  }

  public static let todayDefault = SeptaskWidgetListEntity(
    id: TasksWidgetListSummary.todayID,
    title: "Today",
    symbol: "star.fill"
  )

  static let builtInDefaults: [SeptaskWidgetListEntity] = [
    todayDefault,
    SeptaskWidgetListEntity(id: TasksWidgetListSummary.upcomingID, title: "Upcoming", symbol: "calendar"),
    SeptaskWidgetListEntity(id: TasksWidgetListSummary.inboxID, title: "Inbox", symbol: "tray.fill"),
    SeptaskWidgetListEntity(id: TasksWidgetListSummary.starredID, title: "Starred", symbol: "star"),
  ]
}

public struct SeptaskWidgetListQuery: EntityQuery {
  public init() {}

  public func entities(for identifiers: [String]) async throws -> [SeptaskWidgetListEntity] {
    let all = allOptions()
    return identifiers.compactMap { id in all.first(where: { $0.id == id }) }
  }

  public func suggestedEntities() async throws -> [SeptaskWidgetListEntity] {
    allOptions()
  }

  public func defaultResult() async -> SeptaskWidgetListEntity? {
    .todayDefault
  }

  private func allOptions() -> [SeptaskWidgetListEntity] {
    guard let snapshot = TasksWidgetSnapshotStore.load(), !snapshot.lists.isEmpty else {
      return SeptaskWidgetListEntity.builtInDefaults
    }
    return snapshot.lists.map {
      SeptaskWidgetListEntity(id: $0.id, title: $0.title, symbol: $0.symbol)
    }
  }
}

public struct SeptaskWidgetConfigurationIntent: WidgetConfigurationIntent {
  public static var title: LocalizedStringResource = "Septena Tasks"
  public static var description = IntentDescription("Choose which list to show in the widget. Defaults to Today.")

  @Parameter(title: "List")
  public var list: SeptaskWidgetListEntity?

  public init() {}

  public init(list: SeptaskWidgetListEntity?) {
    self.list = list
  }

  public var resolvedListID: String {
    list?.id ?? TasksWidgetListSummary.todayID
  }
}

public struct CompleteTaskWidgetIntent: AppIntent {
  public static var title: LocalizedStringResource = "Complete Task"
  public static var description = IntentDescription("Marks a task done from a Septena widget.")
  public static var openAppWhenRun: Bool = false
  public static var isDiscoverable: Bool = false

  @Parameter(title: "Task ID")
  public var taskID: String

  public init() {
    self.taskID = ""
  }

  public init(taskID: String) {
    self.taskID = taskID
  }

  @MainActor
  public func perform() async throws -> some IntentResult {
    let trimmed = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .result() }
    #if WIDGET_EXTENSION
    TasksWidgetSnapshotStore.markCompletedOptimistically(taskID: trimmed)
    #else
    await SeptenaServices.shared.start()
    SeptenaServices.shared.taskMutator.complete(id: trimmed)
    TasksWidgetSnapshotPublisher.shared.publishNow()
    #endif
    return .result()
  }
}
