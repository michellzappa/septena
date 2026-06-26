import Foundation
import SwiftData

@MainActor
enum TasksWidgetBuilder {
  static let displayLimit = 4

  static func buildSnapshot(context: ModelContext) -> TasksWidgetWire {
    let open = LocalCache.tasks(in: context, filter: .today)
      .filter { $0.status == .open }
    let rows = open.prefix(displayLimit).map { task in
      TasksWidgetTaskWire(id: task.id, title: task.title, isOverdue: task.isOverdue)
    }
    return TasksWidgetWire(
      today: SeptenaDate.today,
      totalCount: open.count,
      tasks: Array(rows),
      updatedAt: .now)
  }
}
