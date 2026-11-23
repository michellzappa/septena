import SwiftUI

// One task row. Two targets, like Reminders: the checkbox completes, the rest
// of the row opens the task. Each label carries `.contentShape` so its whole
// frame is tappable, gaps included (AGENTS.md "row dead zone").

struct TaskRowView: View {
  let task: WatchTask
  let today: String
  let onComplete: () -> Void
  let onOpen: () -> Void

  @State private var checked = false
  private var store: WatchStore { .shared }

  private static let boxSize: CGFloat = 18
  private static let boxCorner: CGFloat = 4.5
  private static let boxStroke: CGFloat = 1.4

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
        ZStack {
          RoundedRectangle(cornerRadius: Self.boxCorner, style: .continuous)
            .strokeBorder(Color.secondary, lineWidth: Self.boxStroke)
            .frame(width: Self.boxSize, height: Self.boxSize)
            .opacity(checked ? 0 : 1)
          ZStack {
            RoundedRectangle(cornerRadius: Self.boxCorner, style: .continuous)
              .fill(store.accentColor)
              .frame(width: Self.boxSize, height: Self.boxSize)
            Image(systemName: "checkmark")
              .font(.system(size: 11, weight: .bold))
              .foregroundStyle(store.accentInkColor)
          }
          .scaleEffect(checked ? 1 : 0.55)
          .opacity(checked ? 1 : 0)
        }
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
      out.append(AnyView(Text("Today").foregroundStyle(.red)))
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
