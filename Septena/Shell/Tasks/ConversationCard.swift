import SwiftUI

// The conversation surface for a task, embedded in the task composer (edit mode)
// below the fields. Renders a PERSISTENT transcript — every turn stays visible
// (agent questions, the user's answers, agent notes) — with option buttons only
// on the latest open question. A tap writes a `user` turn through TaskMutator;
// gateway-authored turns arrive via CloudKit sync on `.septenaTasksChanged`.
// Phase 1 (agent_doable): docs/TASK_CONVERSATIONS_PHASE1.md.
//
// Pure content (no NavigationStack/dismiss); SeptenaCore is compiled into the app
// target so the convo types / mutator resolve without an import.
struct ConversationCard: View {
  let taskID: String
  let accent: Color

  @State private var convo: TaskConvo
  @State private var showOther = false
  @State private var otherText = ""
  @State private var showInfo = false

  /// Seed `convo` from the already-loaded task so the card paints on the FIRST
  /// frame (no fetch-on-open lag); `onAppear`/`.septenaTasksChanged` then refresh
  /// it (a single by-id read) to pick up turns appended after open.
  init(taskID: String, initial: TaskConvo = TaskConvo(), accent: Color = .accentColor) {
    self.taskID = taskID
    self.accent = accent
    _convo = State(initialValue: initial)
  }

  var body: some View {
    Group {
      if convo.hasStarted {
        VStack(alignment: .leading, spacing: 12) {
          // Resolved turns sit above as a compact history; the current open
          // question is promoted to a prominent title over its option pills.
          ForEach(historyTurns, id: \.seq) { transcriptRow($0) }

          // Agent deliverable (agent_assisted) — what Claude produced.
          if let artifact = convo.artifact { artifactBlock(artifact) }

          if let q = openQuestion {
            questionBlock(q)
          } else if let handoff = convo.handoff {
            handoffButton(handoff)            // human last-mile — show even when the agent's side is done
          } else if convo.isTerminal {
            terminalRow
          } else {
            Label("Claude is working…", systemImage: "ellipsis.bubble")
              .font(.caption).foregroundStyle(.secondary)
          }

          // The agent-done bar (distinct from task completion = human-done).
          if let acceptance = convo.acceptance, !acceptance.isEmpty {
            Divider()
            Label("Done when: \(acceptance)", systemImage: "target")
              .font(.caption2).foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .onAppear(perform: reload)
    .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in reload() }
    .sheet(isPresented: $showInfo) { AIExplainerView() }
  }

  /// Everything except the current open question (which renders as the title).
  private var historyTurns: [ConvoTurn] {
    guard let q = openQuestion else { return convo.thread }
    return convo.thread.filter { $0.seq != q.seq }
  }

  // MARK: Transcript (resolved history)

  @ViewBuilder private func transcriptRow(_ t: ConvoTurn) -> some View {
    if t.role == .provider {
      if let q = t.question {
        row(icon: "bubble.left", tint: .secondary, text: q, font: .subheadline)
      } else if let note = t.note {
        row(icon: "bubble.left", tint: .secondary, text: note, font: .caption, dim: true)
      }
    } else if let answer = t.chosen ?? t.otherText {
      row(icon: "checkmark.circle.fill", tint: .green, text: answer, font: .subheadline, weight: .medium)
    }
  }

  @ViewBuilder
  private func row(icon: String, tint: Color, text: String, font: Font,
                   weight: Font.Weight = .regular, dim: Bool = false) -> some View {
    HStack(alignment: .top, spacing: 6) {
      Image(systemName: icon).font(.caption).foregroundStyle(tint)
      Text(text).font(font).fontWeight(weight)
        .foregroundStyle(dim ? Color.secondary : Color.primary)
      Spacer(minLength: 0)
    }
  }

  // MARK: Open question — the prominent title + option pills

  @ViewBuilder private func questionBlock(_ q: ConvoTurn) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      // The question IS the title: chat glyph beside it, ⓘ explainer trailing.
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "bubble.left.and.bubble.right.fill")
          .font(.subheadline).foregroundStyle(accent)
        Text(q.question ?? "").font(.headline).foregroundStyle(.primary)
        Spacer(minLength: 6)
        Button { showInfo = true } label: { Image(systemName: "info.circle").font(.subheadline) }
          .buttonStyle(.borderless).foregroundStyle(.secondary)
          .help("How AI helps with your tasks")
      }

      // Options as content-width pills (wrap), with "Other" opening a field.
      FlowLayout(spacing: 8) {
        ForEach(q.options ?? [], id: \.self) { option in
          Button { choose(option, replyTo: q.seq, step: q.step) } label: { Text(option) }
            .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(accent)
        }
        Button { withAnimation { showOther.toggle() } } label: { Text("Other…") }
          .buttonStyle(.bordered).buttonBorderShape(.capsule)
      }

      if showOther {
        HStack {
          TextField("Type your answer", text: $otherText)
            .textFieldStyle(.roundedBorder)
            .onSubmit { submitOther(replyTo: q.seq, step: q.step) }
          Button("Send") { submitOther(replyTo: q.seq, step: q.step) }
            .buttonStyle(.borderedProminent)
            .disabled(otherText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
    }
  }

  @ViewBuilder private var terminalRow: some View {
    let wontDo = convo.endState == .wontDo
    HStack(alignment: .top, spacing: 6) {
      Image(systemName: wontDo ? "xmark.circle" : "checkmark.seal.fill")
        .font(.caption).foregroundStyle(wontDo ? .gray : .green)
      VStack(alignment: .leading, spacing: 2) {
        Text(wontDo ? "Won't do" : "Resolved").font(.subheadline)
        if let note = convo.endStateNote {
          Text(note).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  // MARK: Artifact + handoff (agent_assisted)

  @ViewBuilder private func artifactBlock(_ a: ConvoArtifact) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(a.title, systemImage: "doc.text").font(.subheadline).fontWeight(.medium)
      Text(a.body).font(.caption).foregroundStyle(.primary)
      if let refs = a.refs, !refs.isEmpty {
        ForEach(refs, id: \.self) { ref in
          Text(ref).font(.caption2).foregroundStyle(.secondary)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(Theme.paperBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
  }

  @ViewBuilder private func handoffButton(_ h: ConvoHandoff) -> some View {
    if let url = actionURL(h) {
      Link(destination: url) {
        Label(h.instruction, systemImage: actionIcon(h.actionType))
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.borderedProminent)
    } else {
      Label(h.instruction, systemImage: actionIcon(h.actionType))
        .font(.subheadline)
    }
  }

  private func actionURL(_ h: ConvoHandoff) -> URL? {
    guard let p = h.payload, !p.isEmpty else { return nil }
    switch h.actionType {
    case .openURL: return URL(string: p)
    case .compose: return URL(string: "mailto:\(p)")
    case .call:    return URL(string: "tel:\(p)")
    case .none:    return nil
    }
  }

  private func actionIcon(_ t: ConvoHandoff.ActionType) -> String {
    switch t {
    case .openURL: return "arrow.up.right.square"
    case .compose: return "envelope"
    case .call:    return "phone"
    case .none:    return "hand.point.right"
    }
  }

  // MARK: Derived

  private var openQuestion: ConvoTurn? {
    guard convo.hasOpenProviderQuestion else { return nil }
    return convo.thread.last
  }

  // MARK: Actions

  private func reload() {
    convo = SeptenaServices.shared.taskMutator.conversation(id: taskID) ?? TaskConvo()
  }

  private func choose(_ label: String, replyTo: Int, step: ConvoTurn.Step) {
    append(ConvoTurn(seq: 0, role: .user, step: step, chosen: label, inReplyTo: replyTo, ts: Date()))
  }

  private func submitOther(replyTo: Int, step: ConvoTurn.Step) {
    let text = otherText.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return }
    append(ConvoTurn(seq: 0, role: .user, step: step, otherText: text, inReplyTo: replyTo, ts: Date()))
    otherText = ""
    showOther = false
  }

  private func append(_ turn: ConvoTurn) {
    SeptenaServices.shared.taskMutator.appendConvoTurn(id: taskID, turn)
    reload()
  }
}

/// The conversation as a normal section inside the task composer's scroll: the
/// `ConversationCard` (open question promoted to a title over its option pills),
/// and the `AskAIButton` shown only before a conversation exists. No header
/// chrome and no card box — it's inline content that scrolls with the drawer and
/// runs full-width, like the rest of the form.
struct ConversationSection: View {
  let task: SeptenaTask
  let accent: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ConversationCard(taskID: task.id, initial: task.conversation, accent: accent)
      AskAIButton(task: task)
    }
  }
}

/// Plain-language explainer of how AI works around tasks. Copy source of truth:
/// docs/AI_TASKS_EXPLAINER.md (the website reuses it later). Opened from the ⓘ on
/// the Conversation card; reusable from Settings too.
struct AIExplainerView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Text("Some to-dos need a moment of thinking before you can act. Septena can talk that through with AI — right on the task.")
            .font(.headline)

          VStack(alignment: .leading, spacing: 0) {
            Text("How a task conversation moves")
              .font(.subheadline).fontWeight(.semibold).padding(.bottom, 10)
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
              stepRow(s, isLast: i == steps.count - 1)
            }
            Text("On Automatic, every step runs on your device first — it leaves only for the steps on-device can't do (↗), never wholesale.")
              .font(.caption2).foregroundStyle(.secondary).padding(.top, 6)
          }

          VStack(alignment: .leading, spacing: 6) {
            Text("Whose turn?").font(.subheadline).fontWeight(.semibold)
            legend(.yellow, "Your turn — a question is waiting")
            legend(.blue, "AI's turn — it's working")
            legend(.green, "Done")
          }

          VStack(alignment: .leading, spacing: 6) {
            Label("Some help is always on your device", systemImage: "iphone")
              .font(.subheadline).fontWeight(.semibold)
            Text("Beyond conversations, Septena learns small things locally — like the “Move to…” suggestion that figures out where a task belongs from your own history. That model trains on your device and never leaves it.")
              .font(.callout).foregroundStyle(.secondary)
          }

          VStack(alignment: .leading, spacing: 6) {
            Label("It's your AI — we never see your data", systemImage: "lock.fill")
              .font(.subheadline).fontWeight(.semibold)
            Text("Septena never runs AI on your tasks and never reads them. The intelligence is your own — your Claude, or on-device — connected by you. Your tasks live only in your private iCloud. Turn the AI off and the app works exactly the same, minus the conversations.")
              .font(.callout).foregroundStyle(.secondary)
          }
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Theme.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

          Text("Nothing important happens on its own. The AI fills in small, reversible stuff; anything that's a real decision or can't be undone always waits for your tap.")
            .font(.callout).foregroundStyle(.secondary)
        }
        .padding(20)
      }
      .navigationTitle("How AI helps")
      .septenaInlineTitle()
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
  }

  private struct Step { let icon: String; let title: String; let desc: String; let runs: String; let tint: Color }
  private var steps: [Step] {
    [
      Step(icon: "square.and.pencil", title: "Capture", desc: "You jot the task — a few words is fine.", runs: "You", tint: .gray),
      Step(icon: "questionmark.bubble", title: "Confirm", desc: "AI asks what you actually mean. Nothing happens until you tap.", runs: "On-device", tint: .green),
      Step(icon: "doc.text.magnifyingglass", title: "Ground", desc: "It pulls the relevant context from your own data.", runs: "On-device", tint: .green),
      Step(icon: "checklist", title: "Decide", desc: "It offers a few options; you pick. A hard call may use the cloud.", runs: "On-device ↗", tint: .blue),
      Step(icon: "hammer", title: "Work", desc: "It does what it can — a draft, a comparison. Web / your Claude only if a step needs it.", runs: "On-device ↗", tint: .blue),
      Step(icon: "hand.point.right", title: "Hand off", desc: "Anything only you can do (pay, send) becomes one clear button.", runs: "You", tint: .gray),
    ]
  }

  @ViewBuilder private func stepRow(_ s: Step, isLast: Bool) -> some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(spacing: 0) {
        Image(systemName: s.icon).font(.callout).foregroundStyle(s.tint)
          .frame(width: 28, height: 28)
          .background(s.tint.opacity(0.12), in: Circle())
        if !isLast {
          Rectangle().fill(.quaternary).frame(width: 1.5).frame(maxHeight: .infinity)
        }
      }
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(s.title).font(.subheadline).fontWeight(.semibold)
          Spacer()
          Text(s.runs).font(.caption2).foregroundStyle(s.tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(s.tint.opacity(0.12), in: Capsule())
        }
        Text(s.desc).font(.footnote).foregroundStyle(.secondary)
      }
      .padding(.bottom, isLast ? 0 : 14)
    }
  }

  @ViewBuilder private func legend(_ color: Color, _ text: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "circle.fill").font(.caption2).foregroundStyle(color)
      Text(text).font(.callout)
    }
  }
}

/// Kicks off a conversation on a fresh task — runs the on-device first step
/// (via `ConversationEngine`, which routes per the AI dial). Shows only when no
/// conversation exists yet; once a turn lands, the card takes over. Press-to-
/// advance: nothing runs until tapped.
struct AskAIButton: View {
  let task: SeptenaTask
  @State private var hasStarted: Bool
  @State private var working = false

  init(task: SeptenaTask) {
    self.task = task
    _hasStarted = State(initialValue: task.conversation.hasStarted)
  }

  var body: some View {
    Group {
      if !hasStarted {
        Button(action: run) {
          HStack(spacing: 6) {
            if working { ProgressView().controlSize(.small) }
            else { Image(systemName: "bubble.left.and.bubble.right") }
            Text(working ? "Thinking…" : "Talk it through with AI")
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(working || !OnDeviceAI.isAvailable)
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in refresh() }
  }

  private func run() {
    working = true
    Task {
      _ = await ConversationEngine.advance(task: task)
      working = false
      refresh()
    }
  }

  private func refresh() {
    hasStarted = SeptenaServices.shared.taskMutator.conversation(id: task.id)?.hasStarted ?? false
  }
}

/// Plain ball-in-court indicator for a task row's trailing slot — 🟡/🔵/✅/⚫.
/// Reads the convo by id on appear (only visible rows fetch) and refreshes on
/// `.septenaTasksChanged`. Renders nothing without a conversation. The exchange
/// itself opens with the task (in the composer) — this is just the signal.
struct ConvoBadgeView: View {
  /// The conversation carried on the already-loaded `SeptenaTask` — no
  /// fetch-by-id per row. Refreshes when the list rebuilds its tasks (which it
  /// does on `.septenaTasksChanged`).
  let convo: TaskConvo

  var body: some View {
    if convo.hasStarted, let badge = deriveConvo(convo).badge {
      glyph(badge)
    }
  }

  private func glyph(_ b: ConvoBadge) -> some View {
    let spec: (name: String, color: Color) = {
      switch b {
      case .needsYou: return ("circle.fill", .yellow)
      case .working:  return ("circle.fill", .blue)
      case .done:     return ("checkmark.circle.fill", .green)
      case .wontDo:   return ("circle.slash", .gray)
      }
    }()
    return Image(systemName: spec.name).font(.caption2).foregroundStyle(spec.color)
      .accessibilityLabel("Conversation: \(b)")
  }
}
