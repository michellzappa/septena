import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// The one genuinely new bit of UI: a transcript + input. The session is
// created lazily in `.task` (so it has access to the environment's
// modelContext) and held as @State so it isn't rebuilt on every redraw.

struct CoachChatView: View {
  let domain: CoachDomain
  /// Bridge back to the Discovery flow: hand it DraftGoals to leave the
  /// chat and drop the user into goal review (the sanctioned write path).
  let onFinish: ([DraftGoal]) -> Void

  @Environment(\.modelContext) private var context
  @Environment(DayClock.self) private var clock
  @State private var session: CoachSession?
  @State private var window: CoachWindow = .default
  /// Section keys the user tapped to mute — excluded from the coach's
  /// context. Persists across window changes within this chat.
  @State private var mutedKeys: Set<String> = []
  @State private var draft = ""
  @State private var makingGoal = false
  @State private var showingPrompt = false
  /// Proposed-commitment cards the user has accepted / dismissed (by action id).
  @State private var acceptedActions: Set<UUID> = []
  @State private var dismissedActions: Set<UUID> = []
  @FocusState private var inputFocused: Bool

  private var goalMutator: GoalMutator { SeptenaServices.shared.goalMutator }

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
        OverflowMenu(systemImage: makingGoal ? "hourglass" : "ellipsis") {
          // Time window — tucked into its own submenu.
          Menu {
            Picker("Look back", selection: $window) {
              ForEach(CoachWindow.allCases) { w in Text(w.label).tag(w) }
            }
          } label: {
            Label("Time · \(window.label)", systemImage: "calendar")
          }

          if let session {
            Divider()
            Button {
              showingPrompt = true
            } label: {
              Label("View prompt", systemImage: "doc.text.magnifyingglass")
            }
            Button {
              makeCommitment(session)
            } label: {
              Label("Propose a commitment", systemImage: "target")
            }
            .disabled(!hasUserMessage(session) || session.isThinking || makingGoal || !session.isLive)

            Divider()
            Button(role: .destructive) {
              session.clearTranscript()
            } label: {
              Label("Clear conversation", systemImage: "trash")
            }
            .disabled(session.isThinking)
          }
        }
      }
    }
    .sheet(isPresented: $showingPrompt) {
      if let session {
        CoachPromptInspector(text: session.systemPrompt, accent: domain.accent)
      }
    }
    .task {
      if session == nil {
        // Freeform coach starts with nothing in scope — you opt sections in.
        if domain.handPicksContext {
          mutedKeys = Set(domain.sectionKeys ?? CoachContextBuilder.supportedKeys)
        }
        rebuild()
      }
    }
    .onChange(of: window) { rebuild() }
  }

  /// Build (or rebuild) the session for the current window. Changing the
  /// window re-reads the data, so the conversation resets with fresh facts
  /// and pills — the model can't be left citing a window it can't see.
  private func rebuild() {
    session = CoachSession(domain: domain, window: window, context: context,
                           excluding: mutedKeys, now: clock.now)
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
              messageRow(session, message).id(message.id)
            }
            if session.awaitingFirstToken {
              thinkingRow.id("thinking")
            }
          }
          .padding(16)
        }
        .onChange(of: session.messages.last?.text) {
          withAnimation { proxy.scrollTo(session.messages.last?.id, anchor: .bottom) }
        }
      }

      Divider()
      // Just above the keyboard: tappable starters, until the chat begins.
      // For the freeform coach, hold them back until something's in scope.
      if !hasUserMessage(session), session.isLive, !session.domain.starters.isEmpty,
         !domain.handPicksContext || anyInScope(session) {
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

  /// Any section currently in scope (pill present and not muted).
  private func anyInScope(_ session: CoachSession) -> Bool {
    session.pills.contains { !mutedKeys.contains($0.id) }
  }

  /// One transcript row: the bubble plus any follow-up / action / citation
  /// chips. Empty coach placeholders (pre-first-token) render nothing — the
  /// "Thinking…" row covers that gap.
  @ViewBuilder
  private func messageRow(_ session: CoachSession, _ message: CoachSession.Message) -> some View {
    let isCoach = message.role == .coach
    if isCoach && message.text.isEmpty {
      EmptyView()
    } else {
      VStack(alignment: isCoach ? .leading : .trailing, spacing: 6) {
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
        if isCoach, !message.followUps.isEmpty { followUpChips(session, message.followUps) }
        // Dormant today — lit up by a reasoning backend that proposes actions
        // (confirmable, routed through mutators) and cites the data it used.
        if isCoach, !message.actions.isEmpty { actionChips(message.actions) }
        if isCoach, !message.citations.isEmpty { citationRow(message.citations) }
      }
      .frame(maxWidth: .infinity, alignment: isCoach ? .leading : .trailing)
      .padding(isCoach ? .trailing : .leading, 40)
    }
  }

  /// Tappable follow-ups offered after a coach reply — tap to ask it.
  private func followUpChips(_ session: CoachSession, _ followUps: [String]) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach(followUps, id: \.self) { q in
          Button {
            draft = q
            submit(session)
          } label: {
            Text(q)
              .font(.caption.weight(.medium))
              .foregroundStyle(domain.accent)
              .padding(.horizontal, 12).padding(.vertical, 7)
              .background(Capsule().stroke(domain.accent.opacity(0.35), lineWidth: 1))
          }
          .buttonStyle(.plain)
          .disabled(session.isThinking)
        }
      }
    }
  }

  /// Confirm-gated commitment cards. The model only proposes; tapping "Add"
  /// is what writes — through `GoalMutator` (the write-boundary invariant).
  @ViewBuilder
  private func actionChips(_ actions: [CoachProposedAction]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(actions) { action in
        if !dismissedActions.contains(action.id) {
          commitmentCard(action)
        }
      }
    }
  }

  private func commitmentCard(_ action: CoachProposedAction) -> some View {
    let accepted = acceptedActions.contains(action.id)
    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "target").foregroundStyle(domain.accent)
        Text(action.goalText)
          .font(.subheadline.weight(.medium))
          .fixedSize(horizontal: false, vertical: true)
      }
      if let detail = metricDetail(action) {
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      if accepted {
        Label("Added to your goals", systemImage: "checkmark.circle.fill")
          .font(.caption.weight(.medium))
          .foregroundStyle(domain.accent)
      } else {
        HStack(spacing: 8) {
          Button { accept(action) } label: { Text("Add").fontWeight(.semibold) }
            .buttonStyle(.borderedProminent)
            .tint(domain.accent)
          Button { dismissedActions.insert(action.id) } label: { Text("Dismiss") }
            .buttonStyle(.bordered)
        }
        .font(.caption)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(domain.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(domain.accent.opacity(0.3), lineWidth: 1))
  }

  /// Human caption for the proposed measurement, e.g. "Target 140–170 g".
  private func metricDetail(_ a: CoachProposedAction) -> String? {
    guard let key = a.metricKey, let target = a.metricTarget else { return nil }
    let unit = GoalMetricCatalog.metric(for: key)?.unitLabel ?? ""
    let existing = LocalCache.goals(in: context).contains { $0.metricKey == key }
    let verb = existing ? "Update target to" : "Target"
    if a.metricComparator == "range", let upper = a.metricUpper {
      return "\(verb) \(num(target))–\(num(upper)) \(unit)"
    }
    let cmp = a.metricComparator == "lte" ? "≤" : (a.metricComparator == "eq" ? "=" : "≥")
    return "\(verb) \(cmp) \(num(target)) \(unit)"
  }

  private func num(_ v: Double) -> String {
    v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
  }

  /// Apply an accepted commitment. If a goal already carries this metric, move
  /// its target (edit); otherwise create a new goal. Always via the mutator.
  private func accept(_ a: CoachProposedAction) {
    let clean = a.goalText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return }
    if let key = a.metricKey,
       let existing = LocalCache.goals(in: context).first(where: { $0.metricKey == key }) {
      // Edit: keep the user's own goal text/sections, just move the target.
      goalMutator.updateGoalMetric(id: existing.id,
                                   metricKey: key,
                                   window: a.metricWindow,
                                   comparator: a.metricComparator,
                                   target: a.metricTarget,
                                   baseline: existing.metricBaseline,
                                   upper: a.metricUpper)
    } else {
      let goal = goalMutator.createGoal(text: clean)
      goalMutator.updateGoal(id: goal.id, text: clean, sections: a.sections)
      if let key = a.metricKey {
        goalMutator.updateGoalMetric(id: goal.id,
                                     metricKey: key,
                                     window: a.metricWindow,
                                     comparator: a.metricComparator,
                                     target: a.metricTarget,
                                     baseline: nil,
                                     upper: a.metricUpper)
      }
    }
    acceptedActions.insert(a.id)
    Haptics.success()
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

  /// Ask the coach for a structured commitment and surface it as a confirm
  /// card in the transcript. The card's "Add" is the only thing that writes.
  private func makeCommitment(_ session: CoachSession) {
    makingGoal = true
    Task {
      _ = await session.proposeCommitment()
      makingGoal = false
    }
  }
}

/// Read-only inspector for the exact context seeded into the model — the
/// persona + computed FACTS/GOALS block. Has a copy button so the prompt
/// can be pasted into another model for testing.
private struct CoachPromptInspector: View {
  let text: String
  let accent: Color

  @Environment(\.dismiss) private var dismiss
  @State private var copied = false

  var body: some View {
    NavigationStack {
      ScrollView {
        Text(text)
          .font(.system(.footnote, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(16)
      }
      .navigationTitle("Prompt")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            CoachClipboard.copy(text)
            withAnimation { copied = true }
          } label: {
            Label(copied ? "Copied" : "Copy",
                  systemImage: copied ? "checkmark" : "doc.on.doc")
          }
          .tint(accent)
        }
      }
    }
  }
}

/// Tiny cross-platform pasteboard wrapper.
private enum CoachClipboard {
  static func copy(_ text: String) {
    #if canImport(UIKit)
    UIPasteboard.general.string = text
    #elseif canImport(AppKit)
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
    #endif
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
