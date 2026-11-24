import SwiftUI

// One pattern for every agent exchange (docs/AGENT_PROMPT_SPEC.md): a kicker
// (who asks, when), the question in full, a vertical list of choices, and a
// last choice that turns in place into a multi-line field for telling the
// agent what to do instead. Review, open questions and follow-up replies all
// draw through these two views, so they cannot drift apart.

/// One choice in an agent prompt. At most one is primary.
struct AgentPromptChoice: Identifiable {
  let id: String
  let title: String
  var isPrimary = false
  let action: () -> Void
}

/// The free-text last choice: the button title, and the registry text prompt
/// (`surfaces.json` `prompts.text`) that supplies the placeholder and the
/// confirm title.
struct AgentPromptFreeText {
  let buttonTitle: String
  let prompt: RegistryTextPrompt
  let onSend: (String) -> Void
}

struct AgentPromptCard: View {
  let kicker: String?
  let question: String
  let choices: [AgentPromptChoice]
  let freeText: AgentPromptFreeText?
  /// Opens the free-text field (and focuses it) as soon as the card shows.
  /// The Review row's Send back uses it to land straight in the field.
  @Binding var freeTextOpen: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        if let kicker {
          Text(kicker)
            .font(.septenaMeta)
            .foregroundStyle(Theme.inkSecondary)
        }
        Text(question)
          .font(.septenaTaskTitle)
          .foregroundStyle(Theme.inkPrimary)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }

      VStack(alignment: .leading, spacing: 8) {
        ForEach(choices) { choice in
          choiceButton(choice)
        }
        if let freeText {
          if freeTextOpen {
            AgentReplyField(prompt: freeText.prompt,
                            onSend: { text in
                              freeText.onSend(text)
                              a11yAnimate { freeTextOpen = false }
                            },
                            onCancel: { a11yAnimate { freeTextOpen = false } })
          } else {
            Button { a11yAnimate { freeTextOpen = true } } label: {
              Text(freeText.buttonTitle).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.taskAction)
          }
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.secondaryGroupedBackground,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  @ViewBuilder private func choiceButton(_ choice: AgentPromptChoice) -> some View {
    let label = Text(choice.title)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity)
    if choice.isPrimary {
      Button(action: choice.action) { label }
        .buttonStyle(.borderedProminent)
        .controlSize(.taskAction)
    } else {
      Button(action: choice.action) { label }
        .buttonStyle(.bordered)
        .controlSize(.taskAction)
    }
  }
}

/// The multi-line field for telling an agent something: Send back, Other…,
/// Reply…. It takes focus when it appears. ⌘Return sends; Cancel (or
/// Escape on the Mac) closes it.
struct AgentReplyField: View {
  let prompt: RegistryTextPrompt
  let onSend: (String) -> Void
  let onCancel: () -> Void

  @State private var text = ""
  @FocusState private var focused: Bool

  private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField(prompt.placeholder, text: $text, axis: .vertical)
        .lineLimit(3...6)
        .font(.septenaTaskTitle)
        .focused($focused)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.groupedBackground,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onKeyPress(.escape) { onCancel(); return .handled }

      HStack(spacing: 8) {
        Button(RegistryPrompts.cancelTitle, action: onCancel)
          .buttonStyle(.bordered)
          .controlSize(.taskAction)
        Spacer(minLength: 0)
        Button(prompt.confirmTitle, action: send)
          .buttonStyle(.borderedProminent)
          .controlSize(.taskAction)
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(trimmed.isEmpty)
      }
    }
    .onAppear { focused = true }
  }

  private func send() {
    guard !trimmed.isEmpty else { return }
    onSend(trimmed)
    text = ""
  }
}

/// A request to open the Send back field on a task's page. The Review row's
/// Send back sets it and opens the page; the page's conversation reads it
/// once and clears it.
@MainActor @Observable
final class AgentPromptRequests {
  static let shared = AgentPromptRequests()
  var sendBackTaskID: String?
}

extension TaskConvo {
  /// "Review requested · 2h ago" — the kicker of a Review prompt.
  func reviewKicker(now: Date) -> String {
    let base = String(localized: "Review requested", comment: "Agent prompt: kicker over a review hand-off")
    guard let at = endStateAt else { return base }
    return "\(base) · \(TaskHistory.relative(at, now: now))"
  }
}
