import SwiftUI

/// The keyboard-addressable quick-add row. Interaction is supplied by its
/// surrounding selectable list row, keeping creation and task activation on
/// the same contract.
struct QuickAddTriggerRow: View {
  @Environment(\.rowHInset) private var rowHInset
  @Environment(\.rowVInset) private var rowVInset

  var body: some View {
    HStack(alignment: .rowTitleCenter, spacing: Theme.iconTextGap) {
      TaskCheckbox(isDone: false, dashed: TaskRowFlags.languageV2,
                   isToday: false, onToggle: {})
        .allowsHitTesting(false)
        .alignmentGuide(.rowTitleCenter) { d in d[VerticalAlignment.center] }
      Text("New task")
        .font(.septenaTaskTitle)
        .foregroundStyle(Theme.inkSecondary)
        .frame(maxWidth: .infinity, minHeight: Theme.checkboxTap, alignment: .leading)
        .alignmentGuide(.rowTitleCenter) { d in d[VerticalAlignment.center] }
    }
    .padding(.horizontal, rowHInset)
    .padding(.vertical, rowVInset)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityLabel("New task")
    .accessibilityAddTraits(.isButton)
  }
}
