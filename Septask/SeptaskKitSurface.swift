#if os(macOS)
import AppKit

// The ONE place the AppKit shell builds a transient surface. Every popover,
// floating panel and filter list in Septask is made here, so chrome (material,
// corner radius, field face, row height) has a single source of truth and
// cannot drift between surfaces the way it did before
// (docs/SEPTASK_APPKIT_SURFACES.md).
//
// THE RULE: scope picks the container, never convenience.
//
//  Tier 1 — anchored popover (`KitPopover`, `KitSurfaceAnchor.rect`).
//    Edits one attribute of one visible row. Anchors to the row or pill that
//    owns it. Transient: click-away closes. There is NO OK button.
//    → When, Deadline, Repeat, Move (single row).
//
//  Tier 2 — centered command panel (`KitSurfacePanel`, `.window`).
//    Acts across the app, or on a selection with no single anchor. Query field
//    over a filtered list. Losing key dismisses. Return commits.
//    → Quick Find, Quick Entry, Move (multi-selection).
//
//  Tier 3 — alert (`KitPrompt`).
//    Irreversible or forked decisions ONLY. Never used to edit a value.
//    → delete confirmations, the reschedule-repeating fork.
//
// Editing a name is none of the three: it happens inline in the row, the way
// Finder renames a file.
//
// TWO commit contracts, tied to the tiers:
//   * pick-commits-and-closes — a surface that answers ONE question
//     (a date, a destination, a search hit).
//   * close-commits — a surface with SEVERAL fields (Repeat, the inspector).
//     Dismissal accepts, like a text field losing focus. Never a per-keystroke
//     write: that would push one CloudKit change per edit.
@MainActor
enum KitSurface {

  // MARK: - Chrome tokens

  /// Corner radius for EVERY floating surface — panel and popover alike.
  /// One number: the shell used to mix 12 and 14 and the surfaces read as
  /// belonging to different apps.
  static let cornerRadius: CGFloat = 12

  /// The glass every floating surface is cut from.
  static let material: NSVisualEffectView.Material = .popover

  /// A surface's query field — the one oversized face in the shell, so a
  /// command panel reads as a command panel at a glance.
  static var fieldFont: NSFont { .systemFont(ofSize: SeptenaTypeScale.size(.title3)) }

  /// Row height for a surface's result list.
  static let listRowHeight: CGFloat = 34

  /// Inset from a surface's edge to its content.
  static let padding: CGFloat = 8

  /// Horizontal inset for a filter surface's field and rows — wider than
  /// `padding` because these rows carry an icon column.
  static let listInset: CGFloat = 16

  /// Genuine vibrancy, not the flat wash a bare `NSView` falls back to.
  /// Every surface's backdrop comes from here.
  static func backdrop(radius: CGFloat = cornerRadius) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = material
    view.state = .active
    view.wantsLayer = true
    view.layer?.cornerRadius = radius
    view.layer?.masksToBounds = true
    return view
  }

  /// A surface's terminal action row — "Clear (Anytime)", "Don't Repeat".
  /// Always last, always after a separator, always the same shape.
  static func separator() -> NSBox {
    let box = NSBox()
    box.boxType = .separator
    return box
  }
}

// MARK: - Anchor

/// Where a transient surface appears — the ONE decision that separates Tier 1
/// from Tier 2. A caller that can name the row it acts on passes `.rect`; a
/// caller acting on many rows, or on the whole app, passes `.window`.
@MainActor
enum KitSurfaceAnchor {
  /// Anchored to a rect in a view. Tier 1.
  case rect(NSRect, NSView)
  /// Centered over the key window, a little above middle. Tier 2.
  case window
}

// MARK: - Panel

/// The shell's floating command panel: borderless, non-activating, key-capable
/// so a field inside it can edit, and self-dismissing when it loses key.
/// Quick Find, Quick Entry and the bulk Move picker are all this class — they
/// used to be three copies of the same eighty lines.
@MainActor
final class KitSurfacePanel: NSPanel {
  /// ⌘Return, which routes through `performKeyEquivalent` rather than the
  /// field editor, so a field delegate cannot see it.
  var onCommandReturn: (() -> Void)?

  override var canBecomeKey: Bool { true }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if let onCommandReturn,
       event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
       event.keyCode == 36 {
      onCommandReturn()
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  /// Build an empty panel wearing the shell's chrome. The caller installs its
  /// body with `install(_:)`; this owns every piece of chrome.
  static func make(size: NSSize, a11yTitle: String) -> KitSurfacePanel {
    let panel = KitSurfacePanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
    panel.contentView = KitSurface.backdrop()
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.setAccessibilityTitle(a11yTitle)
    return panel
  }

  /// Put `body` in the panel, replacing whatever was there. Returns the outer
  /// constraints so a body shared with a popover can be detached again.
  @discardableResult
  func install(_ body: NSView) -> [NSLayoutConstraint] {
    guard let backdrop = contentView else { return [] }
    backdrop.subviews.forEach { $0.removeFromSuperview() }
    body.translatesAutoresizingMaskIntoConstraints = false
    backdrop.addSubview(body)
    let constraints = [
      body.topAnchor.constraint(equalTo: backdrop.topAnchor),
      body.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
      body.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
      body.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
    ]
    NSLayoutConstraint.activate(constraints)
    return constraints
  }

  /// Centered over the window it steers, a little above middle — the placement
  /// every command palette on the platform uses.
  func centerOverKeyWindow() {
    guard let host = NSApp.keyWindow ?? parent else { return }
    let frame = host.frame
    let size = self.frame.size
    setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                           y: frame.midY - size.height / 2 + frame.height * 0.12))
  }
}

// MARK: - Popover

/// The shell's anchored popover. One construction site, so behavior
/// (`.transient`), material and radius match everywhere, and the content's
/// first responder is claimed on appear — without that the popover routes keys
/// nowhere and the surface is mouse-only.
@MainActor
enum KitPopover {
  @discardableResult
  static func present(_ content: NSView,
                      size: NSSize? = nil,
                      relativeTo rect: NSRect,
                      of view: NSView,
                      preferredEdge: NSRectEdge = .maxY,
                      focus: NSView? = nil,
                      handle: KitPopoverHandle? = nil,
                      onClose: (() -> Void)? = nil) -> NSPopover {
    let controller = KitPopoverController(content: content, focus: focus, onClose: onClose)
    if let size { controller.preferredContentSize = size }
    let popover = NSPopover()
    popover.contentViewController = controller
    popover.behavior = .transient
    popover.delegate = controller
    controller.popover = popover
    handle?.popover = popover
    popover.show(relativeTo: rect, of: view, preferredEdge: preferredEdge)
    return popover
  }
}

/// How a popover's own content closes it. The popover retains its controller,
/// which retains the content view, so content that captured the popover
/// STRONGLY would keep the whole chain alive after it closed. This holds it
/// weakly, which is the whole reason the type exists — do not replace it with
/// a captured local.
@MainActor
final class KitPopoverHandle {
  fileprivate weak var popover: NSPopover?
  func close() { popover?.performClose(nil) }
}

/// Hosts a popover's content in the shell's backdrop and reports its close
/// exactly once. `close-commits` surfaces hang their write off `onClose`.
@MainActor
private final class KitPopoverController: NSViewController, NSPopoverDelegate {
  private let content: NSView
  private weak var focus: NSView?
  private let onClose: (() -> Void)?
  private var didClose = false
  weak var popover: NSPopover?

  init(content: NSView, focus: NSView?, onClose: (() -> Void)?) {
    self.content = content
    self.focus = focus
    self.onClose = onClose
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("KitPopoverController is code-only") }

  override func loadView() {
    let backdrop = KitSurface.backdrop()
    content.translatesAutoresizingMaskIntoConstraints = false
    backdrop.addSubview(content)
    NSLayoutConstraint.activate([
      content.topAnchor.constraint(equalTo: backdrop.topAnchor),
      content.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
      content.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
    ])
    view = backdrop
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    if let focus { view.window?.makeFirstResponder(focus) }
  }

  func popoverDidClose(_ notification: Notification) {
    guard !didClose else { return }
    didClose = true
    onClose?()
  }
}

// MARK: - Filter surface

/// A query field over a filtered list — Quick Find and Move, and any surface
/// like them. The SAME body renders in either tier: anchored in a popover when
/// the caller can name the row it acts on, centered in a panel when it cannot.
///
/// It owns the keyboard contract (↑/↓ walk, Return picks, Esc closes) so the
/// shell has ONE, rather than a `doCommandBy` switch copied per surface.
@MainActor
final class KitFilterSurface: NSObject, NSSearchFieldDelegate, NSTableViewDataSource,
                              NSTableViewDelegate, NSWindowDelegate {

  let field = KitSearchField()
  let tableView = NSTableView()

  /// Filled in by the owner — the surface owns presentation and keys, the
  /// owner owns the data.
  var rowCount: () -> Int = { 0 }
  var rowView: (Int) -> NSView? = { _ in nil }
  var onQueryChanged: () -> Void = {}
  var onChoose: (Int) -> Void = { _ in }

  private let body = NSView()
  private let scroll = NSScrollView()
  private let panelSize: NSSize
  private let a11yTitle: String
  private var panel: KitSurfacePanel?
  private weak var popover: NSPopover?
  private var bodyConstraints: [NSLayoutConstraint] = []

  /// `size` is the centered panel's size; an anchored popover uses the same
  /// height and a narrower width so it does not swamp the row it hangs off.
  init(size: NSSize, a11yTitle: String, fieldA11yTitle: String, placeholder: String = "") {
    panelSize = size
    self.a11yTitle = a11yTitle
    super.init()

    // `KitSearchField.applyPanelStyle()` carries the borderless-search-field
    // rect fix (SeptaskKitRowViews.swift) — a plain NSSearchField with
    // `isBordered = false` draws its text on top of the magnifying glass.
    field.applyPanelStyle()
    field.placeholderString = placeholder
    field.delegate = self
    field.translatesAutoresizingMaskIntoConstraints = false
    field.setAccessibilityTitle(fieldA11yTitle)

    tableView.addTableColumn(NSTableColumn(identifier: .init("kitFilterRow")))
    tableView.headerView = nil
    tableView.style = .plain
    tableView.rowHeight = KitSurface.listRowHeight
    tableView.backgroundColor = .clear
    tableView.dataSource = self
    tableView.delegate = self
    tableView.target = self
    tableView.action = #selector(rowClicked)

    scroll.documentView = tableView
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.translatesAutoresizingMaskIntoConstraints = false

    body.translatesAutoresizingMaskIntoConstraints = false
    body.addSubview(field)
    body.addSubview(scroll)
    let inset = KitSurface.listInset
    NSLayoutConstraint.activate([
      field.topAnchor.constraint(equalTo: body.topAnchor, constant: 14),
      field.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: inset),
      field.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -inset),
      scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
      scroll.leadingAnchor.constraint(equalTo: body.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: body.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: body.bottomAnchor),
    ])
  }

  // MARK: Presentation

  /// `placeholder` is the surface's title — a command panel says what it is in
  /// its field, never in a title bar it does not have.
  func show(anchor: KitSurfaceAnchor, placeholder: String) {
    field.placeholderString = placeholder
    field.stringValue = ""
    onQueryChanged()

    switch anchor {
    case .rect(let rect, let view):
      // Close whatever is already showing before the body moves — otherwise a
      // still-open popover is left holding nothing.
      popover?.performClose(nil)
      dismissPanel()
      detachBody()
      let size = NSSize(width: min(panelSize.width, 340), height: panelSize.height)
      popover = KitPopover.present(body, size: size, relativeTo: rect, of: view,
                                   focus: field)
    case .window:
      popover?.performClose(nil)
      detachBody()
      let panel = ensurePanel()
      panel.centerOverKeyWindow()
      panel.makeKeyAndOrderFront(nil)
      panel.makeFirstResponder(field)
    }
  }

  func dismiss() {
    popover?.performClose(nil)
    dismissPanel()
  }

  private func dismissPanel() { panel?.orderOut(nil) }

  /// The body moves between the panel and the popover, so its outer
  /// constraints are rebuilt on each presentation. The inner layout is built
  /// once in `init` and never torn down.
  private func detachBody() {
    NSLayoutConstraint.deactivate(bodyConstraints)
    bodyConstraints = []
    body.removeFromSuperview()
  }

  private func ensurePanel() -> KitSurfacePanel {
    let panel = self.panel ?? {
      let made = KitSurfacePanel.make(size: panelSize, a11yTitle: a11yTitle)
      made.delegate = self
      self.panel = made
      return made
    }()
    bodyConstraints = panel.install(body)
    return panel
  }

  // MARK: List

  func reload() { tableView.reloadData() }

  func select(_ index: Int) {
    guard rowCount() > index, index >= 0 else { return }
    tableView.selectRowIndexes([index], byExtendingSelection: false)
    tableView.scrollRowToVisible(index)
  }

  var selection: Int { tableView.selectedRow }

  var query: String {
    field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func move(by delta: Int) {
    let count = rowCount()
    guard count > 0 else { return }
    select(max(0, min(count - 1, tableView.selectedRow + delta)))
  }

  @objc private func rowClicked() {
    guard tableView.clickedRow >= 0 else { return }
    tableView.selectRowIndexes([tableView.clickedRow], byExtendingSelection: false)
    choose()
  }

  private func choose() {
    let row = tableView.selectedRow
    guard row >= 0, row < rowCount() else { return }
    dismiss()
    onChoose(row)
  }

  // MARK: Keys — the shell's one filter-surface contract

  func controlTextDidChange(_ obj: Notification) { onQueryChanged() }

  func control(_ control: NSControl, textView: NSTextView,
               doCommandBy commandSelector: Selector) -> Bool {
    switch commandSelector {
    case #selector(NSResponder.moveUp(_:)): move(by: -1); return true
    case #selector(NSResponder.moveDown(_:)): move(by: 1); return true
    case #selector(NSResponder.insertNewline(_:)): choose(); return true
    case #selector(NSResponder.cancelOperation(_:)): dismiss(); return true
    default: return false
    }
  }

  func numberOfRows(in tableView: NSTableView) -> Int { rowCount() }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                 row: Int) -> NSView? {
    rowView(row)
  }

  func windowDidResignKey(_ notification: Notification) { dismissPanel() }
}

// MARK: - Single-line title fields

extension NSTextField {

  /// Flatten a pasted multi-line string as it lands, so a title field can only
  /// ever hold one line.
  ///
  /// AppKit's field editor ends editing on a typed Return, but it accepts a
  /// PASTED line break as ordinary text: the string keeps the breaks, the cell
  /// clips at the first one, and the row (laid out for exactly one line) shows
  /// a title that doesn't match what was pasted. Every title field calls this
  /// from `controlTextDidChange`; `TaskTitleText.singleLine` joins the lines
  /// with one space so the words don't fuse.
  ///
  /// The caret lands at the end — a paste puts it there anyway, and the field
  /// editor's offsets are stale once the text is rewritten.
  func septaskFlattenPastedLineBreaks() {
    let editor = currentEditor()
    let raw = editor?.string ?? stringValue
    guard raw.contains(where: \.isNewline) else { return }
    let flat = TaskTitleText.singleLine(raw)
    guard let editor else { stringValue = flat; return }
    // Rewriting the text drops the run attributes the rename path installed on
    // the field editor (the row's own face), so re-assert them over the whole
    // string — otherwise a paste changes the title's font mid-edit.
    let attributes = (editor as? NSTextView)?.typingAttributes
    editor.string = flat
    if let attributes, let storage = (editor as? NSTextView)?.textStorage {
      storage.setAttributes(attributes,
                            range: NSRange(location: 0, length: storage.length))
    }
    editor.selectedRange = NSRange(location: (flat as NSString).length, length: 0)
  }
}
#endif
