import Foundation

struct TasksWidgetTaskWire: Codable, Equatable, Sendable, Identifiable {
  var id: String
  var title: String
  var isOverdue: Bool
}

/// Today's open task list for the Tasks home-screen widget.
struct TasksWidgetWire: Codable, Equatable, Sendable {
  var today: String
  var totalCount: Int
  /// Up to four rows, in Today-list manual order.
  var tasks: [TasksWidgetTaskWire]
  var updatedAt: Date

  static var sample: TasksWidgetWire {
    TasksWidgetWire(
      today: "2026-06-26",
      totalCount: 7,
      tasks: [
        .init(id: "1", title: "Reply to the landlord", isOverdue: true),
        .init(id: "2", title: "Book dentist", isOverdue: false),
        .init(id: "3", title: "Send invoice", isOverdue: false),
        .init(id: "4", title: "Water the plants", isOverdue: false),
      ],
      updatedAt: .now
    )
  }
}
