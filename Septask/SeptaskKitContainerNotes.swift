#if os(macOS)
import AppKit

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

  @objc private func fire() { onEdit?(self) }
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

  private init(original: String, onCommit: @escaping (String) -> Void) {
    self.original = original
    self.onCommit = onCommit
  }

  /// The popover retains its content, and the content's close handler keeps
  /// this presenter alive until it has committed.
  static func present(isArea: Bool, notes: String, relativeTo anchor: NSView,
                      onCommit: @escaping (String) -> Void) {
    let presenter = KitContainerNotesPopover(original: notes, onCommit: onCommit)
    presenter.show(isArea: isArea, relativeTo: anchor)
  }

  private func show(isArea: Bool, relativeTo anchor: NSView) {
    let heading = NSTextField(labelWithString: isArea
      ? String(localized: "Area notes", comment: "SeptaskKit: notes popover heading")
      : String(localized: "Project notes", comment: "SeptaskKit: notes popover heading"))
    heading.font = SeptaskKitTheme.chip
    heading.textColor = SeptaskKitTheme.inkSecondary

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

    let stack = NSStackView(views: [heading, scroll])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    NSLayoutConstraint.activate([
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

  private func commit() {
    var text = textView.string
    if ContainerNotes.isUntouchedTemplate(text) { text = "" }
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = "" }
    guard text != original else { return }
    onCommit(text)
  }
}
#endif
