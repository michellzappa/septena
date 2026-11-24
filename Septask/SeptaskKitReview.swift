#if os(macOS)
import AppKit
import SwiftData

// Review stage rows for the AppKit shell (#87, docs/AGENT_PROMPT_SPEC.md).
//
// Lists `needs_verify` tasks inside the standard `KitCardRowView` card run:
// each row shows the task title, what the agent asked the user to check
// (`endStateNote`), the list and "asked {ago}", then two direct actions —
// Accept (completes the task) and Send back. Send back does not open a field
// in the row: the list opens the inspector with the Send back field open and
// focused (the agent prompt in `KitConversationView`).

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
  var onSendBack: ((String) -> Void)?

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    titleLabel.font = SeptaskKitTheme.taskTitle
    titleLabel.textColor = .labelColor
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    noteLabel.font = SeptaskKitTheme.meta
    noteLabel.textColor = SeptaskKitTheme.inkSecondary
    // The review question shows in full, never truncated.
    noteLabel.maximumNumberOfLines = 0
    noteLabel.lineBreakMode = .byWordWrapping
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
    // Primary look without a Return key equivalent: a default button would
    // answer Return anywhere in the window, list included.
    acceptButton.bezelColor = .controlAccentColor
    acceptButton.target = self
    acceptButton.action = #selector(acceptTapped)
    // Space in a selected row must never trigger a row button (CLAUDE.md).
    acceptButton.refusesFirstResponder = true

    sendBackButton.title = RegistryActions.title("task.sendBackReview")
    sendBackButton.bezelStyle = .rounded
    sendBackButton.controlSize = .small
    sendBackButton.target = self
    sendBackButton.action = #selector(sendBackTapped)
    sendBackButton.refusesFirstResponder = true

    // Accept first, Send back second: the same order on every surface
    // (docs/AGENT_PROMPT_SPEC.md).
    buttons.setViews([acceptButton, sendBackButton], in: .leading)
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
    // A wrapping label needs its width to report a multi-line height.
    noteLabel.preferredMaxLayoutWidth = max(140, bounds.width - inset * 2 - SeptaskKitLayout.rowLeadingPad - 10)
    super.layout()
  }

  /// `contextText` is the list the task is in ("Area › Project",
  /// `KitListPath`), shown on the meta line with "asked {ago}". `issue` is the
  /// task's newest `issue` reference.
  func configure(with task: SeptenaTask, issue: TaskRefRow?, contextText: String?) {
    taskId = task.id
    titleLabel.stringValue = task.title

    let checkNote = Self.noteText(for: task)
    noteLabel.stringValue = checkNote

    if let meta = Self.metaSummary(for: task, issue: issue, contextText: contextText) {
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
    [acceptButton, sendBackButton]
  }

  @objc private func acceptTapped() {
    onAccept?(taskId)
  }

  @objc private func sendBackTapped() {
    onSendBack?(taskId)
  }

  static func noteText(for task: SeptenaTask) -> String {
    if let note = task.conversation.endStateNote?.trimmingCharacters(in: .whitespacesAndNewlines),
       !note.isEmpty {
      return note
    }
    return RegistrySurfaces.agentPromptReviewFallback
  }

  /// The meta line: the list, "asked {ago}" (only when the backend stamped
  /// `endStateAt`), the issue and the artifact title, joined by " · ".
  static func metaSummary(for task: SeptenaTask, issue: TaskRefRow?, contextText: String?) -> String? {
    var parts: [String] = []
    if let contextText, !contextText.isEmpty { parts.append(contextText) }
    if let asked = task.conversation.endStateAt {
      let ago = TaskHistory.relative(asked, now: DayClock.appNow)
      if !ago.isEmpty {
        parts.append(String(localized: "asked \(ago)",
                            comment: "SeptaskKit: review row, when the agent asked for review"))
      }
    }
    if let issue { parts.append(issue.title) }
    if let artifact = task.conversation.artifact, !artifact.title.isEmpty {
      parts.append(artifact.title)
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private static let buttonGap: CGFloat = 8
  private static let buttonRowHeight: CGFloat = 22

  static func height(for task: SeptenaTask, issue: TaskRefRow?, contextText: String?, width: CGFloat) -> CGFloat {
    let inset = SeptaskKitLayout.inset(for: max(width, 360))
    let textWidth = max(140, width - inset * 2 - SeptaskKitLayout.rowLeadingPad - 10)
    let note = noteText(for: task) as NSString
    let noteRect = note.boundingRect(
      with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: SeptaskKitTheme.meta])
    let titleHeight = ceil(SeptaskKitTheme.taskTitle.ascender - SeptaskKitTheme.taskTitle.descender) + 2
    let noteHeight = ceil(noteRect.height) + 2
    let metaHeight: CGFloat = metaSummary(for: task, issue: issue, contextText: contextText) == nil
      ? 0
      : 3 + ceil(SeptaskKitTheme.chip.ascender - SeptaskKitTheme.chip.descender) + 2
    return 10 + titleHeight + 3 + noteHeight + metaHeight + buttonGap + buttonRowHeight + 10
  }
}

/// The list a task is in, as one line: "Area › Project", or just the area
/// or the project. Nil when the task is in no list. The Review row and the
/// inspector's review depth both read it.
@MainActor
enum KitListPath {
  static func text(for task: SeptenaTask, in context: ModelContext) -> String? {
    let snapshot = StructureCache.snapshot(in: context)
    let project = task.project.flatMap { id in snapshot.projects.first { $0.id == id } }
    let areaID = project?.area ?? task.area
    let area = areaID.flatMap { id in snapshot.areas.first { $0.id == id } }
    let parts = [area?.title, project?.title].compactMap { title -> String? in
      guard let title, !title.isEmpty else { return nil }
      return title
    }
    return parts.isEmpty ? nil : parts.joined(separator: " › ")
  }
}
#endif
