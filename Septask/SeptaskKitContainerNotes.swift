#if os(macOS)
import AppKit
import SwiftUI

// Project and area notes on the AppKit shell's project/area page: the row
// under the page title, and the Tier 1 popover that edits it (ADR 0012,
// docs/PROJECT_NOTES_SPEC.md §6). Notes are the context agents read before
// they decide anything about a task, so they sit first on the page.
//
// Editing happens in a popover anchored to the row, never in the row: a text
// view swapped into a selectable table row breaks its focus and selection
// (CLAUDE.md, "No inline TextField swapped into a selectable native List
// row"). The popover is close-commits, like the inspector: dismissal saves.

@MainActor
enum KitContainerNotes {
  /// Rows of notes shown on the page before the rest truncates. The popover
  /// shows all of it; a long agent log must not push the tasks off screen.
  static let maxLines = 14
  static let topPad: CGFloat = 0
  static let bottomPad: CGFloat = 14

  static var bodyFont: NSFont { .systemFont(ofSize: SeptaskKitTheme.notesFontSize) }
  private static var headingFont: NSFont { .systemFont(ofSize: SeptaskKitTheme.notesFontSize, weight: .semibold) }

  /// Notes as the page shows them: `#`/`##` lines as headings, `###` lines
  /// (how an agent log entry starts: `### <day> · <agent>`) as a quiet
  /// byline, the rest as body text. The placeholder when there is nothing.
  static func attributed(_ text: String, placeholder: String) -> NSAttributedString {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return NSAttributedString(string: placeholder, attributes: [
        .font: bodyFont, .foregroundColor: NSColor.tertiaryLabelColor,
      ])
    }
    let out = NSMutableAttributedString()
    let lines = trimmed.components(separatedBy: "\n")
    for (i, line) in lines.enumerated() {
      let attrs: [NSAttributedString.Key: Any]
      var shown = line
      if line.hasPrefix("### ") {
        shown = String(line.dropFirst(4))
        attrs = [.font: SeptaskKitTheme.meta, .foregroundColor: SeptaskKitTheme.inkSecondary]
      } else if line.hasPrefix("## ") || line.hasPrefix("# ") {
        shown = String(line.drop(while: { $0 == "#" }).dropFirst())
        attrs = [.font: headingFont, .foregroundColor: NSColor.labelColor]
      } else {
        attrs = [.font: bodyFont, .foregroundColor: SeptaskKitTheme.inkSecondary]
      }
      out.append(NSAttributedString(string: shown + (i < lines.count - 1 ? "\n" : ""), attributes: attrs))
    }
    return out
  }

  /// Text column width for a row of the given table width: from the page
  /// title's text edge to the trailing margin.
  static func textWidth(rowWidth: CGFloat) -> CGFloat {
    let inset = SeptaskKitLayout.inset(for: rowWidth)
    return max(120, rowWidth - inset * 2 - SeptaskKitLayout.screenTitleLeading - 8)
  }

  static func height(text: String, placeholder: String, rowWidth: CGFloat) -> CGFloat {
    let string = attributed(text, placeholder: placeholder)
    let rect = string.boundingRect(
      with: NSSize(width: textWidth(rowWidth: rowWidth), height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading])
    let cap = ceil(bodyFont.boundingRectForFont.height * CGFloat(maxLines))
    return min(ceil(rect.height), cap) + topPad + bottomPad
  }
}

// MARK: - Row cell

/// The notes under a project's or an area's page title. Clicks go to a
/// transparent full-bleed `NSButton`, for the reason spelled out on
/// `KitNewTaskCell`: `NSTableView` claims clicks on label content, so only a
/// real `NSControl` reliably receives them.
@MainActor
final class KitContainerNotesCell: NSTableCellView {
  private var hitPin: KitContentColumnPin!
  private let label = NSTextField(wrappingLabelWithString: "")
  private let hit = NSButton()
  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!
  /// Opens the editor, anchored to this cell.
  var onEdit: ((NSView) -> Void)?
  /// Opens the notes history sheet (available when signed in to the backend).
  var onHistory: (() -> Void)?

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    label.translatesAutoresizingMaskIntoConstraints = false
    label.isSelectable = false
    label.maximumNumberOfLines = KitContainerNotes.maxLines
    label.lineBreakMode = .byTruncatingTail
    label.cell?.truncatesLastVisibleLine = true
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    label.kitA11yIgnore()

    hit.translatesAutoresizingMaskIntoConstraints = false
    hit.isBordered = false
    hit.isTransparent = true
    hit.title = ""
    hit.setButtonType(.momentaryChange)
    hit.refusesFirstResponder = true
    hit.target = self
    hit.action = #selector(fire)
    hit.toolTip = String(localized: "Edit notes", comment: "SeptaskKit: tooltip on project or area notes")
    hit.kitA11yIgnore()

    addSubview(label)
    // Last, so it layers above the text and takes every click in the row.
    addSubview(hit)
    textField = label

    leadingConstraint = label.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: KitCardRowView.horizontalInset + SeptaskKitLayout.screenTitleLeading)
    trailingConstraint = label.trailingAnchor.constraint(
      lessThanOrEqualTo: trailingAnchor, constant: -(KitCardRowView.horizontalInset + 8))
    hitPin = KitContentColumnPin(hit, in: self)
    NSLayoutConstraint.activate([
      leadingConstraint,
      trailingConstraint,
      label.topAnchor.constraint(equalTo: topAnchor, constant: KitContainerNotes.topPad),
      hit.topAnchor.constraint(equalTo: topAnchor),
      hit.bottomAnchor.constraint(equalTo: bottomAnchor),
    ] + hitPin.constraints)
  }

  required init?(coder: NSCoder) { fatalError("KitContainerNotesCell is code-only") }

  func configure(text: String, placeholder: String) {
    label.attributedStringValue = KitContainerNotes.attributed(text, placeholder: placeholder)
    let a11y = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? placeholder : text
    kitA11yButton(label: String(localized: "Notes: \(a11y)",
                                comment: "SeptaskKit: accessibility label of project or area notes"))
    window?.invalidateCursorRects(for: self)
  }

  /// Same width-dependent centered-column margin as every other row.
  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + SeptaskKitLayout.screenTitleLeading
    trailingConstraint.constant = -(inset + 8)
    label.preferredMaxLayoutWidth = KitContainerNotes.textWidth(rowWidth: bounds.width)
    hitPin.update(width: bounds.width)
    super.layout()
  }

  override func accessibilityPerformPress() -> Bool {
    onEdit?(self)
    return true
  }

  override func resetCursorRects() {
    addCursorRect(hit.frame, cursor: .iBeam)
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu()
    let editItem = NSMenuItem(title: ContainerNotesCopy.editNotesMenuTitle,
                              action: #selector(fire), keyEquivalent: "")
    editItem.target = self
    menu.addItem(editItem)
    if onHistory != nil, TaskHistory.isAvailable {
      let historyItem = NSMenuItem(title: ContainerNotesCopy.historyMenuTitle,
                                   action: #selector(openHistory), keyEquivalent: "")
      historyItem.target = self
      menu.addItem(historyItem)
    }
    return menu
  }

  @objc private func fire() { onEdit?(self) }
  @objc private func openHistory() { onHistory?() }
}

// MARK: - Proposal card cell (above notes)

@MainActor
enum KitNotesProposalLayout {
  static let cardPadding: CGFloat = 12
  static let bottomGap: CGFloat = 10
  static let maxDiffLines = 12

  private static var diffFont: NSFont { .monospacedSystemFont(ofSize: SeptenaTypeScale.size(.footnote), weight: .regular) }

  static func cardWidth(rowWidth: CGFloat) -> CGFloat {
    let inset = SeptaskKitLayout.inset(for: rowWidth)
    return max(180, rowWidth - inset * 2 - SeptaskKitLayout.screenTitleLeading)
  }

  static func diffAttributed(currentNotes: String, proposal: NotesProposal) -> NSAttributedString {
    let lines = ContainerNotes.diffLines(from: currentNotes, to: proposal.body)
    if lines.isEmpty {
      return NSAttributedString(
        string: ContainerNotesCopy.noChangesInBrief,
        attributes: [.font: SeptaskKitTheme.meta, .foregroundColor: SeptaskKitTheme.inkSecondary]
      )
    }
    let visible = Array(lines.prefix(maxDiffLines))
    let truncated = lines.count > maxDiffLines
    let out = NSMutableAttributedString()
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 2
    for (idx, line) in visible.enumerated() {
      let prefix: String
      let fg: NSColor
      let bg: NSColor?
      var strike = false
      switch line.kind {
      case .added:
        prefix = "+ "
        fg = NSColor.labelColor
        bg = NSColor.systemGreen.withAlphaComponent(0.14)
      case .removed:
        prefix = "− "
        fg = NSColor.secondaryLabelColor
        bg = NSColor.systemRed.withAlphaComponent(0.11)
        strike = true
      case .context:
        prefix = "  "
        fg = NSColor.secondaryLabelColor
        bg = nil
      case .separator:
        prefix = "  "
        fg = NSColor.tertiaryLabelColor
        bg = nil
      }
      var attrs: [NSAttributedString.Key: Any] = [
        .font: diffFont,
        .foregroundColor: fg,
        .paragraphStyle: style,
      ]
      if let bg { attrs[.backgroundColor] = bg }
      if strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
      let suffix = (idx < visible.count - 1 || truncated) ? "\n" : ""
      out.append(NSAttributedString(string: prefix + line.text + suffix, attributes: attrs))
    }
    if truncated {
      out.append(NSAttributedString(
        string: "  …",
        attributes: [.font: diffFont, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: style]
      ))
    }
    return out
  }

  static func height(currentNotes: String, proposal: NotesProposal, rowWidth: CGFloat) -> CGFloat {
    let innerWidth = max(120, cardWidth(rowWidth: rowWidth) - cardPadding * 2)
    var total: CGFloat = cardPadding * 2 + bottomGap
    // Header row
    total += ceil(SeptaskKitTheme.metaStrong.boundingRectForFont.height) + 8
    // Reason (why)
    if let why = proposal.why?.trimmingCharacters(in: .whitespacesAndNewlines), !why.isEmpty {
      let attr = NSAttributedString(string: why, attributes: [.font: KitContainerNotes.bodyFont])
      let rect = attr.boundingRect(with: NSSize(width: innerWidth, height: .greatestFiniteMagnitude),
                                   options: [.usesLineFragmentOrigin, .usesFontLeading])
      total += ceil(rect.height) + 8
    }
    // Diff box
    let diff = diffAttributed(currentNotes: currentNotes, proposal: proposal)
    let diffRect = diff.boundingRect(with: NSSize(width: max(100, innerWidth - 16), height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading])
    total += min(ceil(diffRect.height), 180) + 14 + 8
    // Log-preserved hint
    if ContainerNotes.hasLog(currentNotes) {
      total += ceil(SeptaskKitTheme.meta.boundingRectForFont.height) + 8
    }
    // Action button row
    total += 26
    return ceil(total)
  }
}

/// Compact AppKit card rendered above a project's or area's notes when an
/// agent proposed a new brief (docs/PROJECT_NOTES_SPEC.md §6, #123).
@MainActor
final class KitNotesProposalCell: NSTableCellView {
  var onAccept: (() -> Void)?
  var onReject: (() -> Void)?

  private let card = NSView()
  private let headingLabel = NSTextField(labelWithString: "")
  private let timeLabel = NSTextField(labelWithString: "")
  private let whyLabel = NSTextField(wrappingLabelWithString: "")
  private let diffContainer = NSView()
  private let diffLabel = NSTextField(wrappingLabelWithString: "")
  private let logHintLabel = NSTextField(labelWithString: "")
  private let acceptButton = NSButton(title: ContainerNotesCopy.acceptButton, target: nil, action: nil)
  private let rejectButton = NSButton(title: ContainerNotesCopy.rejectButton, target: nil, action: nil)
  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    card.translatesAutoresizingMaskIntoConstraints = false
    card.wantsLayer = true
    card.layer?.cornerRadius = CGFloat(RegistryTokens.Radii.small)
    card.layer?.borderWidth = 1

    let sparkle = NSImageView()
    if let img = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) {
      sparkle.image = img
      sparkle.contentTintColor = .controlAccentColor
    }
    sparkle.translatesAutoresizingMaskIntoConstraints = false
    sparkle.setContentHuggingPriority(.required, for: .horizontal)

    headingLabel.font = SeptaskKitTheme.metaStrong
    headingLabel.textColor = SeptaskKitTheme.inkPrimary
    headingLabel.lineBreakMode = .byTruncatingTail

    timeLabel.font = SeptaskKitTheme.meta
    timeLabel.textColor = SeptaskKitTheme.inkSecondary
    timeLabel.setContentHuggingPriority(.required, for: .horizontal)

    let headerRow = NSStackView(views: [sparkle, headingLabel, NSView(), timeLabel])
    headerRow.orientation = .horizontal
    headerRow.alignment = .centerY
    headerRow.spacing = 6

    whyLabel.font = KitContainerNotes.bodyFont
    whyLabel.textColor = SeptaskKitTheme.inkPrimary
    whyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    diffContainer.translatesAutoresizingMaskIntoConstraints = false
    diffContainer.wantsLayer = true
    diffContainer.layer?.cornerRadius = 6
    diffLabel.translatesAutoresizingMaskIntoConstraints = false
    diffLabel.isSelectable = false
    diffLabel.maximumNumberOfLines = KitNotesProposalLayout.maxDiffLines + 1
    diffLabel.lineBreakMode = .byTruncatingTail
    diffLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    diffContainer.addSubview(diffLabel)
    NSLayoutConstraint.activate([
      diffLabel.leadingAnchor.constraint(equalTo: diffContainer.leadingAnchor, constant: 8),
      diffLabel.trailingAnchor.constraint(equalTo: diffContainer.trailingAnchor, constant: -8),
      diffLabel.topAnchor.constraint(equalTo: diffContainer.topAnchor, constant: 6),
      diffLabel.bottomAnchor.constraint(equalTo: diffContainer.bottomAnchor, constant: -6),
    ])

    logHintLabel.font = SeptaskKitTheme.meta
    logHintLabel.textColor = SeptaskKitTheme.inkSecondary
    logHintLabel.stringValue = ContainerNotesCopy.logPreservedHint

    acceptButton.bezelStyle = .rounded
    acceptButton.controlSize = .small
    acceptButton.bezelColor = .controlAccentColor
    acceptButton.refusesFirstResponder = true
    acceptButton.target = self
    acceptButton.action = #selector(tapAccept)

    rejectButton.bezelStyle = .rounded
    rejectButton.controlSize = .small
    rejectButton.refusesFirstResponder = true
    rejectButton.target = self
    rejectButton.action = #selector(tapReject)

    let actionsRow = NSStackView(views: [acceptButton, rejectButton, NSView()])
    actionsRow.orientation = .horizontal
    actionsRow.alignment = .centerY
    actionsRow.spacing = 8

    let stack = NSStackView(views: [headerRow, whyLabel, diffContainer, logHintLabel, actionsRow])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false

    card.addSubview(stack)
    addSubview(card)

    leadingConstraint = card.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: KitCardRowView.horizontalInset + SeptaskKitLayout.screenTitleLeading)
    trailingConstraint = card.trailingAnchor.constraint(
      equalTo: trailingAnchor, constant: -KitCardRowView.horizontalInset)

    let pad = KitNotesProposalLayout.cardPadding
    NSLayoutConstraint.activate([
      leadingConstraint,
      trailingConstraint,
      card.topAnchor.constraint(equalTo: topAnchor),
      card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -KitNotesProposalLayout.bottomGap),
      stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: pad),
      stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -pad),
      stack.topAnchor.constraint(equalTo: card.topAnchor, constant: pad),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -pad),
      headerRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
      whyLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
      diffContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
      actionsRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
    applySurfaceColors()
  }

  required init?(coder: NSCoder) { fatalError("KitNotesProposalCell is code-only") }

  func configure(currentNotes: String, proposal: NotesProposal) {
    headingLabel.stringValue = ContainerNotesCopy.proposalHeading(agent: proposal.displayAgent)
    timeLabel.stringValue = TaskHistory.relative(proposal.date, now: DayClock.appNow)
    if let why = proposal.why?.trimmingCharacters(in: .whitespacesAndNewlines), !why.isEmpty {
      whyLabel.stringValue = why
      whyLabel.isHidden = false
    } else {
      whyLabel.stringValue = ""
      whyLabel.isHidden = true
    }
    diffLabel.attributedStringValue = KitNotesProposalLayout.diffAttributed(
      currentNotes: currentNotes, proposal: proposal)
    logHintLabel.isHidden = !ContainerNotes.hasLog(currentNotes)
    applySurfaceColors()
  }

  private func applySurfaceColors() {
    card.layer?.backgroundColor = SeptaskKitTheme.cardSurface.cgColor
    card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
    diffContainer.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.18).cgColor
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applySurfaceColors()
  }

  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + SeptaskKitLayout.screenTitleLeading
    trailingConstraint.constant = -inset
    let innerWidth = max(120, KitNotesProposalLayout.cardWidth(rowWidth: bounds.width) - KitNotesProposalLayout.cardPadding * 2)
    whyLabel.preferredMaxLayoutWidth = innerWidth
    diffLabel.preferredMaxLayoutWidth = max(100, innerWidth - 16)
    super.layout()
  }

  @objc private func tapAccept() { onAccept?() }
  @objc private func tapReject() { onReject?() }
}

// MARK: - Editor popover

/// Tier 1, close-commits: the notes in a plain-text view; closing the popover
/// (click away, Escape) saves. Empty project notes open on the template
/// headings with the cursor under the first one; a template nobody typed
/// into is not saved.
@MainActor
final class KitContainerNotesPopover: NSObject {
  private let textView = NSTextView()
  private let handle = KitPopoverHandle()
  private let original: String
  private let onCommit: (String) -> Void
  private let onHistory: (() -> Void)?

  private init(original: String, onCommit: @escaping (String) -> Void, onHistory: (() -> Void)?) {
    self.original = original
    self.onCommit = onCommit
    self.onHistory = onHistory
  }

  /// The popover retains its content, and the content's close handler keeps
  /// this presenter alive until it has committed.
  static func present(isArea: Bool, notes: String, relativeTo anchor: NSView,
                      onHistory: (() -> Void)? = nil,
                      onCommit: @escaping (String) -> Void) {
    let presenter = KitContainerNotesPopover(original: notes, onCommit: onCommit, onHistory: onHistory)
    presenter.show(isArea: isArea, relativeTo: anchor)
  }

  private func show(isArea: Bool, relativeTo anchor: NSView) {
    let heading = NSTextField(labelWithString: isArea
      ? String(localized: "Area notes", comment: "SeptaskKit: notes popover heading")
      : String(localized: "Project notes", comment: "SeptaskKit: notes popover heading"))
    heading.font = SeptaskKitTheme.chip
    heading.textColor = SeptaskKitTheme.inkSecondary

    let headerRow = NSStackView(views: [heading, NSView()])
    headerRow.orientation = .horizontal
    headerRow.alignment = .centerY
    headerRow.spacing = 8
    if onHistory != nil, TaskHistory.isAvailable {
      let historyBtn = NSButton(title: ContainerNotesCopy.historyButtonTitle,
                                target: self, action: #selector(openHistory))
      historyBtn.bezelStyle = .inline
      historyBtn.controlSize = .small
      historyBtn.font = SeptaskKitTheme.meta
      historyBtn.refusesFirstResponder = true
      headerRow.addArrangedSubview(historyBtn)
    }

    textView.isRichText = false
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.drawsBackground = false
    textView.font = KitContainerNotes.bodyFont
    textView.textColor = .labelColor
    textView.textContainerInset = NSSize(width: 2, height: 6)
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.frame = NSRect(x: 0, y: 0, width: 436, height: 220)
    textView.minSize = NSSize(width: 0, height: 220)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.setAccessibilityLabel(heading.stringValue)

    var startText = original
    var cursor = (original as NSString).length
    if !isArea && original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      startText = ContainerNotes.template
      cursor = ContainerNotes.templateCursorUTF16Offset
    }
    textView.string = startText
    textView.setSelectedRange(NSRange(location: min(cursor, (startText as NSString).length), length: 0))

    let scroll = NSScrollView()
    scroll.borderType = .noBorder
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.documentView = textView
    scroll.translatesAutoresizingMaskIntoConstraints = false

    let stack = NSStackView(views: [headerRow, scroll])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    NSLayoutConstraint.activate([
      headerRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
      scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
      scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
    ])

    KitPopover.present(stack,
                       size: NSSize(width: 460, height: 320),
                       relativeTo: anchor.bounds,
                       of: anchor,
                       preferredEdge: .maxY,
                       focus: textView,
                       handle: handle,
                       onClose: { [self] in commit() })
  }

  @objc private func openHistory() {
    let callback = onHistory
    handle.close()
    DispatchQueue.main.async { callback?() }
  }

  private func commit() {
    var text = textView.string
    if ContainerNotes.isUntouchedTemplate(text) { text = "" }
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = "" }
    guard text != original else { return }
    onCommit(text)
  }
}

// MARK: - Notes history sheet presenter (macOS AppKit)

@MainActor
enum KitNotesHistorySheet {
  static func present(container: ContainerNotes.Container,
                      id: String,
                      title: String,
                      currentNotes: String,
                      from presenter: NSViewController,
                      onRestore: @escaping (String) -> Void) {
    var host: NSHostingController<NotesHistorySheet>?
    let view = NotesHistorySheet(
      container: container,
      containerID: id,
      containerTitle: title,
      currentNotes: currentNotes,
      onRestore: onRestore,
      onClose: {
        if let controller = host {
          presenter.dismiss(controller)
        }
      }
    )
    let controller = NSHostingController(rootView: view)
    host = controller
    presenter.presentAsSheet(controller)
  }
}
#endif
