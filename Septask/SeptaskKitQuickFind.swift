#if os(macOS)
import AppKit
import SwiftData

// Quick Find (⇧⌘F): type to search tasks, projects, and areas; ↑/↓ walk the
// results while the field keeps focus; Return jumps to the item — navigating
// the window to the list that holds it and selecting the row.
//
// A floating panel rather than a sheet, so it never blocks the window it's
// steering, and it reads from the same LocalCache / StructureCache snapshots
// every other surface uses.
@MainActor
final class SeptaskKitQuickFind: NSObject, NSSearchFieldDelegate,
                                 NSTableViewDataSource, NSTableViewDelegate,
                                 NSWindowDelegate {

  /// Where choosing a result should take the window.
  struct Destination {
    let filter: TaskFilter
    /// Non-nil when a specific row should be selected once the list is shown.
    let taskId: String?
  }

  private enum Hit {
    case task(SeptenaTask, subtitle: String)
    case project(Project)
    case area(Area)

    var title: String {
      switch self {
      case .task(let task, _): return task.title
      case .project(let project): return project.title
      case .area(let area): return area.title
      }
    }

    var subtitle: String {
      switch self {
      case .task(_, let subtitle): return subtitle
      case .project: return String(localized: "Project", comment: "SeptaskKit: quick find kind")
      case .area: return String(localized: "Area", comment: "SeptaskKit: quick find kind")
      }
    }

    var symbol: String {
      switch self {
      case .task: return "circle"
      case .project: return "number"
      case .area: return "folder"
      }
    }
  }

  private let onChoose: (Destination) -> Void
  private let field = NSSearchField()
  private let tableView = NSTableView()
  private var hits: [Hit] = []
  private var panel: NSPanel?

  private var context: ModelContext { LocalStore.shared.container.mainContext }

  init(onChoose: @escaping (Destination) -> Void) {
    self.onChoose = onChoose
    super.init()
  }

  // MARK: - Presentation

  func show() {
    let panel = ensurePanel()
    field.stringValue = ""
    reloadHits()
    if let host = NSApp.keyWindow ?? panel.parent {
      // Centered over the window it steers, a little above middle.
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

    field.placeholderString = String(localized: "Search tasks, projects, areas…",
                                     comment: "SeptaskKit: quick find placeholder")
    field.font = .systemFont(ofSize: SeptenaTypeScale.size(.title3))
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.delegate = self
    field.translatesAutoresizingMaskIntoConstraints = false
    field.sendsSearchStringImmediately = true
    field.setAccessibilityTitle(String(localized: "Search",
                                       comment: "SeptaskKit: quick find field a11y title"))

    let column = NSTableColumn(identifier: .init("hit"))
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

    let panel = QuickFindPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
    panel.contentView = content
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.delegate = self
    panel.setAccessibilityTitle(String(localized: "Quick Find",
                                       comment: "SeptaskKit: quick find panel a11y title"))
    self.panel = panel
    return panel
  }

  // MARK: - Search

  private func reloadHits() {
    let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let snapshot = StructureCache.snapshot(in: context)

    // Empty query lists the structure — the panel doubles as a jump-to-list.
    guard !query.isEmpty else {
      hits = snapshot.areas.map(Hit.area) + snapshot.projects.map(Hit.project)
      tableView.reloadData()
      selectFirst()
      return
    }

    let projectTitles = Dictionary(snapshot.projects.map { ($0.id, $0.title) },
                                   uniquingKeysWith: { a, _ in a })
    let areaTitles = Dictionary(snapshot.areas.map { ($0.id, $0.title) },
                                uniquingKeysWith: { a, _ in a })

    var found: [Hit] = []
    found += snapshot.areas.filter { $0.title.lowercased().contains(query) }.map(Hit.area)
    found += snapshot.projects.filter { $0.title.lowercased().contains(query) }.map(Hit.project)
    for task in LocalCache.allTasks(in: context)
    where !task.isHeading && task.title.lowercased().contains(query) {
      let home = task.project.flatMap { projectTitles[$0] }
        ?? task.area.flatMap { areaTitles[$0] }
        ?? (task.today
            ? String(localized: "Today", comment: "Smart list title")
            : String(localized: "Anytime", comment: "Smart list title"))
      let state = task.status == .open
        ? home
        : String(localized: "\(home) · Completed",
                 comment: "SeptaskKit: quick find completed task subtitle")
      found.append(.task(task, subtitle: state))
    }

    hits = Array(found.prefix(60))
    tableView.reloadData()
    selectFirst()
  }

  private func selectFirst() {
    guard !hits.isEmpty else { return }
    tableView.selectRowIndexes([0], byExtendingSelection: false)
    tableView.scrollRowToVisible(0)
  }

  private func move(by delta: Int) {
    guard !hits.isEmpty else { return }
    let next = max(0, min(hits.count - 1, tableView.selectedRow + delta))
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
    guard hits.indices.contains(row) else { return }
    dismiss()

    switch hits[row] {
    case .project(let project):
      onChoose(Destination(filter: .project(project.id), taskId: nil))
    case .area(let area):
      onChoose(Destination(filter: .area(area.id), taskId: nil))
    case .task(let task, _):
      // Show the list that actually contains the task, so the row it selects
      // is visible rather than filtered out.
      let filter: TaskFilter = if let project = task.project {
        .project(project)
      } else if let area = task.area {
        .area(area)
      } else if task.status != .open {
        .logbook
      } else if task.today {
        .today
      } else if task.isInTriageBand {
        .today          // the triage band renders on top of Today
      } else if task.scheduled != nil || task.deadline != nil {
        .upcoming
      } else {
        .unscheduled
      }
      onChoose(Destination(filter: filter, taskId: task.id))
    }
  }

  // MARK: - Field / table plumbing

  func controlTextDidChange(_ obj: Notification) { reloadHits() }

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

  func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                 row: Int) -> NSView? {
    let identifier = NSUserInterfaceItemIdentifier("hitCell")
    let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? HitCell
      ?? HitCell(identifier: identifier)
    let hit = hits[row]
    cell.configure(symbol: hit.symbol, title: hit.title, subtitle: hit.subtitle)
    return cell
  }

  func windowDidResignKey(_ notification: Notification) { dismiss() }

  /// Result row: glyph, title, and where the item lives.
  private final class HitCell: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
      super.init(frame: .zero)
      self.identifier = identifier
      icon.translatesAutoresizingMaskIntoConstraints = false
      icon.contentTintColor = SeptaskKitTheme.iconMuted
      title.translatesAutoresizingMaskIntoConstraints = false
      title.font = SeptaskKitTheme.taskTitle
      title.lineBreakMode = .byTruncatingTail
      subtitle.translatesAutoresizingMaskIntoConstraints = false
      subtitle.font = SeptaskKitTheme.meta
      subtitle.textColor = SeptaskKitTheme.iconMuted
      subtitle.setContentHuggingPriority(.required, for: .horizontal)
      addSubview(icon)
      addSubview(title)
      addSubview(subtitle)
      textField = title
      NSLayoutConstraint.activate([
        icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
        icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        icon.widthAnchor.constraint(equalToConstant: 14),
        title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
        title.centerYAnchor.constraint(equalTo: centerYAnchor),
        subtitle.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 10),
        subtitle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        subtitle.centerYAnchor.constraint(equalTo: centerYAnchor),
      ])
    }

    required init?(coder: NSCoder) { fatalError("HitCell is code-only") }

    func configure(symbol: String, title titleText: String, subtitle subtitleText: String) {
      icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
      title.stringValue = titleText
      subtitle.stringValue = subtitleText
    }
  }
}

/// Borderless panels refuse key status by default; this one must take it so
/// the search field can edit.
private final class QuickFindPanel: NSPanel {
  override var canBecomeKey: Bool { true }
}
#endif
