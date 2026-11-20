#if os(macOS)
import AppKit

// The ONE inline notice of the AppKit task list. Every statement ABOUT the
// list that sits on top of it (rolled into Today, not signed in, a sync
// problem) draws through `KitNoticeCell`, so they share one anatomy:
//
//   [glyph]  Title                              [Primary]  (x)
//            Optional detail line
//
// on a rounded fill in the SAME content column as the task cards: the fill
// spans the card's width (`KitContentColumnPin`), the glyph centers on the
// checkbox axis (`SeptaskKitLayout.leadingGlyphCenterX`), and the text starts
// where a task title starts. Nothing reaches into the page gutter. The
// SwiftUI counterpart is `TaskListNotice` (Septena/Shell/Tasks).
//
// The fill is the card surface, never a selection color (one selection
// language per surface). Only a warning tints it, with a light wash.

/// What a notice is about. One enum for both shells: `TaskNoticeKind`
/// (Septena/Shell/Tasks/TaskNotices.swift), where which notices show is decided.
typealias KitNoticeKind = TaskNoticeKind

/// One notice's content. The cell owns the layout; callers only say this.
struct KitNotice {
  var kind: KitNoticeKind
  var symbol: String
  var title: String
  var detail: String?
  /// Bordered trailing button. Nil means no primary action.
  var primaryTitle: String?
  /// True draws a small close button at the trailing edge.
  var dismissible: Bool
}

extension KitNotice {
  /// The AppKit drawing of a shared notice (`TaskNotices`).
  init(_ notice: TaskNotice) {
    self.init(kind: notice.kind, symbol: notice.symbol, title: notice.title,
              detail: notice.detail, primaryTitle: notice.primaryTitle,
              dismissible: notice.dismissible)
  }
}

@MainActor
final class KitNoticeCell: NSTableCellView {
  /// Padding inside the fill, top and bottom.
  private static let verticalPad: CGFloat = 8
  /// Page space under the fill, before the next row.
  private static let bottomGap: CGFloat = 10
  /// Task title leading from the content inset: checkbox pad + tap + gap,
  /// the same arithmetic `SeptaskKitTaskCell` lays out.
  private static let textLeading: CGFloat =
    SeptaskKitLayout.rowLeadingPad + KitCheckboxView.tapSize + 7

  /// Row height for a notice. Text is one line per field (truncated), so the
  /// height is a function of the content, not of the width.
  static func height(for notice: KitNotice) -> CGFloat {
    let line = lineHeight(SeptaskKitTheme.meta)
    let text = notice.detail == nil ? line : line * 2 + 1
    let control: CGFloat = notice.primaryTitle == nil ? 16 : 22
    return ceil(max(text, control)) + verticalPad * 2 + bottomGap
  }

  private static func lineHeight(_ font: NSFont) -> CGFloat {
    ceil(font.ascender - font.descender + font.leading)
  }

  private let fill = KitNoticeFill()
  private let glyph = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let detailLabel = NSTextField(labelWithString: "")
  private let textStack = NSStackView()
  private let primary = NSButton(title: "", target: nil, action: nil)
  private let dismiss = NSButton()
  private var pin: KitContentColumnPin!
  private var textToPrimary: NSLayoutConstraint!
  private var textToDismiss: NSLayoutConstraint!
  private var primaryToDismiss: NSLayoutConstraint!
  private var primaryToEdge: NSLayoutConstraint!

  var onPrimary: (() -> Void)?
  var onDismiss: (() -> Void)?

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    fill.translatesAutoresizingMaskIntoConstraints = false
    addSubview(fill)

    glyph.translatesAutoresizingMaskIntoConstraints = false
    glyph.setContentHuggingPriority(.required, for: .horizontal)
    glyph.kitA11yIgnore()

    titleLabel.font = SeptaskKitTheme.metaStrong
    titleLabel.textColor = SeptaskKitTheme.inkPrimary
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    detailLabel.font = SeptaskKitTheme.meta
    detailLabel.textColor = SeptaskKitTheme.inkSecondary
    detailLabel.lineBreakMode = .byTruncatingTail
    detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    textStack.translatesAutoresizingMaskIntoConstraints = false
    textStack.orientation = .vertical
    textStack.alignment = .leading
    textStack.spacing = 1
    textStack.addArrangedSubview(titleLabel)
    textStack.addArrangedSubview(detailLabel)
    textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    // A standard bordered push button: the platform's own look for an inline
    // action, sized for a compact row.
    primary.translatesAutoresizingMaskIntoConstraints = false
    primary.bezelStyle = .push
    primary.controlSize = .small
    primary.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
    primary.refusesFirstResponder = true
    primary.target = self
    primary.action = #selector(firePrimary)
    primary.setContentHuggingPriority(.required, for: .horizontal)
    primary.setContentCompressionResistancePriority(.required, for: .horizontal)

    dismiss.translatesAutoresizingMaskIntoConstraints = false
    dismiss.isBordered = false
    dismiss.imagePosition = .imageOnly
    let closeLabel = String(localized: "Dismiss",
                            comment: "SeptaskKit: close button on an inline list notice")
    dismiss.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: closeLabel)?
      .withSymbolConfiguration(.init(pointSize: SeptenaTypeScale.size(.footnote) - 1, weight: .semibold))
    dismiss.contentTintColor = SeptaskKitTheme.iconMuted
    dismiss.refusesFirstResponder = true
    dismiss.target = self
    dismiss.action = #selector(fireDismiss)
    dismiss.toolTip = closeLabel
    dismiss.setAccessibilityLabel(closeLabel)
    dismiss.setContentHuggingPriority(.required, for: .horizontal)
    dismiss.setContentCompressionResistancePriority(.required, for: .horizontal)

    fill.addSubview(glyph)
    fill.addSubview(textStack)
    fill.addSubview(primary)
    fill.addSubview(dismiss)
    textField = titleLabel

    pin = KitContentColumnPin(fill, in: self)
    textToPrimary = textStack.trailingAnchor.constraint(
      lessThanOrEqualTo: primary.leadingAnchor, constant: -10)
    textToDismiss = textStack.trailingAnchor.constraint(
      lessThanOrEqualTo: dismiss.leadingAnchor, constant: -8)
    primaryToDismiss = primary.trailingAnchor.constraint(
      equalTo: dismiss.leadingAnchor, constant: -8)
    primaryToEdge = primary.trailingAnchor.constraint(
      equalTo: fill.trailingAnchor, constant: -10)
    NSLayoutConstraint.activate(pin.constraints + [
      fill.topAnchor.constraint(equalTo: topAnchor),
      fill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.bottomGap),
      glyph.centerXAnchor.constraint(equalTo: fill.leadingAnchor,
                                     constant: SeptaskKitLayout.leadingGlyphCenterX),
      glyph.centerYAnchor.constraint(equalTo: fill.centerYAnchor),
      textStack.leadingAnchor.constraint(equalTo: fill.leadingAnchor, constant: Self.textLeading),
      textStack.centerYAnchor.constraint(equalTo: fill.centerYAnchor),
      textStack.trailingAnchor.constraint(lessThanOrEqualTo: fill.trailingAnchor, constant: -10),
      primary.centerYAnchor.constraint(equalTo: fill.centerYAnchor),
      dismiss.centerYAnchor.constraint(equalTo: fill.centerYAnchor),
      dismiss.trailingAnchor.constraint(equalTo: fill.trailingAnchor, constant: -10),
      dismiss.widthAnchor.constraint(equalToConstant: 16),
      dismiss.heightAnchor.constraint(equalToConstant: 16),
    ])
  }

  required init?(coder: NSCoder) { fatalError("KitNoticeCell is code-only") }

  override func layout() {
    pin.update(width: bounds.width)
    super.layout()
  }

  func configure(_ notice: KitNotice) {
    fill.kind = notice.kind
    glyph.image = NSImage(systemSymbolName: notice.symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: SeptenaTypeScale.size(.body), weight: .regular))
    glyph.contentTintColor = Self.tint(for: notice.kind)

    titleLabel.stringValue = notice.title
    detailLabel.stringValue = notice.detail ?? ""
    detailLabel.isHidden = notice.detail == nil
    toolTip = [notice.title, notice.detail].compactMap { $0 }.joined(separator: " ")

    let hasPrimary = notice.primaryTitle != nil
    primary.isHidden = !hasPrimary
    primary.title = notice.primaryTitle ?? ""
    dismiss.isHidden = !notice.dismissible

    // Text runs up to whichever control comes first; the primary button sits
    // against the close button when both exist, else against the edge.
    textToPrimary.isActive = hasPrimary
    textToDismiss.isActive = !hasPrimary && notice.dismissible
    primaryToDismiss.isActive = hasPrimary && notice.dismissible
    primaryToEdge.isActive = hasPrimary && !notice.dismissible

    titleLabel.kitA11yIgnore()
    detailLabel.kitA11yIgnore()
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel(toolTip)
    window?.invalidateCursorRects(for: self)
  }

  override func accessibilityChildren() -> [Any]? {
    [primary, dismiss].filter { !$0.isHidden }
  }

  override func resetCursorRects() {
    if !primary.isHidden { addCursorRect(convert(primary.frame, from: fill), cursor: .pointingHand) }
    if !dismiss.isHidden { addCursorRect(convert(dismiss.frame, from: fill), cursor: .pointingHand) }
  }

  private static func tint(for kind: KitNoticeKind) -> NSColor {
    switch kind {
    case .info: return SeptaskKitTheme.inkSecondary
    case .actionNeeded: return SeptaskKitTheme.inkPrimary
    case .warning: return SeptaskKitTheme.noticeWarning
    }
  }

  @objc private func firePrimary() { onPrimary?() }
  @objc private func fireDismiss() { onDismiss?() }
}

/// The notice's rounded fill. Drawn in `draw(_:)` so the dynamic colors
/// resolve against the current appearance (light / dark) on every pass.
@MainActor
private final class KitNoticeFill: NSView {
  var kind: KitNoticeKind = .info { didSet { needsDisplay = true } }

  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds,
                            xRadius: KitCardRowView.corner, yRadius: KitCardRowView.corner)
    SeptaskKitTheme.cardSurface.setFill()
    path.fill()
    if kind == .warning {
      SeptaskKitTheme.noticeWarningWash.setFill()
      path.fill()
    }
  }
}

/// One Get started step, drawn as a task row on a card: the task checkbox,
/// then the title with its detail as the dimmed suffix a task row uses for its
/// list name. The checkbox ticks the step by hand; the rest of the row does it
/// (opens the right place). The SwiftUI counterpart is the `steps` rows of
/// `TaskListNotice`.
@MainActor
final class KitNoticeStepCell: NSTableCellView {
  private let checkbox = KitCheckboxView()
  private let title = NSTextField(labelWithString: "")
  private let hit = NSButton()
  private var hitPin: KitContentColumnPin!
  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!
  var onToggle: (() -> Void)?
  var onTap: (() -> Void)?

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    checkbox.translatesAutoresizingMaskIntoConstraints = false
    checkbox.onToggle = { [weak self] in self?.onToggle?() }

    title.translatesAutoresizingMaskIntoConstraints = false
    title.lineBreakMode = .byTruncatingTail
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    title.kitA11yIgnore()

    hit.translatesAutoresizingMaskIntoConstraints = false
    hit.isBordered = false
    hit.isTransparent = true
    hit.title = ""
    hit.setButtonType(.momentaryChange)
    hit.refusesFirstResponder = true
    hit.target = self
    hit.action = #selector(fire)

    addSubview(title)
    // Above the title so it takes clicks on the text; the checkbox stays on
    // top of both so a tick never opens the step.
    addSubview(hit)
    addSubview(checkbox)
    textField = title

    leadingConstraint = checkbox.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: KitCardRowView.horizontalInset + SeptaskKitLayout.rowLeadingPad)
    trailingConstraint = title.trailingAnchor.constraint(
      lessThanOrEqualTo: trailingAnchor, constant: -(KitCardRowView.horizontalInset + 8))
    hitPin = KitContentColumnPin(hit, in: self)
    NSLayoutConstraint.activate([
      leadingConstraint,
      checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
      checkbox.widthAnchor.constraint(equalToConstant: KitCheckboxView.tapSize),
      checkbox.heightAnchor.constraint(equalToConstant: KitCheckboxView.tapSize),
      title.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 7),
      title.centerYAnchor.constraint(equalTo: centerYAnchor),
      trailingConstraint,
      hit.topAnchor.constraint(equalTo: topAnchor),
      hit.bottomAnchor.constraint(equalTo: bottomAnchor),
    ] + hitPin.constraints)
  }

  required init?(coder: NSCoder) { fatalError("KitNoticeStepCell is code-only") }

  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + SeptaskKitLayout.rowLeadingPad
    trailingConstraint.constant = -(inset + 8)
    hitPin.update(width: bounds.width)
    super.layout()
  }

  func configure(_ step: TaskNoticeStep) {
    checkbox.isDone = step.done
    var titleAttributes: [NSAttributedString.Key: Any] = [
      .font: SeptaskKitTheme.taskTitle,
      .foregroundColor: NSColor.labelColor,
    ]
    if step.done {
      titleAttributes[.foregroundColor] = SeptaskKitTheme.inkSecondary
      titleAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
    }
    let text = NSMutableAttributedString(string: step.title, attributes: titleAttributes)
    text.append(NSAttributedString(
      string: "  " + step.detail,
      attributes: [.font: SeptaskKitTheme.meta, .foregroundColor: SeptaskKitTheme.inkSecondary]))
    title.attributedStringValue = text
    hit.isEnabled = !step.done
    kitA11yButton(label: step.title + ", " + step.detail)
  }

  @objc private func fire() { onTap?() }
}
#endif
