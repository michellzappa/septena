#if os(macOS)
import AppKit
import SwiftData

// The Move command's picker (⌘⇧M / Task ▸ Move…, and the row context menu's
// "Move to…") — the AppKit counterpart of SwiftUI's `MovePickerSheet`
// (Septena/Shell/Tasks/TaskPickerSheets.swift). Lists No List, loose
// projects, then each area with its projects nested underneath — type to
// filter, arrows + Return to choose. Same floating-panel shape as
// `SeptaskKitQuickFind`.
@MainActor
final class SeptaskKitMoveModal: NSObject, NSSearchFieldDelegate,
                                 NSTableViewDataSource, NSTableViewDelegate,
                                 NSWindowDelegate {
  private struct Row {
    let title: String
    let destination: KitMoveMenu.Destination
    let emoji: String?
    let indent: Bool
    let projectId: String?
  }

  private let onChoose: (KitMoveMenu.Destination) -> Void
  private let field = NSSearchField()
  private let tableView = NSTableView()
  private var allRows: [Row] = []
  private var rows: [Row] = []
  private var progressByProject: [String: Double] = [:]
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
    reloadProgress()
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

  private func reloadProgress() {
    var done: [String: Int] = [:]
    var total: [String: Int] = [:]
    for task in LocalCache.tasksWithProject(in: context) {
      guard let pid = task.project else { continue }
      switch task.status {
      case .done: done[pid, default: 0] += 1; total[pid, default: 0] += 1
      case .open: total[pid, default: 0] += 1
      case .cancelled: break
      }
    }
    progressByProject = total.reduce(into: [:]) { acc, kv in
      acc[kv.key] = Double(done[kv.key] ?? 0) / Double(kv.value)
    }
  }

  private func reloadRows() {
    let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let snapshot = StructureCache.snapshot(in: context)
    allRows = KitMoveMenu.pickerDestinations(areas: snapshot.areas, projects: snapshot.projects)
      .map { entry in
        Row(title: entry.title, destination: entry.target, emoji: entry.emoji,
            indent: entry.indent, projectId: entry.projectId)
      }
    rows = query.isEmpty ? allRows : Self.filterPickerRows(allRows, query: query)
    tableView.reloadData()
    selectCurrentOrFirst()
  }

  /// SwiftUI `MovePickerSheet` filter: keep No List / loose projects by title;
  /// keep an area if its title matches or any child project matches; keep a
  /// nested project only when its title matches (and emit its parent area
  /// first when needed).
  private static func filterPickerRows(_ all: [Row], query: String) -> [Row] {
    let q = query.lowercased()
    func matches(_ title: String) -> Bool { title.lowercased().contains(q) }

    var result: [Row] = []
    var index = 0
    while index < all.count {
      let row = all[index]
      switch row.destination {
      case .none:
        if matches(row.title) { result.append(row) }
        index += 1
      case .project where !row.indent:
        if matches(row.title) { result.append(row) }
        index += 1
      case .area:
        var children: [Row] = []
        var cursor = index + 1
        while cursor < all.count {
          let next = all[cursor]
          guard case .project = next.destination, next.indent else { break }
          if matches(next.title) { children.append(next) }
          cursor += 1
        }
        if matches(row.title) || !children.isEmpty {
          result.append(row)
          // Area-title match still only lists children whose titles match
          // (SwiftUI `projectsIn` always filters by query).
          result.append(contentsOf: children)
        }
        index = cursor
      case .project:
        index += 1
      }
    }
    return result
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
    let progress = entry.projectId.flatMap { progressByProject[$0] } ?? 0
    cell.configure(destination: entry.destination, emoji: entry.emoji, title: entry.title,
                   indent: entry.indent, progress: progress, checked: checked)
    return cell
  }

  func windowDidResignKey(_ notification: Notification) { dismiss() }

  /// Result row: tray / area emoji-or-folder / project pie, title, trailing
  /// checkmark on the current destination — same anatomy as
  /// `MovePickerSheet`'s row.
  private final class MoveRowCell: NSTableCellView {
    private let icon = NSImageView()
    private let emoji = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let checkmark = NSImageView()
    private var leadingConstraint: NSLayoutConstraint!

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
      leadingConstraint = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16)
      NSLayoutConstraint.activate([
        leadingConstraint,
        icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        icon.widthAnchor.constraint(equalToConstant: 14),
        icon.heightAnchor.constraint(equalToConstant: 14),
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

    func configure(destination: KitMoveMenu.Destination, emoji emojiGlyph: String?,
                   title titleText: String, indent: Bool, progress: Double, checked: Bool) {
      leadingConstraint.constant = indent ? 40 : 16
      switch destination {
      case .none:
        icon.image = NSImage(systemSymbolName: "tray.fill", accessibilityDescription: nil)?
          .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        icon.contentTintColor = SeptaskKitTheme.iconMuted
        icon.isHidden = false
        emoji.isHidden = true
        title.font = SeptaskKitTheme.taskTitle
      case .area:
        if let emojiGlyph {
          emoji.stringValue = emojiGlyph
          emoji.isHidden = false
          icon.isHidden = true
        } else {
          icon.image = KitGlyph.areaDot(diameter: 12)
          icon.contentTintColor = nil
          icon.isHidden = false
          emoji.isHidden = true
        }
        title.font = .systemFont(ofSize: SeptaskKitTheme.taskTitle.pointSize, weight: .semibold)
      case .project:
        icon.image = KitGlyph.progress(progress, tint: SeptaskKitTheme.inkSecondary, diameter: 12)
        icon.contentTintColor = nil
        icon.isHidden = false
        emoji.isHidden = true
        title.font = SeptaskKitTheme.taskTitle
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
