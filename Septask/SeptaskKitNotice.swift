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
// The fill is the card surface. Only a warning tints it, with a light wash.
// A notice without steps is a selectable row (↑/↓ reach it, ⌘K dismisses it,
// Return does its action). Selected, its fill takes the list's ONE selection
// wash (`listSelectionFill`), the same token a task row draws.

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
  /// True when checklist rows (`KitNoticeStepCell`) follow immediately on the
  /// same card: `KitCardRowView` owns the unified card backdrop and this cell
  /// drops its bottom gap so the header joins directly onto row 1.
  var headsCard: Bool = false
}

extension KitNotice {
  /// The AppKit drawing of a shared notice (`TaskNotices`).
  init(_ notice: TaskNotice) {
    self.init(kind: notice.kind, symbol: notice.symbol, title: notice.title,
              detail: notice.detail, primaryTitle: notice.primaryTitle,
              dismissible: notice.dismissible, headsCard: !notice.steps.isEmpty)
  }
}

@MainActor
final class KitNoticeCell: NSTableCellView, KitSelfSelectingCell {
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
    // The title reads like a task title (same font), the detail like a
    // task's meta line.
    let title = lineHeight(SeptaskKitTheme.taskTitle)
    let text = notice.detail == nil ? title : title + lineHeight(SeptaskKitTheme.meta) + 1
    let control: CGFloat = notice.primaryTitle == nil ? 16 : 22
    let gap: CGFloat = notice.headsCard ? 0 : bottomGap
    // A one-line notice is exactly a task row tall, button or not, so every
    // notice matches the rows under it. Only a detail line makes it taller.
    // The small push button (22pt) still fits a task row with room to spare;
    // its content centers vertically.
    guard notice.detail != nil else { return SeptaskKitTheme.rowHeight + gap }
    let content = ceil(max(text, control)) + verticalPad * 2
    return max(content, SeptaskKitTheme.rowHeight) + gap
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
  private var fillBottom: NSLayoutConstraint!
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

    titleLabel.font = SeptaskKitTheme.taskTitle
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
    let closeLabel = RegistryNotices.dismissTitle
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
    fillBottom = fill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.bottomGap)
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
      fillBottom,
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
    fill.drawsSurface = !notice.headsCard
    fillBottom.constant = notice.headsCard ? 0 : -Self.bottomGap
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

  func rowNeedsRepaint() { fill.refreshAppearance() }

  @objc private func firePrimary() { onPrimary?() }
  @objc private func fireDismiss() { onDismiss?() }
}

/// The notice's rounded fill. Uses the exact same frosted `NSVisualEffectView`
/// + translucent `cardSurface` veil + top specular rim recipe (`KitCardGlassStyle`)
/// as `KitCardRowView` when a Header Wash texture is active, falling back to
/// solid `cardSurface` when no texture is set or Reduce Transparency is enabled.
/// When `drawsSurface == false` (a checklist notice heading a `KitCardRowView`
/// card run), `KitCardRowView` paints the unified card backdrop instead.
@MainActor
final class KitNoticeFill: NSView {
  var kind: KitNoticeKind = .info { didSet { syncGlass(); needsDisplay = true } }
  var drawsSurface: Bool = true { didSet { syncGlass(); needsDisplay = true } }

  private let effectView: KitPassthroughVisualEffectView = {
    let v = KitCardGlassStyle.makeBackdrop()
    v.layer?.mask = CAShapeLayer()
    return v
  }()
  private let overlayView = KitNoticeGlassOverlayView()

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    addSubview(effectView)
    addSubview(overlayView, positioned: .above, relativeTo: effectView)
    syncGlass()
  }

  required init?(coder: NSCoder) { fatalError("KitNoticeFill is code-only") }

  func refreshAppearance() {
    syncGlass()
    needsDisplay = true
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    syncGlass()
    needsDisplay = true
  }

  override func layout() {
    super.layout()
    syncGlass()
  }

  /// The enclosing row's selection, read at draw time so it cannot go stale
  /// on a recycled cell. Nil when the row is not selected.
  fileprivate var selectionFill: NSColor? {
    var view = superview
    while let current = view, !(current is NSTableRowView) { view = current.superview }
    guard drawsSurface, let row = view as? NSTableRowView, row.isSelected else { return nil }
    return SeptaskKitTheme.listSelectionFill(emphasized: row.septaskSelectionIsActive)
  }

  private var usesGlass: Bool {
    AppearancePreferences.shared.hasActiveTexture
      && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
  }

  private func syncGlass() {
    let active = drawsSurface && usesGlass
    effectView.isHidden = !active
    overlayView.isHidden = !active
    guard active, bounds.width > 1, bounds.height > 1 else { return }

    effectView.frame = bounds
    let local = NSRect(origin: .zero, size: bounds.size)
    let maskPath = NSBezierPath(roundedRect: local,
                                xRadius: KitCardRowView.corner,
                                yRadius: KitCardRowView.corner)
    if let mask = effectView.layer?.mask as? CAShapeLayer {
      mask.frame = local
      mask.path = maskPath.cgPath
    }

    overlayView.frame = bounds
    overlayView.kind = kind
    overlayView.selectionFill = selectionFill
    overlayView.needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    guard drawsSurface, !usesGlass else { return }
    let path = NSBezierPath(roundedRect: bounds,
                            xRadius: KitCardRowView.corner, yRadius: KitCardRowView.corner)
    SeptaskKitTheme.cardSurface.setFill()
    path.fill()
    if kind == .warning {
      SeptaskKitTheme.noticeWarningWash.setFill()
      path.fill()
    }
    if let selectionFill {
      selectionFill.setFill()
      path.fill()
    }
  }
}

/// Translucent card veil, optional warning wash, and top specular rim drawn on
/// top of `KitNoticeFill`'s frosted `NSVisualEffectView` — identical to
/// `KitCardGlassOverlayView` so standalone notices and task cards share one
/// unified material language.
@MainActor
private final class KitNoticeGlassOverlayView: NSView {
  var kind: KitNoticeKind = .info
  var selectionFill: NSColor?

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds,
                            xRadius: KitCardRowView.corner, yRadius: KitCardRowView.corner)
    let isDark = KitCardGlassStyle.isDark(effectiveAppearance)
    NSGraphicsContext.saveGraphicsState()
    KitCardGlassStyle.veilColor(isDark: isDark).setFill()
    path.fill()
    if kind == .warning {
      SeptaskKitTheme.noticeWarningWash.setFill()
      path.fill()
    }
    if let selectionFill {
      selectionFill.setFill()
      path.fill()
    }
    path.addClip()
    let rim = NSRect(x: bounds.minX, y: bounds.minY,
                     width: bounds.width, height: KitCardGlassStyle.topRimHeight)
    KitCardGlassStyle.topRimColor(isDark: isDark).setFill()
    rim.fill()
    NSGraphicsContext.restoreGraphicsState()
  }
}

/// One Get started step, drawn as a task row on a card: the task checkbox,
/// then the title with its detail as the dimmed suffix a task row uses for its
/// list name. It is a real row of the table: a click selects it, ↑/↓ reach
/// it, Return or a double-click does the step and ⌘K ticks it (all wired by
/// the controller, as for a task row). The checkbox ticks the step by hand.
/// The SwiftUI counterpart is `TaskNoticeStepRow`.
@MainActor
final class KitNoticeStepCell: NSTableCellView {
  private let checkbox = KitCheckboxView()
  private let title = NSTextField(labelWithString: "")
  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!
  var onToggle: (() -> Void)?

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    checkbox.translatesAutoresizingMaskIntoConstraints = false
    checkbox.onToggle = { [weak self] in self?.onToggle?() }

    title.translatesAutoresizingMaskIntoConstraints = false
    title.lineBreakMode = .byTruncatingTail
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    title.kitA11yIgnore()

    addSubview(title)
    addSubview(checkbox)
    textField = title

    leadingConstraint = checkbox.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: KitCardRowView.horizontalInset + SeptaskKitLayout.rowLeadingPad)
    trailingConstraint = title.trailingAnchor.constraint(
      lessThanOrEqualTo: trailingAnchor, constant: -(KitCardRowView.horizontalInset + 8))
    NSLayoutConstraint.activate([
      leadingConstraint,
      checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
      checkbox.widthAnchor.constraint(equalToConstant: KitCheckboxView.tapSize),
      checkbox.heightAnchor.constraint(equalToConstant: KitCheckboxView.tapSize),
      title.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 7),
      title.centerYAnchor.constraint(equalTo: centerYAnchor),
      trailingConstraint,
    ])
  }

  required init?(coder: NSCoder) { fatalError("KitNoticeStepCell is code-only") }

  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + SeptaskKitLayout.rowLeadingPad
    trailingConstraint.constant = -(inset + 8)
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
    // Read like a task row: a group named by its title, the checkbox inside
    // it carries the done state.
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel(step.title + ", " + step.detail)
    setAccessibilityRoleDescription(nil)
  }
}
#endif
