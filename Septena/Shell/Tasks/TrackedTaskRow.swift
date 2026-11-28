import SwiftUI

/// One row of Review ▸ Tracked in the SwiftUI shell (ADR 0066,
/// docs/REVIEW_SPEC.md §2): the title, the end-state note as the context
/// line, and the issue link from the task's references, which opens in the
/// browser. A tap anywhere else opens the task page.
struct TrackedTaskRow: View {
  let task: SeptenaTask
  /// The newest `issue` reference with a URL, else the first reference with
  /// one (`LocalCache.trackedLinkRefs`).
  var link: TaskRefRow? = nil
  let onOpen: () -> Void

  private var note: String? {
    let trimmed = task.conversation.endStateNote?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      VStack(alignment: .leading, spacing: 4) {
        Text(task.title)
          .font(.septenaTaskTitle)
          .foregroundStyle(.primary)
          .lineLimit(2)
        if let note {
          Text(note)
            .font(.septenaMeta)
            .foregroundStyle(Theme.inkSecondary)
            .lineLimit(2)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .onTapGesture(perform: onOpen)

      if let link {
        Button {
          TaskRefActions.open(link, navigation: nil)
        } label: {
          Label(link.title, systemImage: link.sfSymbol)
            .font(.septenaMeta)
            .lineLimit(1)
        }
        .buttonStyle(.borderless)
        .help(link.link?.absoluteString ?? link.title)
      }
    }
    .padding(.horizontal, TaskCardMetrics.headerLeading)
    .padding(.vertical, 12)
    .accessibilityElement(children: .contain)
  }
}
