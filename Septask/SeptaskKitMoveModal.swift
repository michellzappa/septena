#if os(macOS)
import AppKit
import SwiftData

// The Move command's picker (⌘⇧M / Task ▸ Move…, and the row context menu's
// "Move to…") — the AppKit counterpart of SwiftUI's `MovePickerSheet`
// (Septena/Shell/Tasks/TaskPickerSheets.swift), cut down to AREAS ONLY: an
// area (or "No List") is a filing DECISION; a specific project is detail a
// user picks once inside the area, not something the Move command should
// offer (see `KitMoveMenu.destinations`'s comment). Same floating-panel,
// type-to-filter, arrow-keys, Return shape as `SeptaskKitQuickFind` — not a
// new UI pattern, the established one for this shell's "type to jump"
// surfaces.
@MainActor
final class SeptaskKitMoveModal: NSObject, NSSearchFieldDelegate,
                                 NSTableViewDataSource, NSTableViewDelegate,
                                 NSWindowDelegate {
  private struct Row {
    let title: String
    let destination: KitMoveMenu.Destination
    /// Fallback SF Symbol — shown only when `emoji` is nil (an area with no
    /// emoji, or the "No List" row).
    let symbol: String
    let emoji: String?
  }

  private let onChoose: (KitMoveMenu.Destination) -> Void
  private let field = NSSearchField()
  private let tableView = NSTableView()
  private var allRows: [Row] = []
  private var rows: [Row] = []
  private var panel: NSPanel?
  /// Marks the checkmark row — nil for a bulk move (no single "current" to
  /// mark, matching `MovePickerSheet.showCurrentSelection`).
  private var currentDestination: KitMoveMenu.Destination?

  private var context: ModelContext { LocalStore.shared.container.mainContext }

  init(onChoose: @escaping (KitMoveMenu.Destination) -> Void) {
    self.onChoose = onChoose
    super.init()
  }

  // MARK: - Presentation

  /// `current` marks the checkmark row; `title` becomes the field's
  /// placeholder ("Move" vs "Move N Tasks", matching `MovePickerSheet`'s
  /// navigation title exactly).
  func show(current: KitMoveMenu.Destination?, title: String) {
    currentDestination = current
    let panel = ensurePanel()
    field.stringValue = ""
    field.placeholderString = title
    reloadRows()
    if let host = NSApp.keyWindow ?? panel.parent {
      // Centered over the window it steers, a little above middle — same
      // placement as Quick Find.
      let frame = host.frame
      let size = panel.frame.size
      panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                   y: frame.midY - size.height / 2 + frame.height * 0.12))
    }
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(field)
  }

  private func dismiss() { panel?.orderOut(nil) }

  private func ensurePanel() -> NSPanel {
    if let panel { return panel }

    let content = NSVisualEffectView()
    content.material = .popover
    content.state = .active
    content.wantsLayer = true
    content.layer?.cornerRadius = 12
    content.layer?.masksToBounds = true

    field.font = .systemFont(ofSize: SeptenaTypeScale.size(.title3))
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.delegate = self
    field.translatesAutoresizingMaskIntoConstraints = false
    field.sendsSearchStringImmediately = true
    field.setAccessibilityTitle(String(localized: "Filter destinations",
                                       comment: "SeptaskKit: move modal search field a11y"))

    let column = NSTableColumn(identifier: .init("moveRow"))
    tableView.addTableColumn(column)
    tableView.headerView = nil
    tableView.style = .plain
    tableView.rowHeight = 34
    tableView.backgroundColor = .clear
    tableView.dataSource = self
    tableView.delegate = self
    tableView.target = self
    tableView.action = #selector(rowClicked)

    let scroll = NSScrollView()
    scroll.documentView = tableView
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.translatesAutoresizingMaskIntoConstraints = false

    content.addSubview(field)
    content.addSubview(scroll)
    NSLayoutConstraint.activate([
      field.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
      field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
      field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
      scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
      scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
    ])

    let panel = MoveModalPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 340),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
    panel.contentView = content
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.delegate = self
    panel.setAccessibilityTitle(String(localized: "Move",
                                       comment: "SeptaskKit: move modal panel a11y title"))
    self.panel = panel
    return panel
  }

  // MARK: - Filtering

  private func reloadRows() {
    let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let snapshot = StructureCache.snapshot(in: context)
    allRows = KitMoveMenu.destinations(areas: snapshot.areas, projects: snapshot.projects)
      .map { entry in
        Row(title: entry.title, destination: entry.target,
           symbol: entry.target == .none ? "tray.fill" : "folder", emoji: entry.emoji)
      }
    rows = query.isEmpty ? allRows : allRows.filter { $0.title.lowercased().contains(query) }
    tableView.reloadData()
    selectCurrentOrFirst()
  }

  private func selectCurrentOrFirst() {
    guard !rows.isEmpty else { return }
    let target = currentDestination.flatMap { current in rows.firstIndex { $0.destination == current } } ?? 0
    tableView.selectRowIndexes([target], byExtendingSelection: false)
    tableView.scrollRowToVisible(target)
  }

  private func move(by delta: Int) {
    guard !rows.isEmpty else { return }
    let next = max(0, min(rows.count - 1, tableView.selectedRow + delta))
    tableView.selectRowIndexes([next], byExtendingSelection: false)
    tableView.scrollRowToVisible(next)
  }

  // MARK: - Choosing

  @objc private func rowClicked() {
    guard tableView.clickedRow >= 0 else { return }
    tableView.selectRowIndexes([tableView.clickedRow], byExtendingSelection: false)
    chooseSelection()
  }

  private func chooseSelection() {
    let row = tableView.selectedRow
    guard rows.indices.contains(row) else { return }
    dismiss()
    onChoose(rows[row].destination)
  }

  // MARK: - Field / table plumbing

  func controlTextDidChange(_ obj: Notification) { reloadRows() }

  func control(_ control: NSControl, textView: NSTextView,
               doCommandBy commandSelector: Selector) -> Bool {
    switch commandSelector {
    case #selector(NSResponder.moveUp(_:)): move(by: -1); return true
    case #selector(NSResponder.moveDown(_:)): move(by: 1); return true
    case #selector(NSResponder.insertNewline(_:)): chooseSelection(); return true
    case #selector(NSResponder.cancelOperation(_:)): dismiss(); return true
    default: return false
    }
  }

  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                 row: Int) -> NSView? {
    let identifier = NSUserInterfaceItemIdentifier("moveRowCell")
    let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? MoveRowCell
      ?? MoveRowCell(identifier: identifier)
    let entry = rows[row]
    let checked = currentDestination.map { $0 == entry.destination } ?? false
    cell.configure(symbol: entry.symbol, emoji: entry.emoji, title: entry.title, checked: checked)
    return cell
  }

  func windowDidResignKey(_ notification: Notification) { dismiss() }

  /// Result row: glyph (or an area's own emoji, swapped in — never both, same
  /// rule `KitScreenTitleCell`/`SidebarCell` follow), title, trailing
  /// checkmark on the current destination — same anatomy as
  /// `MovePickerSheet`'s row.
  private final class MoveRowCell: NSTableCellView {
    private let icon = NSImageView()
    private let emoji = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let checkmark = NSImageView()

    init(identifier: NSUserInterfaceItemIdentifier) {
      super.init(frame: .zero)
      self.identifier = identifier
      icon.translatesAutoresizingMaskIntoConstraints = false
      icon.contentTintColor = SeptaskKitTheme.iconMuted
      emoji.translatesAutoresizingMaskIntoConstraints = false
      emoji.font = .systemFont(ofSize: SeptenaTypeScale.size(.subheadline))
      title.translatesAutoresizingMaskIntoConstraints = false
      title.font = SeptaskKitTheme.taskTitle
      title.lineBreakMode = .byTruncatingTail
      checkmark.translatesAutoresizingMaskIntoConstraints = false
      checkmark.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
      checkmark.contentTintColor = SeptaskKitTheme.inkSecondary
      addSubview(icon)
      addSubview(emoji)
      addSubview(title)
      addSubview(checkmark)
      textField = title
      NSLayoutConstraint.activate([
        icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
        icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        icon.widthAnchor.constraint(equalToConstant: 14),
        emoji.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
        emoji.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
        title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
        title.centerYAnchor.constraint(equalTo: centerYAnchor),
        checkmark.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 10),
        checkmark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        checkmark.centerYAnchor.constraint(equalTo: centerYAnchor),
      ])
    }

    required init?(coder: NSCoder) { fatalError("MoveRowCell is code-only") }

    func configure(symbol: String, emoji emojiGlyph: String?, title titleText: String, checked: Bool) {
      if let emojiGlyph {
        emoji.stringValue = emojiGlyph
        emoji.isHidden = false
        icon.isHidden = true
      } else {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
          .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        icon.isHidden = false
        emoji.isHidden = true
      }
      title.stringValue = titleText
      checkmark.isHidden = !checked
    }
  }
}

/// Borderless panels refuse key status by default; this one must take it so
/// the search field can edit.
private final class MoveModalPanel: NSPanel {
  override var canBecomeKey: Bool { true }
}
#endif
