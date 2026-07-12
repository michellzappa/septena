import Foundation

/// CloudKit snapshot identity — reuses the existing `WatchSnapshot` Production
/// schema (same fields as Septena's watch snapshot) with a distinct record name
/// so the two watch apps never clobber each other.
enum TasksWatchSnapshot {
  static let recordType = "WatchSnapshot"
  static let recordName = "septask-watch-snapshot"
}

struct TasksWatchTaskWire: Codable, Equatable, Sendable, Identifiable {
  var id: String
  var title: String
  var isOverdue: Bool
  var sortKey: Int
}

/// Today's open task list for the Septask watch app — the full Today list in
/// manual order (not capped like the iOS widget wire).
struct TasksWatchWire: Codable, Equatable, Sendable {
  var today: String
  var totalCount: Int
  var tasks: [TasksWatchTaskWire]
  /// The tasks section accent from the phone (`SectionEntity.color`), so the
  /// wrist can tint chrome without compiling `SectionTheme`.
  var accentColor: String?
  var updatedAt: Date

  static var sample: TasksWatchWire {
    TasksWatchWire(
      today: "2026-07-12",
      totalCount: 3,
      tasks: [
        .init(id: "1", title: "Reply to the landlord", isOverdue: true, sortKey: 0),
        .init(id: "2", title: "Book dentist", isOverdue: false, sortKey: 1),
        .init(id: "3", title: "Send invoice", isOverdue: false, sortKey: 2),
      ],
      accentColor: "#3b82f6",
      updatedAt: .now)
  }
}
