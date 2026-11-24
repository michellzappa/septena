import SwiftUI

/// One `needs_verify` row in the SwiftUI Review stage (#87): the title, what
/// the agent asked the user to check (in full), where the task lives and how
/// long the hand-off has waited, then Accept and Send back on their own line
/// (docs/AGENT_PROMPT_SPEC.md). Send back opens the task page with the note
/// field already open: the row never hosts a text field.
struct ReviewTaskRow: View {
  let task: SeptenaTask
  /// The task's newest `issue` reference.
  var issue: TaskRefRow? = nil
  let isSelected: Bool
  /// "Area › Project", the area alone, or the Inbox.
  let listLabel: String
  let onOpen: () -> Void
  let onAccept: () -> Void
  let onSendBack: () -> Void

  private var checkNote: String {
    if let note = task.conversation.endStateNote?.trimmingCharacters(in: .whitespacesAndNewlines),
       !note.isEmpty {
      return note
    }
    return RegistrySurfaces.agentPromptReviewFallback
  }

  private var metaLine: String {
    var parts = [listLabel]
    if let at = task.conversation.endStateAt {
      parts.append(TaskHistory.relative(at, now: DayClock.appNow))
    }
    if let issue { parts.append(issue.title) }
    if let artifact = task.conversation.artifact, !artifact.title.isEmpty {
      parts.append(artifact.title)
    }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 4) {
        Text(task.title)
          .font(.septenaTaskTitle)
          .foregroundStyle(.primary)
          .lineLimit(2)
        // The review question shows in full, never truncated.
        Text(checkNote)
          .font(.septenaTaskTitle)
          .foregroundStyle(Theme.inkSecondary)
          .fixedSize(horizontal: false, vertical: true)
        Text(metaLine)
          .font(.septenaMeta)
          .foregroundStyle(Theme.inkSecondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .onTapGesture(perform: onOpen)

      // Same order as the task page's agent prompt: Accept, then Send back.
      HStack(spacing: 8) {
        Button(RegistryActions.title("task.acceptReview"), action: onAccept)
          .buttonStyle(.borderedProminent)
          .controlSize(.taskAction)
        Button(RegistryActions.title("task.sendBackReview"), action: onSendBack)
          .buttonStyle(.bordered)
          .controlSize(.taskAction)
      }
    }
    .padding(.horizontal, TaskCardMetrics.headerLeading)
    .padding(.vertical, 12)
    .accessibilityElement(children: .contain)
  }
}
