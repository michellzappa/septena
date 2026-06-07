import SwiftData
import SwiftUI

// The one genuinely new bit of UI: a transcript + input. The session is
// created lazily in `.task` (so it has access to the environment's
// modelContext) and held as @State so it isn't rebuilt on every redraw.

struct CoachChatView: View {
  let domain: CoachDomain

  @Environment(\.modelContext) private var context
  @State private var session: CoachSession?
  @State private var window: CoachWindow = .week
  /// Section keys the user tapped to mute — excluded from the coach's
  /// context. Persists across window changes within this chat.
  @State private var mutedKeys: Set<String> = []
  @State private var draft = ""
  @FocusState private var inputFocused: Bool

  var body: some View {
    Group {
      if let session {
        chat(session)
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .navigationTitle(domain.title)
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu {
          Picker("Look back", selection: $window) {
            ForEach(CoachWindow.allCases) { w in Text(w.label).tag(w) }
          }
        } label: {
          Label(window.shortLabel, systemImage: "calendar")
            .labelStyle(.titleAndIcon)
        }
      }
    }
    .task {
      if session == nil { rebuild() }
    }
    .onChange(of: window) { rebuild() }
  }

  /// Build (or rebuild) the session for the current window. Changing the
  /// window re-reads the data, so the conversation resets with fresh facts
  /// and pills — the model can't be left citing a window it can't see.
  private func rebuild() {
    session = CoachSession(domain: domain, window: window, context: context, excluding: mutedKeys)
    draft = ""
  }

  private func toggleMute(_ key: String) {
    if mutedKeys.contains(key) { mutedKeys.remove(key) } else { mutedKeys.insert(key) }
    rebuild()   // re-seed the model with the new scope (pre-chat only)
  }

  // MARK: - Chat

  private func chat(_ session: CoachSession) -> some View {
    VStack(spacing: 0) {
      // Top: the data scope — what the coach can see, tap to mute. Collapses
      // once the conversation begins.
      if !hasUserMessage(session), !session.pills.isEmpty {
        pillStrip(session)
        Divider()
      }
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 12) {
            ForEach(session.messages) { message in
              bubble(message).id(message.id)
            }
            if session.isThinking {
              thinkingRow.id("thinking")
            }
          }
          .padding(16)
        }
        .onChange(of: session.messages.count) {
          withAnimation { proxy.scrollTo(session.messages.last?.id, anchor: .bottom) }
        }
      }

      Divider()
      // Just above the keyboard: tappable starters, until the chat begins.
      if !hasUserMessage(session), session.isLive, !session.domain.starters.isEmpty {
        starterStrip(session)
      }
      inputBar(session)
    }
  }

  /// Accent-tinted pills showing which sections — and how many entries —
  /// the coach can "see". Tap a pill to mute that section: it dims and
  /// drops out of the coach's context until tapped again.
  private func pillStrip(_ session: CoachSession) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(session.pills) { pill in
          let muted = mutedKeys.contains(pill.id)
          Button {
            toggleMute(pill.id)
          } label: {
            HStack(spacing: 5) {
              Image(systemName: muted ? "eye.slash" : pill.systemImage)
                .font(.caption2)
              Text(pill.label)
                .font(.caption.weight(.medium))
                .strikethrough(muted, color: .secondary)
              Text("\(pill.count)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background((muted ? Color.secondary : domain.accent).opacity(0.22), in: Capsule())
            }
            .foregroundStyle(muted ? Color.secondary : domain.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background((muted ? Color.secondary : domain.accent).opacity(0.12), in: Capsule())
            .opacity(muted ? 0.6 : 1)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
    }
  }

  /// Tappable starters sitting just above the input. Tapping fills the
  /// field with that text and sends it; they collapse once the chat begins.
  private func starterStrip(_ session: CoachSession) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(session.domain.starters, id: \.self) { starter in
          Button {
            draft = starter
            submit(session)
          } label: {
            Text(starter)
              .font(.caption.weight(.medium))
              .foregroundStyle(domain.accent)
              .padding(.horizontal, 12)
              .padding(.vertical, 7)
              .background(
                Capsule().stroke(domain.accent.opacity(0.35), lineWidth: 1)
              )
          }
          .buttonStyle(.plain)
          .disabled(session.isThinking)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
    }
  }

  private func hasUserMessage(_ session: CoachSession) -> Bool {
    session.messages.contains { $0.role == .user }
  }

  private func bubble(_ message: CoachSession.Message) -> some View {
    let isCoach = message.role == .coach
    return VStack(alignment: isCoach ? .leading : .trailing, spacing: 6) {
      Text(message.text)
        .font(.body)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
          isCoach ? AnyShapeStyle(Theme.secondaryGroupedBackground)
                  : AnyShapeStyle(domain.accent.opacity(0.18)),
          in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
      // Dormant today — lit up by a reasoning backend that proposes actions
      // (confirmable, routed through mutators) and cites the data it used.
      if isCoach, !message.actions.isEmpty { actionChips(message.actions) }
      if isCoach, !message.citations.isEmpty { citationRow(message.citations) }
    }
    .frame(maxWidth: .infinity, alignment: isCoach ? .leading : .trailing)
    .padding(isCoach ? .trailing : .leading, 40)
  }

  /// Proposed actions as confirmable chips. The accept handler is a TODO:
  /// it must route through the section's mutator, never write directly.
  private func actionChips(_ actions: [CoachProposedAction]) -> some View {
    FlowChips(actions) { action in
      Button {
        // TODO(reasoning-backend): route through the section mutator.
      } label: {
        Label(action.title, systemImage: "plus.circle")
          .font(.caption.weight(.medium))
          .padding(.horizontal, 12).padding(.vertical, 7)
          .background(domain.accent.opacity(0.14), in: Capsule())
      }
      .buttonStyle(.plain)
      .foregroundStyle(domain.accent)
    }
  }

  private func citationRow(_ citations: [CoachCitation]) -> some View {
    FlowChips(citations) { citation in
      Label(citation.label, systemImage: "quote.opening")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.secondary.opacity(0.1), in: Capsule())
    }
  }

  private var thinkingRow: some View {
    HStack(spacing: 8) {
      ProgressView()
      Text("Thinking…").font(.footnote).foregroundStyle(.secondary)
      Spacer()
    }
  }

  private func inputBar(_ session: CoachSession) -> some View {
    HStack(spacing: 10) {
      TextField(session.isLive ? "Message your coach…" : "On-device AI unavailable",
                text: $draft, axis: .vertical)
        .lineLimit(1...4)
        .textFieldStyle(.plain)
        .focused($inputFocused)
        .disabled(!session.isLive)
        .onSubmit { submit(session) }

      Button {
        submit(session)
      } label: {
        Image(systemName: "arrow.up.circle.fill")
          .font(.title2)
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(domain.accent)
      }
      .buttonStyle(.plain)
      .disabled(!canSend(session))
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  // MARK: - Actions

  private func canSend(_ session: CoachSession) -> Bool {
    session.isLive
      && !session.isThinking
      && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func submit(_ session: CoachSession) {
    guard canSend(session) else { return }
    let text = draft
    draft = ""
    Task { await session.send(text) }
  }
}

/// A simple horizontal row of chips. Used for proposed-action and citation
/// chips under coach messages (dormant until a reasoning backend fills them).
private struct FlowChips<Item: Identifiable, Content: View>: View {
  let items: [Item]
  let content: (Item) -> Content

  init(_ items: [Item], @ViewBuilder content: @escaping (Item) -> Content) {
    self.items = items
    self.content = content
  }

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach(items) { content($0) }
      }
    }
  }
}
