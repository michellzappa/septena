import Foundation

// Wire shapes and deep-link routing shared between the host app (Septask /
// SeptaskMac) and its WidgetKit extensions (docs/TASK_WIDGETS_SPEC.md, #160).
// Pure Foundation — no SwiftData, no SwiftUI — so widget extensions stay tiny
// and under WidgetKit's memory ceiling, and SeptenaCoreTests can test it
// hermetically.

public enum TasksWidgetKind {
  public static let tasks = "SeptaskTasksWidget"
  public static let pendingCompletionDarwinNotification = "com.septena.widget.pendingCompletion"
}

public enum TasksWidgetListKind: String, Codable, Equatable, Hashable, Sendable {
  case today
  case upcoming
  case inbox
  case starred
  case project
  case area
}

public struct TasksWidgetTaskItem: Codable, Equatable, Hashable, Sendable, Identifiable {
  public var id: String
  public var title: String
  public var isOverdue: Bool
  public var isStarred: Bool
  public var subtitle: String?
  public var timeBadge: String?
  public var deadlineBadge: String?

  public init(
    id: String,
    title: String,
    isOverdue: Bool = false,
    isStarred: Bool = false,
    subtitle: String? = nil,
    timeBadge: String? = nil,
    deadlineBadge: String? = nil
  ) {
    self.id = id
    self.title = title
    self.isOverdue = isOverdue
    self.isStarred = isStarred
    self.subtitle = subtitle
    self.timeBadge = timeBadge
    self.deadlineBadge = deadlineBadge
  }
}

public struct TasksWidgetListSummary: Codable, Equatable, Hashable, Sendable, Identifiable {
  public static let todayID = "smart:today"
  public static let upcomingID = "smart:upcoming"
  public static let inboxID = "smart:inbox"
  public static let starredID = "smart:starred"

  public var id: String
  public var kind: TasksWidgetListKind
  public var title: String
  public var symbol: String
  public var count: Int
  public var items: [TasksWidgetTaskItem]

  public init(
    id: String,
    kind: TasksWidgetListKind,
    title: String,
    symbol: String,
    count: Int,
    items: [TasksWidgetTaskItem]
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.symbol = symbol
    self.count = count
    self.items = items
  }

  public static func projectID(_ rawID: String) -> String { "project:\(rawID)" }
  public static func areaID(_ rawID: String) -> String { "area:\(rawID)" }
}

public struct TasksWidgetSnapshot: Codable, Equatable, Sendable {
  public static let currentVersion = 1
  public static let maxItemsPerList = 12

  public var version: Int
  public var day: String
  public var updatedAt: Date
  public var isRedacted: Bool
  public var accentHex: String?
  public var lists: [TasksWidgetListSummary]

  public init(
    version: Int = currentVersion,
    day: String,
    updatedAt: Date = Date(),
    isRedacted: Bool = false,
    accentHex: String? = nil,
    lists: [TasksWidgetListSummary]
  ) {
    self.version = version
    self.day = day
    self.updatedAt = updatedAt
    self.isRedacted = isRedacted
    self.accentHex = accentHex
    self.lists = lists
  }

  public var todayList: TasksWidgetListSummary {
    list(for: TasksWidgetListSummary.todayID)
      ?? TasksWidgetListSummary(
        id: TasksWidgetListSummary.todayID,
        kind: .today,
        title: "Today",
        symbol: "star.fill",
        count: 0,
        items: []
      )
  }

  public func list(for id: String) -> TasksWidgetListSummary? {
    lists.first { $0.id == id }
  }

  /// Optimistically removes a task ID from every list summary when checked off
  /// directly inside a widget, keeping counts truthful until the host app
  /// commits and publishes the authoritative snapshot.
  public func removingTask(id taskID: String) -> TasksWidgetSnapshot {
    var copy = self
    copy.updatedAt = Date()
    copy.lists = lists.map { summary in
      var next = summary
      let before = next.items.count
      next.items.removeAll { $0.id == taskID }
      if next.items.count < before {
        next.count = max(0, next.count - (before - next.items.count))
      }
      return next
    }
    return copy
  }

  public static var sample: TasksWidgetSnapshot {
    TasksWidgetSnapshot(
      day: "2026-11-22",
      updatedAt: Date(),
      isRedacted: false,
      accentHex: nil,
      lists: [
        TasksWidgetListSummary(
          id: TasksWidgetListSummary.todayID,
          kind: .today,
          title: "Today",
          symbol: "star.fill",
          count: 4,
          items: [
            TasksWidgetTaskItem(id: "sample-1", title: "Review quarterly roadmap", isOverdue: true, subtitle: "Work", deadlineBadge: "Today"),
            TasksWidgetTaskItem(id: "sample-2", title: "Dentist appointment", subtitle: "Health", timeBadge: "14:00–15:00"),
            TasksWidgetTaskItem(id: "sample-3", title: "Pick up coffee beans", subtitle: "Errands"),
            TasksWidgetTaskItem(id: "sample-4", title: "Send project update", isStarred: true, subtitle: "Work"),
          ]
        ),
        TasksWidgetListSummary(
          id: TasksWidgetListSummary.upcomingID,
          kind: .upcoming,
          title: "Upcoming",
          symbol: "calendar",
          count: 2,
          items: [
            TasksWidgetTaskItem(id: "sample-5", title: "Renew passport", subtitle: "Tomorrow"),
            TasksWidgetTaskItem(id: "sample-6", title: "Team offsite prep", subtitle: "Nov 25"),
          ]
        ),
        TasksWidgetListSummary(
          id: TasksWidgetListSummary.inboxID,
          kind: .inbox,
          title: "Inbox",
          symbol: "tray.fill",
          count: 1,
          items: [
            TasksWidgetTaskItem(id: "sample-7", title: "Book train tickets", subtitle: "Inbox"),
          ]
        ),
        TasksWidgetListSummary(
          id: TasksWidgetListSummary.starredID,
          kind: .starred,
          title: "Favorites",
          symbol: "star",
          count: 1,
          items: [
            TasksWidgetTaskItem(id: "sample-4", title: "Send project update", isStarred: true, subtitle: "Work"),
          ]
        ),
      ]
    )
  }
}

/// Deep links shared between widgets, iCal events, and the app targets.
public enum TasksWidgetDeepLink: Equatable, Sendable {
  case quickAdd
  case list(id: String)
  case task(id: String)

  public var url: URL {
    switch self {
    case .quickAdd:
      return URL(string: "septask://quick-add")!
    case .list(let id):
      let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
      return URL(string: "septask://list/\(encoded)")!
    case .task(let id):
      let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
      return URL(string: "septask://task/\(encoded)")!
    }
  }

  public static func parse(_ url: URL) -> TasksWidgetDeepLink? {
    guard url.scheme?.lowercased() == "septask" else { return nil }
    let host = url.host?.lowercased() ?? ""
    let pathParts = url.pathComponents.filter { $0 != "/" }
    switch host {
    case "quick-add":
      return .quickAdd
    case "list":
      guard let raw = pathParts.first, !raw.isEmpty else { return .list(id: TasksWidgetListSummary.todayID) }
      return .list(id: raw.removingPercentEncoding ?? raw)
    case "task":
      guard let raw = pathParts.first, !raw.isEmpty else { return nil }
      return .task(id: raw.removingPercentEncoding ?? raw)
    default:
      return nil
    }
  }
}
