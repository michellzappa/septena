import SwiftUI

// One task row. Two targets, like Reminders: the circle completes, the rest
// of the row opens the task. Each label carries `.contentShape` so its whole
// frame is tappable, gaps included (AGENTS.md "row dead zone").

struct TaskRowView: View {
  let task: WatchTask
  let today: String
  let onComplete: () -> Void
  let onOpen: () -> Void

  @State private var checked = false

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Button {
        guard !checked else { return }
        withAnimation(.snappy(duration: 0.2)) { checked = true }
        // Let the check draw before the row leaves.
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(350))
          onComplete()
          checked = false
        }
      } label: {
        Image(systemName: checked ? "checkmark.circle.fill" : "circle")
          .font(.title3)
          .foregroundStyle(checked ? Color.green : circleTint)
          .contentTransition(.symbolEffect(.replace))
          .frame(width: 28, height: 28)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Complete \(task.title)")

      Button(action: onOpen) {
        VStack(alignment: .leading, spacing: 2) {
          Text(task.title)
            .font(.body)
            .lineLimit(3)
            .strikethrough(checked)
            .foregroundStyle(checked ? .secondary : .primary)
          TaskMetaLine(task: task, today: today)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .contain)
  }

  /// Tasks carried over for days darken, as on the phone (one seventh a day).
  private var circleTint: Color {
    let days = min(task.daysOnToday ?? 0, 7)
    return days == 0 ? .secondary : Color.orange.opacity(0.45 + Double(days) * 0.08)
  }
}

/// Due state, time, list and repeat glyph — whatever applies, on one line.
struct TaskMetaLine: View {
  let task: WatchTask
  let today: String

  var body: some View {
    let parts = items
    if !parts.isEmpty {
      HStack(spacing: 4) {
        ForEach(parts.indices, id: \.self) { i in
          parts[i]
        }
      }
      .font(.footnote)
      .lineLimit(1)
    }
  }

  private var items: [AnyView] {
    var out: [AnyView] = []
    switch task.due(today: today) {
    case .overdue:
      out.append(AnyView(Text("Overdue").foregroundStyle(.red)))
    case .dueToday:
      out.append(AnyView(Text("Due today").foregroundStyle(.orange)))
    case .none:
      if let deadline = task.deadline, deadline > today {
        out.append(AnyView(Text(Self.short(deadline)).foregroundStyle(.orange)))
      }
    }
    if let time = task.startTime {
      out.append(AnyView(Text(time).foregroundStyle(.secondary)))
    }
    if let list = task.container {
      out.append(AnyView(Text(list).foregroundStyle(.secondary)))
    }
    if let total = task.checklistCount, total > 0 {
      out.append(AnyView(Text("\(task.checklistDoneCount ?? 0)/\(total)").foregroundStyle(.secondary)))
    }
    if task.isRepeating {
      out.append(AnyView(Image(systemName: "repeat").foregroundStyle(.secondary).accessibilityLabel("Repeats")))
    }
    return out
  }

  static func short(_ ymd: String) -> String {
    guard let date = WatchDay.date(from: ymd) else { return ymd }
    return date.formatted(.dateTime.month(.abbreviated).day())
  }
}
