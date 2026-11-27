#if os(macOS)
import AppKit
import SwiftData

private extension Int {
  /// `0 → nil` — the sidebar's convention for "count present but empty",
  /// same as the hand-written ternaries the other counts already used.
  var nilIfZero: Int? { self > 0 ? self : nil }
}

// The shell's source-list sidebar (see SeptaskKitWindow.swift for scope).
// Reads the same ordered structure snapshot the SwiftUI sidebar uses
// (StructureCache), rendered as a native NSOutlineView: fixed views up top,
// then areas (selectable, expandable) with their projects nested and loose
// projects alongside. Selection drives the detail pane via `onSelect`.
//
// Things-style layout, deliberately un-Finder-like: NO section header rows
// ("Views" / "Areas & Projects"), NO per-level indentation — a project sits
// in the same left column as an area, distinguished only by nesting/order,
// not by an indent step. That means the built-in disclosure triangle (which
// lives IN the indentation column) has nowhere natural to draw, so it's
// suppressed and replaced with a custom chevron on the row's trailing edge,
// left of the count badge.

/// Where the sidebar points the detail pane. Every destination is a task
/// list. (Septask's Next page was removed on 2026-11-19: it showed life-OS
/// content, not tasks.)
enum KitSidebarDestination: Equatable {
  case filter(TaskFilter, title: String)

  /// The AppKit shell's smart-list destinations, in the account's configured
  /// order — read from `TaskDestinations.sidebarRoutes(in:nonEmptyIDs:)`, which
  /// reads `SmartListPreferences.shared` over `registry/destinations.json`.
  @MainActor static func smartLists(in section: SmartListSection,
                                    nonEmptyIDs: Set<RegistryDestinationID>) -> [KitSidebarDestination] {
    TaskDestinations.sidebarRoutes(in: section, nonEmptyIDs: nonEmptyIDs)
      .compactMap(KitSidebarDestination.init(route:))
  }

  @MainActor static func smartLists(in section: SmartListSection,
                                    context: ModelContext) -> [KitSidebarDestination] {
    TaskDestinations.sidebarRoutes(in: section, context: context)
      .compactMap(KitSidebarDestination.init(route:))
  }

  @MainActor static func smartLists(nonEmptyIDs: Set<RegistryDestinationID>) -> [KitSidebarDestination] {
    TaskDestinations.sidebarRoutes(nonEmptyIDs: nonEmptyIDs).compactMap(KitSidebarDestination.init(route:))
  }

  @MainActor static func smartLists(in context: ModelContext) -> [KitSidebarDestination] {
    TaskDestinations.sidebarRoutes(in: context).compactMap(KitSidebarDestination.init(route:))
  }

  @MainActor static var smartLists: [KitSidebarDestination] {
    smartLists(nonEmptyIDs: [])
  }

  /// Bridge from the shared `Route` vocabulary. Areas / projects carry only an
  /// id in a `Route`, so they resolve at their own call sites (which hold the
  /// live record) and return nil here.
  init?(route: Route) {
    switch route {
    case .filter(let f):   self = .filter(f, title: route.title)
    // Septask has no Next destination; Septena's `Route.next` maps to nothing.
    case .next, .area, .project:  return nil
    }
  }

  /// SF Symbol for the row / menu item — off `Route`, so an icon change lands
  /// on every surface at once.
  var symbol: String {
    switch self {
    case .filter(let f, _): return Route.filter(f).icon
    }
  }

  var title: String {
    switch self {
    case .filter(_, let title): return title
    }
  }

  /// The shared `Route` this destination points at — the vocabulary the
  /// SwiftUI page titles and dropdowns speak.
  var route: Route {
    switch self {
    case .filter(let filter, _):
      switch filter {
      case .area(let id):    return .area(id: id)
      case .project(let id): return .project(id: id)
      default:               return .filter(filter)
      }
    }
  }

  /// Stable selection key — the one the sidebar's `Node.key` and its
  /// `select(_:)` lookup both speak.
  var key: String { Self.key(for: route) }

  /// The same key straight off a `Route`, for callers that only have one. A
  /// `Route` carries no title for an area or
  /// project, and none is needed: the lookup is by key, and the row that gets
  /// selected re-emits its own real title.
  static func key(for route: Route) -> String {
    switch route {
    // No sidebar row has this key, so a lookup by it (e.g. a restored
    // "next" from before Next was removed) finds nothing and falls back.
    case .next:            return "next"
    case .filter(let f):   return "filter:\(f.navigationKey)"
    case .area(let id):    return "area:\(id)"
    case .project(let id): return "project:\(id)"
    }
  }
}

@MainActor
final class SeptaskKitSidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {

  /// Reference type on purpose — NSOutlineView tracks items by identity.
  final class Node {
    enum Content {
      case filter(TaskFilter, title: String, symbol: String)
      case area(Area)
      /// `progress` drives the completion ring, matching `ProjectProgressIcon`.
      case project(Project, progress: Double)
    }
    let content: Content
    var children: [Node]
    /// Open-task count shown as a quiet trailing badge; nil hides it.
    var count: Int?
    init(_ content: Content, children: [Node] = [], count: Int? = nil) {
      self.content = content
      self.children = children
      self.count = count
    }

    /// Stable key so selection survives a structure reload.
    var key: String {
      switch content {
      case .filter(let filter, _, _): return "filter:\(filter.navigationKey)"
      case .area(let area): return "area:\(area.id)"
      case .project(let project, _): return "project:\(project.id)"
      }
    }
  }

  var onSelect: ((KitSidebarDestination) -> Void)?
  /// Tab pressed while the sidebar holds focus — the window owns moving
  /// focus to the list (mirrors the list's own `onFocusSidebar`).
  var onFocusList: (() -> Void)?

  private let outlineView = KitSidebarOutlineView()
  private let magicPlusBar = KitSidebarMagicPlusBar()
  private let magicDropBadge = KitSidebarMagicDropBadge()
  private var roots: [Node] = []
  /// Every TOP-LEVEL area/loose-project row (not their nested project
  /// children) — each gets a bit of extra height above it in
  /// `heightOfRowByItem`, so each area still reads as its own section without
  /// the "Areas & Projects" text header that used to separate them.
  private var topLevelAreaOrProjectKeys: Set<String> = []
  /// Smart lists in the bottom section (Logbook, Faded). Their
  /// titles draw in secondary ink so the fixed lists recede below the work.
  private var bottomSmartListKeys: Set<String> = []
  /// Where `organize` (loose projects, then areas) begins and ends within
  /// `roots` — `roots = topViews + organize + bottomViews`. Structure
  /// drag-reorder uses `[organizeStartIndex, bottomStartIndex)` so areas and
  /// projects never cross into either special smart-list cluster.
  private var organizeStartIndex = 0
  private var bottomStartIndex = 0
  private var observers: [NSObjectProtocol] = []
  /// A task edit can emit several synchronous notifications. Sidebar counts
  /// are expensive aggregate reads, so rebuild once after the gesture settles
  /// on the main run loop and preserve the latest selection key.
  private var rebuildWorkItem: DispatchWorkItem?
  private var pendingPreservedKey: String?
  /// True while `rebuild` re-applies the selection it preserved across
  /// `reloadData()`. That reselect is a repaint, not navigation: it must not
  /// fire `onSelect`, because the window's route handler answers every
  /// `onSelect` with `list.focusList()` — and since the rebuild is coalesced
  /// onto the next run-loop tick (`scheduleRebuild`), that focus move landed
  /// right after ⌘N / the "New task" line had attached its field editor. The
  /// editor resigned with an empty title, `commitRename` purged the draft,
  /// and the new row vanished before a character was typed.
  private var isRestoringSelection = false
  /// Which areas the user has folded shut, by `Node.key`. THE source of truth
  /// for the fold — `numberOfChildrenOfItem` reads it (see the long comment
  /// there for why NSOutlineView's own expansion can't be used).
  ///
  /// Keyed by `Node.key`, not by item identity: `rebuild` throws every `Node`
  /// away and makes new ones, and a rebuild happens on every task change, so
  /// anything keyed on identity would be lost within seconds. Persisted, so a
  /// fold also outlives a relaunch, matching the SwiftUI sidebar's own
  /// `DisclosureGroup` state.
  private var collapsedKeys: Set<String> = Set(
    UserDefaults.standard.stringArray(forKey: SettingsKey.septaskSidebarCollapsed) ?? [])

  private func setCollapsed(_ collapsed: Bool, forKey key: String) {
    if collapsed { collapsedKeys.insert(key) } else { collapsedKeys.remove(key) }
    UserDefaults.standard.set(Array(collapsedKeys), forKey: SettingsKey.septaskSidebarCollapsed)
  }

  /// Fold or unfold one area and reflect it on screen.
  ///
  /// `reloadItem(_:reloadChildren:)` re-asks the data source for the child
  /// count, which is where the fold actually lives; `expandItem` afterwards
  /// keeps the row "expanded" in outline-view terms, which it must always be
  /// for its children to be reachable at all.
  private func toggleFold(_ node: Node) {
    setCollapsed(!collapsedKeys.contains(node.key), forKey: node.key)
    outlineView.reloadItem(node, reloadChildren: true)
    outlineView.expandItem(node)
    updateDisclosure(for: node)
  }

  /// Re-assert "everything expanded" after a `reloadData()`. Real folds are
  /// applied by `numberOfChildrenOfItem`, not by collapsing rows.
  private func restoreExpansion() {
    outlineView.expandItem(nil, expandChildren: true)
  }

  private var context: ModelContext { LocalStore.shared.container.mainContext }

  /// The shape `StructureCache.snapshot(in:)` returns.
  private typealias StructureSnapshot = (areas: [Area], projects: [Project])

  /// Mirrors `SettingsKey.septaskSidebarCounts`'s contract: absent → on.
  static var showsCounts: Bool {
    UserDefaults.standard.object(forKey: SettingsKey.septaskSidebarCounts) == nil
      ? true
      : UserDefaults.standard.bool(forKey: SettingsKey.septaskSidebarCounts)
  }

  /// View ▸ Show Sidebar Counts — flips the setting and redraws every row
  /// (a rebuild isn't needed, the counts are already computed; only the
  /// badge text visibility changes).
  func toggleShowsCounts() {
    UserDefaults.standard.set(!Self.showsCounts, forKey: SettingsKey.septaskSidebarCounts)
    outlineView.reloadData()
  }

  /// Refresh native sidebar cells and their width-dependent row heights after
  /// the app-wide macOS text-size setting changes.
  func refreshTextSize() {
    outlineView.reloadData()
    if outlineView.numberOfRows > 0 {
      outlineView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<outlineView.numberOfRows))
    }
    outlineView.needsLayout = true
  }

  override func loadView() {
    let column = NSTableColumn(identifier: .init("main"))
    outlineView.addTableColumn(column)
    outlineView.outlineTableColumn = column
    outlineView.headerView = nil
    outlineView.style = .sourceList
    // KitSidebarRowView already draws the app's one selection language; a
    // system focus ring on top is a second highlight (and, being
    // accent-colored, black — same bug as the task list's ring).
    outlineView.focusRingType = .none
    // MUST be .custom: any other value makes AppKit impose its own row
    // height AND its own font on `NSTableCellView`s, which silently discards
    // `heightOfRowByItem` (the per-area top margin) and the bold area font.
    outlineView.rowSizeStyle = .custom
    outlineView.floatsGroupRows = false
    outlineView.autoresizesOutlineColumn = false
    // AppKit's own source-list selection is off: it flashed the accent ink
    // (black) on the row being left at mouse-down and filled the area rows'
    // top margin. `KitSidebarRowView` paints the only selection, in
    // `drawBackground`, the same way the task list's card rows do.
    outlineView.selectionHighlightStyle = .none
    // Rows abut: a drop target is a solid run with no dead gap between rows.
    outlineView.intercellSpacing = NSSize(width: 0, height: 0)
    // No indentation column, no built-in triangle: every row starts at the
    // same left edge (Things-style), and the custom chevron in SidebarCell
    // is the only expand affordance.
    outlineView.indentationPerLevel = 0
    outlineView.dataSource = self
    outlineView.delegate = self
    outlineView.registerForDraggedTypes([.septaskTask, .septaskStructureItem, .septaskSmartListItem, .septaskMagicPlus])
    outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
    // NOT `.menu`: same reasoning as the task table (SeptaskKitTaskList) —
    // AppKit's automatic path for a table's `.menu` paints its own native
    // "row targeted by a context menu" highlight the row view can't suppress.
    outlineView.onRightClick = { [weak self] event in self?.presentContextMenu(for: event) }
    outlineView.onTab = { [weak self] in self?.onFocusList?() }
    // A CLICK on a row hands the keyboard to the detail pane (the row's list
    // is what the person wants to work in). Arrow keys do NOT — they walk the
    // sidebar, and focus stays here until Return or Tab.
    outlineView.onRowClick = { [weak self] in self?.onFocusList?() }
    outlineView.onReturn = { [weak self] in self?.handleReturn() }
    outlineView.onDragEnded = { [weak self] in self?.hideMagicDropBadge() }

    let scroll = NSScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.documentView = outlineView
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false

    magicPlusBar.translatesAutoresizingMaskIntoConstraints = false
    magicPlusBar.onClick = { [weak self] button in self?.presentMagicPlusMenu(from: button) }
    magicPlusBar.onDragEnded = { [weak self] in self?.hideMagicDropBadge() }

    magicDropBadge.isHidden = true

    let container = NSView()
    container.addSubview(scroll)
    container.addSubview(magicPlusBar)
    container.addSubview(magicDropBadge)
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: container.topAnchor),
      scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: magicPlusBar.topAnchor),
      magicPlusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      magicPlusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      magicPlusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      magicPlusBar.heightAnchor.constraint(equalToConstant: 44),
    ])
    view = container

    rebuild(preserving: nil)

    // Structure changes arrive from local mutations in the SwiftUI window or
    // a CloudKit batch; both post these. StructureCache invalidates itself on
    // the same signal, so re-reading here is always fresh. Tasks-changed is
    // in the list for the counts.
    for name in [Notification.Name.septenaStructureChanged, .septenaDataChanged,
                 .septenaTasksChanged, .septenaSmartListsChanged, .septaskSettingsPulled] {
      observers.append(NotificationCenter.default.addObserver(
        forName: name, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.scheduleRebuild() }
      })
    }
    observers.append(NotificationCenter.default.addObserver(
      forName: .septenaTextSizeDidChange, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshTextSize() }
    })
    observers.append(NotificationCenter.default.addObserver(
      forName: .septenaAppearanceChanged, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.outlineView.enumerateAvailableRowViews { rowView, _ in
          rowView.needsDisplay = true
        }
        self?.magicPlusBar.refreshAppearance()
        // Recolor the Today sidebar icon immediately when the user switches accent.
        self?.scheduleRebuild()
      }
    })
  }

  deinit {
    rebuildWorkItem?.cancel()
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }

  /// Coalesce task/structure/data notifications into one aggregate pass. The
  /// notification itself remains synchronous for mutation correctness; only
  /// this sidebar's derived-count repaint waits until the current gesture has
  /// finished emitting changes.
  private func scheduleRebuild() {
    pendingPreservedKey = selectedKey()
    guard rebuildWorkItem == nil else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.rebuildWorkItem = nil
      let key = self.pendingPreservedKey
      self.pendingPreservedKey = nil
      self.rebuild(preserving: key)
    }
    rebuildWorkItem = work
    DispatchQueue.main.async(execute: work)
  }

  /// Point the sidebar at a destination (Quick Find, or any other jump).
  /// Selecting the row is what drives the detail pane, so navigation always
  /// leaves the sidebar and the content in agreement.
  func select(_ filter: TaskFilter) {
    select(.filter(filter, title: filter.title))
  }

  func select(_ destination: KitSidebarDestination) {
    selectRow(key: destination.key)
  }

  /// Same jump, named by a shared `Route`.
  func select(_ route: Route) {
    selectRow(key: KitSidebarDestination.key(for: route))
  }

  /// Select a destination by its stable key — how the shell restores the
  /// last list at launch. Returns false when no such row exists (the area or
  /// project was deleted, the trash was emptied), so the caller can fall back.
  @discardableResult
  func select(key: String) -> Bool {
    selectRow(key: key)
    return selectedKey() == key
  }

  private func selectRow(key: String) {
    // A project inside a FOLDED area has no row at all (its parent reports
    // zero children), so unfold just THAT area — not every one of them. A
    // blanket unfold here would undo the user's folds on every navigation.
    if let owner = roots.first(where: { node in
      node.children.contains { $0.key == key }
    }), collapsedKeys.contains(owner.key) {
      toggleFold(owner)
    }
    if key == KitSidebarDestination.key(for: .filter(.review)),
       row(forKey: key) == nil {
      rebuild(preserving: key)
    }
    guard let row = row(forKey: key) else { return }
    outlineView.selectRowIndexes([row], byExtendingSelection: false)
    outlineView.scrollRowToVisible(row)
  }

  /// Initial selection: Today, mirroring the SwiftUI app's landing list.
  func selectDefault() {
    guard let today = roots.first else { return }
    let row = outlineView.row(forItem: today)
    guard row >= 0 else { return }
    outlineView.selectRowIndexes([row], byExtendingSelection: false)
  }

  /// Give the sidebar keyboard focus — the list's side of the Tab loop
  /// (`SeptaskKitTaskListController.focusList()`). Selection already exists
  /// (the sidebar always has a current filter), so this only moves the
  /// responder, never the selection.
  func focusSidebar() {
    view.window?.makeFirstResponder(outlineView)
  }

  /// The sidebar holds the keyboard (or is renaming one of its rows) — the
  /// shell then routes Task ▸ Rename / Delete here instead of to the list.
  var hasKeyboardFocus: Bool {
    view.window?.firstResponder === outlineView || isRenaming
  }

  /// The selected row is an area or a project — the only rows that can be
  /// renamed or deleted.
  var selectionIsStructure: Bool {
    switch selectedNode?.content {
    case .area, .project: return true
    default: return false
    }
  }

  /// Task ▸ Rename (⌘R) with the sidebar focused.
  func renameSelectedItem() { renameSelected() }

  /// Task ▸ Delete (⌘⌫) with the sidebar focused. Always confirms.
  func deleteSelectedItem() { deleteSelected() }

  /// Return on a row: rename an area or project (the Finder idiom); on a
  /// smart list it hands the keyboard to the list, like a click.
  private func handleReturn() {
    if selectionIsStructure {
      renameSelected()
    } else {
      onFocusList?()
    }
  }

  // MARK: - Tree

  /// The trailing badge for one smart list. Counts are computed from the one
  /// live-task snapshot in `rebuild`; avoid asking `LocalCache` to refetch the
  /// open table once per sidebar destination.
  private func smartListCount(_ destination: KitSidebarDestination,
                              counts: [TaskFilter: Int],
                              today: Int, doneToday: Int) -> Int? {
    switch destination {
    case .filter(let filter, _):
      switch filter {
      case .today:   return today.nilIfZero
      case .logbook: return doneToday.nilIfZero
      default:       return counts[filter]?.nilIfZero
      }
    }
  }

  private func rebuild(preserving key: String?) {
    // A direct rebuild (for example after creating an area/project) supersedes
    // any notification-driven rebuild that has not run yet.
    if rebuildWorkItem != nil {
      rebuildWorkItem?.cancel()
      rebuildWorkItem = nil
      pendingPreservedKey = nil
    }
    // `reloadData()` would destroy a live rename field mid-word (a CloudKit
    // batch or any task edit lands here). Defer until the rename ends — the
    // same rule the task list applies to its own title editor.
    if isRenaming {
      rebuildDeferredForRename = true
      return
    }
    rebuildDeferredForRename = false
    let snapshot = StructureCache.snapshot(in: context)

    // Counts come from one live-task pass. The filter semantics below mirror
    // `LocalCache.convert`, but sharing this snapshot avoids refetching the
    // entire open table for every smart-list badge on every task edit. The
    // pass reads entities, not row objects: a badge never needs the
    // conversation or recurrence JSON that building a row object decodes.
    let all = LocalCache.liveAggregateEntities(in: context)
    // Faded open tasks leave every list count and project ratio (docs/TASK_FADE_SPEC.md §4).
    let open = all.filter { $0.status == .open && !$0.isFaded }
    let fadedCount = all.filter(\.isFaded).count
    let starredCount = open.filter(\.starred).count
    let today = SeptenaDate.today
    let inboxCount = open.filter { $0.isInTriageBand }.count
    let todayCount = open.filter { $0.isOnToday && !$0.isInTriageBand }.count
    // One conversation decode per row that carries JSON. Review shows what
    // waits on the user and agent work in progress (ADR 0046); only the
    // first counts in its badge. A claim lease is backend wall-clock time.
    let now = Date()
    var reviewCount = 0, agentCount = 0
    for task in open where task.conversationJSON != nil || task.isWaiting {
      guard let group = task.conversation.reviewGroup(at: now, waiting: task.isWaiting) else { continue }
      if group.countsInBadge { reviewCount += 1 } else { agentCount += 1 }
    }
    let smartCounts: [TaskFilter: Int] = [
      .review: reviewCount,
      .upcoming: open.filter(\.isUpcoming).count,
      .repeating: open.filter { $0.recurrenceUnit != nil && $0.recurrence != nil }.count,
      .unscheduled: open.filter(\.isAnytime).count,
      .starred: starredCount,
    ]
    let openByProject = Dictionary(grouping: open.compactMap(\.project), by: { $0 })
      .mapValues(\.count)
    // An area's count is its DIRECT tasks only — the ones loose in the area,
    // not in any of its projects. Nested projects render as their own rows
    // with their own counts, so rolling them up would double-count (same
    // rule the SwiftUI sidebar's `areaDirectOpen` follows).
    let openByArea = Dictionary(grouping: open.filter { $0.project == nil }
                                  .compactMap(\.area), by: { $0 })
      .mapValues(\.count)
    // Project completion rings, same ratio the SwiftUI sidebar draws:
    // done / (done + open), cancelled counted in neither.
    var doneByProject: [String: Int] = [:]
    for task in all where task.status == .done {
      if let project = task.project { doneByProject[project, default: 0] += 1 }
    }
    var progressByProject: [String: Double] = [:]
    for project in Set(openByProject.keys).union(doneByProject.keys) {
      let done = doneByProject[project] ?? 0
      let total = done + (openByProject[project] ?? 0)
      progressByProject[project] = total > 0 ? Double(done) / Double(total) : 0
    }

    // Logbook shows "completed TODAY" (matching the SwiftUI sidebar's
    // `doneTodayCount`), not the full archive size — the archive can run to
    // thousands of rows, and that number wouldn't mean anything useful in a
    // sidebar badge anyway.
    let doneTodayCount = all.filter {
      ($0.status == .done || $0.status == .cancelled)
        && ($0.completedAt ?? "").hasPrefix(today)
    }.count

    // Symbols come from `Route.filterIcon`; no separate Inbox row — loose
    // captures live in the triage band on top of Today (the same structure
    // the SwiftUI sidebar settled on, docs/TRIAGE_BAND_SPEC.md). The band's
    // size rides on Today's count so nothing about it is hidden.
    // Set + order come from `SmartListPreferences.shared` over
    // `registry/destinations.json`, shared across both sidebars and title menus.
    var nonEmptyIDs = Set<RegistryDestinationID>()
    // Review also stays while selected, so accepting the last item does not
    // yank the row away.
    if reviewCount + agentCount + fadedCount > 0
        || key == KitSidebarDestination.key(for: .filter(.review)) {
      nonEmptyIDs.insert(.review)
    }
    if starredCount > 0 { nonEmptyIDs.insert(.starred) }
    let makeViewNode: (KitSidebarDestination) -> Node = { destination in
      Node(destination.nodeContent, count: self.smartListCount(destination,
                                                               counts: smartCounts,
                                                               today: todayCount + inboxCount,
                                                               doneToday: doneTodayCount))
    }
    let topViews = KitSidebarDestination.smartLists(in: .top, nonEmptyIDs: nonEmptyIDs).map(makeViewNode)
    let bottomViews = KitSidebarDestination.smartLists(in: .bottom, nonEmptyIDs: nonEmptyIDs).map(makeViewNode)

    let projectsByArea = Dictionary(grouping: snapshot.projects.filter { $0.deletedAt == nil },
                                    by: { $0.area ?? "" })
    var organize: [Node] = []
    // Loose projects first, then areas with their projects nested — the same
    // vertical order TaskStructureOrder gives the SwiftUI sidebar.
    for project in projectsByArea[""] ?? [] {
      organize.append(Node(.project(project, progress: progressByProject[project.id] ?? 0),
                           count: openByProject[project.id]))
    }
    for area in snapshot.areas {
      let projects = projectsByArea[area.id] ?? []
      let children = projects.map {
        Node(.project($0, progress: progressByProject[$0.id] ?? 0),
             count: openByProject[$0.id])
      }
      organize.append(Node(.area(area), children: children,
                           count: openByArea[area.id]?.nilIfZero))
    }

    // No group wrapper nodes — top smart lists, areas/projects, and bottom
    // smart lists sit as adjacent siblings at the root, separated by a 16pt
    // top margin on each top-level area/loose-project and on the first bottom
    // smart list.
    roots = topViews + organize + bottomViews
    organizeStartIndex = topViews.count
    bottomStartIndex = topViews.count + organize.count
    var gapKeys = Set(organize.map(\.key))
    if let firstBottom = bottomViews.first { gapKeys.insert(firstBottom.key) }
    topLevelAreaOrProjectKeys = gapKeys
    bottomSmartListKeys = Set(bottomViews.map(\.key))
    outlineView.reloadData()
    restoreExpansion()

    if let key, let row = row(forKey: key) {
      isRestoringSelection = true
      outlineView.selectRowIndexes([row], byExtendingSelection: false)
      isRestoringSelection = false
    }
  }

  /// True while an area/project rename field is live in this outline.
  private var isRenaming: Bool {
    guard let editor = view.window?.firstResponder as? NSTextView,
          let field = editor.delegate as? NSTextField else { return false }
    return field.isDescendant(of: outlineView)
  }

  /// Set when a rebuild was skipped because a rename was live.
  private var rebuildDeferredForRename = false

  private func selectedKey() -> String? {
    guard outlineView.selectedRow >= 0,
          let node = outlineView.item(atRow: outlineView.selectedRow) as? Node else { return nil }
    return node.key
  }

  private func row(forKey key: String) -> Int? {
    for row in 0..<outlineView.numberOfRows {
      if let node = outlineView.item(atRow: row) as? Node, node.key == key { return row }
    }
    return nil
  }

  // MARK: - NSOutlineViewDataSource

  /// A folded area reports ZERO children — that is how the fold works here,
  /// and it has to be, because NSOutlineView's own expand/collapse is
  /// unavailable to this sidebar.
  ///
  /// Measured, not assumed: with `shouldShowOutlineCellForItem` returning
  /// false (below — this sidebar suppresses the native triangle in favour of
  /// its own trailing chevron), `collapseItem` is a NO-OP. `isItemExpanded`
  /// stays true and the child rows stay on screen, even when called
  /// programmatically. Suppressing the outline cell doesn't just hide the
  /// triangle, it opts the item out of expansion entirely. So every row stays
  /// "expanded" as far as the outline view is concerned, and visibility is
  /// decided here instead.
  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    guard let node = item as? Node else { return roots.count }
    return collapsedKeys.contains(node.key) ? 0 : node.children.count
  }

  func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
    guard let node = item as? Node else { return roots[index] }
    return node.children[index]
  }

  func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
    guard let node = item as? Node else { return false }
    return !node.children.isEmpty
  }

  // MARK: Drops (file / schedule dragged tasks)

  /// What dropping a task onto this node does; nil = not a drop target.
  private enum DropAction {
    case today
    case scheduleTomorrow
    case anytime
    case area(String)
    case project(String)
  }

  private func dropAction(for node: Node) -> DropAction? {
    switch node.content {
    case .filter(let filter, _, _):
      switch filter {
      case .today: return .today
      case .upcoming: return .scheduleTomorrow
      case .unscheduled: return .anytime
      default: return nil   // Inbox is where captures start, not a filing target; Logbook is an archive.
      }
    case .area(let area):
      return .area(area.id)
    case .project(let project, _):
      return .project(project.id)
    }
  }

  func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                   proposedItem item: Any?, proposedChildIndex index: Int)
    -> NSDragOperation {
    if isMagicPlusDrag(info) {
      return validateMagicPlusDrop(info, proposedItem: item, proposedChildIndex: index)
    }
    hideMagicDropBadge()
    if !KitDrag.ids(from: info).isEmpty {
      // Target the row under the pointer, not AppKit's proposal: between two
      // rows it proposes the PARENT with a child index, which lit up the area
      // while the pointer sat on its project. Rows abut (no intercell gap),
      // so every point resolves to one row, except an area's top margin band,
      // which is the divider and targets nothing.
      guard let node = taskDropNode(at: info.draggingLocation),
            dropAction(for: node) != nil else { return [] }
      outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
      return .move
    }
    if let movedID = draggedSmartListID(from: info) {
      return validateSmartListReorder(movedID: movedID, proposedItem: item, proposedChildIndex: index)
    }
    return validateStructureReorder(info, proposedItem: item, proposedChildIndex: index)
  }

  /// The row a task drop at `windowPoint` lands on, or nil inside the top
  /// margin band of a top-level area/project row (the section divider).
  private func taskDropNode(at windowPoint: NSPoint) -> Node? {
    let point = outlineView.convert(windowPoint, from: nil)
    let row = outlineView.row(at: point)
    guard row >= 0, let node = outlineView.item(atRow: row) as? Node else { return nil }
    if topLevelAreaOrProjectKeys.contains(node.key) {
      // NSOutlineView is flipped: the margin is the first 16pt from minY,
      // the same +16 `heightOfRowByItem` adds.
      let rect = outlineView.rect(ofRow: row)
      if point.y < rect.minY + 16 { return nil }
    }
    return node
  }

  func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                   item: Any?, childIndex index: Int) -> Bool {
    if isMagicPlusDrag(info) {
      hideMagicDropBadge()
      return acceptMagicPlusDrop(info, item: item, childIndex: index)
    }
    guard !KitDrag.ids(from: info).isEmpty else {
      if draggedSmartListID(from: info) != nil {
        return acceptSmartListReorder(info, proposedItem: item, proposedChildIndex: index)
      }
      return acceptStructureReorder(info, proposedItem: item, proposedChildIndex: index)
    }
    guard let node = item as? Node, let action = dropAction(for: node) else { return false }
    let ids = KitDrag.ids(from: info)
    guard !ids.isEmpty else { return false }

    let mutator = SeptenaServices.shared.taskMutator
    // A sidebar drop is a user gesture like any other, so it goes on the ONE
    // shared undo stack (`TaskUndo`). Which kind of snapshot depends on what
    // the drop changed: the three smart lists move DATES, an area / project
    // row moves FILING.
    let dropped = LocalCache.liveTasks(ids: ids, in: context)
    let scheduleBefore = dropped.map(TaskUndo.ScheduleSnapshot.init)
    let filingBefore = dropped.map(TaskUndo.FilingSnapshot.init)
    switch action {
    case .area(let areaId):
      mutator.moveToList(ids: ids, area: areaId, project: nil, acknowledge: true)
    case .project(let projectId):
      mutator.moveToList(ids: ids, area: nil, project: projectId, acknowledge: true)
    case .today, .scheduleTomorrow, .anytime:
      // Field rules: `TaskDateActions` (spec §4). Each action also clears
      // the agent cue: a drop is a disposition, like filing from the list.
      // A drop on Anytime is Clear When (A6, decision Q6): it must land the
      // task in Anytime, so a deadline goes too.
      for id in ids {
        switch action {
        case .today:
          mutator.apply(.putOnToday, to: id)
        case .scheduleTomorrow:
          guard let tomorrow = KitDayFormat.tomorrow() else { continue }
          mutator.apply(.scheduleFor(tomorrow), to: id)
        case .anytime:
          mutator.apply(.clearWhen, to: id)
        case .area, .project:
          break
        }
      }
    }
    switch action {
    case .today:
      TaskUndo.recordScheduleChange(
        name: RegistryActions.title(.taskToggleToday, .add),
        before: scheduleBefore, context: context, mutator: mutator)
    case .scheduleTomorrow, .anytime:
      TaskUndo.recordScheduleChange(
        name: String(localized: "Change When", comment: "SeptaskKit: undo action"),
        before: scheduleBefore, context: context, mutator: mutator)
    case .area, .project:
      TaskUndo.recordMove(before: filingBefore, context: context, mutator: mutator)
    }
    return true
  }

  // MARK: - Structure drag-reorder (areas / projects)
  //
  // Always compatible with the existing data: this calls the SAME
  // `reorder(orderedIDs:)` API and the SAME move-before-target math
  // (`SidebarView.reorderArea`/`reorderProject`) the SwiftUI sidebar's own
  // drag-and-drop already uses — areas reorder among themselves (a flat id
  // list). A project dropped among another parent's projects (another area,
  // or the loose zone at the root before the first area), or ON an area row,
  // is RE-PARENTED with `ProjectsMutator.setArea` — the same move the context
  // menu's "Move to Area" makes. Every structure gesture records undo.

  /// The `roots` index range areas occupy (always the tail of `organize`,
  /// after any loose projects and before `bottomStartIndex`). Empty range at
  /// `bottomStartIndex` if there are no areas.
  private var areaNodeRange: Range<Int> {
    guard let first = roots[organizeStartIndex..<bottomStartIndex].firstIndex(where: {
      if case .area = $0.content { return true }
      return false
    }) else { return bottomStartIndex..<bottomStartIndex }
    return first..<bottomStartIndex
  }

  private func node(forKey key: String) -> Node? {
    func search(_ nodes: [Node]) -> Node? {
      for candidate in nodes {
        if candidate.key == key { return candidate }
        if let found = search(candidate.children) { return found }
      }
      return nil
    }
    return search(roots)
  }

  func outlineView(_ outlineView: NSOutlineView,
                   pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
    guard let node = item as? Node else { return nil }
    switch node.content {
    case .area, .project:
      let pbItem = NSPasteboardItem()
      pbItem.setString(node.key, forType: .septaskStructureItem)
      return pbItem
    case .filter(let filter, _, _):
      guard let destID = filter.destinationID else { return nil }
      let pbItem = NSPasteboardItem()
      pbItem.setString(destID.rawValue, forType: .septaskSmartListItem)
      return pbItem
    }
  }

  private func draggedSmartListID(from info: NSDraggingInfo) -> RegistryDestinationID? {
    (info.draggingPasteboard.pasteboardItems ?? [])
      .first?.string(forType: .septaskSmartListItem)
      .flatMap(RegistryDestinationID.init(rawValue:))
  }

  /// Smart lists live in two dedicated "special" clusters framing Areas &
  /// Projects: top (`0...organizeStartIndex`) and bottom
  /// (`bottomStartIndex...roots.count`). They can reorder within a cluster or
  /// move between top and bottom (when `canMoveSection` is true), but can
  /// never drop inside Areas & Projects.
  private func smartListDropTarget(movedID: RegistryDestinationID, index: Int) -> (section: SmartListSection, localIndex: Int)? {
    guard index >= 0, index <= roots.count else { return nil }
    let canMove = SmartListPreferences.sidebarById[movedID]?.canMoveSection ?? false
    let hasOrganize = bottomStartIndex > organizeStartIndex
    if index <= organizeStartIndex {
      return (.top, index)
    }
    if hasOrganize, index >= bottomStartIndex, canMove {
      return (.bottom, index - bottomStartIndex)
    }
    if !hasOrganize, index >= bottomStartIndex {
      if bottomStartIndex < roots.count, canMove {
        return (.bottom, index - bottomStartIndex)
      }
      return (.top, index)
    }
    return nil
  }

  private func validateSmartListReorder(movedID: RegistryDestinationID,
                                        proposedItem item: Any?,
                                        proposedChildIndex index: Int) -> NSDragOperation {
    guard item == nil,
          index != NSOutlineViewDropOnItemIndex,
          smartListDropTarget(movedID: movedID, index: index) != nil
    else { return [] }
    outlineView.setDropItem(nil, dropChildIndex: index)
    return .move
  }

  private func acceptSmartListReorder(_ info: NSDraggingInfo, proposedItem item: Any?,
                                      proposedChildIndex index: Int) -> Bool {
    guard item == nil,
          index != NSOutlineViewDropOnItemIndex,
          let movedID = draggedSmartListID(from: info),
          let target = smartListDropTarget(movedID: movedID, index: index)
    else { return false }
    let slice = target.section == .top
      ? roots[0..<organizeStartIndex]
      : roots[bottomStartIndex..<roots.count]
    let targetVisibleIDs: [RegistryDestinationID] = slice.compactMap { node in
      guard case .filter(let f, _, _) = node.content else { return nil }
      return f.destinationID
    }
    let prefs = SmartListPreferences.shared
    let before = prefs.snapshot()
    prefs.reorderVisible(movedID: movedID,
                         toSection: target.section,
                         targetVisibleIDs: targetVisibleIDs,
                         toVisibleIndex: target.localIndex)
    let after = prefs.snapshot()
    guard after != before else { return true }
    recordStructure(
      name: String(localized: "Reorder Lists", comment: "SeptaskKit: undo action"),
      undo: { SmartListPreferences.shared.restore(before) },
      redo: { SmartListPreferences.shared.restore(after) })
    return true
  }

  private func draggedStructureNode(from info: NSDraggingInfo) -> Node? {
    guard let key = (info.draggingPasteboard.pasteboardItems ?? [])
      .first?.string(forType: .septaskStructureItem) else { return nil }
    return node(forKey: key)
  }

  private func validateStructureReorder(_ info: NSDraggingInfo, proposedItem item: Any?,
                                        proposedChildIndex index: Int) -> NSDragOperation {
    guard let dragged = draggedStructureNode(from: info) else { return [] }

    // Dropping a PROJECT ON an area row re-parents it into that area (it
    // lands at the end of the area's projects). Any other drop-on-row is
    // meaningless for a structure item.
    if index == NSOutlineViewDropOnItemIndex {
      guard case .project(let project, _) = dragged.content,
            let target = item as? Node, case .area(let area) = target.content,
            area.id != project.area
      else { return [] }
      outlineView.setDropItem(target, dropChildIndex: NSOutlineViewDropOnItemIndex)
      return .move
    }

    switch dragged.content {
    case .area:
      guard item == nil,
            areaNodeRange.contains(index) || index == areaNodeRange.upperBound
      else { return [] }
      outlineView.setDropItem(nil, dropChildIndex: index)
      return .move

    case .project:
      // A project may land among the loose projects at the root (the "no
      // area" zone, before the first area) or among ANY area's projects. The
      // same parent is a reorder; a different one is a re-parent.
      if item == nil {
        guard index >= organizeStartIndex, index <= areaNodeRange.lowerBound
        else { return [] }
        outlineView.setDropItem(nil, dropChildIndex: index)
        return .move
      }
      guard let parent = item as? Node, case .area = parent.content else { return [] }
      outlineView.setDropItem(parent, dropChildIndex: index)
      return .move

    case .filter:
      return []
    }
  }

  private func acceptStructureReorder(_ info: NSDraggingInfo, proposedItem item: Any?,
                                      proposedChildIndex index: Int) -> Bool {
    guard let dragged = draggedStructureNode(from: info) else { return false }
    let snapshot = StructureCache.snapshot(in: context)

    switch dragged.content {
    case .area(let area):
      let before = snapshot.areas.map(\.id)
      var ids = before
      guard let from = ids.firstIndex(of: area.id) else { return false }
      ids.remove(at: from)
      let to = min(max(0, index - areaNodeRange.lowerBound), ids.count)
      ids.insert(area.id, at: to)
      guard ids != before else { return true }
      reorderAreas(ids)
      recordStructure(name: String(localized: "Reorder Areas", comment: "SeptaskKit: undo action"),
                      undo: { [weak self] in self?.reorderAreas(before) },
                      redo: { [weak self] in self?.reorderAreas(ids) })
      return true

    case .project(let project, _):
      // Where it lands: the root's loose-project zone (no area), or an area.
      let targetArea: String?
      let localIndex: Int?
      if index == NSOutlineViewDropOnItemIndex {
        guard let target = item as? Node, case .area(let area) = target.content else { return false }
        targetArea = area.id
        localIndex = nil   // end of the area's projects
      } else if let parent = item as? Node, case .area(let area) = parent.content {
        targetArea = area.id
        localIndex = index
      } else {
        targetArea = nil
        localIndex = index - organizeStartIndex
      }
      moveProject(project, toArea: targetArea, at: localIndex, snapshot: snapshot)
      return true

    case .filter:
      return false
    }
  }

  /// Active sibling ids of one parent group (an area, or nil for loose), in
  /// sidebar order — the list `ProjectsMutator.reorder(orderedIDs:)` takes.
  private func projectOrder(inArea area: String?, snapshot: StructureSnapshot) -> [String] {
    snapshot.projects
      .filter { $0.area == area && $0.status == .active && $0.deletedAt == nil }
      .map(\.id)
  }

  /// Reorder within a parent, or re-parent into another area (or out to the
  /// loose zone) at `localIndex` (nil = end). One undo step either way: undo
  /// puts the project back in its old parent AND restores both groups' order.
  private func moveProject(_ project: Project, toArea targetArea: String?, at localIndex: Int?,
                           snapshot: StructureSnapshot) {
    let oldArea = project.area
    let oldOrder = projectOrder(inArea: oldArea, snapshot: snapshot)
    let targetBefore = projectOrder(inArea: targetArea, snapshot: snapshot)
    var targetAfter = targetBefore.filter { $0 != project.id }
    let to = min(max(0, localIndex ?? targetAfter.count), targetAfter.count)
    targetAfter.insert(project.id, at: to)

    let reparent = oldArea != targetArea
    guard reparent || targetAfter != targetBefore else { return }
    let oldAfter = oldOrder.filter { $0 != project.id }

    let apply: @MainActor (_ area: String?, _ orders: [[String]]) -> Void = { [weak self] area, orders in
      guard let self else { return }
      let mutator = self.projectsMutator
      Task {
        if reparent { try? await mutator.setArea(id: project.id, area: area) }
        for order in orders { try? await mutator.reorder(orderedIDs: order) }
      }
    }
    let forward: [[String]] = reparent ? [oldAfter, targetAfter] : [targetAfter]
    let backward: [[String]] = reparent ? [targetBefore, oldOrder] : [oldOrder]
    apply(targetArea, forward)
    recordStructure(
      name: reparent
        ? String(localized: "Move Project", comment: "SeptaskKit: undo action")
        : String(localized: "Reorder Projects", comment: "SeptaskKit: undo action"),
      undo: { apply(oldArea, backward) },
      redo: { apply(targetArea, forward) })
  }

  private func reorderAreas(_ ids: [String]) {
    let mutator = areasMutator
    Task { try? await mutator.reorder(orderedIDs: ids) }
  }

  /// Area / project changes go on the ONE shared undo stack (`TaskUndo`), so
  /// ⌘Z after a sidebar gesture means the same thing it means in the list.
  private func recordStructure(name: String,
                               undo: @escaping @MainActor () -> Void,
                               redo: @escaping @MainActor () -> Void) {
    TaskUndo.record(name: name, undo: undo, redo: redo)
  }

  // MARK: - NSOutlineViewDelegate

  func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
    let identifier = NSUserInterfaceItemIdentifier("sidebarRow")
    let row = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? KitSidebarRowView)
      ?? { let fresh = KitSidebarRowView(); fresh.identifier = identifier; return fresh }()
    // Must match `heightOfRowByItem`'s own `+16` exactly, or the selection
    // pill either clips into the margin band (too big) or leaves a sliver of
    // unselected content band showing (too small).
    row.extraTopMargin = (item as? Node).map { topLevelAreaOrProjectKeys.contains($0.key) ? 16 : 0 } ?? 0
    row.selectionHighlightStyle = .none
    row.needsDisplay = true
    return row
  }

  /// Uniform row height, +margin above EVERY top-level area/loose-project row
  /// — content stays vertically centered (`centerYAnchor` throughout
  /// `SidebarCell`), so the extra height reads as breathing room around that
  /// row rather than a shift. Nested project children don't get it — they're
  /// part of their area's block, not a section start of their own.
  func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
    let base = SeptenaTypeScale.size(.body) + 18
    guard let node = item as? Node, topLevelAreaOrProjectKeys.contains(node.key) else { return base }
    return base + 16
  }

  func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
    // No indentation column, so there's nowhere for the native triangle to
    // draw — SidebarCell's own chevron is the expand affordance.
    false
  }

  func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
    guard let node = item as? Node else { return nil }

    let identifier = NSUserInterfaceItemIdentifier("cell")
    let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? SidebarCell
      ?? SidebarCell(identifier: identifier)

    // Glyph vocabulary mirrors the SwiftUI sidebar: smart lists use bare SF
    // Symbols with no background box (Today wears the user's active accent
    // color; the rest stay quiet secondary ink), areas their emoji or the
    // muted dot, projects their completion ring.
    cell.emoji.isHidden = true
    cell.sharedMark.isHidden = true
    switch node.content {
    case .filter(let filter, let title, let symbol):
      cell.textField?.font = SeptaskKitTheme.sidebarTitle
      cell.textField?.stringValue = title
      cell.textField?.textColor = bottomSmartListKeys.contains(node.key)
        ? SeptaskKitTheme.inkSecondary
        : SeptaskKitTheme.inkPrimary
      let isToday = filter == .today
      // Today wears its glyph color: gold under Colorful, else the accent
      // (`tokens.json` `multicolorGlyphs`).
      let tint: NSColor = isToday
        ? AppearancePreferences.shared.glyphNSColor(TaskFilter.today.registryDestination?.iconId ?? "list.today")
        : SeptaskKitTheme.inkSecondary
      let tag = isToday ? "accent:\(AppearancePreferences.shared.accentColorID)" : "secondary"
      cell.imageView?.image = KitGlyph.symbol(symbol, color: tint, cacheTag: tag)
    case .area(let area):
      // Areas share the same semibold navigation weight as smart lists and
      // projects; structure is carried by indentation and the disclosure
      // affordance rather than a heavy bold face.
      cell.textField?.font = SeptaskKitTheme.sidebarTitle
      cell.textField?.stringValue = area.title
      cell.textField?.textColor = SeptaskKitTheme.inkPrimary
      if let emoji = area.emoji, !emoji.isEmpty {
        cell.emoji.isHidden = false
        cell.emoji.stringValue = emoji
        cell.imageView?.image = nil
      } else {
        cell.imageView?.image = KitGlyph.areaDot()
      }
    case .project(let project, let progress):
      // Nested projects stay at the regular task-title weight; the area
      // label and top navigation carry the semibold hierarchy.
      cell.textField?.font = SeptaskKitTheme.taskTitle
      cell.textField?.stringValue = project.title
      cell.textField?.textColor = SeptaskKitTheme.inkPrimary
      cell.imageView?.image = KitGlyph.progress(progress)
      if let share = project.share {
        cell.sharedMark.isHidden = false
        cell.sharedMark.toolTip = share.membersLabel
        cell.sharedMark.setAccessibilityLabel(share.membersLabel)
      }
    }
    cell.badge.stringValue = Self.showsCounts ? (node.count.map(String.init) ?? "") : ""

    if node.children.isEmpty {
      cell.disclosure.isHidden = true
      cell.disclosure.kitA11yIgnore()
      cell.onToggleDisclosure = nil
    } else {
      cell.disclosure.isHidden = false
      applyDisclosure(to: cell, node: node)
      cell.onToggleDisclosure = { [weak self] in self?.toggleFold(node) }
    }
    return cell
  }

  /// Chevron direction + spoken label for one row. Driven by `collapsedKeys`,
  /// NOT by `isItemExpanded` — every row is permanently "expanded" as far as
  /// the outline view is concerned (see `numberOfChildrenOfItem`), so
  /// `isItemExpanded` is always true and would pin the chevron open.
  private func applyDisclosure(to cell: SidebarCell, node: Node) {
    let folded = collapsedKeys.contains(node.key)
    cell.disclosure.image = Self.chevronImage(expanded: !folded)
    let title = cell.textField?.stringValue ?? ""
    cell.disclosure.kitA11yButton(
      label: folded ? TaskA11y.expand(title) : TaskA11y.collapse(title))
  }

  /// Refresh one row's chevron without reloading its children.
  private func updateDisclosure(for node: Node) {
    let row = outlineView.row(forItem: node)
    guard row >= 0, let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
      as? SidebarCell else { return }
    applyDisclosure(to: cell, node: node)
  }

  // Only the chevron direction here — deliberately NOT `setCollapsed`.
  // `restoreExpansion` calls `expandItem(nil, expandChildren: true)` after
  // every rebuild, which fires didExpand for every node; recording the fold
  // from these would wipe every fold on the next task change.
  func outlineViewItemDidExpand(_ notification: Notification) {
    guard let node = notification.userInfo?["NSObject"] as? Node else { return }
    updateDisclosure(for: node)
  }

  func outlineViewItemDidCollapse(_ notification: Notification) {
    guard let node = notification.userInfo?["NSObject"] as? Node else { return }
    updateDisclosure(for: node)
  }

  private static func chevronImage(expanded: Bool) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
    return NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right",
                   accessibilityDescription: nil)?
      .withSymbolConfiguration(config)
  }

  func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { true }

  /// Source-list row: icon/emoji, title, a trailing chevron (areas only, next
  /// to the count), and the count badge. Every row — filter, area, project —
  /// shares this exact layout, so nothing needs per-kind alignment.
  @MainActor
  fileprivate final class SidebarCell: NSTableCellView, NSTextFieldDelegate {
    let badge = NSTextField(labelWithString: "")
    /// An area's user glyph sits where the icon would — same slot, so titles
    /// stay aligned whether an area has an emoji or the muted dot.
    let emoji = NSTextField(labelWithString: "")
    /// After the title of a shared project.
    let sharedMark = NSImageView()
    /// Custom expand/collapse affordance — see the controller's
    /// `shouldShowOutlineCellForItem`.
    let disclosure = KitDisclosureView()
    var onToggleDisclosure: (() -> Void)?

    /// Inline rename — the Finder idiom, and the shell's ONE answer to
    /// "name this thing" (see SeptaskKitSurface.swift: naming is not one of
    /// the three surface tiers, it happens in the row that holds the name).
    /// The label turns into a field for the duration of the edit and turns
    /// back after, so nothing about the row's layout moves.
    private var renameCommit: ((String) -> Void)?
    /// Fires once when the rename ends, however it ended. `true` = the
    /// keyboard should go back to the outline view (Return, Tab, Esc); false
    /// = the user clicked elsewhere, so focus already moved on.
    private var renameEnded: ((Bool) -> Void)?
    private var renameActive = false
    private var titleBeforeRename = ""

    func beginRename(onCommit: @escaping (String) -> Void,
                     onEnd: @escaping (_ returnFocus: Bool) -> Void) {
      guard let text = textField else { return }
      renameCommit = onCommit
      renameEnded = onEnd
      renameActive = true
      titleBeforeRename = text.stringValue
      text.isEditable = true
      text.isSelectable = true
      text.drawsBackground = true
      text.backgroundColor = .textBackgroundColor
      text.focusRingType = .default
      text.delegate = self
      text.window?.makeFirstResponder(text)
      text.currentEditor()?.selectAll(nil)
    }

    private func endRename(commit: Bool, returnFocus: Bool) {
      guard renameActive, let text = textField else { return }
      renameActive = false
      if !commit {
        // Drop the field editor's text before the field turns back into a
        // label, so the typed-and-abandoned name never lands in it.
        text.abortEditing()
      }
      let value = text.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      let handler = renameCommit
      let ended = renameEnded
      renameCommit = nil
      renameEnded = nil
      text.isEditable = false
      text.isSelectable = false
      text.drawsBackground = false
      text.focusRingType = .none
      text.delegate = nil
      // An empty name is a cancel, not a rename to "" — same rule Finder uses.
      if commit, !value.isEmpty, value != titleBeforeRename {
        text.stringValue = value
        handler?(value)
      } else {
        text.stringValue = titleBeforeRename
      }
      ended?(returnFocus)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
      // Return / Tab end the edit from the keyboard: the keyboard goes back
      // to the outline. A click elsewhere already moved focus on purpose.
      let movement = obj.userInfo?["NSTextMovement"] as? Int
      let keyboard = movement == NSTextMovement.return.rawValue
        || movement == NSTextMovement.tab.rawValue
        || movement == NSTextMovement.backtab.rawValue
      endRename(commit: true, returnFocus: keyboard)
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
      guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
      endRename(commit: false, returnFocus: true)
      return true
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
      super.init(frame: .zero)
      self.identifier = identifier
      let text = NSTextField(labelWithString: "")
      text.translatesAutoresizingMaskIntoConstraints = false
      text.lineBreakMode = .byTruncatingTail
      text.font = SeptaskKitTheme.sidebarTitle
      text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      let image = NSImageView()
      image.translatesAutoresizingMaskIntoConstraints = false
      emoji.translatesAutoresizingMaskIntoConstraints = false
      // +2 to match the area glyph's visual weight against the 18pt icon slot.
      emoji.font = .systemFont(ofSize: SeptenaTypeScale.size(.subheadline) + 2)
      badge.font = SeptaskKitTheme.meta
      badge.textColor = SeptaskKitTheme.iconMuted
      badge.translatesAutoresizingMaskIntoConstraints = false
      badge.setContentHuggingPriority(.required, for: .horizontal)

      sharedMark.translatesAutoresizingMaskIntoConstraints = false
      sharedMark.image = NSImage(systemSymbolName: RegistryIcons.sfSymbol(for: "project.shared"),
                                 accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
      sharedMark.contentTintColor = SeptaskKitTheme.iconMuted
      sharedMark.setContentHuggingPriority(.required, for: .horizontal)
      sharedMark.setContentCompressionResistancePriority(.required, for: .horizontal)

      disclosure.translatesAutoresizingMaskIntoConstraints = false
      disclosure.onTap = { [weak self] in self?.onToggleDisclosure?() }
      disclosure.setContentHuggingPriority(.required, for: .horizontal)

      addSubview(text)
      addSubview(image)
      addSubview(emoji)
      addSubview(sharedMark)
      addSubview(disclosure)
      addSubview(badge)
      textField = text
      imageView = image
      // Content anchors to the row's BOTTOM edge (fixed inset), not its
      // center. A per-item top-margin (see `heightOfRowByItem`) works by
      // making that ONE row's rect taller — with centered content, the extra
      // height splits invisibly above AND below, reading as no margin at all.
      // Bottom-anchoring with a FIXED offset means any extra row height shows
      // up entirely ABOVE the content, exactly where the removed "Areas &
      // Projects" text header used to put its own air. Normal (non-tall) rows
      // look identically centered either way — this constant is tuned so a
      // base-height row's content sits where centering would have put it.
      let contentBottomInset: CGFloat = 6
      NSLayoutConstraint.activate([
        image.leadingAnchor.constraint(equalTo: leadingAnchor),
        image.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -contentBottomInset),
        image.heightAnchor.constraint(equalToConstant: 18),
        image.widthAnchor.constraint(equalToConstant: 18),
        emoji.centerXAnchor.constraint(equalTo: image.centerXAnchor),
        emoji.centerYAnchor.constraint(equalTo: image.centerYAnchor),
        text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
        text.centerYAnchor.constraint(equalTo: image.centerYAnchor),
        badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
        badge.centerYAnchor.constraint(equalTo: image.centerYAnchor),
        disclosure.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -6),
        disclosure.centerYAnchor.constraint(equalTo: image.centerYAnchor),
        disclosure.widthAnchor.constraint(equalToConstant: 14),
        disclosure.heightAnchor.constraint(equalToConstant: 14),
        sharedMark.leadingAnchor.constraint(equalTo: text.trailingAnchor, constant: 5),
        sharedMark.centerYAnchor.constraint(equalTo: image.centerYAnchor),
        sharedMark.trailingAnchor.constraint(lessThanOrEqualTo: disclosure.leadingAnchor, constant: -6),
        text.trailingAnchor.constraint(lessThanOrEqualTo: disclosure.leadingAnchor, constant: -6),
      ])
    }

    required init?(coder: NSCoder) { fatalError("SidebarCell is code-only") }
  }

  func outlineViewSelectionDidChange(_ notification: Notification) {
    // A rebuild restoring the row it already had is not a navigation.
    guard !isRestoringSelection else { return }
    guard outlineView.selectedRow >= 0,
          let node = outlineView.item(atRow: outlineView.selectedRow) as? Node else { return }
    switch node.content {
    case .filter(let filter, let title, _):
      onSelect?(.filter(filter, title: title))
    case .area(let area):
      onSelect?(.filter(.area(area.id), title: area.title))
    case .project(let project, _):
      onSelect?(.filter(.project(project.id), title: project.title))
    }
  }

  // MARK: - Structure CRUD (create / rename / delete)

  private var areasMutator: AreasMutator { SeptenaServices.shared.areasMutator }
  private var projectsMutator: ProjectsMutator { SeptenaServices.shared.projectsMutator }

  /// Right-click menu: on an area/project row it's rename/delete (+ "New
  /// Project" on an area, filed into it); on blank sidebar space, or with
  /// nothing under the pointer, it's just the two "New" commands.
  private func presentContextMenu(for event: NSEvent) {
    let point = outlineView.convert(event.locationInWindow, from: nil)
    let row = outlineView.row(at: point)
    let node = row >= 0 ? outlineView.item(atRow: row) as? Node : nil
    if row >= 0 {
      outlineView.selectRowIndexes([row], byExtendingSelection: false)
    }

    // Registry menus (`sidebar.area`, `sidebar.project`, `sidebar.empty`) —
    // the same trees the SwiftUI sidebar renders.
    let menu: NSMenu
    switch node?.content {
    case .area:
      menu = KitRegistryMenu.build(RegistryActions.menu(.sidebarArea)) { [weak self] id in
        guard let self else { return nil }
        switch id {
        case .areaNewProject: return .init { self.newProjectInSelectedArea() }
        case .areaRename: return .init { self.renameSelected() }
        case .areaChangeEmoji: return .init { self.changeEmojiOfSelectedArea() }
        case .areaDelete: return .init { self.deleteSelected() }
        default: return nil
        }
      }
    case .project(let project, _):
      menu = KitRegistryMenu.build(RegistryActions.menu(.sidebarProject), bind: { [weak self] id in
        guard let self else { return nil }
        switch id {
        case .projectRename: return .init { self.renameSelected() }
        case .projectMarkDone: return .init { self.markSelectedProjectDone() }
        case .projectCancel: return .init { self.cancelSelectedProject() }
        case .projectShare: return .init { SeptaskSharing.present(projectID: project.id) }
        // A shared project ends from its Share screen.
        case .projectDelete: return project.share == nil ? .init { self.deleteSelected() } : nil
        default: return nil
        }
      }, slot: { [weak self] id in
        guard let self, id == "moveToAreaDestinations" else { return [] }
        return self.areaDestinationNodes(for: project)
      })
    case .filter(_, _, _), .none:
      menu = KitRegistryMenu.build(RegistryActions.menu(.sidebarEmpty)) { [weak self] id in
        guard let self else { return nil }
        switch id {
        case .sidebarNewArea: return .init { self.newArea() }
        case .sidebarNewProject: return .init { self.newProjectLoose() }
        case .sidebarJoinShared: return .init { SeptaskSharing.presentJoin() }
        default: return nil
        }
      }
      // Smart-list placement + show/hide (SmartListPreferences) rides on top of
      // the registry menu: Move Above/Below, Hide <list>, then Customize.
      menu.insertItem(.separator(), at: 0)
      menu.insertItem(smartListMenuItem(String(localized: "Customize Lists…",
                                               comment: "SeptaskKit: sidebar context menu"),
                                        #selector(openSmartListsSettings)), at: 0)
      if case .filter(let filter, let title, _)? = node?.content,
         let destID = filter.destinationID,
         let dest = SmartListPreferences.sidebarById[destID] {
        if dest.canHide {
          let hideItem = smartListMenuItem(String(localized: "Hide \(title)",
                                                  comment: "SeptaskKit: sidebar context menu"),
                                           #selector(hideSmartList(_:)))
          hideItem.representedObject = destID
          menu.insertItem(hideItem, at: 0)
        }
        if dest.canMoveSection {
          let currentSection = SmartListPreferences.shared.section(for: destID)
          let moveTitle = currentSection == .top
            ? String(localized: "Move Below Areas & Projects", comment: "SeptaskKit: sidebar context menu")
            : String(localized: "Move Above Areas & Projects", comment: "SeptaskKit: sidebar context menu")
          let moveItem = smartListMenuItem(moveTitle, #selector(toggleSmartListSection(_:)))
          moveItem.representedObject = destID
          menu.insertItem(moveItem, at: 0)
        }
      }
    }
    menu.popUp(positioning: nil, at: point, in: outlineView)
  }

  private func smartListMenuItem(_ title: String, _ action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    return item
  }

  @objc private func toggleSmartListSection(_ sender: NSMenuItem) {
    guard let destID = sender.representedObject as? RegistryDestinationID else { return }
    let prefs = SmartListPreferences.shared
    let before = prefs.snapshot()
    let target: SmartListSection = prefs.section(for: destID) == .top ? .bottom : .top
    prefs.setSection(target, for: destID)
    let after = prefs.snapshot()
    guard after != before else { return }
    let title = SmartListPreferences.sidebarById[destID]?.title ?? "Smart List"
    recordStructure(
      name: String(localized: "Move \(title)", comment: "SeptaskKit: undo action"),
      undo: { SmartListPreferences.shared.restore(before) },
      redo: { SmartListPreferences.shared.restore(after) })
  }

  @objc private func hideSmartList(_ sender: NSMenuItem) {
    guard let destID = sender.representedObject as? RegistryDestinationID else { return }
    let prefs = SmartListPreferences.shared
    let before = prefs.snapshot()
    let wasSelected = selectedKey() == "filter:\(TaskFilter(destinationID: destID)?.navigationKey ?? "")"
    prefs.setHidden(true, for: destID)
    let after = prefs.snapshot()
    guard after != before else { return }
    if wasSelected {
      select(.today)
    }
    let title = RegistryDestinations.byId[destID]?.title ?? "Smart List"
    recordStructure(
      name: String(localized: "Hide \(title)", comment: "SeptaskKit: undo action"),
      undo: { SmartListPreferences.shared.restore(before) },
      redo: { SmartListPreferences.shared.restore(after) })
  }

  @objc private func openSmartListsSettings() {
    SeptaskSettingsLink.request(RegistrySettings.PageID.smartLists)
    SeptaskKitSettingsWindow.show()
  }

  /// "Move to Area ▸" — No Area, then every area; the current parent is
  /// checked and inert. The same slot the SwiftUI sidebar fills.
  private func areaDestinationNodes(for project: Project) -> [RegistryMenuNode] {
    let areas = StructureCache.snapshot(in: context).areas
    var nodes: [RegistryMenuNode] = [
      RegistryMenuEntry.slot(
        id: "area.none",
        title: String(localized: "No Area", comment: "SeptaskKit: sidebar context menu"),
        sfSymbol: "tray",
        isOn: project.area == nil,
        perform: project.area == nil ? nil : { [weak self] in self?.moveProject(project, toArea: nil) }),
    ]
    if !areas.isEmpty { nodes.append(.divider(id: "areas.divider")) }
    for area in areas {
      nodes.append(RegistryMenuEntry.slot(
        id: "area.\(area.id)", title: area.title,
        listIcon: .area(emoji: area.emoji),
        isOn: project.area == area.id,
        perform: project.area == area.id ? nil : { [weak self] in self?.moveProject(project, toArea: area.id) }))
    }
    return nodes
  }

  private func moveProject(_ project: Project, toArea area: String?) {
    moveProject(project, toArea: area, at: nil, snapshot: StructureCache.snapshot(in: context))
  }

  private var selectedNode: Node? {
    outlineView.selectedRow >= 0 ? outlineView.item(atRow: outlineView.selectedRow) as? Node : nil
  }

  /// New Area lands a named row and opens it for editing, the way Finder
  /// lands "untitled folder". It used to stop the whole app with a modal text
  /// prompt to ask for a string the row can take directly.
  ///
  /// The new row is also OPENED in the detail pane, before the rename. The
  /// rebuild selects it as a restore, which never fires `onSelect`, and the
  /// rename's own select is a no-op on an already-selected row — so the row
  /// showed selected while the list still held the previous page. `show`
  /// leaves the keyboard in the sidebar, so the rename field still gets it.
  @objc func newArea() { createArea(atIndex: nil) }

  private func createArea(atIndex index: Int?) {
    let beforeIDs = StructureCache.snapshot(in: context).areas.map(\.id)
    Task { [weak self] in
      guard let self,
            let area = try? await self.areasMutator.create(
              title: RegistryActions.title(.sidebarNewArea))
      else { return }
      if let index {
        var ids = beforeIDs.filter { $0 != area.id }
        ids.insert(area.id, at: min(max(0, index), ids.count))
        try? await self.areasMutator.reorder(orderedIDs: ids)
      }
      self.recordAreaCreate(area)
      self.rebuild(preserving: "area:\(area.id)")
      self.onSelect?(.filter(.area(area.id), title: area.title))
      self.beginRename(key: "area:\(area.id)")
    }
  }

  /// Undo for a new area deletes it; redo re-creates it under the SAME id,
  /// so anything later filed into it (and later undo steps) still resolve.
  private func recordAreaCreate(_ area: Area) {
    let mutator = areasMutator
    recordStructure(
      name: RegistryActions.title(.sidebarNewArea),
      undo: { Task { try? await mutator.delete(id: area.id) } },
      redo: { Task { _ = try? await mutator.createWithExplicitID(id: area.id, title: area.title) } })
  }

  private func recordProjectCreate(_ project: Project) {
    TaskUndo.recordProjectCreate(project, projects: projectsMutator)
  }

  @objc private func newProjectLoose() { newProject(inArea: nil, atIndex: nil) }

  @objc private func newProjectInSelectedArea() {
    guard let areaId = selectedAreaID else { return }
    newProject(inArea: areaId, atIndex: nil)
  }

  /// The Area currently selected in the sidebar, or the owning Area of the
  /// currently selected Project. Used to pre-select the target Area for
  /// `New Project` commands (matching iOS / Android / Web).
  private var selectedAreaID: String? {
    switch selectedNode?.content {
    case .area(let area): return area.id
    case .project(let project, _): return project.area
    default: return nil
    }
  }

  private var selectedAreaTitle: String? {
    switch selectedNode?.content {
    case .area(let area):
      return area.title
    case .project(let project, _):
      guard let areaId = project.area else { return nil }
      return StructureCache.snapshot(in: context).areas.first(where: { $0.id == areaId })?.title
    default:
      return nil
    }
  }

  @objc func newProject() { newProject(inArea: selectedAreaID, atIndex: nil) }

  /// The area page's "New Project" row (#706): the same create, select and
  /// rename-in-place the sidebar's own New Project does.
  func newProject(inArea areaId: String) { newProject(inArea: areaId, atIndex: nil) }

  private func newProject(inArea areaId: String?, atIndex index: Int?) {
    if let areaId { setCollapsed(false, forKey: "area:\(areaId)") }
    let snapshot = StructureCache.snapshot(in: context)
    let beforeSiblings = projectOrder(inArea: areaId, snapshot: snapshot)
    Task { [weak self] in
      guard let self,
            let project = try? await self.projectsMutator.create(
              title: RegistryActions.title(.sidebarNewProject),
              area: areaId)
      else { return }
      if let index {
        var ids = beforeSiblings.filter { $0 != project.id }
        ids.insert(project.id, at: min(max(0, index), ids.count))
        try? await self.projectsMutator.reorder(orderedIDs: ids)
      }
      self.recordProjectCreate(project)
      self.rebuild(preserving: "project:\(project.id)")
      self.onSelect?(.filter(.project(project.id), title: project.title))
      self.beginRename(key: "project:\(project.id)")
    }
  }

  // MARK: - Sidebar Magic Plus (click menu + drag-to-create Area or Project)

  private enum MagicPlusTarget {
    case area(index: Int)
    case project(areaId: String?, areaTitle: String?, index: Int?)
  }

  private func isMagicPlusDrag(_ info: NSDraggingInfo) -> Bool {
    (info.draggingPasteboard.pasteboardItems ?? [])
      .contains { $0.types.contains(.septaskMagicPlus) }
  }

  private func resolveMagicPlusTarget(proposedItem item: Any?,
                                      proposedChildIndex index: Int) -> MagicPlusTarget? {
    // Dropped ON an Area row → first Project inside that Area.
    if index == NSOutlineViewDropOnItemIndex {
      guard let target = item as? Node, case .area(let area) = target.content else { return nil }
      return .project(areaId: area.id, areaTitle: area.title, index: 0)
    }
    // Dropped between an Area's nested Projects → Project inside that Area at `index`.
    if let parent = item as? Node, case .area(let area) = parent.content {
      return .project(areaId: area.id, areaTitle: area.title, index: max(0, index))
    }
    // Top-level drops: between loose projects makes a loose Project; at Area
    // level (above first Area, between Areas, or below last Area) makes an Area.
    guard item == nil else { return nil }
    let hasLooseProjects = areaNodeRange.lowerBound > organizeStartIndex
    if hasLooseProjects, index >= organizeStartIndex, index < areaNodeRange.lowerBound {
      return .project(areaId: nil, areaTitle: nil, index: index - organizeStartIndex)
    }
    if index >= areaNodeRange.lowerBound, index <= areaNodeRange.upperBound {
      return .area(index: index - areaNodeRange.lowerBound)
    }
    if index >= bottomStartIndex {
      return .area(index: areaNodeRange.count)
    }
    return nil
  }

  private func validateMagicPlusDrop(_ info: NSDraggingInfo, proposedItem item: Any?,
                                     proposedChildIndex index: Int) -> NSDragOperation {
    guard let target = resolveMagicPlusTarget(proposedItem: item, proposedChildIndex: index) else {
      hideMagicDropBadge()
      return []
    }
    switch target {
    case .area(let areaIdx):
      outlineView.setDropItem(nil, dropChildIndex: areaNodeRange.lowerBound + areaIdx)
      showMagicDropBadge(isArea: true, label: RegistryActions.title(.sidebarNewArea),
                         atWindowPoint: info.draggingLocation)
    case .project(let areaId, let areaTitle, let localIdx):
      if let areaId, let areaNode = node(forKey: "area:\(areaId)") {
        if index == NSOutlineViewDropOnItemIndex || collapsedKeys.contains(areaNode.key) {
          outlineView.setDropItem(areaNode, dropChildIndex: NSOutlineViewDropOnItemIndex)
        } else {
          outlineView.setDropItem(areaNode, dropChildIndex: localIdx ?? areaNode.children.count)
        }
      } else {
        outlineView.setDropItem(nil, dropChildIndex: organizeStartIndex + (localIdx ?? 0))
      }
      let label: String = if let areaTitle {
        String(localized: "New Project in \(areaTitle)", comment: "Magic Plus: drop inside an area")
      } else {
        RegistryActions.title(.sidebarNewProject)
      }
      showMagicDropBadge(isArea: false, label: label, atWindowPoint: info.draggingLocation)
    }
    return .copy
  }

  private func acceptMagicPlusDrop(_ info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
    guard let target = resolveMagicPlusTarget(proposedItem: item, proposedChildIndex: index) else {
      return false
    }
    switch target {
    case .area(let areaIdx):
      createArea(atIndex: areaIdx)
    case .project(let areaId, _, let localIdx):
      newProject(inArea: areaId, atIndex: localIdx)
    }
    return true
  }

  private func showMagicDropBadge(isArea: Bool, label: String, atWindowPoint windowPoint: NSPoint) {
    magicDropBadge.configure(isArea: isArea, label: label)
    let size = magicDropBadge.fittingSize
    let pt = view.convert(windowPoint, from: nil)
    let x = min(max(12, view.bounds.width - size.width - 12), max(12, pt.x - size.width / 2))
    let y = min(max(50, pt.y + 12), view.bounds.height - size.height - 12)
    magicDropBadge.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
    magicDropBadge.isHidden = false
  }

  private func hideMagicDropBadge() {
    magicDropBadge.isHidden = true
  }

  private func presentMagicPlusMenu(from button: NSView) {
    let menu = NSMenu()
    if let areaId = selectedAreaID, let areaTitle = selectedAreaTitle {
      let inArea = NSMenuItem(
        title: String(localized: "New Project in \(areaTitle)", comment: "Sidebar footer menu"),
        action: #selector(newProjectInCurrentAreaFromFooter(_:)),
        keyEquivalent: ""
      )
      inArea.target = self
      inArea.representedObject = areaId
      inArea.image = NSImage(systemSymbolName: "number", accessibilityDescription: nil)
      menu.addItem(inArea)
    }
    let looseProject = NSMenuItem(
      title: RegistryActions.title(.sidebarNewProject),
      action: #selector(newProjectLoose),
      keyEquivalent: ""
    )
    looseProject.target = self
    looseProject.image = NSImage(systemSymbolName: "number", accessibilityDescription: nil)
    menu.addItem(looseProject)

    let areaItem = NSMenuItem(
      title: RegistryActions.title(.sidebarNewArea),
      action: #selector(newArea),
      keyEquivalent: ""
    )
    areaItem.target = self
    areaItem.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)
    menu.addItem(areaItem)

    menu.addItem(.separator())
    let joinItem = NSMenuItem(
      title: RegistryActions.title(.sidebarJoinShared),
      action: #selector(joinSharedFromFooter),
      keyEquivalent: ""
    )
    joinItem.target = self
    joinItem.image = NSImage(systemSymbolName: RegistryIcons.sfSymbol(for: "action.share_project"),
                             accessibilityDescription: nil)
    menu.addItem(joinItem)

    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
  }

  @objc private func newProjectInCurrentAreaFromFooter(_ sender: NSMenuItem) {
    newProject(inArea: sender.representedObject as? String, atIndex: nil)
  }

  @objc private func joinSharedFromFooter() {
    SeptaskSharing.presentJoin()
  }

  @objc private func renameSelected() {
    guard let key = selectedKey() else { return }
    beginRename(key: key)
  }

  /// The area glyph picker, anchored on the row's glyph slot — the same
  /// picker the area page's icon opens.
  private func changeEmojiOfSelectedArea() {
    let row = outlineView.selectedRow
    guard row >= 0, let node = outlineView.item(atRow: row) as? Node,
          case .area(let area) = node.content else { return }
    if let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell,
       let anchor = cell.imageView {
      KitEmojiPopover.present(for: area, relativeTo: anchor.bounds, of: anchor,
                              preferredEdge: .maxX)
    } else {
      KitEmojiPopover.present(for: area, relativeTo: outlineView.rect(ofRow: row),
                              of: outlineView, preferredEdge: .maxX)
    }
  }

  /// Turn the row's label into a field and write the result through the
  /// matching mutator. One rename path for areas and projects, and the same
  /// one the ⌘R menu item, the context menu and a fresh row all use.
  private func beginRename(key: String) {
    guard let row = row(forKey: key),
          let node = outlineView.item(atRow: row) as? Node,
          let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCell
    else { return }
    outlineView.selectRowIndexes([row], byExtendingSelection: false)
    outlineView.scrollRowToVisible(row)

    // After Return / Esc the keyboard comes back to the outline; any rebuild
    // the live field held off runs now that it is gone.
    let onEnd: (Bool) -> Void = { [weak self] returnFocus in
      guard let self else { return }
      if returnFocus { self.view.window?.makeFirstResponder(self.outlineView) }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.rebuildDeferredForRename, !self.isRenaming else { return }
        self.rebuild(preserving: self.selectedKey())
      }
    }

    switch node.content {
    case .area(let area):
      let mutator = areasMutator
      cell.beginRename(onCommit: { [weak self] title in
        Task { try? await mutator.rename(id: area.id, to: title) }
        self?.recordStructure(
          name: RegistryPrompts.textPrompt(.renameArea).title,
          undo: { Task { try? await mutator.rename(id: area.id, to: area.title) } },
          redo: { Task { try? await mutator.rename(id: area.id, to: title) } })
      }, onEnd: onEnd)
    case .project(let project, _):
      let mutator = projectsMutator
      cell.beginRename(onCommit: { [weak self] title in
        Task { try? await mutator.rename(id: project.id, to: title) }
        self?.recordStructure(
          name: RegistryPrompts.textPrompt(.renameProject).title,
          undo: { Task { try? await mutator.rename(id: project.id, to: project.title) } },
          redo: { Task { try? await mutator.rename(id: project.id, to: title) } })
      }, onEnd: onEnd)
    default:
      break
    }
  }

  @objc private func deleteSelected() {
    if case .project(let project, _) = selectedNode?.content, project.share != nil {
      SeptaskSharing.present(projectID: project.id)
      return
    }
    // Copy matches the SwiftUI sidebar's confirmation exactly
    // (`RegistryPrompts.deleteArea` / `deleteProject`) — one deletion story between the two shells. A
    // window SHEET, not an app-modal alert, with Cancel as the Return default.
    switch selectedNode?.content {
    case .area(let area):
      let copy = RegistryPrompts.deleteArea(id: area.id, title: area.title, context: context)
      KitPrompt.confirmDestructive(copy, in: view.window) { [weak self] in
        self?.deleteArea(area)
      }
    case .project(let project, _):
      let copy = RegistryPrompts.deleteProject(id: project.id, title: project.title, context: context)
      KitPrompt.confirmDestructive(copy, in: view.window) { [weak self] in
        self?.deleteProject(project)
      }
    default:
      break
    }
  }

  /// The area delete takes its projects and every task in it to Recently
  /// Deleted (`AreasMutator.delete`). Undo revives the area — every field,
  /// sidebar position included — then its projects and tasks, each re-filed
  /// exactly. One shared inverse (`TaskUndo.recordAreaDelete`) for every
  /// surface that deletes an area.
  private func deleteArea(_ area: Area) {
    let mutator = areasMutator
    let projects = projectsMutator
    let snapshot = TaskUndo.areaDeleteSnapshot(id: area.id, areas: mutator, projects: projects,
                                               context: context)
    bounceToTodayIfShowing(key: "area:\(area.id)")
    Task { try? await mutator.delete(id: area.id) }
    if let snapshot {
      TaskUndo.recordAreaDelete(snapshot, areas: mutator, projects: projects,
                                mutator: SeptenaServices.shared.taskMutator)
    }
  }

  /// The project delete takes every task in it to Recently Deleted (the
  /// mutator's cascade), so undo rebuilds the project — every field, sidebar
  /// position included — brings its headings and tasks back, and re-files
  /// each exactly. One shared inverse (`TaskUndo.recordProjectDelete`) for
  /// every surface that deletes a project.
  private func deleteProject(_ project: Project) {
    let mutator = projectsMutator
    let snapshot = TaskUndo.projectDeleteSnapshot(id: project.id, projects: mutator,
                                                  context: context)
    bounceToTodayIfShowing(key: "project:\(project.id)")
    Task { try? await mutator.delete(id: project.id) }
    if let snapshot {
      TaskUndo.recordProjectDelete(snapshot, projects: mutator,
                                   mutator: SeptenaServices.shared.taskMutator)
    }
  }

  /// Context menu ▸ Move to Area — the keyboard-and-pointer twin of dragging
  /// a project onto an area row. `representedObject` is the area id, or
  /// `NSNull` for "No Area".
  /// Matches `SidebarView.projectMenu` and `registry/actions.json` (`sidebar.project`).
  @objc private func markSelectedProjectDone() {
    setSelectedProjectStatus(.done)
  }

  @objc private func cancelSelectedProject() {
    setSelectedProjectStatus(.cancelled)
  }

  private func setSelectedProjectStatus(_ status: ProjectStatus) {
    guard case .project(let project, _) = selectedNode?.content else { return }
    let mutator = projectsMutator
    bounceToTodayIfShowing(key: "project:\(project.id)")
    Task { [weak self] in
      try? await mutator.setStatus(id: project.id, status: status)
      self?.rebuild(preserving: self?.selectedKey())
    }
  }

  /// If the item being deleted is the one currently on screen, don't leave
  /// the list showing a destination that no longer exists — same rescue the
  /// SwiftUI sidebar does.
  private func bounceToTodayIfShowing(key: String) {
    guard selectedKey() == key else { return }
    select(.today)
  }

}

/// The disclosure chevron — a real `NSButton`.
///
/// This was a hand-tracked custom `NSView` for a long time, on the theory that
/// an `NSButton` would lose its click to the row's drag-threshold tracking.
/// That theory was never verified, and three rounds of fixes on top of it
/// (mouseDown/mouseUp overrides, then a `hitTest` override) all failed to make
/// the fold work — the tell being that the pointing-hand cursor appeared the
/// whole time, which proves only that the view exists, never that clicks reach
/// it. `NSOutlineView` is built to host controls in its cells; a button gets
/// its own tracking, pressed state, keyboard activation, and accessibility for
/// free. Standard control, per CLAUDE.md — arrived at the hard way.
@MainActor
final class KitDisclosureView: NSButton {
  var onTap: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    isBordered = false
    bezelStyle = .inline
    imagePosition = .imageOnly
    contentTintColor = SeptaskKitTheme.iconMuted
    title = ""
    target = self
    action = #selector(fire)
    // Keyboard focus belongs to the outline view — arrow keys already expand
    // and collapse rows natively, so this must not become a tab stop.
    refusesFirstResponder = true
  }

  required init?(coder: NSCoder) { fatalError("KitDisclosureView is code-only") }

  @objc private func fire() { onTap?() }
}

/// Keyboard/right-click seam mirroring `SeptaskKitTableView` — see the
/// `onRightClick` comment in `loadView()` for why this bypasses `.menu`.
@MainActor
private final class KitSidebarOutlineView: NSOutlineView {
  var onRightClick: ((NSEvent) -> Void)?
  /// Tab / Shift-Tab — two-pane keyboard nav, list ⇄ sidebar (mirrors
  /// `SeptaskKitTableView.onFocusSidebar`).
  var onTab: (() -> Void)?
  /// A left click landed on a row (after AppKit's own tracking — selection
  /// and any drag — has finished).
  var onRowClick: (() -> Void)?
  /// Return / Enter with no modifiers.
  var onReturn: (() -> Void)?
  /// Fired when a drag leaves or ends over the outline view so transient drop
  /// chrome (like the Magic Plus badge) hides cleanly.
  var onDragEnded: (() -> Void)?

  override func draggingExited(_ sender: NSDraggingInfo?) {
    super.draggingExited(sender)
    onDragEnded?()
  }

  override func draggingEnded(_ sender: NSDraggingInfo) {
    super.draggingEnded(sender)
    onDragEnded?()
  }

  override func rightMouseDown(with event: NSEvent) {
    onRightClick?(event)
  }

  override func mouseDown(with event: NSEvent) {
    super.mouseDown(with: event)
    let point = convert(event.locationInWindow, from: nil)
    if row(at: point) >= 0, event.modifierFlags.isDisjoint(with: [.command, .shift]) {
      onRowClick?()
    }
  }

  /// Selection emphasis is computed per draw (`septaskSelectionIsActive`), so
  /// the rows must repaint when focus enters or leaves this sidebar. AppKit
  /// posts no notification for a first-responder change — these two overrides
  /// are the hook.
  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { septaskRefreshSelectionEmphasis() }
    return accepted
  }

  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    if resigned { septaskRefreshSelectionEmphasis() }
    return resigned
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 48 {  // Tab / Shift-Tab — only two stops in the loop.
      onTab?()
      return
    }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if event.keyCode == 36 || event.keyCode == 76,
       flags.isDisjoint(with: [.command, .shift, .option, .control]) {
      onReturn?()
      return
    }
    super.keyDown(with: event)
  }
}

/// Bottom strip of the macOS sidebar hosting the draggable Magic Plus control:
/// click opens the New Project / New Area menu; drag into the sidebar drops a
/// new Area (at Area level) or new Project (inside an Area or loose zone).
@MainActor
private final class KitSidebarMagicPlusBar: NSView, NSDraggingSource {
  var onClick: ((NSView) -> Void)?
  var onDragEnded: (() -> Void)?

  private let divider = NSBox()
  private let orb = NSView()
  private let plusIcon = NSImageView()
  private let label = NSTextField(labelWithString: String(localized: "New List", comment: "Sidebar footer button"))
  private var mouseDownPoint: NSPoint?
  private var didStartDrag = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    divider.boxType = .separator
    divider.translatesAutoresizingMaskIntoConstraints = false

    orb.wantsLayer = true
    orb.layer?.cornerRadius = 11
    orb.translatesAutoresizingMaskIntoConstraints = false

    plusIcon.translatesAutoresizingMaskIntoConstraints = false
    let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
    plusIcon.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
      .withSymbolConfiguration(cfg)

    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = SeptaskKitTheme.sidebarTitle
    label.textColor = SeptaskKitTheme.inkSecondary
    toolTip = String(localized: "Click for New Project or Area, or drag into the sidebar",
                     comment: "Sidebar Magic Plus tooltip")

    orb.addSubview(plusIcon)
    addSubview(divider)
    addSubview(orb)
    addSubview(label)
    NSLayoutConstraint.activate([
      divider.topAnchor.constraint(equalTo: topAnchor),
      divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      orb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      orb.centerYAnchor.constraint(equalTo: centerYAnchor),
      orb.widthAnchor.constraint(equalToConstant: 22),
      orb.heightAnchor.constraint(equalToConstant: 22),
      plusIcon.centerXAnchor.constraint(equalTo: orb.centerXAnchor),
      plusIcon.centerYAnchor.constraint(equalTo: orb.centerYAnchor),
      label.leadingAnchor.constraint(equalTo: orb.trailingAnchor, constant: 8),
      label.centerYAnchor.constraint(equalTo: orb.centerYAnchor),
      label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
    ])
    refreshAppearance()
  }

  required init?(coder: NSCoder) { fatalError("KitSidebarMagicPlusBar is code-only") }

  func refreshAppearance() {
    orb.layer?.backgroundColor = AppearancePreferences.shared.magicPlusNSColor.cgColor
    let ink: NSColor = AppearancePreferences.shared.magicPlusNSColor.isLightLuminance ? .black : .white
    plusIcon.contentTintColor = ink
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refreshAppearance()
  }

  override func mouseDown(with event: NSEvent) {
    mouseDownPoint = convert(event.locationInWindow, from: nil)
    didStartDrag = false
  }

  override func mouseDragged(with event: NSEvent) {
    guard !didStartDrag, let start = mouseDownPoint else { return }
    let current = convert(event.locationInWindow, from: nil)
    guard hypot(current.x - start.x, current.y - start.y) >= 5 else { return }
    didStartDrag = true

    let pbItem = NSPasteboardItem()
    pbItem.setString("magic-plus", forType: .septaskMagicPlus)
    let dragItem = NSDraggingItem(pasteboardWriter: pbItem)
    let preview = Self.dragOrbImage()
    let origin = NSPoint(x: current.x - preview.size.width / 2,
                         y: current.y - preview.size.height / 2)
    dragItem.setDraggingFrame(NSRect(origin: origin, size: preview.size), contents: preview)
    beginDraggingSession(with: [dragItem], event: event, source: self)
  }

  override func mouseUp(with event: NSEvent) {
    defer { mouseDownPoint = nil; didStartDrag = false }
    guard !didStartDrag else { return }
    let pt = convert(event.locationInWindow, from: nil)
    if bounds.contains(pt) {
      onClick?(orb)
    }
  }

  func draggingSession(_ session: NSDraggingSession,
                       sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
    context == .withinApplication ? .copy : []
  }

  func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                       operation: NSDragOperation) {
    onDragEnded?()
  }

  private static func dragOrbImage() -> NSImage {
    let size = NSSize(width: 24, height: 24)
    return NSImage(size: size, flipped: false) { rect in
      let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
      AppearancePreferences.shared.magicPlusNSColor.setFill()
      path.fill()
      let ink: NSColor = AppearancePreferences.shared.magicPlusNSColor.isLightLuminance ? .black : .white
      let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
      if let plus = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let tinted = plus.copy() as? NSImage ?? plus
        tinted.isTemplate = true
        let imgSize = tinted.size
        let imgRect = NSRect(x: (rect.width - imgSize.width) / 2,
                             y: (rect.height - imgSize.height) / 2,
                             width: imgSize.width, height: imgSize.height)
        ink.set()
        tinted.draw(in: imgRect)
      }
      return true
    }
  }
}

/// Floating pill shown over the macOS sidebar while dragging Magic Plus so the
/// user sees live whether releasing will create an Area or a Project (and in
/// which Area).
@MainActor
private final class KitSidebarMagicDropBadge: NSView {
  private let text = NSTextField(labelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = 11
    text.translatesAutoresizingMaskIntoConstraints = false
    text.font = .systemFont(ofSize: 11, weight: .semibold)
    text.lineBreakMode = .byTruncatingTail
    addSubview(text)
    NSLayoutConstraint.activate([
      text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
      text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
      text.topAnchor.constraint(equalTo: topAnchor, constant: 3),
      text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
    ])
  }

  required init?(coder: NSCoder) { fatalError("KitSidebarMagicDropBadge is code-only") }

  func configure(isArea: Bool, label: String) {
    let fill = AppearancePreferences.shared.magicPlusNSColor
    let ink: NSColor = fill.isLightLuminance ? .black : .white
    layer?.backgroundColor = fill.cgColor
    text.textColor = ink
    text.stringValue = (isArea ? "• " : "○ ") + label
    invalidateIntrinsicContentSize()
  }

  override var fittingSize: NSSize {
    let textSize = text.fittingSize
    return NSSize(width: min(210, textSize.width + 18), height: textSize.height + 6)
  }
}

private extension NSColor {
  var isLightLuminance: Bool {
    guard let srgb = usingColorSpace(.sRGB) else { return false }
    let luminance = 0.2126 * srgb.redComponent + 0.7152 * srgb.greenComponent + 0.0722 * srgb.blueComponent
    return luminance > 0.62
  }
}

/// Bridge to the outline view's node model. Kept here (not on the controller)
/// so the destination list stays the single source both the tree and the title
/// dropdown read.
extension KitSidebarDestination {
  var nodeContent: SeptaskKitSidebarController.Node.Content {
    switch self {
    case .filter(let f, let title): return .filter(f, title: title, symbol: symbol)
    }
  }
}

#endif
