import WidgetKit
import SwiftUI

struct TasksTodayEntry: TimelineEntry {
  let date: Date
  let snapshot: TasksWidgetWire?

  var isEmpty: Bool { snapshot?.totalCount == 0 }

  static var sample: TasksTodayEntry {
    TasksTodayEntry(date: .now, snapshot: .sample)
  }

  static var empty: TasksTodayEntry {
    TasksTodayEntry(date: .now, snapshot: nil)
  }
}

struct TasksTodayProvider: TimelineProvider {
  func placeholder(in context: Context) -> TasksTodayEntry { .sample }

  func getSnapshot(in context: Context, completion: @escaping (TasksTodayEntry) -> Void) {
    if context.isPreview {
      completion(.sample)
      return
    }
    completion(entry())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<TasksTodayEntry>) -> Void) {
    let entry = entry()
    let next = Calendar.current.date(byAdding: .minute, value: 30, to: .now)
      ?? Date(timeIntervalSinceNow: 1800)
    completion(Timeline(entries: [entry], policy: .after(next)))
  }

  private func entry() -> TasksTodayEntry {
    guard let snapshot = TasksWidgetSnapshotStore.load() else { return .empty }
    return TasksTodayEntry(date: .now, snapshot: snapshot)
  }
}

struct TasksTodayWidgetView: View {
  @Environment(\.widgetFamily) private var family
  let entry: TasksTodayEntry

  var body: some View {
    content
      .widgetSurfaceInsets()
      .widgetURL(URL(string: "septena://tasks/today"))
      .containerBackground(for: .widget) {
        Theme.widgetSurface
      }
  }

  @ViewBuilder
  private var content: some View {
    if let snapshot = entry.snapshot {
      TasksTodayWidgetContent(snapshot: snapshot, compact: family == .systemSmall)
    } else {
      placeholder
    }
  }

  // Snapshot missing — keep the shared header, swap the rows for a hint.
  private var placeholder: some View {
    WidgetListLayout(
      compact: family == .systemSmall,
      header: header(totalCount: 0, compact: family == .systemSmall),
      isEmpty: false
    ) {
      Text("Open Septena once to load today.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

/// Today's shared header — the gold sun, the "Today" title, and the open count.
private func header(totalCount: Int, compact: Bool) -> WidgetListHeader {
  WidgetListHeader(
    icon: "sun.max.fill",
    title: "Today",
    accent: Theme.todayAccent,
    trailing: "\(totalCount)",
    compact: compact
  )
}

private struct TasksTodayWidgetContent: View {
  let snapshot: TasksWidgetWire
  let compact: Bool

  var body: some View {
    WidgetListLayout(
      compact: compact,
      header: header(totalCount: snapshot.totalCount, compact: compact),
      isEmpty: snapshot.totalCount == 0
    ) {
      ForEach(snapshot.tasks, id: \.id) { task in
        WidgetListRow(
          compact: compact,
          title: task.title,
          overdue: task.isOverdue
        ) {
          // Match the app's task checkbox: a neutral-gray rounded square
          // (`Theme.checkboxStroke`), not a gold progress dot.
          RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .strokeBorder(Theme.checkboxStroke, lineWidth: 1.5)
            .frame(width: WidgetListMetrics.glyphFrame(compact),
                   height: WidgetListMetrics.glyphFrame(compact))
        }
      }
    }
  }
}

struct TasksTodayWidget: Widget {
  static let kind = "TasksTodayWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: Self.kind, provider: TasksTodayProvider()) { entry in
      TasksTodayWidgetView(entry: entry)
    }
    .configurationDisplayName("Today")
    .description("Your Today list — open tasks at a glance.")
    .supportedFamilies([.systemSmall, .systemMedium])
    .septenaWidgetMargins()
  }
}

#Preview("Small", as: .systemSmall) {
  TasksTodayWidget()
} timeline: {
  TasksTodayEntry.sample
}

#Preview("Medium", as: .systemMedium) {
  TasksTodayWidget()
} timeline: {
  TasksTodayEntry.sample
}

#Preview("Empty", as: .systemSmall) {
  TasksTodayWidget()
} timeline: {
  TasksTodayEntry(date: .now, snapshot: TasksWidgetWire(
    today: "2026-06-26", totalCount: 0, tasks: [], updatedAt: .now))
}
