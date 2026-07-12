import Foundation
import SwiftData

@MainActor
enum TasksWatchBuilder {
  static func buildSnapshot(context: ModelContext) -> TasksWatchWire {
    let open = LocalCache.tasks(in: context, filter: .today)
      .filter { $0.status == .open }
    let rows = open.enumerated().map { idx, task in
      TasksWatchTaskWire(
        id: task.id,
        title: task.title,
        isOverdue: task.isOverdue,
        sortKey: idx)
    }
    let sections = SettingsMirror.loadSections(context: context)
    let accent = sections.first(where: { $0.key == "tasks" })?.color
    return TasksWatchWire(
      today: SeptenaDate.today,
      totalCount: open.count,
      tasks: rows,
      accentColor: accent,
      updatedAt: .now)
  }
}
