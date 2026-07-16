import SwiftUI

/// The keyboard-addressable quick-add row. Interaction is supplied by its
/// surrounding selectable list row, keeping creation and task activation on
/// the same contract.
struct QuickAddTriggerRow: View {
  @Environment(\.rowHInset) private var rowHInset
  @Environment(\.rowVInset) private var rowVInset

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.iconTextGap) {
      TaskCheckbox(isDone: false, dashed: TaskRowFlags.languageV2,
                   isToday: false, onToggle: {})
        .allowsHitTesting(false)
        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }
      Text("New task")
        .font(.septenaTaskTitle)
        .foregroundStyle(Theme.inkSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, rowHInset)
    .padding(.vertical, rowVInset)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel("New task")
    .accessibilityAddTraits(.isButton)
  }
}
