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

  @State private var convo = TaskConvo()
  @State private var showOther = false
  @State private var otherText = ""

  var body: some View {
    Group {
      if convo.hasStarted {
        VStack(alignment: .leading, spacing: 10) {
          Label("Conversation", systemImage: "bubble.left.and.bubble.right")
            .font(.caption).foregroundStyle(.secondary)

          // Persistent transcript — never collapses after an exchange.
          ForEach(convo.thread, id: \.seq) { transcriptRow($0) }

          // Agent deliverable (agent_assisted) — what Claude produced.
          if let artifact = convo.artifact { artifactBlock(artifact) }

          if let q = openQuestion {
            optionButtons(for: q)
          } else if let handoff = convo.handoff {
            handoffButton(handoff)            // human last-mile — show even when the agent's side is done
          } else if convo.isTerminal {
            terminalRow
          } else {
            Label("Claude is working…", systemImage: "circle.dotted")
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
        .padding(14)
        .background(Theme.secondaryGroupedBackground,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      }
    }
    .onAppear(perform: reload)
    .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in reload() }
  }

  // MARK: Transcript

  @ViewBuilder private func transcriptRow(_ t: ConvoTurn) -> some View {
    if t.role == .provider {
      if let q = t.question {
        row(icon: "sparkles", tint: .purple, text: q, font: .subheadline)
      } else if let note = t.note {
        row(icon: "sparkles", tint: .secondary, text: note, font: .caption, dim: true)
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

  // MARK: Open question

  @ViewBuilder private func optionButtons(for q: ConvoTurn) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(q.options ?? [], id: \.self) { option in
        Button { choose(option, replyTo: q.seq, step: q.step) } label: {
          Text(option).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
      }
      Button { withAnimation { showOther.toggle() } } label: {
        Label("Other…", systemImage: "square.and.pencil")
      }
      .buttonStyle(.borderless).font(.caption)

      if showOther {
        HStack {
          TextField("Type your answer", text: $otherText)
            .textFieldStyle(.roundedBorder)
            .onSubmit { submitOther(replyTo: q.seq, step: q.step) }
          Button("Send") { submitOther(replyTo: q.seq, step: q.step) }
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

/// Plain ball-in-court indicator for a task row's trailing slot — 🟡/🔵/✅/⚫.
/// Reads the convo by id on appear (only visible rows fetch) and refreshes on
/// `.septenaTasksChanged`. Renders nothing without a conversation. The exchange
/// itself opens with the task (in the composer) — this is just the signal.
struct ConvoBadgeView: View {
  let taskID: String
  @State private var badge: ConvoBadge?

  var body: some View {
    Group {
      if let badge { glyph(badge) }
    }
    .onAppear(perform: load)
    .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in load() }
  }

  private func load() {
    guard let convo = SeptenaServices.shared.taskMutator.conversation(id: taskID),
          convo.hasStarted else { badge = nil; return }
    badge = deriveConvo(convo).badge
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
