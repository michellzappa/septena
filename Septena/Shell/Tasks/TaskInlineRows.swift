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

/// Inline title edit/create row. This deliberately lives outside
/// `TaskListView`: the list owns state transitions, while this view owns only
/// field focus, platform text behavior, and visual alignment.
struct InlineTaskRow: View {
  @Binding var text: String
  let placeholder: String
  let accent: Color
  let isDone: Bool
  var isToday: Bool = false
  var dashed: Bool = false
  @FocusState.Binding var focus: TaskListView.InlineFocus?
  let focusValue: TaskListView.InlineFocus
  var showsDetails: Bool = false
  var allowsMultiline: Bool = true
  let onToggle: () -> Void
  let onCommit: () -> Void
  let onCancel: () -> Void
  var onOpenDetails: (() -> Void)? = nil

  @Environment(\.rowHInset) private var rowHInset
  @Environment(\.rowVInset) private var rowVInset

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.iconTextGap) {
      TaskCheckbox(isDone: isDone, dashed: dashed, isToday: isToday, onToggle: onToggle)
        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }

      titleField.frame(maxWidth: .infinity, alignment: .leading)

      if showsDetails, let onOpenDetails {
        Button(action: onOpenDetails) {
          Image(systemName: "info.circle")
            .font(.body)
            .foregroundStyle(accent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit details")
      }
    }
    .padding(.horizontal, rowHInset)
    .padding(.vertical, rowVInset)
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private var titleField: some View {
    Group {
      if allowsMultiline {
        TextField(placeholder, text: $text, axis: .vertical).lineLimit(1...4)
      } else {
        TextField(placeholder, text: $text).lineLimit(1)
      }
    }
    .textFieldStyle(.plain)
    .font(.septenaTaskTitle)
    .foregroundStyle(Theme.inkPrimary)
    .focused($focus, equals: focusValue)
    .submitLabel(.done)
    .onSubmit(onCommit)
    #if os(iOS)
    .onChange(of: text) { _, newValue in
      guard allowsMultiline, newValue.contains("\n") else { return }
      text = newValue.replacingOccurrences(of: "\n", with: "")
      onCommit()
    }
    #endif
    #if os(macOS)
    .onKeyPress(.return) { onCommit(); return .handled }
    .onKeyPress(.escape) { onCancel(); return .handled }
    .onExitCommand(perform: onCancel)
    #endif
  }
}
