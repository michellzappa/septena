import SwiftUI

/// Placeholder rows in the task-list shape, for a Today that has nothing to
/// draw yet but is still loading (#82): signed in on a new device, before the
/// account's first pull lands. Never a spinner on Today.
///
/// Same geometry as a closed `TaskRow` inside a task card: the checkbox
/// column, `Theme.iconTextGap`, a title band in `.septenaTaskTitle` (redacted
/// text, so the band has the real line height), and the list's
/// `rowHInset` / `rowVInset`. A slow opacity pulse says "loading"; with Reduce
/// Motion on, the rows stay still.
struct TaskSkeletonRows: View {
  var count: Int = 6

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var dimmed = false

  /// Varied title lengths, so the rows read as a list and not as a grid.
  private static let titles = [
    "Placeholder task title here",
    "Short task",
    "A somewhat longer placeholder task",
    "Placeholder title",
    "Another placeholder task row",
    "Task title",
  ]

  var body: some View {
    VStack(spacing: 0) {
      ForEach(0..<count, id: \.self) { index in
        TaskSkeletonRow(title: Self.titles[index % Self.titles.count])
          .taskCardChrome(TaskCardPosition(index: index, count: count))
      }
    }
    .opacity(dimmed && !reduceMotion ? 0.5 : 1)
    .a11yAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dimmed)
    .onAppear { dimmed = true }
    .allowsHitTesting(false)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text("Loading tasks"))
  }
}

private struct TaskSkeletonRow: View {
  let title: String

  @Environment(\.rowHInset) private var rowHInset
  @Environment(\.rowVInset) private var rowVInset

  var body: some View {
    HStack(spacing: Theme.iconTextGap) {
      Circle()
        .strokeBorder(Theme.border, lineWidth: 1.5)
        .frame(width: Theme.checkboxBoxSize, height: Theme.checkboxBoxSize)
        .frame(width: Theme.checkboxTap)
      Text(title)
        .font(.septenaTaskTitle)
        .lineLimit(1)
        .redacted(reason: .placeholder)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, rowHInset)
    .padding(.vertical, rowVInset)
  }
}
