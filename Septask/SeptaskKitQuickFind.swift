#if os(macOS)
import AppKit
import SwiftData

// Quick Find (⇧⌘F): type to search tasks, projects, and areas; ↑/↓ walk the
// results while the field keeps focus; Return jumps to the item — navigating
// the window to the list that holds it and selecting the row.
//
// Quick Find is a TIER 2 surface (see SeptaskKitSurface.swift): it searches
// the whole app, so there is no single row to hang it off. It is a centered
// `KitFilterSurface` command panel — never a sheet, so it never blocks the
// window it steers — and it reads from the same LocalCache / StructureCache
// snapshots every other surface uses.
@MainActor
final class SeptaskKitQuickFind {

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
  private var hits: [Hit] = []

  /// Chrome, keyboard and presentation all live in the shared surface; this
  /// type owns the search and what a hit means.
  private lazy var surface: KitFilterSurface = {
    let surface = KitFilterSurface(
      size: NSSize(width: 620, height: 380),
      a11yTitle: String(localized: "Quick Find",
                        comment: "SeptaskKit: quick find panel a11y title"),
      fieldA11yTitle: String(localized: "Search",
                             comment: "SeptaskKit: quick find field a11y title"))
    surface.rowCount = { [weak self] in self?.hits.count ?? 0 }
    surface.rowView = { [weak self] row in self?.cell(for: row) }
    surface.onQueryChanged = { [weak self] in self?.reloadHits() }
    surface.onChoose = { [weak self] row in self?.choose(row) }
    return surface
  }()

  private var context: ModelContext { LocalStore.shared.container.mainContext }

  init(onChoose: @escaping (Destination) -> Void) {
    self.onChoose = onChoose
  }

  // MARK: - Presentation

  func show() {
    surface.show(anchor: .window,
                 placeholder: String(localized: "Search tasks, projects, areas…",
                                     comment: "SeptaskKit: quick find placeholder"))
  }

  // MARK: - Search

  private func reloadHits() {
    let query = surface.query.lowercased()
    let snapshot = StructureCache.snapshot(in: context)

    // Empty query lists the structure — the panel doubles as a jump-to-list.
    guard !query.isEmpty else {
      hits = snapshot.areas.map(Hit.area) + snapshot.projects.map(Hit.project)
      surface.reload()
      surface.select(0)
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
    surface.reload()
    surface.select(0)
  }

  // MARK: - Choosing

  private func choose(_ row: Int) {
    guard hits.indices.contains(row) else { return }

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

  private func cell(for row: Int) -> NSView? {
    guard hits.indices.contains(row) else { return nil }
    let identifier = NSUserInterfaceItemIdentifier("hitCell")
    let cell = surface.tableView.makeView(withIdentifier: identifier, owner: nil) as? HitCell
      ?? HitCell(identifier: identifier)
    let hit = hits[row]
    cell.configure(symbol: hit.symbol, title: hit.title, subtitle: hit.subtitle)
    return cell
  }

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
        icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: KitSurface.listInset),
        icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        icon.widthAnchor.constraint(equalToConstant: 14),
        title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
        title.centerYAnchor.constraint(equalTo: centerYAnchor),
        subtitle.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 10),
        subtitle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -KitSurface.listInset),
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
#endif
