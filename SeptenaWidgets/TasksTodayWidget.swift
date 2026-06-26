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
      .widgetTileInnerPadding()
      .widgetSurfaceInsets()
      .widgetURL(URL(string: "septena://tasks/today"))
      .containerBackground(for: .widget) {
        Theme.cardSurface
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

  private var placeholder: some View {
    VStack(alignment: .leading, spacing: 8) {
      TasksTodayHeader(totalCount: 0)
      Text("Open Septena once to load today.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  }
}

private struct TasksTodayWidgetContent: View {
  let snapshot: TasksWidgetWire
  let compact: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 6 : 8) {
      TasksTodayHeader(totalCount: snapshot.totalCount)
      if snapshot.totalCount == 0 {
        Spacer(minLength: 0)
        Text("All done")
          .font(compact ? .subheadline.weight(.semibold) : .title3.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
        Spacer(minLength: 0)
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(snapshot.tasks.enumerated()), id: \.element.id) { index, task in
            if index > 0 {
              Spacer(minLength: compact ? 5 : 7)
            }
            TasksTodayRow(task: task, compact: compact)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

private struct TasksTodayHeader: View {
  let totalCount: Int

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: "sun.max.fill")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Theme.todayAccent)
      Text("Today")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.primary)
      Spacer(minLength: 0)
      Text("\(totalCount)")
        .font(.subheadline.weight(.semibold).monospacedDigit())
        .foregroundStyle(.secondary)
    }
  }
}

private struct TasksTodayRow: View {
  let task: TasksWidgetTaskWire
  let compact: Bool

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      Circle()
        .stroke(Theme.todayAccent, lineWidth: 1.5)
        .frame(width: compact ? 13 : 14, height: compact ? 13 : 14)
      Text(task.title)
        .font(.system(size: compact ? 12.5 : 13.5, weight: .medium))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .truncationMode(.tail)
      if task.isOverdue {
        Spacer(minLength: 0)
        Image(systemName: "exclamationmark.circle.fill")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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
