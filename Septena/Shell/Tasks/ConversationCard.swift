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
  @State private var isTaskOpen: Bool = true
  @State private var showOther = false
  @State private var otherText = ""
  @State private var showSendBack = false
  @State private var sendBackNote = ""
  @State private var showReply = false
  @State private var replyText = ""
  @State private var showInfo = false

  /// Seed `convo` from the already-loaded task so the card paints on the FIRST
  /// frame (no fetch-on-open lag); `onAppear`/`.septenaTasksChanged` then refresh
  /// it (a single by-id read) to pick up turns appended after open.
  init(taskID: String, initial: TaskConvo = TaskConvo(), isTaskOpen: Bool = true, accent: Color = .accentColor) {
    self.taskID = taskID
    self.accent = accent
    _convo = State(initialValue: initial)
    _isTaskOpen = State(initialValue: isTaskOpen)
  }

  var body: some View {
    // A VStack, not a Group: with no conversation yet the Group had no child,
    // so `.onAppear` / `.onReceive` never ran and a thread that started later
    // never showed (CLAUDE.md Group-modifier trap).
    VStack(alignment: .leading, spacing: 0) {
      if convo.hasStarted {
        VStack(alignment: .leading, spacing: 12) {
          // Resolved turns sit above as a compact history; the current open
          // question is promoted to a prominent title over its option pills.
          ForEach(historyTurns, id: \.seq) { transcriptRow($0) }

          // Agent deliverable (agent_assisted) — what Claude produced.
          if let artifact = convo.artifact { artifactBlock(artifact) }

          // Associated GitHub issue/PR when not already shown inside an artifact block.
          if convo.artifact?.linkedIssue == nil, let issue = convo.linkedIssue {
            issueLinkPill(issue)
          }

          if let q = openQuestion {
            questionBlock(q)
          } else if convo.needsHumanReview || (convo.endState == .agentAssistedDone && !isTaskOpen) {
            reviewBlock
          } else if let handoff = convo.handoff {
            handoffButton(handoff)            // human last-mile — show even when the agent's side is done
          } else if convo.isTerminal {
            terminalRow
          } else {
            agentRow
          }

          if openQuestion == nil, isTaskOpen, !convo.needsHumanReview {
            followUpBlock
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
    } else if let answer = t.chosen ?? t.otherText ?? t.note {
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

      // Beta diagnostic: which model raised this question (hidden when off).
      if q.provider != nil {
        AIModelTagBadge(tag: AIModelTag(q.provider))
      }

      // Short choices flow as compact capsule chips; longer options stack as
      // full-width wrapped rounded cards so text never clips off-screen.
      let options = q.options ?? []
      if options.contains(where: { $0.count > 22 }) {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(options, id: \.self) { option in
            Button { choose(option, replyTo: q.seq, step: q.step) } label: {
              Text(option)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .tint(accent)
          }
          Button { a11yAnimate { showOther.toggle() } } label: { Text("Other…") }
            .buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
      } else {
        FlowLayout(spacing: 8) {
          ForEach(options, id: \.self) { option in
            Button { choose(option, replyTo: q.seq, step: q.step) } label: {
              Text(option)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(accent)
          }
          Button { a11yAnimate { showOther.toggle() } } label: { Text("Other…") }
            .buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
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

  /// Agent status with the human's stop. Stopped: the backend refuses every
  /// agent write until Resume (ADR 0008).
  @ViewBuilder private var agentRow: some View {
    HStack(spacing: 8) {
      if convo.stoppedAt != nil {
        Label("Agent work stopped", systemImage: "stop.circle")
          .font(.caption).foregroundStyle(.secondary)
        Spacer(minLength: 0)
        Button("Resume") { setStopped(false) }
          .font(.caption).buttonStyle(.borderless)
      } else {
        Label(convo.isClaimed(at: DayClock.appNow) ? "Claude is working…" : "Waiting for Claude",
              systemImage: "ellipsis.bubble")
          .font(.caption).foregroundStyle(.secondary)
        Spacer(minLength: 0)
        Button("Stop", role: .destructive) { setStopped(true) }
          .font(.caption).buttonStyle(.borderless)
      }
    }
  }

  /// Agent finished and asked the human to verify (`needs_verify`, #87).
  @ViewBuilder private var reviewBlock: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 6) {
        Image(systemName: isTaskOpen ? "eye" : "checkmark.seal.fill")
          .font(.septenaCaption)
          .foregroundStyle(isTaskOpen ? Color.yellow : Color.green)
        VStack(alignment: .leading, spacing: 2) {
          Text(isTaskOpen ? "Needs review" : "Accepted")
            .font(.septenaLabel)
          if let note = convo.endStateNote, !note.isEmpty {
            Text(note).font(.septenaMeta).foregroundStyle(.secondary)
          }
        }
      }
      if isTaskOpen {
        HStack(spacing: 8) {
          Button("Accept") { acceptReview() }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
          Button("Send back") { a11yAnimate { showSendBack.toggle() } }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        if showSendBack {
          HStack(spacing: 6) {
            TextField("What needs another pass?", text: $sendBackNote)
              .textFieldStyle(.roundedBorder)
              .onSubmit { submitSendBack() }
            Button("Send") { submitSendBack() }
              .buttonStyle(.borderedProminent)
              .controlSize(.small)
              .disabled(sendBackNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
      }
    }
  }

  @ViewBuilder private var followUpBlock: some View {
    if showReply {
      HStack(spacing: 6) {
        TextField("Reply to thread", text: $replyText)
          .textFieldStyle(.roundedBorder)
          .onSubmit(submitReply)
        Button("Send", action: submitReply)
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    } else {
      Button { a11yAnimate { showReply = true } } label: {
        Label("Reply…", systemImage: "arrowshape.turn.up.left")
          .font(.septenaCaption)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
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
    VStack(alignment: .leading, spacing: 6) {
      Label(a.title, systemImage: a.linkedIssue?.symbolName ?? "doc.text")
        .font(.septenaLabel)
      if !a.body.isEmpty {
        Text(a.body).font(.septenaCaption).foregroundStyle(.primary)
      }
      if let refs = a.refs, !refs.isEmpty {
        ForEach(refs, id: \.self) { ref in
          artifactRefRow(ref)
        }
      } else if let issue = a.linkedIssue {
        issueLinkPill(issue)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(Theme.paperBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
  }

  @ViewBuilder private func artifactRefRow(_ ref: String) -> some View {
    if let issue = ConvoIssueLink.parse(in: ref) {
      issueLinkPill(issue)
    } else if let url = ConvoIssueLink.parseURL(ref) {
      Link(destination: url) {
        Label(ref, systemImage: "arrow.up.right.square")
          .font(.septenaCaption)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    } else {
      Text(ref).font(.septenaMetaMicro).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private func issueLinkPill(_ issue: ConvoIssueLink) -> some View {
    Link(destination: issue.url) {
      HStack(spacing: 5) {
        Image(systemName: issue.symbolName)
        Text("Open \(issue.fullLabel)")
        Image(systemName: "arrow.up.right")
      }
      .font(.septenaLabel)
    }
    .buttonStyle(.bordered)
    .buttonBorderShape(.capsule)
    .controlSize(.small)
    .tint(accent)
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
    let ctx = LocalStore.shared.container.mainContext
    if let task = LocalCache.task(id: taskID, in: ctx) {
      convo = task.conversation
      isTaskOpen = task.status == .open
    } else {
      convo = SeptenaServices.shared.taskMutator.conversation(id: taskID) ?? TaskConvo()
    }
  }

  private func acceptReview() {
    let mutator = SeptenaServices.shared.taskMutator
    let previousNote = convo.endStateNote
    mutator.complete(id: taskID)
    mutator.acknowledge(id: taskID)
    TaskUndo.recordAcceptReview(id: taskID, previousNote: previousNote, mutator: mutator)
    Haptics.tick()
    showSendBack = false
    reload()
  }

  private func submitSendBack() {
    let text = sendBackNote.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    let mutator = SeptenaServices.shared.taskMutator
    let before = convo
    mutator.sendBackConvo(id: taskID, note: text)
    let after = mutator.conversation(id: taskID) ?? before
    TaskUndo.recordSendBack(id: taskID, before: before, after: after, mutator: mutator)
    Haptics.tick()
    sendBackNote = ""
    showSendBack = false
    reload()
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

  private func submitReply() {
    let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    append(ConvoTurn(seq: 0, role: .user, step: .work, note: text, ts: Date()))
    Haptics.tick()
    replyText = ""
    showReply = false
  }

  private func setStopped(_ stopped: Bool) {
    SeptenaServices.shared.taskMutator.setConvoStopped(id: taskID, stopped)
    reload()
  }

  private func append(_ turn: ConvoTurn) {
    SeptenaServices.shared.taskMutator.appendConvoTurn(id: taskID, turn)
    // Answering a card is a user gesture: it stamps the fade clock
    // (docs/TASK_FADE_SPEC.md §3).
    SeptenaServices.shared.taskMutator.touch(id: taskID)
    reload()
  }
}

/// The conversation as a normal section inside the task composer's scroll: the
/// `ConversationCard` once a thread exists (open question promoted to a title
/// over its option pills). The Discuss kickoff lives in the attribute pill rail
/// above — no header chrome and no card box here.
struct ConversationSection: View {
  let task: SeptenaTask
  let accent: Color

  var body: some View {
    ConversationCard(taskID: task.id, initial: task.conversation, isTaskOpen: task.status == .open, accent: accent)
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
          Text("Some tasks need a moment of thinking before you can act. \(AppDisplayName.current) can talk them through with AI, right on the task.")
            .font(.headline)

          VStack(alignment: .leading, spacing: 0) {
            Text("How a task conversation moves")
              .font(.subheadline).fontWeight(.semibold).padding(.bottom, 10)
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
              stepRow(s, isLast: i == steps.count - 1)
            }
            Text("On Automatic, every step runs on your device first. It only escalates for steps the on-device model can’t handle (↗).")
              .font(.caption2).foregroundStyle(.secondary).padding(.top, 6)
          }

          VStack(alignment: .leading, spacing: 6) {
            Text("Whose turn?").font(.subheadline).fontWeight(.semibold)
            legend(.yellow, "Your turn: a question is waiting")
            legend(.blue, "AI’s turn: it’s working")
            legend(.green, "Done")
          }

          VStack(alignment: .leading, spacing: 6) {
            Label("Some help is always on your device", systemImage: "iphone")
              .font(.subheadline).fontWeight(.semibold)
            Text("Beyond conversations, \(AppDisplayName.current) learns small patterns locally, like the “Move to…” suggestion that predicts where a task belongs from your own history. That model trains on your device and never leaves it.")
              .font(.callout).foregroundStyle(.secondary)
          }

          VStack(alignment: .leading, spacing: 6) {
            Label("Your AI, never our servers", systemImage: "lock.fill")
              .font(.subheadline).fontWeight(.semibold)
            Text("\(AppDisplayName.current) never runs AI on your tasks and never reads them. The intelligence is your own (on-device or your Claude), connected by you. Your tasks stay on your device, and sync through Septena’s private server only if you sign in. Turn AI off and the app works the same, minus the conversations.")
              .font(.callout).foregroundStyle(.secondary)
          }
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Theme.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

          Text("Nothing important happens on its own. AI can fill in small, reversible details; any real decision or action that can’t be undone waits for your confirmation.")
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
      Step(icon: "square.and.pencil", title: "Capture", desc: "Jot down the task. A few words are enough.", runs: "You", tint: .gray),
      Step(icon: "questionmark.bubble", title: "Confirm", desc: "AI asks what you mean. Nothing happens until you answer.", runs: "On-device", tint: .green),
      Step(icon: "doc.text.magnifyingglass", title: "Ground", desc: "Pulls relevant context from your own data.", runs: "On-device", tint: .green),
      Step(icon: "checklist", title: "Decide", desc: "Offers a few options for you to pick. A harder call may use the cloud.", runs: "On-device ↗", tint: .blue),
      Step(icon: "hammer", title: "Work", desc: "Does what it can: a draft, a comparison. Uses the web or your Claude only when needed.", runs: "On-device ↗", tint: .blue),
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
