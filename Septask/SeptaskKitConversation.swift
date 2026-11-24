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
  /// The one free-text field of the agent prompt ("Tell the agent instead",
  /// docs/AGENT_PROMPT_SPEC.md). Only one prompt can hold it at a time, so
  /// one box serves the open question's Other… and the review's Send back.
  private let replyBox = KitPromptReplyBox()
  private var taskID: String?
  private var convo = TaskConvo()
  private var isTaskOpen = true

  /// Which prompt's free-text choice is open. Collapsed until asked for —
  /// choices first, typing second.
  enum ReplyMode: Equatable { case none, other, sendBack }
  private var replyMode: ReplyMode = .none
  /// Half-typed replies by task id, so the draft stays while the user looks
  /// at another task in this session (docs/AGENT_PROMPT_SPEC.md part 4).
  private static var drafts: [String: (mode: ReplyMode, text: String)] = [:]

  /// Called after a turn is appended, so the host can re-read and redraw.
  var onAppend: (() -> Void)?
  /// Called when a reply is sent or cancelled, so the host can hand the
  /// keyboard back (the inspector gives it to the list).
  var onEndReply: (() -> Void)?

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

    replyBox.translatesAutoresizingMaskIntoConstraints = false
    replyBox.onSend = { [weak self] text in self?.submitReply(text) }
    replyBox.onCancel = { [weak self] in self?.cancelReply() }
  }

  required init?(coder: NSCoder) { fatalError("KitConversationView is code-only") }

  /// Point this at a task. Returns false when there is nothing worth showing,
  /// so the host can hide the whole section rather than leave an empty header.
  @discardableResult
  func configure(taskID: String, convo: TaskConvo, isTaskOpen: Bool = true) -> Bool {
    let sameTask = self.taskID == taskID
    // A different task must not inherit the previous one's half-typed reply;
    // it keeps its own draft instead.
    if !sameTask {
      stashDraft()
      if let draft = Self.drafts[taskID] {
        replyMode = draft.mode
        replyBox.text = draft.text
      } else {
        replyMode = .none
        replyBox.text = ""
      }
    }
    self.taskID = taskID
    self.convo = convo
    self.isTaskOpen = isTaskOpen
    guard convo.hasStarted else {
      isHidden = true
      return false
    }
    isHidden = false
    // A refresh of the SAME task while the reply field is being typed in
    // must not rebuild: `rebuild()` pulls the field out of the view tree,
    // which ends the edit and drops the keyboard mid-sentence. The new turns
    // land on the next refresh after the reply is sent or abandoned.
    if sameTask, isEditingReply { return true }
    rebuild()
    return true
  }

  /// The free-text reply field holds the keyboard.
  var isEditingReply: Bool {
    window?.firstResponder === replyBox.textView
  }

  /// Open the review's Send back field and give it the keyboard — how Send
  /// back on a Review row lands here. No-op when the task is not in Review.
  func openSendBack() {
    guard convo.needsHumanReview, isTaskOpen, !isHidden else { return }
    if replyMode != .sendBack {
      replyMode = .sendBack
      rebuild()
    }
    focusReply()
  }

  /// ⌘↩ while the reply field holds the keyboard sends it. The window asks
  /// (through the inspector) before any view's key equivalents run.
  func handleCommandReturn() -> Bool {
    guard isEditingReply else { return false }
    // Deferred a tick: the send's synchronous mutator notification must not
    // re-enter the responder chain while this key event is on the stack.
    DispatchQueue.main.async { [weak self] in self?.replyBox.submit() }
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
    if convo.needsHumanReview || (convo.endState == .agentAssistedDone && !isTaskOpen) {
      stack.addArrangedSubview(reviewBlock())
    } else if convo.isTerminal {
      stack.addArrangedSubview(terminalRow())
    }
    if let agent = agentRow() { stack.addArrangedSubview(agent) }
    if let artifact = convo.artifact { stack.addArrangedSubview(artifactBlock(artifact)) }
    if convo.artifact?.linkedIssue == nil, let issue = convo.linkedIssue {
      stack.addArrangedSubview(issueLinkButton(issue))
    }
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
    guard let answer = turn.chosen ?? turn.otherText ?? turn.note else { return nil }
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

  /// The open question as an agent prompt: kicker, the question, each
  /// option as a full-width choice, then Other… (docs/AGENT_PROMPT_SPEC.md).
  private func questionBlock(_ question: ConvoTurn) -> NSView {
    let choices = (question.options ?? []).map { option in
      KitPromptChoiceButton(title: option) { [weak self] in
        self?.choose(option, replyTo: question.seq, step: question.step)
      }
    }
    return promptBlock(
      kicker: RegistrySurfaces.agentPromptAskKicker,
      question: question.question ?? "",
      choices: choices,
      freeText: .other)
  }

  /// One agent prompt, top to bottom: kicker (small, secondary ink, no
  /// icon), the question (primary ink, wrapping, never truncated), the
  /// choices as a vertical list of full-width buttons, and last the free
  /// text choice, which turns in place into the multi-line reply field.
  private func promptBlock(kicker: String, question: String,
                           choices: [NSButton], freeText mode: ReplyMode) -> NSView {
    let block = NSStackView()
    block.orientation = .vertical
    block.alignment = .leading
    block.spacing = 6

    let kickerLabel = NSTextField(wrappingLabelWithString: kicker)
    kickerLabel.font = SeptaskKitTheme.meta
    kickerLabel.textColor = SeptaskKitTheme.inkSecondary
    block.addArrangedSubview(kickerLabel)
    block.setCustomSpacing(4, after: kickerLabel)

    let questionLabel = NSTextField(wrappingLabelWithString: question)
    questionLabel.font = SeptaskKitTheme.taskTitle
    questionLabel.textColor = SeptaskKitTheme.inkPrimary
    questionLabel.isSelectable = true
    block.addArrangedSubview(questionLabel)
    block.setCustomSpacing(10, after: questionLabel)

    for choice in choices { block.addArrangedSubview(choice) }

    let prompt = Self.textPrompt(for: mode)
    if replyMode == mode {
      replyBox.configure(prompt)
      block.addArrangedSubview(replyBox)
    } else {
      let title = mode == .sendBack ? RegistryActions.title("task.sendBackReview") : prompt.title
      block.addArrangedSubview(KitPromptChoiceButton(title: title) { [weak self] in
        self?.openReply(mode)
      })
    }

    for view in block.arrangedSubviews {
      view.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
    }
    return block
  }

  /// The registry copy for a free-text choice (`surfaces.json`
  /// `prompts.text`).
  private static func textPrompt(for mode: ReplyMode) -> RegistryTextPrompt {
    let id = mode == .sendBack ? "sendBackReview" : "conversationOther"
    return RegistryPrompts.text[id]
      ?? RegistryTextPrompt(id: id, title: "", placeholder: "", confirmTitle: RegistryPrompts.errorConfirmTitle)
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
      case .me: RegistrySurfaces.provenanceSelfLabel
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

  /// Agent status with the human's stop, while the agent owes the next move
  /// (Claude assigned, no open question, not terminal). Stopped: the backend
  /// refuses every agent write until Resume (ADR 0008).
  private func agentRow() -> NSView? {
    let stopped = convo.stoppedAt != nil
    guard !convo.isTerminal, openQuestion == nil, stopped || convo.assignee == .claude else { return nil }
    let text = stopped
      ? String(localized: "Agent work stopped", comment: "SeptaskKit: the user stopped agent work on a task")
      : convo.isClaimed(at: DayClock.appNow)
        ? String(localized: "Your agent is working…", comment: "SeptaskKit: an agent holds the task")
        : String(localized: "Waiting for your agent", comment: "SeptaskKit: assigned to an agent, not picked up yet")
    let label = NSTextField(labelWithString: text)
    label.font = SeptaskKitTheme.chip
    label.textColor = SeptaskKitTheme.inkSecondary
    let title = stopped
      ? RegistryActions.title("task.conversation.stop", .active)
      : RegistryActions.title("task.conversation.stop")
    let button = NSButton(title: title, target: self, action: #selector(toggleStopped))
    button.bezelStyle = .rounded
    button.controlSize = .small
    let row = NSStackView(views: [label, button])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    return row
  }

  /// Agent finished and asked the human to verify (`needs_verify`, #87).
  /// Open: the agent prompt with Accept (marks the task done) and Send back
  /// (appends a user turn with a note and reopens the conversation for the
  /// agent). Accepted: one quiet line.
  private func reviewBlock() -> NSView {
    let note = convo.endStateNote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard isTaskOpen else {
      let block = NSStackView()
      block.orientation = .vertical
      block.alignment = .leading
      block.spacing = 2
      block.addArrangedSubview(row(symbol: "checkmark.seal.fill", tint: .systemGreen,
                                   text: RegistrySurfaces.agentPromptAcceptedLabel,
                                   font: SeptaskKitTheme.taskTitle,
                                   ink: SeptaskKitTheme.inkPrimary))
      if !note.isEmpty {
        let detail = NSTextField(wrappingLabelWithString: note)
        detail.font = SeptaskKitTheme.meta
        detail.textColor = SeptaskKitTheme.inkSecondary
        detail.isSelectable = true
        block.addArrangedSubview(detail)
      }
      return block
    }

    let kicker = convo.reviewKicker(now: DayClock.appNow)
    let question = note.isEmpty
      ? RegistrySurfaces.agentPromptReviewFallback
      : note
    let accept = KitPromptChoiceButton(title: RegistryActions.title("task.acceptReview"),
                                       primary: true) { [weak self] in
      self?.acceptReview()
    }
    // Accept first, Send back second: the same order on every surface.
    return promptBlock(kicker: kicker, question: question, choices: [accept], freeText: .sendBack)
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
  /// meant to be copied out. URL refs (especially GitHub issues/PRs) render as
  /// clickable buttons so the user can jump straight to the issue.
  private func artifactBlock(_ artifact: ConvoArtifact) -> NSView {
    let heading = NSTextField(labelWithString: artifact.title)
    heading.font = NSFont.systemFont(ofSize: SeptenaTypeScale.size(.body), weight: .medium)
    heading.textColor = SeptaskKitTheme.inkPrimary
    heading.isSelectable = true

    let block = NSStackView(views: [heading])
    block.orientation = .vertical
    block.alignment = .leading
    block.spacing = 6
    block.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
    if !artifact.body.isEmpty {
      let body = NSTextField(wrappingLabelWithString: artifact.body)
      body.font = SeptaskKitTheme.meta
      body.textColor = SeptaskKitTheme.inkPrimary
      body.isSelectable = true
      block.addArrangedSubview(body)
    }
    if let refs = artifact.refs, !refs.isEmpty {
      for ref in refs {
        if let issue = ConvoIssueLink.parse(in: ref) {
          block.addArrangedSubview(issueLinkButton(issue))
        } else if let url = ConvoIssueLink.parseURL(ref) {
          block.addArrangedSubview(urlLinkButton(title: ref, symbol: "arrow.up.right.square", url: url))
        } else {
          let line = NSTextField(wrappingLabelWithString: ref)
          line.font = SeptaskKitTheme.chip
          line.textColor = SeptaskKitTheme.inkSecondary
          line.isSelectable = true
          block.addArrangedSubview(line)
        }
      }
    } else if let issue = artifact.linkedIssue {
      block.addArrangedSubview(issueLinkButton(issue))
    }
    block.wantsLayer = true
    block.layer?.cornerRadius = 12
    block.layer?.cornerCurve = .continuous
    block.layer?.backgroundColor = SeptaskKitTheme.chipFill.cgColor
    return block
  }

  private func issueLinkButton(_ issue: ConvoIssueLink) -> NSButton {
    let title = String(localized: "Open \(issue.fullLabel)",
                       comment: "SeptaskKit: open linked GitHub issue or pull request")
    let button = urlLinkButton(title: title, symbol: issue.symbolName, url: issue.url)
    button.toolTip = issue.url.absoluteString
    return button
  }

  private func urlLinkButton(title: String, symbol: String, url: URL) -> NSButton {
    let button = NSButton(title: title, target: nil, action: nil)
    button.bezelStyle = .rounded
    button.controlSize = .small
    button.refusesFirstResponder = true
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    button.imagePosition = .imageLeading
    button.alignment = .left
    button.setAccessibilityLabel(title)
    button.target = KitHandoffOpener.shared
    button.action = #selector(KitHandoffOpener.open(_:))
    KitHandoffOpener.shared.register(url, for: button)
    return button
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

  private func openReply(_ mode: ReplyMode) {
    replyMode = mode
    rebuild()
    focusReply()
  }

  /// The field takes the keyboard and scrolls into view once laid out.
  private func focusReply() {
    window?.makeFirstResponder(replyBox.textView)
    DispatchQueue.main.async { [weak self] in
      guard let self, self.replyBox.superview != nil else { return }
      self.replyBox.scrollToVisible(self.replyBox.bounds)
    }
  }

  private func cancelReply() {
    closeReply()
    rebuild()
  }

  /// Clear the field and its draft, and hand the keyboard back first: the
  /// rebuild that follows pulls the field out of the view tree.
  private func closeReply() {
    replyMode = .none
    replyBox.text = ""
    if let taskID { Self.drafts[taskID] = nil }
    onEndReply?()
  }

  /// Keep the shown task's half-typed reply before another task replaces it.
  private func stashDraft() {
    guard let taskID else { return }
    let text = replyBox.text
    if replyMode != .none, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      Self.drafts[taskID] = (replyMode, text)
    } else {
      Self.drafts[taskID] = nil
    }
  }

  private func submitReply(_ text: String) {
    switch replyMode {
    case .other: submitOther(text)
    case .sendBack: submitSendBack(text)
    case .none: break
    }
  }

  private func choose(_ label: String, replyTo: Int, step: ConvoTurn.Step) {
    append(ConvoTurn(seq: 0, role: .user, step: step,
                     chosen: label, inReplyTo: replyTo, ts: Date()))
  }

  private func submitOther(_ text: String) {
    guard let open = openQuestion else { return }
    closeReply()
    append(ConvoTurn(seq: 0, role: .user, step: open.step,
                     otherText: text, inReplyTo: open.seq, ts: Date()))
  }

  @objc private func toggleStopped() {
    guard let taskID else { return }
    mutator.setConvoStopped(id: taskID, convo.stoppedAt == nil)
    convo = mutator.conversation(id: taskID) ?? convo
    rebuild()
  }

  private func acceptReview() {
    guard let taskID else { return }
    let previousNote = convo.endStateNote
    mutator.complete(id: taskID)
    mutator.acknowledge(id: taskID)
    TaskUndo.recordAcceptReview(id: taskID, previousNote: previousNote, mutator: mutator)
    convo = mutator.conversation(id: taskID) ?? convo
    isTaskOpen = false
    if replyMode == .sendBack {
      replyMode = .none
      replyBox.text = ""
      Self.drafts[taskID] = nil
    }
    rebuild()
    onAppend?()
  }

  private func submitSendBack(_ text: String) {
    guard let taskID else { return }
    closeReply()
    let before = convo
    mutator.sendBackConvo(id: taskID, note: text)
    let after = mutator.conversation(id: taskID) ?? before
    TaskUndo.recordSendBack(id: taskID, before: before, after: after, mutator: mutator)
    convo = after
    rebuild()
    onAppend?()
  }

  /// `seq: 0` is deliberate — `appendConvoTurn` assigns the real sequence
  /// (`nextSeq`), so the shell never guesses at ordering.
  private func append(_ turn: ConvoTurn) {
    guard let taskID else { return }
    mutator.appendConvoTurn(id: taskID, turn)
    // Answering a card is a user gesture: it stamps the fade clock
    // (docs/TASK_FADE_SPEC.md §3).
    mutator.touch(id: taskID)
    convo = mutator.conversation(id: taskID) ?? convo
    rebuild()
    onAppend?()
  }
}

/// One choice of an agent prompt: a full-width push button with a closure.
/// At most one per prompt is primary — the accent bezel, never a Return key
/// equivalent, which would answer Return anywhere in the window.
@MainActor
final class KitPromptChoiceButton: NSButton {
  private let onPress: () -> Void

  init(title: String, primary: Bool = false, onPress: @escaping () -> Void) {
    self.onPress = onPress
    super.init(frame: .zero)
    self.title = title
    bezelStyle = .rounded
    controlSize = .small
    if primary { bezelColor = .controlAccentColor }
    // Keyboard focus stays with the list and the fields (CLAUDE.md: Space
    // must never fire a button in a selected row).
    refusesFirstResponder = true
    setContentHuggingPriority(.defaultLow, for: .horizontal)
    target = self
    action = #selector(pressed)
  }

  required init?(coder: NSCoder) { fatalError("KitPromptChoiceButton is code-only") }

  @objc private func pressed() { onPress() }
}

/// "Tell the agent instead": a multi-line wrapping field that grows to about
/// six lines, with Cancel and a primary send button under it. Copy comes from
/// a registry text prompt. ⌘↩ sends (through the window, see
/// `KitConversationView.handleCommandReturn`, and here as a fallback); Escape
/// cancels; Return types a new line.
@MainActor
final class KitPromptReplyBox: NSView, NSTextViewDelegate {
  let textView: NSTextView
  private let scroll: NSScrollView
  private let placeholder = KitPassThroughLabel(labelWithString: "")
  private let sendButton = NSButton()
  private let cancelButton = NSButton()
  private var scrollHeight: NSLayoutConstraint!
  private static let maxLines: CGFloat = 6
  private static let minLines: CGFloat = 2

  var onSend: ((String) -> Void)?
  var onCancel: (() -> Void)?

  override init(frame frameRect: NSRect) {
    scroll = NSTextView.scrollableTextView()
    // swiftlint:disable:next force_cast
    textView = scroll.documentView as! NSTextView
    super.init(frame: frameRect)

    scroll.borderType = .bezelBorder
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.translatesAutoresizingMaskIntoConstraints = false

    textView.font = SeptaskKitTheme.taskTitle
    textView.textColor = SeptaskKitTheme.inkPrimary
    textView.isRichText = false
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.textContainerInset = NSSize(width: 2, height: 5)
    textView.delegate = self

    placeholder.font = SeptaskKitTheme.taskTitle
    placeholder.textColor = .placeholderTextColor
    placeholder.lineBreakMode = .byTruncatingTail
    placeholder.translatesAutoresizingMaskIntoConstraints = false
    placeholder.kitA11yIgnore()

    cancelButton.bezelStyle = .rounded
    cancelButton.controlSize = .small
    cancelButton.refusesFirstResponder = true
    cancelButton.target = self
    cancelButton.action = #selector(cancelPressed)
    sendButton.bezelStyle = .rounded
    sendButton.controlSize = .small
    sendButton.bezelColor = .controlAccentColor
    sendButton.refusesFirstResponder = true
    sendButton.target = self
    sendButton.action = #selector(sendPressed)

    let actions = NSStackView()
    actions.setViews([cancelButton, sendButton], in: .trailing)
    actions.orientation = .horizontal
    actions.spacing = 6
    actions.translatesAutoresizingMaskIntoConstraints = false

    addSubview(scroll)
    addSubview(placeholder)
    addSubview(actions)
    scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 44)
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: topAnchor),
      scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollHeight,
      placeholder.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 6),
      placeholder.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 8),
      placeholder.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor, constant: -8),
      actions.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
      actions.leadingAnchor.constraint(equalTo: leadingAnchor),
      actions.trailingAnchor.constraint(equalTo: trailingAnchor),
      actions.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    refreshState()
  }

  required init?(coder: NSCoder) { fatalError("KitPromptReplyBox is code-only") }

  var text: String {
    get { textView.string }
    set {
      textView.string = newValue
      refreshState()
    }
  }

  func configure(_ prompt: RegistryTextPrompt) {
    placeholder.stringValue = prompt.placeholder
    sendButton.title = prompt.confirmTitle
    cancelButton.title = RegistryPrompts.cancelTitle
    textView.setAccessibilityLabel(prompt.title)
    textView.setAccessibilityPlaceholderValue(prompt.placeholder)
  }

  /// Send the trimmed text. Empty does nothing.
  func submit() {
    let trimmed = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    onSend?(trimmed)
  }

  @objc private func sendPressed() { submit() }
  @objc private func cancelPressed() { onCancel?() }

  override func layout() {
    super.layout()
    // The wrap width changes with the pane; the height follows it.
    updateHeight()
  }

  /// Grow with the text from two lines to six, then scroll.
  private func updateHeight() {
    guard let layoutManager = textView.layoutManager,
          let container = textView.textContainer else { return }
    layoutManager.ensureLayout(for: container)
    let used = layoutManager.usedRect(for: container).height
    let line = layoutManager.defaultLineHeight(for: SeptaskKitTheme.taskTitle)
    let chrome = textView.textContainerInset.height * 2 + 2
    let height = ceil(min(max(used, line * Self.minLines), line * Self.maxLines) + chrome)
    if abs(scrollHeight.constant - height) > 0.5 {
      scrollHeight.constant = height
    }
  }

  private func refreshState() {
    placeholder.isHidden = !textView.string.isEmpty
    sendButton.isEnabled = !textView.string
      .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    updateHeight()
  }

  func textDidChange(_ notification: Notification) { refreshState() }

  func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    switch commandSelector {
    case #selector(NSResponder.cancelOperation(_:)):
      // Deferred: cancelling pulls this view out of the tree.
      DispatchQueue.main.async { [weak self] in self?.onCancel?() }
      return true
    case #selector(NSResponder.insertNewline(_:)), NSSelectorFromString("noop:"):
      // Plain Return types a new line. ⌘↩ normally never gets here (the
      // window routes it first); this covers a host window that does not.
      guard NSApp.currentEvent?.modifierFlags.contains(.command) == true else { return false }
      DispatchQueue.main.async { [weak self] in self?.submit() }
      return true
    default:
      return false
    }
  }
}

/// A placeholder label that lets clicks through to the field under it.
private final class KitPassThroughLabel: NSTextField {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
