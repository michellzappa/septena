#if os(macOS)
import AppKit

// Review stage rows and Send-back popover for the AppKit shell (#87).
//
// Lists `needs_verify` tasks inside the standard `KitCardRowView` card run:
// each row shows the task title, what Claude asked the user to check
// (`endStateNote`), and two direct actions — Accept (completes the task) and
// Send back (opens a Tier 1 `KitPopover` to append a user turn with a note
// and reopen the conversation for Claude).

@MainActor
final class KitReviewTaskCell: NSTableCellView {
  private let titleLabel = NSTextField(labelWithString: "")
  private let noteLabel = NSTextField(wrappingLabelWithString: "")
  private let metaLabel = NSTextField(labelWithString: "")
  private let acceptButton = NSButton()
  private let sendBackButton = NSButton()
  private let buttons = NSStackView()
  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!
  private var taskId: String = ""

  var onAccept: ((String) -> Void)?
  var onSendBack: ((String, NSView) -> Void)?

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    titleLabel.font = SeptaskKitTheme.taskTitle
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    noteLabel.font = SeptaskKitTheme.meta
    noteLabel.textColor = SeptaskKitTheme.inkSecondary
    noteLabel.maximumNumberOfLines = 3
    noteLabel.lineBreakMode = .byTruncatingTail
    noteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    metaLabel.font = SeptaskKitTheme.chip
    metaLabel.textColor = SeptaskKitTheme.inkSecondary
    metaLabel.lineBreakMode = .byTruncatingTail
    metaLabel.isHidden = true
    metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let textStack = NSStackView(views: [titleLabel, noteLabel, metaLabel])
    textStack.orientation = .vertical
    textStack.alignment = .leading
    textStack.spacing = 3
    textStack.translatesAutoresizingMaskIntoConstraints = false
    textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

    acceptButton.title = RegistryActions.title("task.acceptReview")
    acceptButton.bezelStyle = .rounded
    acceptButton.controlSize = .small
    acceptButton.target = self
    acceptButton.action = #selector(acceptTapped)
    // Space in a selected row must never trigger a row button (CLAUDE.md).
    acceptButton.refusesFirstResponder = true

    sendBackButton.title = String(localized: "Send back", comment: "SeptaskKit: send back review task")
    sendBackButton.bezelStyle = .rounded
    sendBackButton.controlSize = .small
    sendBackButton.target = self
    sendBackButton.action = #selector(sendBackTapped)
    sendBackButton.refusesFirstResponder = true

    buttons.setViews([sendBackButton, acceptButton], in: .leading)
    buttons.orientation = .horizontal
    buttons.alignment = .centerY
    buttons.spacing = 6
    buttons.translatesAutoresizingMaskIntoConstraints = false
    buttons.setContentHuggingPriority(.required, for: .horizontal)
    buttons.setContentCompressionResistancePriority(.required, for: .horizontal)

    addSubview(textStack)
    addSubview(buttons)

    // Actions sit on their own row under the text, so a long title or note
    // never fights the buttons for width.
    leadingConstraint = textStack.leadingAnchor.constraint(
      equalTo: leadingAnchor,
      constant: KitCardRowView.horizontalInset + SeptaskKitLayout.rowLeadingPad)
    trailingConstraint = textStack.trailingAnchor.constraint(
      equalTo: trailingAnchor,
      constant: -(KitCardRowView.horizontalInset + 10))

    NSLayoutConstraint.activate([
      leadingConstraint,
      trailingConstraint,
      textStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),

      buttons.leadingAnchor.constraint(equalTo: textStack.leadingAnchor),
      buttons.topAnchor.constraint(equalTo: textStack.bottomAnchor, constant: Self.buttonGap),
      buttons.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
      buttons.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
    ])
  }

  required init?(coder: NSCoder) { fatalError("KitReviewTaskCell is code-only") }

  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + SeptaskKitLayout.rowLeadingPad
    trailingConstraint.constant = -(inset + 10)
    super.layout()
  }

  func configure(with task: SeptenaTask, contextText: String?) {
    taskId = task.id
    let composed = NSMutableAttributedString(
      string: task.title,
      attributes: [
        .font: SeptaskKitTheme.taskTitle,
        .foregroundColor: NSColor.labelColor,
      ])
    if let contextText, !contextText.isEmpty {
      composed.append(NSAttributedString(
        string: "  " + contextText,
        attributes: [
          .font: SeptaskKitTheme.meta,
          .foregroundColor: SeptaskKitTheme.inkSecondary,
        ]))
    }
    titleLabel.attributedStringValue = composed

    let checkNote = Self.noteText(for: task)
    noteLabel.stringValue = checkNote

    if let meta = Self.metaSummary(for: task) {
      metaLabel.stringValue = meta
      metaLabel.isHidden = false
    } else {
      metaLabel.stringValue = ""
      metaLabel.isHidden = true
    }

    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("\(task.title). \(checkNote)")
  }

  override func accessibilityChildren() -> [Any]? {
    [sendBackButton, acceptButton]
  }

  @objc private func acceptTapped() {
    onAccept?(taskId)
  }

  @objc private func sendBackTapped() {
    onSendBack?(taskId, sendBackButton)
  }

  static func noteText(for task: SeptenaTask) -> String {
    if let note = task.conversation.endStateNote?.trimmingCharacters(in: .whitespacesAndNewlines),
       !note.isEmpty {
      return note
    }
    return String(localized: "Ready for review", comment: "SeptaskKit: fallback review note")
  }

  static func metaSummary(for task: SeptenaTask) -> String? {
    if let artifact = task.conversation.artifact, !artifact.title.isEmpty {
      return artifact.title
    }
    return nil
  }

  private static let buttonGap: CGFloat = 8
  private static let buttonRowHeight: CGFloat = 22

  static func height(for task: SeptenaTask, width: CGFloat) -> CGFloat {
    let inset = SeptaskKitLayout.inset(for: max(width, 360))
    let textWidth = max(140, width - inset * 2 - SeptaskKitLayout.rowLeadingPad - 10)
    let note = noteText(for: task) as NSString
    let noteRect = note.boundingRect(
      with: NSSize(width: textWidth, height: 60),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: SeptaskKitTheme.meta])
    let titleHeight = ceil(SeptaskKitTheme.taskTitle.ascender - SeptaskKitTheme.taskTitle.descender) + 2
    let noteHeight = min(ceil(noteRect.height) + 2, ceil(SeptaskKitTheme.meta.pointSize * 1.4 * 3))
    let metaHeight: CGFloat = metaSummary(for: task) == nil
      ? 0
      : 3 + ceil(SeptaskKitTheme.chip.ascender - SeptaskKitTheme.chip.descender) + 2
    return 10 + titleHeight + 3 + noteHeight + metaHeight + buttonGap + buttonRowHeight + 10
  }
}

/// Tier 1 anchored popover for typing a "Send back" note from the Review list.
@MainActor
final class KitSendBackPopover {
  private let field = NSTextField()
  private let handle = KitPopoverHandle()
  private let onSend: (String) -> Void

  init(onSend: @escaping (String) -> Void) {
    self.onSend = onSend
  }

  @discardableResult
  static func present(relativeTo view: NSView,
                      onSend: @escaping (String) -> Void,
                      onClose: (() -> Void)? = nil) -> KitSendBackPopover {
    let presenter = KitSendBackPopover(onSend: onSend)
    presenter.show(relativeTo: view, onClose: onClose)
    return presenter
  }

  private func show(relativeTo anchor: NSView, onClose: (() -> Void)?) {
    let heading = NSTextField(labelWithString: String(
      localized: "Send back for another pass",
      comment: "SeptaskKit: send-back popover heading"))
    heading.font = SeptaskKitTheme.chip
    heading.textColor = SeptaskKitTheme.inkSecondary

    field.placeholderString = String(
      localized: "What needs another pass?",
      comment: "SeptaskKit: send-back note placeholder")
    field.font = SeptaskKitTheme.taskTitle
    field.bezelStyle = .roundedBezel
    field.target = self
    field.action = #selector(submit)
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let send = NSButton(
      title: String(localized: "Send", comment: "SeptaskKit: submit send-back note"),
      target: self, action: #selector(submit))
    send.bezelStyle = .rounded
    send.controlSize = .small
    send.keyEquivalent = "\r"

    let row = NSStackView(views: [field, send])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 6

    let stack = NSStackView(views: [heading, row])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true

    KitPopover.present(stack,
                       size: NSSize(width: 310, height: 80),
                       relativeTo: anchor.bounds,
                       of: anchor,
                       preferredEdge: .maxY,
                       focus: field,
                       handle: handle,
                       onClose: onClose)
  }

  @objc private func submit() {
    let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    onSend(text)
    handle.close()
  }
}
#endif
