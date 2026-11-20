import SwiftUI

// The ONE inline notice of the SwiftUI task lists. Every statement ABOUT the
// list that sits on top of it (rolled into Today, not signed in, a sync
// problem) draws through `TaskListNotice`, so they share one anatomy:
//
//   [glyph]  Title                                  (x)
//            Optional detail
//            [Action]            (macOS: the action sits trailing instead)
//
// on a rounded card-surface fill in the SAME column as the task cards
// (`TaskCardMetrics.margin` outside, `contentInset` inside), with the glyph in
// the checkbox column (`Theme.checkboxTap`). The fill is the card surface,
// never a selection color (one selection language per surface); only a
// warning adds a light wash. The AppKit counterpart is `KitNoticeCell`
// (Septask/SeptaskKitNotice.swift).

/// What a notice is about. One enum for both shells: `TaskNoticeKind`
/// (TaskNotices.swift), where which notices show is decided.
typealias TaskListNoticeKind = TaskNoticeKind

struct TaskListNotice<Actions: View>: View {
  let kind: TaskListNoticeKind
  let symbol: String
  let title: Text
  var detail: Text?
  /// Non-nil draws a small close button at the trailing edge.
  var onDismiss: (() -> Void)?
  /// Checklist rows (the Get started notice), drawn as task rows inside the
  /// card: the same checkbox, the same title and meta type. Empty for a plain
  /// notice.
  var steps: [TaskNoticeStep] = []
  /// The row's checkbox: ticks the step by hand.
  var onStepToggle: ((TaskNoticeStep.ID) -> Void)?
  /// The row itself: does the step (opens the right place).
  var onStepTap: ((TaskNoticeStep.ID) -> Void)?
  @ViewBuilder var actions: Actions

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      ForEach(steps) { step in
        CheckableRow(
          tint: Theme.inkPrimary,
          isDone: step.done,
          isInactive: step.done,
          title: step.title,
          subtitle: step.detail,
          onToggle: { if !step.done { onStepToggle?(step.id) } },
          onTap: step.done ? nil : { onStepTap?(step.id) })
        .environment(\.rowHInset, 0)
      }
    }
    .padding(.horizontal, TaskCardMetrics.contentInset)
    .padding(.vertical, 10)
    .background(fill)
    // Same margin as the task cards below, so the notice sits in the card
    // column rather than on its own inset.
    .padding(.horizontal, TaskCardMetrics.margin)
    .padding(.bottom, TaskCardMetrics.groupGap)
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.iconTextGap) {
      Image(systemName: symbol)
        .scaledFont(size: 16)
        .foregroundStyle(tint)
        .frame(width: Theme.checkboxTap, alignment: .center)
        .offset(x: -Theme.checkboxLeadingNudge)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        message
        #if !os(macOS)
        // Phone width has no room beside the text: the action goes under it,
        // like a system banner's button.
        actions.padding(.top, 6)
        #endif
      }
      Spacer(minLength: Theme.iconTextGap)
      #if os(macOS)
      actions
      #endif
      if let onDismiss { dismissButton(onDismiss) }
    }
  }

  private var message: some View {
    VStack(alignment: .leading, spacing: 2) {
      title
        .font(.septenaMetaStrong)
        .foregroundStyle(Theme.inkPrimary)
      if let detail {
        detail
          .font(.septenaMeta)
          .foregroundStyle(Theme.inkSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func dismissButton(_ action: @escaping () -> Void) -> some View {
    Button {
      Haptics.tick()
      action()
    } label: {
      Image(systemName: "xmark")
        .font(.septenaMetaStrong)
        .foregroundStyle(Theme.iconMuted)
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .inlineHover(capsule: true)
    .accessibilityLabel(Text("Dismiss"))
  }

  private var fill: some View {
    let shape = RoundedRectangle(cornerRadius: TaskCardMetrics.radius, style: .continuous)
    return shape
      .fill(Theme.cardSurface)
      .overlay(shape.fill(kind == .warning ? Theme.noticeWarning.opacity(0.12) : Color.clear))
  }

  private var tint: Color {
    switch kind {
    case .info: return Theme.inkSecondary
    case .actionNeeded: return Theme.inkPrimary
    case .warning: return Theme.noticeWarning
    }
  }
}

extension TaskListNotice where Actions == EmptyView {
  /// A notice with no action button (dismiss only, or nothing).
  init(kind: TaskListNoticeKind, symbol: String, title: Text, detail: Text? = nil,
       onDismiss: (() -> Void)? = nil) {
    self.init(kind: kind, symbol: symbol, title: title, detail: detail,
              onDismiss: onDismiss, actions: { EmptyView() })
  }
}
