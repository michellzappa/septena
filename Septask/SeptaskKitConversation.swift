#if os(macOS)
import AppKit

// Task Conversations in the AppKit shell — §2 of docs/SEPTASK_APPKIT_PARITY.md,
// following docs/SEPTASK_CONVERSATIONS_PLAN.md.
//
// The SwiftUI reference is `ConversationCard` (Septena/Shell/Tasks/). This is
// the same content in AppKit, not a second interpretation of it: same turn
// filtering, same "the open question IS the title" promotion, same artifact and
// handoff blocks, same `mailto:` / `tel:` mapping.
//
// PRESENTATION ONLY. Reads come from the decoded `TaskConvo` the caller already
// holds; the single write is `appendConvoTurn`, and only ever a USER turn
// (a chosen option or free text). `propose` turns come from the agent/gateway
// and are never authored here.
//
// One surface, not three: this lives in the inspector, where a transcript has
// the vertical room it needs. No conversation tab and no separate window —
// the plan calls a third surface scope creep against "presentation only".
@MainActor
final class KitConversationView: NSView {
  private let stack = NSStackView()
  private let otherField = NSTextField()
  private var taskID: String?
  private var convo = TaskConvo()
  /// The free-text escape hatch is collapsed until asked for, like SwiftUI's
  /// `showOther` — options first, typing second.
  private var showOther = false

  /// Called after a turn is appended, so the host can re-read and redraw.
  var onAppend: (() -> Void)?

  private var mutator: TaskMutator { SeptenaServices.shared.taskMutator }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    otherField.placeholderString = String(localized: "Type your answer",
                                          comment: "SeptaskKit: conversation free-text reply")
    otherField.font = SeptaskKitTheme.taskTitle
    otherField.bezelStyle = .roundedBezel
    otherField.target = self
    otherField.action = #selector(submitOther)
  }

  required init?(coder: NSCoder) { fatalError("KitConversationView is code-only") }

  /// Point this at a task. Returns false when there is nothing worth showing,
  /// so the host can hide the whole section rather than leave an empty header.
  @discardableResult
  func configure(taskID: String, convo: TaskConvo) -> Bool {
    // A different task must not inherit the previous one's half-typed reply.
    if self.taskID != taskID {
      showOther = false
      otherField.stringValue = ""
    }
    self.taskID = taskID
    self.convo = convo
    guard convo.hasStarted else {
      isHidden = true
      return false
    }
    isHidden = false
    rebuild()
    return true
  }

  // MARK: - Building

  /// Plain rebuild on every change. The plan calls animated turn arrival a
  /// non-goal for v1, and a transcript is short enough that a full rebuild is
  /// cheaper to reason about than a diff.
  private func rebuild() {
    for view in stack.arrangedSubviews {
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }

    let open = openQuestion
    // Everything except the current open question, which renders as the title.
    let history = open.map { q in convo.thread.filter { $0.seq != q.seq } } ?? convo.thread
    for turn in history {
      if let row = transcriptRow(turn) { stack.addArrangedSubview(row) }
    }
    if let open { stack.addArrangedSubview(questionBlock(open)) }
    if let meta = metaRow() { stack.addArrangedSubview(meta) }
    if convo.isTerminal { stack.addArrangedSubview(terminalRow()) }
    if let artifact = convo.artifact { stack.addArrangedSubview(artifactBlock(artifact)) }
    if let handoff = convo.handoff { stack.addArrangedSubview(handoffView(handoff)) }

    for view in stack.arrangedSubviews {
      view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
  }

  /// A resolved turn. Provider turns show their question (or their narration,
  /// dimmed); user turns show what was chosen or typed, with a green check —
  /// the same three shapes `ConversationCard.transcriptRow` draws.
  private func transcriptRow(_ turn: ConvoTurn) -> NSView? {
    if turn.role == .provider {
      if let question = turn.question {
        return row(symbol: "bubble.left", tint: SeptaskKitTheme.inkSecondary,
                   text: question, font: SeptaskKitTheme.taskTitle,
                   ink: SeptaskKitTheme.inkPrimary)
      }
      if let note = turn.note {
        return row(symbol: "bubble.left", tint: SeptaskKitTheme.iconMuted,
                   text: note, font: SeptaskKitTheme.meta,
                   ink: SeptaskKitTheme.inkSecondary)
      }
      return nil
    }
    guard let answer = turn.chosen ?? turn.otherText else { return nil }
    return row(symbol: "checkmark.circle.fill", tint: .systemGreen,
               text: answer, font: SeptaskKitTheme.taskTitle,
               ink: SeptaskKitTheme.inkPrimary)
  }

  private func row(symbol: String, tint: NSColor, text: String,
                   font: NSFont, ink: NSColor) -> NSView {
    let glyph = NSImageView()
    glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: SeptenaTypeScale.size(.footnote),
                                     weight: .regular))
    glyph.contentTintColor = tint
    glyph.setContentHuggingPriority(.required, for: .horizontal)
    glyph.kitA11yIgnore()

    let label = NSTextField(wrappingLabelWithString: text)
    label.font = font
    label.textColor = ink
    label.isSelectable = true
    label.drawsBackground = false
    label.isBordered = false

    let line = NSStackView(views: [glyph, label])
    line.orientation = .horizontal
    line.alignment = .firstBaseline
    line.spacing = 6
    line.setAccessibilityElement(true)
    line.setAccessibilityRole(.staticText)
    line.setAccessibilityLabel(text)
    return line
  }

  /// The open question, promoted to a title with its options beneath — the
  /// shape SwiftUI's `questionBlock` uses. Options are `KitPillButton`s
  /// (the shell's existing recessed-capsule language), never a second style.
  private func questionBlock(_ question: ConvoTurn) -> NSView {
    let title = NSTextField(wrappingLabelWithString: question.question ?? "")
    title.font = SeptaskKitTheme.heading
    title.textColor = SeptaskKitTheme.inkPrimary
    title.isSelectable = true

    let options = NSStackView()
    options.orientation = .horizontal
    options.alignment = .centerY
    options.spacing = 6
    for option in question.options ?? [] {
      let pill = KitPillButton()
      pill.title = option
      pill.onPress = { [weak self] _ in
        self?.choose(option, replyTo: question.seq, step: question.step)
      }
      options.addArrangedSubview(pill)
    }
    let other = KitPillButton()
    other.title = String(localized: "Other…",
                         comment: "SeptaskKit: conversation free-text escape hatch")
    other.onPress = { [weak self] _ in self?.toggleOther() }
    options.addArrangedSubview(other)

    let block = NSStackView(views: [title, options])
    block.orientation = .vertical
    block.alignment = .leading
    block.spacing = 8

    if showOther {
      // Return in the field submits; the button is for pointer users.
      let send = NSButton(title: String(localized: "Send",
                                        comment: "SeptaskKit: send a free-text reply"),
                          target: self, action: #selector(submitOther))
      send.bezelStyle = .rounded
      send.keyEquivalent = "\r"
      let replyRow = NSStackView(views: [otherField, send])
      replyRow.orientation = .horizontal
      replyRow.alignment = .centerY
      replyRow.spacing = 6
      otherField.setContentHuggingPriority(.defaultLow, for: .horizontal)
      block.addArrangedSubview(replyRow)
      replyRow.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
    }
    return block
  }

  /// Acceptance (the AGENT-done bar, distinct from the task's own status) and
  /// assignee. READ-ONLY here, per the plan: these are mostly agent-authored,
  /// and a human override is a separate decision from showing what's there.
  /// Nil when neither is set, so an ordinary conversation gains no chrome.
  private func metaRow() -> NSView? {
    var lines: [String] = []
    if let acceptance = convo.acceptance, !acceptance.isEmpty {
      lines.append(String(localized: "Done when: \(acceptance)",
                          comment: "SeptaskKit: conversation acceptance bar"))
    }
    if let assignee = convo.assignee {
      let who = switch assignee {
      case .me: String(localized: "You", comment: "SeptaskKit: conversation assignee")
      case .local: String(localized: "On-device AI", comment: "SeptaskKit: conversation assignee")
      case .claude: String(localized: "Claude", comment: "SeptaskKit: conversation assignee")
      }
      lines.append(String(localized: "Assigned to \(who)",
                          comment: "SeptaskKit: conversation assignee line"))
    }
    guard !lines.isEmpty else { return nil }
    let block = NSStackView()
    block.orientation = .vertical
    block.alignment = .leading
    block.spacing = 2
    for line in lines {
      let label = NSTextField(wrappingLabelWithString: line)
      label.font = SeptaskKitTheme.chip
      label.textColor = SeptaskKitTheme.inkSecondary
      label.isSelectable = true
      block.addArrangedSubview(label)
    }
    return block
  }

  /// The conversation reached a terminal state. `wontDo` reads grey and
  /// neutral rather than red — deciding not to do something is a valid
  /// outcome, not a failure.
  private func terminalRow() -> NSView {
    let wontDo = convo.endState == .wontDo
    let heading = wontDo
      ? String(localized: "Won't do", comment: "SeptaskKit: conversation end state")
      : String(localized: "Resolved", comment: "SeptaskKit: conversation end state")
    let block = NSStackView()
    block.orientation = .vertical
    block.alignment = .leading
    block.spacing = 2
    block.addArrangedSubview(row(symbol: wontDo ? "xmark.circle" : "checkmark.seal.fill",
                                 tint: wontDo ? SeptaskKitTheme.iconMuted : .systemGreen,
                                 text: heading, font: SeptaskKitTheme.taskTitle,
                                 ink: SeptaskKitTheme.inkPrimary))
    if let note = convo.endStateNote, !note.isEmpty {
      let detail = NSTextField(wrappingLabelWithString: note)
      detail.font = SeptaskKitTheme.meta
      detail.textColor = SeptaskKitTheme.inkSecondary
      detail.isSelectable = true
      block.addArrangedSubview(detail)
    }
    return block
  }

  /// What the agent produced. Selectable on purpose — an artifact is usually
  /// meant to be copied out.
  private func artifactBlock(_ artifact: ConvoArtifact) -> NSView {
    let heading = NSTextField(labelWithString: artifact.title)
    heading.font = NSFont.systemFont(ofSize: SeptenaTypeScale.size(.body), weight: .medium)
    heading.textColor = SeptaskKitTheme.inkPrimary
    heading.isSelectable = true

    let body = NSTextField(wrappingLabelWithString: artifact.body)
    body.font = SeptaskKitTheme.meta
    body.textColor = SeptaskKitTheme.inkPrimary
    body.isSelectable = true

    let block = NSStackView(views: [heading, body])
    block.orientation = .vertical
    block.alignment = .leading
    block.spacing = 4
    block.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
    for ref in artifact.refs ?? [] {
      let line = NSTextField(wrappingLabelWithString: ref)
      line.font = SeptaskKitTheme.chip
      line.textColor = SeptaskKitTheme.inkSecondary
      line.isSelectable = true
      block.addArrangedSubview(line)
    }
    block.wantsLayer = true
    block.layer?.cornerRadius = 12
    block.layer?.cornerCurve = .continuous
    block.layer?.backgroundColor = SeptaskKitTheme.chipFill.cgColor
    return block
  }

  /// The human last mile. A real button when there's somewhere to go, plain
  /// text when there isn't — never a button that does nothing.
  private func handoffView(_ handoff: ConvoHandoff) -> NSView {
    guard let url = Self.actionURL(handoff) else {
      return row(symbol: Self.actionSymbol(handoff.actionType),
                 tint: SeptaskKitTheme.inkSecondary,
                 text: handoff.instruction, font: SeptaskKitTheme.taskTitle,
                 ink: SeptaskKitTheme.inkPrimary)
    }
    let button = NSButton(title: handoff.instruction, target: nil, action: nil)
    button.bezelStyle = .rounded
    button.image = NSImage(systemSymbolName: Self.actionSymbol(handoff.actionType),
                           accessibilityDescription: nil)
    button.imagePosition = .imageLeading
    button.alignment = .left
    button.setAccessibilityLabel(handoff.instruction)
    // A local closure would need a stored target; a tiny action shim keeps the
    // button honest without another stored property per handoff.
    button.target = KitHandoffOpener.shared
    button.action = #selector(KitHandoffOpener.open(_:))
    KitHandoffOpener.shared.register(url, for: button)
    return button
  }

  /// Same mapping as `ConversationCard.actionURL` — kept identical so a
  /// handoff behaves the same in both shells.
  static func actionURL(_ handoff: ConvoHandoff) -> URL? {
    guard let payload = handoff.payload, !payload.isEmpty else { return nil }
    switch handoff.actionType {
    case .openURL: return URL(string: payload)
    case .compose: return URL(string: "mailto:\(payload)")
    case .call: return URL(string: "tel:\(payload)")
    case .none: return nil
    }
  }

  static func actionSymbol(_ type: ConvoHandoff.ActionType) -> String {
    switch type {
    case .openURL: return "arrow.up.right.square"
    case .compose: return "envelope"
    case .call: return "phone"
    case .none: return "hand.point.right"
    }
  }

  // MARK: - Derived

  /// The question awaiting an answer, if the last turn is one.
  private var openQuestion: ConvoTurn? {
    guard convo.hasOpenProviderQuestion else { return nil }
    return convo.thread.last
  }

  // MARK: - Actions

  private func toggleOther() {
    showOther.toggle()
    rebuild()
    if showOther { window?.makeFirstResponder(otherField) }
  }

  private func choose(_ label: String, replyTo: Int, step: ConvoTurn.Step) {
    append(ConvoTurn(seq: 0, role: .user, step: step,
                     chosen: label, inReplyTo: replyTo, ts: Date()))
  }

  @objc private func submitOther() {
    guard let open = openQuestion else { return }
    let text = otherField.stringValue.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return }
    otherField.stringValue = ""
    showOther = false
    append(ConvoTurn(seq: 0, role: .user, step: open.step,
                     otherText: text, inReplyTo: open.seq, ts: Date()))
  }

  /// `seq: 0` is deliberate — `appendConvoTurn` assigns the real sequence
  /// (`nextSeq`), so the shell never guesses at ordering.
  private func append(_ turn: ConvoTurn) {
    guard let taskID else { return }
    mutator.appendConvoTurn(id: taskID, turn)
    convo = mutator.conversation(id: taskID) ?? convo
    rebuild()
    onAppend?()
  }
}

/// Opens a handoff's URL. A shared shim so each handoff button doesn't need a
/// stored owner just to carry one URL.
@MainActor
private final class KitHandoffOpener: NSObject {
  static let shared = KitHandoffOpener()
  private var urls: [ObjectIdentifier: URL] = [:]

  func register(_ url: URL, for button: NSButton) {
    urls[ObjectIdentifier(button)] = url
  }

  @objc func open(_ sender: NSButton) {
    guard let url = urls[ObjectIdentifier(sender)] else { return }
    NSWorkspace.shared.open(url)
  }
}
#endif
