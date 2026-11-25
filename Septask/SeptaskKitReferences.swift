#if os(macOS)
import AppKit
import SwiftData

// Task references in the AppKit shell (docs/TASK_REFERENCES_SPEC.md §8): the
// References block of the inspector and the composer, and the Add Reference popover. The rows
// and the gestures are shared with the SwiftUI shell (`TaskRefRows`,
// `TaskRefActions`).

// MARK: - Block

/// The rows of one task's references. The host hides the block when it is empty.
@MainActor
final class KitReferencesView: NSView {
  /// `rows` in the inspector; `chips` in the composer, drawn as its attachments are.
  enum Style { case rows, chips }

  private let style: Style
  private let stack = NSStackView()
  private var rows: [TaskRefRow] = []
  var isEmpty: Bool { rows.isEmpty }
  /// The rows' height, for a host that computes its own (the composer).
  var preferredHeight: CGFloat { rows.isEmpty ? 0 : ceil(stack.fittingSize.height) }

  init(style: Style = .rows) {
    self.style = style
    super.init(frame: .zero)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = style == .chips ? 4 : 2
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("KitReferencesView is code-only") }

  func configure(rows next: [TaskRefRow]) {
    guard next != rows else { return }
    rows = next
    stack.kitReplaceArrangedSubviews(with: rows.map { KitReferenceRowView(row: $0, isChip: style == .chips) },
                                     fillsWidth: style == .rows)
  }
}

/// Kind icon, title, subtitle. A click opens the item; the context menu is the
/// registry's `task.reference`.
@MainActor
private final class KitReferenceRowView: NSView {
  private let row: TaskRefRow
  private let isInteractive: Bool
  /// Takes the clicks. In the composer the row sits in an `NSTableView`, which
  /// claims clicks on labels and images, so only a real `NSControl` gets them.
  private let hit = KitReferenceHitButton()

  /// `isHighlighted` marks the row of a key that the task has already.
  init(row: TaskRefRow, isInteractive: Bool = true, isHighlighted: Bool = false,
       isChip: Bool = false) {
    self.row = row
    self.isInteractive = isInteractive
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    if isHighlighted {
      wantsLayer = true
      layer?.cornerRadius = 6
      layer?.backgroundColor = SeptaskKitTheme.listSelectionFill(emphasized: true).cgColor
    }

    if isChip {
      wantsLayer = true
      layer?.cornerRadius = 6
      layer?.borderWidth = 0.75
      layer?.borderColor = NSColor.secondaryLabelColor.withAlphaComponent(0.25).cgColor
    }

    let icon = NSImageView()
    icon.image = NSImage(systemSymbolName: row.sfSymbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
    icon.contentTintColor = SeptaskKitTheme.inkSecondary
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.kitA11yIgnore()

    let title = NSTextField(labelWithString: row.title)
    title.font = SeptaskKitTheme.meta
    title.textColor = .labelColor
    let labels = NSStackView(views: [title])
    if let subtitle = row.subtitle {
      let detail = NSTextField(labelWithString: subtitle)
      detail.font = SeptaskKitTheme.chip
      detail.textColor = SeptaskKitTheme.inkSecondary
      labels.addArrangedSubview(detail)
    }
    for case let label as NSTextField in labels.arrangedSubviews {
      label.lineBreakMode = .byTruncatingMiddle
      label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    labels.orientation = isChip ? .horizontal : .vertical
    labels.alignment = isChip ? .firstBaseline : .leading
    labels.spacing = isChip ? 6 : 1
    labels.translatesAutoresizingMaskIntoConstraints = false

    addSubview(icon)
    addSubview(labels)
    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
      icon.centerYAnchor.constraint(equalTo: centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 18),
      labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
      isChip ? labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        : labels.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
      labels.topAnchor.constraint(equalTo: topAnchor, constant: 3),
      labels.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
    ])

    if isInteractive {
      hit.target = self
      hit.action = #selector(openRow)
      hit.menuProvider = { [weak self] in self?.rowMenu() }
      addSubview(hit)
      NSLayoutConstraint.activate([
        hit.topAnchor.constraint(equalTo: topAnchor),
        hit.bottomAnchor.constraint(equalTo: bottomAnchor),
        hit.leadingAnchor.constraint(equalTo: leadingAnchor),
        hit.trailingAnchor.constraint(equalTo: trailingAnchor),
      ])
    }

    setAccessibilityElement(true)
    setAccessibilityRole(isInteractive && row.target != nil ? .button : .staticText)
    setAccessibilityLabel([row.title, row.subtitle].compactMap { $0 }.joined(separator: ", "))
  }

  required init?(coder: NSCoder) { fatalError("KitReferenceRowView is code-only") }

  @objc private func openRow() { TaskRefActions.open(row, navigation: nil) }

  override func resetCursorRects() {
    if isInteractive, row.target != nil { addCursorRect(bounds, cursor: .pointingHand) }
  }

  private func rowMenu() -> NSMenu? {
    KitRegistryMenu.build(RegistryActions.menu(.taskReference),
                          bind: { TaskRefActions.bind($0, row: self.row, navigation: nil) })
  }

  override func accessibilityPerformPress() -> Bool {
    guard isInteractive, row.target != nil else { return false }
    TaskRefActions.open(row, navigation: nil)
    return true
  }
}

/// The transparent click target over one reference row.
@MainActor
private final class KitReferenceHitButton: NSButton {
  var menuProvider: (() -> NSMenu?)?

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    isBordered = false
    isTransparent = true
    title = ""
    setButtonType(.momentaryChange)
    refusesFirstResponder = true
    kitA11yIgnore()
  }

  required init?(coder: NSCoder) { fatalError("KitReferenceHitButton is code-only") }

  override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}

private extension NSStackView {
  /// Rows in place of what the stack showed: full width, or no wider than it.
  func kitReplaceArrangedSubviews(with views: [NSView], fillsWidth: Bool = true) {
    for view in arrangedSubviews {
      removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    for view in views {
      addArrangedSubview(view)
      let inset = -edgeInsets.left - edgeInsets.right
      (fillsWidth ? view.widthAnchor.constraint(equalTo: widthAnchor, constant: inset)
        : view.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: inset)).isActive = true
    }
  }
}

// MARK: - Add Reference

/// Paste a link, or take one that is in the task's title or notes already
/// (the AppKit `AddReferenceSheet`).
@MainActor
enum SeptaskKitAddReferencePopover {
  static func present(taskID: String, relativeTo rect: NSRect, of view: NSView) {
    let handle = KitPopoverHandle()
    let board = KitAddReferenceBoard(taskID: taskID, onClose: { handle.close() })
    board.popover = KitPopover.present(board, size: board.fittingSize, relativeTo: rect, of: view,
                                       focus: board.field, handle: handle)
  }
}

@MainActor
private final class KitAddReferenceBoard: NSView, NSTextFieldDelegate {
  private static let width: CGFloat = 340
  /// More rows than this would push the popover off a small screen.
  private static let maxListed = 8

  let field = NSTextField()
  weak var popover: NSPopover?

  private let taskID: String
  private let onClose: () -> Void
  private let messageLabel = NSTextField(wrappingLabelWithString: "")
  private let lists = NSStackView()
  private let stack = NSStackView()
  private var offers: [TaskRefRows.Offer] = []
  private var rows: [TaskRefRow] = []
  private var highlightedID: String?

  init(taskID: String, onClose: @escaping () -> Void) {
    self.taskID = taskID
    self.onClose = onClose
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    let heading = NSTextField(labelWithString: RegistryActions.title(.taskAddReference, .short))
    heading.font = SeptaskKitTheme.chip
    heading.textColor = SeptaskKitTheme.inkSecondary

    field.placeholderString = RegistryTaskReferences.addPlaceholder
    field.font = SeptaskKitTheme.taskTitle
    field.bezelStyle = .roundedBezel
    field.delegate = self
    field.target = self
    field.action = #selector(submit)
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false

    let add = NSButton(title: RegistryTaskReferences.addConfirmTitle, target: self,
                       action: #selector(submit))
    add.bezelStyle = .rounded
    let entry = NSStackView(views: [field, add])
    entry.orientation = .horizontal
    entry.spacing = 6

    messageLabel.font = SeptaskKitTheme.chip
    messageLabel.textColor = SeptaskKitTheme.overdueRed
    messageLabel.isHidden = true

    lists.orientation = .vertical
    lists.alignment = .leading
    lists.spacing = 4

    stack.setViews([heading, entry, messageLabel, lists], in: .leading)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    let contentWidth = Self.width - 24
    messageLabel.preferredMaxLayoutWidth = contentWidth
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
      widthAnchor.constraint(equalToConstant: Self.width),
      entry.widthAnchor.constraint(equalToConstant: contentWidth),
      lists.widthAnchor.constraint(equalToConstant: contentWidth),
    ])
    reload()
  }

  required init?(coder: NSCoder) { fatalError("KitAddReferenceBoard is code-only") }

  // MARK: Content

  private func reload() {
    let context = LocalStore.shared.container.mainContext
    rows = LocalCache.taskRefRows(forTaskID: taskID, in: context)
    let task = LocalCache.task(id: taskID, in: context)
    offers = TaskRefRows.offers(title: task?.title ?? "", notes: task?.notes,
                                existing: rows.flatMap(\.refs))
    rebuild()
  }

  private func rebuild() {
    var views: [NSView] = []
    if !offers.isEmpty {
      views.append(listHeading(RegistryTaskReferences.offersTitle))
      for (index, offer) in offers.prefix(Self.maxListed).enumerated() {
        views.append(offerButton(offer, index: index))
      }
    }
    if !rows.isEmpty {
      views.append(listHeading(RegistrySurfaces.taskPageBlock(.references).label ?? ""))
      // The highlighted row always shows.
      var shown = Array(rows.prefix(Self.maxListed))
      if let hit = rows.first(where: { $0.id == highlightedID }), !shown.contains(hit) {
        shown[shown.count - 1] = hit
      }
      views += shown.map {
        KitReferenceRowView(row: $0, isInteractive: false, isHighlighted: $0.id == highlightedID)
      }
    }
    lists.kitReplaceArrangedSubviews(with: views)
    lists.isHidden = views.isEmpty
    layoutSubtreeIfNeeded()
    popover?.contentSize = fittingSize
  }

  private func listHeading(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = SeptaskKitTheme.chip
    label.textColor = SeptaskKitTheme.iconMuted
    return label
  }

  private func offerButton(_ offer: TaskRefRows.Offer, index: Int) -> NSButton {
    let button = NSButton(title: offer.title, target: self, action: #selector(takeOffer(_:)))
    button.tag = index
    button.bezelStyle = .rounded
    button.alignment = .left
    button.image = NSImage(systemSymbolName: offer.sfSymbol, accessibilityDescription: nil)
    button.imagePosition = .imageLeading
    button.lineBreakMode = .byTruncatingMiddle
    button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    button.toolTip = offer.input
    return button
  }

  // MARK: Adding

  @objc private func submit() {
    let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    if add(text) { onClose() }
  }

  @objc private func takeOffer(_ sender: NSButton) {
    guard offers.indices.contains(sender.tag) else { return }
    if add(offers[sender.tag].input) { reload() }
  }

  /// True when the reference is new.
  private func add(_ input: String) -> Bool {
    let result = TaskRefActions.add(input, to: taskID)
    show(message: TaskRefActions.message(for: result))
    switch result {
    case .added:
      highlightedID = nil
      return true
    case .existing(let ref):
      highlightedID = rows.first { $0.contains(ref) }?.id
    default:
      highlightedID = nil
    }
    rebuild()
    return false
  }

  private func show(message: String?) {
    messageLabel.stringValue = message ?? ""
    messageLabel.isHidden = message == nil
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
    onClose()
    return true
  }

  func controlTextDidChange(_ obj: Notification) {
    guard !messageLabel.isHidden || highlightedID != nil else { return }
    show(message: nil)
    highlightedID = nil
    rebuild()
  }
}
#endif
