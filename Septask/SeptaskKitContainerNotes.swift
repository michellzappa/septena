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
  static let topPad: CGFloat = 0
  static let bottomPad: CGFloat = 14
  /// The Show more line under notes that are folded or unfolded.
  static let toggleGap: CGFloat = 4
  static var toggleHeight: CGFloat { ceil(SeptaskKitTheme.meta.boundingRectForFont.height) }

  static var bodyFont: NSFont { .systemFont(ofSize: SeptaskKitTheme.notesFontSize) }
  private static var headingFont: NSFont { .systemFont(ofSize: SeptaskKitTheme.notesFontSize, weight: .semibold) }

  /// Notes as the page shows them (`ContainerNotes.previewLines`): `#`/`##`
  /// lines as headings, `###` lines (how an agent log entry starts:
  /// `### <day> · <agent>`) as a quiet byline, list items with a hanging
  /// indent. The placeholder when there is nothing.
  static func attributed(_ text: String, placeholder: String) -> NSAttributedString {
    let lines = ContainerNotes.previewLines(text)
    guard !lines.isEmpty else {
      return NSAttributedString(string: placeholder, attributes: [
        .font: bodyFont, .foregroundColor: NSColor.tertiaryLabelColor,
      ])
    }
    let out = NSMutableAttributedString()
    for (i, line) in lines.enumerated() {
      let shown = rendered(line)
      if i < lines.count - 1 {
        shown.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
      }
      // The break belongs to the paragraph it ends, so one style covers both.
      shown.addAttribute(.paragraphStyle, value: paragraph(for: line),
                         range: NSRange(location: 0, length: shown.length))
      out.append(shown)
    }
    return out
  }

  private static func rendered(_ line: NotesPreviewLine) -> NSMutableAttributedString {
    switch line {
    case .blank:
      return NSMutableAttributedString()
    case .heading(let level, let text):
      return level >= 3
        ? inline(text, font: SeptaskKitTheme.meta, color: SeptaskKitTheme.inkSecondary)
        : inline(text, font: headingFont, color: .labelColor)
    case .item(_, let marker, let text):
      let item = NSMutableAttributedString(string: marker + "\t", attributes: [
        .font: bodyFont, .foregroundColor: SeptaskKitTheme.inkSecondary,
      ])
      item.append(inline(text, font: bodyFont, color: SeptaskKitTheme.inkSecondary))
      return item
    case .quote(let text):
      return inline(text, font: NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask),
                    color: SeptaskKitTheme.inkSecondary)
    case .body(let text):
      return inline(text, font: bodyFont, color: SeptaskKitTheme.inkSecondary)
    }
  }

  /// Word wrap on every line: the label's own `truncatesLastVisibleLine` draws
  /// the ellipsis. A list item wraps under its text, not under its marker.
  private static func paragraph(for line: NotesPreviewLine) -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byWordWrapping
    if case .item(let depth, let marker, _) = line {
      let step = SeptaskKitTheme.notesFontSize
      let markerWidth = (marker + " " as NSString).size(withAttributes: [.font: bodyFont]).width
      let lead = CGFloat(depth) * step
      let textStart = lead + max(step, ceil(markerWidth) + 2)
      style.firstLineHeadIndent = lead
      style.headIndent = textStart
      style.tabStops = [NSTextTab(textAlignment: .left, location: textStart)]
    }
    return style
  }

  private static func inline(_ text: String, font: NSFont, color: NSColor) -> NSMutableAttributedString {
    let out = NSMutableAttributedString()
    let parsed = ContainerNotes.inlineMarkdown(text)
    for run in parsed.runs {
      let intent = run.inlinePresentationIntent ?? []
      var runFont = font
      if intent.contains(.code) {
        runFont = .monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: .regular)
      }
      if intent.contains(.stronglyEmphasized) {
        runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask)
      }
      if intent.contains(.emphasized) {
        runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask)
      }
      var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: color]
      if run.link != nil { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
      out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
    }
    return out
  }

  /// One label setup for the row and for the measuring label, so a measured
  /// height is the height the row draws.
  static func style(_ label: NSTextField) {
    label.isSelectable = false
    label.lineBreakMode = .byWordWrapping
    label.cell?.truncatesLastVisibleLine = true
    label.cell?.wraps = true
  }

  private static let sizer: NSTextField = {
    let label = NSTextField(wrappingLabelWithString: "")
    style(label)
    return label
  }()

  private static func labelHeight(_ string: NSAttributedString, width: CGFloat, lines: Int) -> CGFloat {
    sizer.attributedStringValue = string
    sizer.maximumNumberOfLines = lines
    sizer.preferredMaxLayoutWidth = width
    return ceil(sizer.intrinsicContentSize.height)
  }

  /// The folded or unfolded text's height, and whether folding cuts anything
  /// off. Measured, not guessed from the line count: one paragraph wraps too.
  static func layout(text: String, placeholder: String, rowWidth: CGFloat,
                     expanded: Bool) -> (textHeight: CGFloat, hasToggle: Bool) {
    let string = attributed(text, placeholder: placeholder)
    let width = textWidth(rowWidth: rowWidth)
    let full = labelHeight(string, width: width, lines: 0)
    let folded = labelHeight(string, width: width, lines: RegistryPlaceNotes.previewLines)
    return (expanded ? full : folded, full > folded + 1)
  }

  /// Text column width for a row of the given table width: from the page
  /// title's text edge to the trailing margin.
  static func textWidth(rowWidth: CGFloat) -> CGFloat {
    let inset = SeptaskKitLayout.inset(for: rowWidth)
    return max(120, rowWidth - inset * 2 - SeptaskKitLayout.screenTitleLeading - 8)
  }

  static func height(text: String, placeholder: String, rowWidth: CGFloat, expanded: Bool) -> CGFloat {
    let layout = layout(text: text, placeholder: placeholder, rowWidth: rowWidth, expanded: expanded)
    return topPad + layout.textHeight + (layout.hasToggle ? toggleGap + toggleHeight : 0) + bottomPad
  }
}

// MARK: - Row cell

/// The notes under a project's or an area's page title, folded to
/// `RegistryPlaceNotes.previewLines` with a Show more line, as on iPhone: a
/// click on cut-off notes unfolds them, a click on whole notes edits them.
/// Clicks go to a
/// transparent full-bleed `NSButton`, for the reason spelled out on
/// `KitNewTaskCell`: `NSTableView` claims clicks on label content, so only a
/// real `NSControl` reliably receives them.
@MainActor
final class KitContainerNotesCell: NSTableCellView {
  private var hitPin: KitContentColumnPin!
  private let label = NSTextField(wrappingLabelWithString: "")
  private let hit = NSButton()
  private let toggle = NSButton()
  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!
  private var text = ""
  private var placeholder = ""
  private var expanded = false
  /// Unfolds or folds the notes: the row's height changes with it.
  var onToggle: (() -> Void)?
  /// Opens the editor, anchored to this cell.
  var onEdit: ((NSView) -> Void)?
  /// Opens the notes history sheet (available when signed in to the backend).
  var onHistory: (() -> Void)?
  /// The row is not as tall as the notes need at this cell's width. Passes
  /// the width, so the list measures the row at the width the cell draws.
  var onHeightMismatch: ((CGFloat) -> Void)?
  /// The last (width, height) reported, so a mismatch reports once.
  private var reportedMismatch: NSSize?

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier
    // Long notes never draw past the row into the task card below it. If the
    // row is ever shorter than the text, the text is cut here and
    // `layout()` asks the list for the right height.
    clipsToBounds = true

    label.translatesAutoresizingMaskIntoConstraints = false
    KitContainerNotes.style(label)
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    label.kitA11yIgnore()

    hit.translatesAutoresizingMaskIntoConstraints = false
    hit.isBordered = false
    hit.isTransparent = true
    hit.title = ""
    hit.setButtonType(.momentaryChange)
    hit.refusesFirstResponder = true
    hit.target = self
    hit.action = #selector(pressText)
    hit.toolTip = String(localized: "Edit notes", comment: "SeptaskKit: tooltip on project or area notes")
    hit.kitA11yIgnore()

    addSubview(label)
    // Above the text, so it takes every click in the row but the toggle's.
    addSubview(hit)

    toggle.translatesAutoresizingMaskIntoConstraints = false
    toggle.isBordered = false
    toggle.font = SeptaskKitTheme.meta
    toggle.contentTintColor = SeptaskKitTheme.inkSecondary
    toggle.imagePosition = .imageTrailing
    toggle.imageHugsTitle = true
    toggle.refusesFirstResponder = true
    toggle.target = self
    toggle.action = #selector(pressToggle)
    addSubview(toggle)
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
      toggle.topAnchor.constraint(equalTo: label.bottomAnchor, constant: KitContainerNotes.toggleGap),
      toggle.leadingAnchor.constraint(equalTo: label.leadingAnchor),
      hit.topAnchor.constraint(equalTo: topAnchor),
      hit.bottomAnchor.constraint(equalTo: bottomAnchor),
    ] + hitPin.constraints)
  }

  required init?(coder: NSCoder) { fatalError("KitContainerNotesCell is code-only") }

  func configure(text: String, placeholder: String, expanded: Bool) {
    self.text = text
    self.placeholder = placeholder
    self.expanded = expanded
    label.maximumNumberOfLines = expanded ? 0 : RegistryPlaceNotes.previewLines
    toggle.title = expanded ? RegistryPlaceNotes.showLessTitle : RegistryPlaceNotes.showMoreTitle
    toggle.image = NSImage(systemSymbolName: expanded ? "chevron.up" : "chevron.down",
                           accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
    needsLayout = true
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
    toggle.isHidden = !hasToggle
    super.layout()
    reportHeightMismatch()
  }

  /// Notes that unfold, sync in or rewrap must never sit under the next row.
  /// The list measures the row ahead of layout; when that height is not the
  /// one the text needs at this cell's real width, the cell says so once.
  private func reportHeightMismatch() {
    guard bounds.width > 1, onHeightMismatch != nil else { return }
    let needed = KitContainerNotes.height(text: text, placeholder: placeholder,
                                          rowWidth: bounds.width, expanded: expanded)
    guard abs(needed - bounds.height) > 1 else {
      reportedMismatch = nil
      return
    }
    let key = NSSize(width: bounds.width, height: bounds.height)
    guard reportedMismatch != key else { return }
    reportedMismatch = key
    let width = bounds.width
    // Not inside this layout pass: the list re-notes row heights.
    DispatchQueue.main.async { [weak self] in self?.onHeightMismatch?(width) }
  }

  private var hasToggle: Bool {
    KitContainerNotes.layout(text: text, placeholder: placeholder, rowWidth: bounds.width,
                             expanded: expanded).hasToggle
  }

  override func accessibilityPerformPress() -> Bool {
    onEdit?(self)
    return true
  }

  override func resetCursorRects() {
    if toggle.isHidden {
      addCursorRect(hit.frame, cursor: .iBeam)
    } else {
      addCursorRect(hit.frame.intersection(label.frame), cursor: .iBeam)
      addCursorRect(toggle.frame, cursor: .pointingHand)
    }
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

  @objc private func pressText() {
    if !expanded, hasToggle { onToggle?() } else { onEdit?(self) }
  }
  @objc private func pressToggle() { onToggle?() }
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
