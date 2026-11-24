import SwiftUI

/// One `needs_verify` row in the SwiftUI Review stage (#87).
/// Shows the task title, what Claude asked the user to check (`endStateNote`),
/// and direct Accept (completes it) / Send back (appends a user turn with a
/// note and reopens the conversation for Claude) actions.
struct ReviewTaskRow: View {
  let task: SeptenaTask
  let isSelected: Bool
  let onOpen: () -> Void
  let onAccept: () -> Void
  let onSendBack: (String) -> Void

  @State private var showingSendBack = false
  @State private var noteText = ""

  private var checkNote: String {
    if let note = task.conversation.endStateNote?.trimmingCharacters(in: .whitespacesAndNewlines),
       !note.isEmpty {
      return note
    }
    return String(localized: "Ready for review", comment: "Review stage: fallback check note")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      VStack(alignment: .leading, spacing: 3) {
        Text(task.title)
          .font(.septenaTaskTitle)
          .foregroundStyle(.primary)
          .lineLimit(2)
        Text(checkNote)
          .font(.septenaMeta)
          .foregroundStyle(Theme.inkSecondary)
          .lineLimit(3)
        if let artifact = task.conversation.artifact, !artifact.title.isEmpty {
          Label(artifact.title, systemImage: "doc.text")
            .font(.septenaCaption)
            .foregroundStyle(Theme.inkSecondary)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .onTapGesture(perform: onOpen)

      // Actions sit on their own row under the text, so a long title or
      // note never fights the buttons for width.
      HStack(spacing: 8) {
        Button("Send back") {
          a11yAnimate { showingSendBack.toggle() }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        Button(RegistryActions.title("task.acceptReview")) {
          onAccept()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
      }

      if showingSendBack {
        HStack(spacing: 6) {
          TextField("What needs another pass?", text: $noteText)
            .textFieldStyle(.roundedBorder)
            .onSubmit { submitSendBack() }
          Button("Send") { submitSendBack() }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
    .padding(.horizontal, TaskCardMetrics.headerLeading)
    .padding(.vertical, 10)
    .accessibilityElement(children: .contain)
  }

  private func submitSendBack() {
    let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    onSendBack(trimmed)
    noteText = ""
    a11yAnimate { showingSendBack = false }
  }
}
