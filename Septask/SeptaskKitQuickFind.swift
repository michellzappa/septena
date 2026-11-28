#if os(macOS)
import AppKit
import SwiftData

// Command Bar (⌘K, alias ⇧⌘F): type to run contextual task actions, global
// app commands, or jump to any list, project, area, tag, or task. Prefix with
// `>` to filter to commands only. ↑/↓ walk the results while the field keeps
// focus; Return runs the command or jumps to the item.
//
// Command Bar is a TIER 2 surface (see SeptaskKitSurface.swift): it acts across
// the whole app, so there is no single row to hang it off. It is a centered
// `KitFilterSurface` command panel — never a sheet, so it never blocks the
// window it steers — and it reads from the same LocalCache / StructureCache
// snapshots every other surface uses.
@MainActor
final class SeptaskKitQuickFind {

  /// Where choosing a navigation result should take the window.
  struct Destination {
    let filter: TaskFilter
    /// Non-nil when a specific row should be selected once the list is shown.
    let taskId: String?
  }

  /// A registry-backed command runnable from the Command Bar.
  struct Command {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let keywords: [String]
    let isContextual: Bool
    let run: () -> Void
  }

  private enum Hit {
    case command(Command)
    case task(SeptenaTask, subtitle: String)
    case project(Project)
    case area(Area)
    /// A smart list — offered when the query is empty, so the panel doubles
    /// as a jump-to-list.
    case list(TaskFilter, title: String, symbol: String)

    var title: String {
      switch self {
      case .command(let cmd): return cmd.title
      case .task(let task, _): return task.title
      case .project(let project): return project.title
      case .area(let area): return area.title
      case .list(_, let title, _): return title
      }
    }

    var subtitle: String {
      switch self {
      case .command(let cmd): return cmd.subtitle
      case .task(_, let subtitle): return subtitle
      case .project: return TaskFilter.project("").title
      case .area: return TaskFilter.area("").title
      case .list: return String(localized: "List", comment: "SeptaskKit: quick find kind")
      }
    }

    var symbol: String {
      switch self {
      case .command(let cmd): return cmd.symbol
      case .task: return "circle"
      case .project: return "number"
      case .area: return "folder"
      case .list(_, _, let symbol): return symbol
      }
    }
  }

  private let onChoose: (Destination) -> Void
  private let commandsProvider: () -> [Command]
  private var availableCommands: [Command] = []
  private var hits: [Hit] = []

  /// Chrome, keyboard and presentation all live in the shared surface; this
  /// type owns the search, commands, and what a hit means.
  private lazy var surface: KitFilterSurface = {
    let surface = KitFilterSurface(
      size: NSSize(width: 620, height: 420),
      a11yTitle: RegistryActions.title(.appQuickFind),
      fieldA11yTitle: String(localized: "Search",
                             comment: "SeptaskKit: quick find field a11y title"))
    surface.rowCount = { [weak self] in self?.hits.count ?? 0 }
    surface.rowView = { [weak self] row in self?.cell(for: row) }
    surface.onQueryChanged = { [weak self] in self?.reloadHits() }
    surface.onChoose = { [weak self] row in self?.choose(row) }
    return surface
  }()

  private var context: ModelContext { LocalStore.shared.container.mainContext }

  init(
    onChoose: @escaping (Destination) -> Void,
    commandsProvider: @escaping () -> [Command] = { [] }
  ) {
    self.onChoose = onChoose
    self.commandsProvider = commandsProvider
  }

  // MARK: - Presentation

  func show() {
    if surface.isVisible {
      surface.dismiss()
      return
    }
    availableCommands = commandsProvider()
    surface.show(anchor: .window,
                 placeholder: RegistrySurfaces.quickFindCommandPlaceholder)
  }

  // MARK: - Search

  /// Case- and accent-blind containment, so "cafe" finds "Café".
  private static func matches(_ text: String, _ query: String) -> Bool {
    text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
  }

  private static func prefixMatches(_ text: String, _ query: String) -> Bool {
    text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
  }

  /// The smart lists an empty query offers. Inbox has no list of its own —
  /// it is the triage band on top of Today — so it lands on Today.
  private static var emptyQueryLists: [Hit] {
    [
      .list(.today, title: Route.filter(.today).title, symbol: Route.filter(.today).icon),
      .list(.review, title: Route.filter(.review).title, symbol: Route.filter(.review).icon),
      .list(.today, title: TaskFilter.triage.title, symbol: Route.filter(.triage).icon),
      .list(.upcoming, title: Route.filter(.upcoming).title,
            symbol: Route.filter(.upcoming).icon),
      .list(.logbook, title: Route.filter(.logbook).title,
            symbol: Route.filter(.logbook).icon),
    ]
  }

  private func matchingCommands(for query: String) -> [Hit] {
    guard !query.isEmpty else { return availableCommands.map(Hit.command) }
    let tokens = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard !tokens.isEmpty else { return availableCommands.map(Hit.command) }
    var scored: [(command: Command, score: Int, order: Int)] = []
    for (idx, cmd) in availableCommands.enumerated() {
      let haystack = ([cmd.title] + cmd.keywords).joined(separator: " ")
      guard tokens.allSatisfy({ Self.matches(haystack, $0) }) else { continue }
      var score = cmd.isContextual ? 20 : 10
      if Self.prefixMatches(cmd.title, query) { score += 40 }
      else if Self.matches(cmd.title, query) { score += 20 }
      else if cmd.keywords.contains(where: { Self.prefixMatches($0, query) }) { score += 12 }
      scored.append((cmd, score, idx))
    }
    return scored
      .sorted { ($0.score, -$0.order) > ($1.score, -$1.order) }
      .map { .command($0.command) }
  }

  private func reloadHits() {
    let rawQuery = surface.query.trimmingCharacters(in: .whitespaces)
    let commandsOnly = rawQuery.hasPrefix(">")
    let query = commandsOnly
      ? String(rawQuery.dropFirst()).trimmingCharacters(in: .whitespaces)
      : rawQuery

    if commandsOnly {
      hits = Array(matchingCommands(for: query).prefix(60))
      surface.reload()
      surface.select(0)
      return
    }

    let snapshot = StructureCache.snapshot(in: context)
    let liveProjects = snapshot.projects.filter { $0.deletedAt == nil }

    // Empty query offers contextual task commands (when a row is selected),
    // the smart lists, primary global commands, then areas & projects.
    guard !query.isEmpty else {
      let contextual = availableCommands.filter(\.isContextual).prefix(6).map(Hit.command)
      let global = availableCommands.filter { !$0.isContextual }.prefix(6).map(Hit.command)
      hits = Array(contextual)
        + Self.emptyQueryLists
        + Array(global)
        + snapshot.areas.map(Hit.area)
        + liveProjects.map(Hit.project)
      surface.reload()
      surface.select(0)
      return
    }

    let projectTitles = Dictionary(snapshot.projects.map { ($0.id, $0.title) },
                                   uniquingKeysWith: { a, _ in a })
    let areaTitles = Dictionary(snapshot.areas.map { ($0.id, $0.title) },
                                uniquingKeysWith: { a, _ in a })

    func taskHit(_ task: SeptenaTask) -> Hit {
      let home = task.project.flatMap { projectTitles[$0] }
        ?? task.area.flatMap { areaTitles[$0] }
        ?? (task.isOnToday || task.isInTriageBand
            ? TaskFilter.today.title
            : TaskFilter.unscheduled.title)
      let state = task.status == .open
        ? home
        : String(localized: "\(home) · Completed",
                 comment: "SeptaskKit: quick find completed task subtitle")
      return .task(task, subtitle: state)
    }

    var found: [Hit] = []
    found += matchingCommands(for: query)
    found += Self.emptyQueryLists.filter { Self.matches($0.title, query) }
    found += snapshot.areas.filter { Self.matches($0.title, query) }.map(Hit.area)
    found += liveProjects.filter { Self.matches($0.title, query) }.map(Hit.project)
    // Title matches first, then tag matches, then tasks that match only in
    // their notes or their references. Open tasks rank ahead of completed ones inside each band.
    let tagsByID = LocalCache.tagsByID(in: context)
    let strippedTagQuery = query.hasPrefix("#") ? String(query.dropFirst()) : query
    let refTexts = TaskRefLookup.searchTexts(in: context)
    // A pasted link: the tasks that point at the item come first, whatever way
    // the link is spelled there.
    let pointing = TaskRefLookup.taskIDs(forLink: query, in: context) ?? []
    let pointingIDs = Set(pointing)
    var pointingHits: [String: SeptenaTask] = [:]
    var titleHits: [SeptenaTask] = []
    var tagHits: [SeptenaTask] = []
    var notesHits: [SeptenaTask] = []
    // Match on entities and build a row object only for a hit. This runs on
    // every keystroke, and building one per task (logbook included) decoded
    // every task's JSON each time. Same rows as `allTasks` (headings and
    // orphans already excluded).
    for e in LocalCache.liveAggregateEntities(in: context) {
      if pointingIDs.contains(e.id) {
        pointingHits[e.id] = SeptenaTask(e)
      } else if Self.matches(e.title, query) {
        titleHits.append(SeptenaTask(e))
      } else if !strippedTagQuery.isEmpty, e.tagIDsJSON != nil,
                e.tagIDs.compactMap({ tagsByID[$0]?.name }).contains(where: { Self.matches($0, strippedTagQuery) }) {
        tagHits.append(SeptenaTask(e))
      } else if let notes = e.notes, Self.matches(notes, query) {
        notesHits.append(SeptenaTask(e))
      } else if let text = refTexts[e.id], Self.matches(text, query) {
        notesHits.append(SeptenaTask(e))
      }
    }
    let openFirst: (SeptenaTask, SeptenaTask) -> Bool = { a, b in
      (a.status == .open ? 0 : 1) < (b.status == .open ? 0 : 1)
    }
    found += pointing.compactMap { pointingHits[$0] }.sorted(by: openFirst).map(taskHit)
    found += titleHits.sorted(by: openFirst).map(taskHit)
    found += tagHits.sorted(by: openFirst).map { task in
      let names = task.tags.compactMap { tagsByID[$0]?.name }.map { "#\($0)" }.joined(separator: " ")
      let home = task.project.flatMap { projectTitles[$0] }
        ?? task.area.flatMap { areaTitles[$0] }
        ?? (task.isOnToday || task.isInTriageBand
            ? TaskFilter.today.title
            : TaskFilter.unscheduled.title)
      let base = names.isEmpty ? home : "\(names) · \(home)"
      let state = task.status == .open
        ? base
        : String(localized: "\(base) · Completed",
                 comment: "SeptaskKit: quick find completed task subtitle")
      return .task(task, subtitle: state)
    }
    found += notesHits.sorted(by: openFirst).map(taskHit)

    hits = Array(found.prefix(60))
    surface.reload()
    surface.select(0)
  }

  // MARK: - Choosing

  private func choose(_ row: Int) {
    guard hits.indices.contains(row) else { return }

    switch hits[row] {
    case .command(let cmd):
      // Let the panel finish closing and hand key status back to the main
      // window before opening popovers (When, Move, Tags, etc.).
      DispatchQueue.main.async { cmd.run() }
    case .project(let project):
      onChoose(Destination(filter: .project(project.id), taskId: nil))
    case .area(let area):
      onChoose(Destination(filter: .area(area.id), taskId: nil))
    case .list(let filter, _, _):
      onChoose(Destination(filter: filter, taskId: nil))
    case .task(let task, _):
      onChoose(Destination(filter: Self.listShowing(task), taskId: task.id))
    }
  }

  /// The list the task is actually VISIBLE in, so the row the jump selects
  /// exists. Completed and cancelled rows live in the Logbook (a project or
  /// area page folds them away); open rows show on their project / area
  /// page, else Today (the triage band rides on top of it), else Upcoming,
  /// else Anytime.
  private static func listShowing(_ task: SeptenaTask) -> TaskFilter {
    if task.status != .open { return .logbook }
    // A tracked task (ADR 0065) is in Review, not on its project or area page.
    if task.isTracked {
      if task.isOnToday { return .today }
      // The jump selects the row, so its group must be open.
      UserDefaults.standard.set(true, forKey: ReviewGroup.trackedExpandedKey)
      return .review
    }
    if let project = task.project { return .project(project) }
    if let area = task.area { return .area(area) }
    if task.isOnToday || task.isInTriageBand { return .today }
    if task.scheduled != nil || task.deadline != nil { return .upcoming }
    return .unscheduled
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
