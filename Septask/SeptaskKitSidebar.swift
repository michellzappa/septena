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

  /// The AppKit shell's smart-list destinations, in order — read from the SAME
  /// `TaskDestinations.sidebarRoutes` the SwiftUI sidebar and `TaskNavMenu`
  /// use, so all four surfaces (both shells' sidebars, both shells' title
  /// dropdowns) can never disagree about which lists exist or in what order.
  /// Recently Deleted is deliberately absent: it's appended by each surface
  /// only when the trash is non-empty.
  @MainActor static var smartLists: [KitSidebarDestination] {
    TaskDestinations.sidebarRoutes.compactMap(KitSidebarDestination.init(route:))
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
  private var roots: [Node] = []
  /// Every TOP-LEVEL area/loose-project row (not their nested project
  /// children) — each gets a bit of extra height above it in
  /// `heightOfRowByItem`, so each area still reads as its own section without
  /// the "Areas & Projects" text header that used to separate them.
  private var topLevelAreaOrProjectKeys: Set<String> = []
  /// Where `organize` (loose projects, then areas) begins within `roots` —
  /// `roots = views + organize`. Structure drag-reorder uses this to convert
  /// between "position within `roots`" (what NSOutlineView hands back for a
  /// root-level drop) and "position within the pure loose-project or
  /// pure-area id list" (what the mutators' `reorder(orderedIDs:)` expects).
  private var organizeStartIndex = 0
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
  private var showsCounts: Bool {
    UserDefaults.standard.object(forKey: SettingsKey.septaskSidebarCounts) == nil
      ? true
      : UserDefaults.standard.bool(forKey: SettingsKey.septaskSidebarCounts)
  }

  /// View ▸ Show Sidebar Counts — flips the setting and redraws every row
  /// (a rebuild isn't needed, the counts are already computed; only the
  /// badge text visibility changes).
  func toggleShowsCounts() {
    UserDefaults.standard.set(!showsCounts, forKey: SettingsKey.septaskSidebarCounts)
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
    outlineView.registerForDraggedTypes([.septaskTask, .septaskStructureItem])
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

    let scroll = NSScrollView()
    scroll.documentView = outlineView
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    view = scroll

    rebuild(preserving: nil)

    // Structure changes arrive from local mutations in the SwiftUI window or
    // a CloudKit batch; both post these. StructureCache invalidates itself on
    // the same signal, so re-reading here is always fresh. Tasks-changed is
    // in the list for the counts.
    for name in [Notification.Name.septenaStructureChanged, .septenaDataChanged,
                 .septenaTasksChanged] {
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
    // entire open table for every smart-list badge on every task edit.
    let all = LocalCache.allTasks(in: context).filter { !$0.isHeading }
    let open = all.filter { $0.status == .open }
    let today = SeptenaDate.today
    let inboxCount = open.filter { $0.isInTriageBand }.count
    let todayCount = open.filter { $0.isOnToday && !$0.isInTriageBand }.count
    let smartCounts: [TaskFilter: Int] = [
      .upcoming: open.filter { task in
        guard !task.today else { return false }
        return task.scheduled.map { $0 > today } == true
          || task.deadline.map { $0 > today } == true
      }.count,
      .repeating: open.filter { $0.recurrence != nil }.count,
      .unscheduled: open.filter {
        !$0.today && $0.scheduled == nil && $0.deadline == nil
      }.count,
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
    // Set + order come from `KitSidebarDestination.smartLists`, which reads
    // `TaskDestinations.sidebarRoutes` — the same list the title dropdown
    // builds from, so the two can't drift. Only the counts are sidebar work.
    var views = KitSidebarDestination.smartLists.map { destination in
      Node(destination.nodeContent, count: smartListCount(destination,
                                                          counts: smartCounts,
                                                          today: todayCount + inboxCount,
                                                          doneToday: doneTodayCount))
    }
    // Only shown once there's something in it — same gate the SwiftUI
    // sidebar uses, so an empty trash doesn't sit in the list forever.
    let recentlyDeletedCount = LocalCache.tasks(in: context, filter: .recentlyDeleted).count
    if recentlyDeletedCount > 0 {
      let deleted = KitSidebarDestination.filter(.recentlyDeleted,
                                                 title: TaskFilter.recentlyDeleted.title)
      views.append(Node(deleted.nodeContent, count: recentlyDeletedCount))
    }

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

    // No group wrapper nodes — the views cluster and the areas/projects
    // cluster are just adjacent siblings at the root. `roots` is what
    // `numberOfChildrenOfItem(nil)` returns, so this list order IS the
    // top-level row order.
    roots = views + organize
    organizeStartIndex = views.count
    topLevelAreaOrProjectKeys = Set(organize.map(\.key))
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
    guard !KitDrag.ids(from: info).isEmpty else {
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
    let dropped = LocalCache.allTasks(in: context).filter { ids.contains($0.id) }
    let scheduleBefore = dropped.map(TaskUndo.ScheduleSnapshot.init)
    let filingBefore = dropped.map(TaskUndo.FilingSnapshot.init)
    for id in ids {
      switch action {
      case .today:
        mutator.moveToToday(id: id)
      case .scheduleTomorrow:
        mutator.schedule(id: id, date: KitDayFormat.tomorrow())
        mutator.removeFromToday(id: id)
      case .anytime:
        mutator.schedule(id: id, date: nil)
        mutator.removeFromToday(id: id)
      case .area(let areaId):
        mutator.moveToList(id: id, area: areaId, project: nil)
      case .project(let projectId):
        mutator.moveToList(id: id, area: nil, project: projectId)
      }
      // A drop is a disposition, like filing from the list: it clears the
      // agent cue, so a proposal leaves the Inbox once the user has placed it.
      mutator.acknowledge(id: id)
    }
    switch action {
    case .today:
      TaskUndo.recordScheduleChange(
        name: String(localized: "Move to Today", comment: "SeptaskKit: undo action"),
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
  /// after any loose projects). Empty range at `roots.count` if there are
  /// no areas.
  private var areaNodeRange: Range<Int> {
    guard let first = roots.firstIndex(where: {
      if case .area = $0.content { return true }
      return false
    }) else { return roots.count..<roots.count }
    return first..<roots.count
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
    case .filter:
      return nil
    }
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

    // Glyph vocabulary mirrors the SwiftUI sidebar: smart lists wear the
    // Reminders-style colored square (only Today earns the accent — the rest
    // are quiet gray filing locations), areas their emoji or the muted dot,
    // projects their completion ring.
    cell.emoji.isHidden = true
    switch node.content {
    case .filter(let filter, let title, let symbol):
      cell.textField?.font = SeptaskKitTheme.sidebarTitle
      cell.textField?.stringValue = title
      let tint: NSColor = filter == .today
        ? SeptaskKitTheme.todayAccent
        : SeptaskKitTheme.inkSecondary
      cell.imageView?.image = KitGlyph.colored(symbol: symbol, color: tint)
    case .area(let area):
      // Areas share the same semibold navigation weight as smart lists and
      // projects; structure is carried by indentation and the disclosure
      // affordance rather than a heavy bold face.
      cell.textField?.font = SeptaskKitTheme.sidebarTitle
      cell.textField?.stringValue = area.title
      if let emoji = area.emoji {
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
      cell.imageView?.image = KitGlyph.progress(progress)
    }
    cell.badge.stringValue = showsCounts ? (node.count.map(String.init) ?? "") : ""

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

      disclosure.translatesAutoresizingMaskIntoConstraints = false
      disclosure.onTap = { [weak self] in self?.onToggleDisclosure?() }
      disclosure.setContentHuggingPriority(.required, for: .horizontal)

      addSubview(text)
      addSubview(image)
      addSubview(emoji)
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

    let menu = NSMenu()
    switch node?.content {
    case .area(let area):
      menu.addItem(item(String(localized: "New Project in \(area.title)",
                               comment: "SeptaskKit: sidebar context menu"),
                        #selector(newProjectInSelectedArea)))
      menu.addItem(.separator())
      menu.addItem(item(String(localized: "Rename Area…", comment: "SeptaskKit: sidebar context menu"),
                        #selector(renameSelected)))
      menu.addItem(item(String(localized: "Delete Area…", comment: "SeptaskKit: sidebar context menu"),
                        #selector(deleteSelected)))
    case .project(let project, _):
      menu.addItem(item(String(localized: "Rename Project…", comment: "SeptaskKit: sidebar context menu"),
                        #selector(renameSelected)))
      menu.addItem(moveToAreaItem(for: project))
      menu.addItem(.separator())
      menu.addItem(item(String(localized: "Delete Project…", comment: "SeptaskKit: sidebar context menu"),
                        #selector(deleteSelected)))
    case .filter(_, _, _), .none:
      menu.addItem(item(String(localized: "New Area…", comment: "SeptaskKit: sidebar context menu"),
                        #selector(newArea)))
      menu.addItem(item(String(localized: "New Project…", comment: "SeptaskKit: sidebar context menu"),
                        #selector(newProjectLoose)))
    }
    menu.popUp(positioning: nil, at: point, in: outlineView)
  }

  /// "Move to Area ▸" — No Area, then every area; the current parent is
  /// checked and inert.
  private func moveToAreaItem(for project: Project) -> NSMenuItem {
    let parent = NSMenuItem(title: String(localized: "Move to Area",
                                          comment: "SeptaskKit: sidebar context menu"),
                            action: nil, keyEquivalent: "")
    let submenu = NSMenu()
    let none = item(String(localized: "No Area", comment: "SeptaskKit: sidebar context menu"),
                    #selector(moveSelectedProject(_:)))
    none.representedObject = NSNull()
    none.state = project.area == nil ? .on : .off
    submenu.addItem(none)
    let areas = StructureCache.snapshot(in: context).areas
    if !areas.isEmpty { submenu.addItem(.separator()) }
    for area in areas {
      let entry = item(area.title, #selector(moveSelectedProject(_:)))
      entry.representedObject = area.id
      entry.state = project.area == area.id ? .on : .off
      submenu.addItem(entry)
    }
    parent.submenu = submenu
    return parent
  }

  private func item(_ title: String, _ action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    return item
  }

  private var selectedNode: Node? {
    outlineView.selectedRow >= 0 ? outlineView.item(atRow: outlineView.selectedRow) as? Node : nil
  }

  /// New Area lands a named row and opens it for editing, the way Finder
  /// lands "untitled folder". It used to stop the whole app with a modal text
  /// prompt to ask for a string the row can take directly.
  @objc func newArea() {
    Task { [weak self] in
      guard let self,
            let area = try? await self.areasMutator.create(
              title: String(localized: "New Area", comment: "SeptaskKit: structure CRUD"))
      else { return }
      self.recordAreaCreate(area)
      self.rebuild(preserving: "area:\(area.id)")
      self.beginRename(key: "area:\(area.id)")
    }
  }

  /// Undo for a new area deletes it; redo re-creates it under the SAME id,
  /// so anything later filed into it (and later undo steps) still resolve.
  private func recordAreaCreate(_ area: Area) {
    let mutator = areasMutator
    recordStructure(
      name: String(localized: "New Area", comment: "SeptaskKit: undo action"),
      undo: { Task { try? await mutator.delete(id: area.id) } },
      redo: { Task { _ = try? await mutator.createWithExplicitID(id: area.id, title: area.title) } })
  }

  private func recordProjectCreate(_ project: Project) {
    let mutator = projectsMutator
    recordStructure(
      name: String(localized: "New Project", comment: "SeptaskKit: undo action"),
      undo: { Task { try? await mutator.delete(id: project.id) } },
      redo: {
        Task {
          _ = try? await mutator.createWithExplicitID(id: project.id, title: project.title,
                                                      area: project.area)
        }
      })
  }

  @objc private func newProjectLoose() { newProject(inArea: nil) }

  @objc private func newProjectInSelectedArea() {
    guard case .area(let area) = selectedNode?.content else { return }
    newProject(inArea: area.id)
  }

  @objc func newProject() { newProject(inArea: nil) }

  private func newProject(inArea areaId: String?) {
    Task { [weak self] in
      guard let self,
            let project = try? await self.projectsMutator.create(
              title: String(localized: "New Project", comment: "SeptaskKit: structure CRUD"),
              area: areaId)
      else { return }
      self.recordProjectCreate(project)
      self.rebuild(preserving: "project:\(project.id)")
      self.beginRename(key: "project:\(project.id)")
    }
  }

  @objc private func renameSelected() {
    guard let key = selectedKey() else { return }
    beginRename(key: key)
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
          name: String(localized: "Rename Area", comment: "SeptaskKit: undo action"),
          undo: { Task { try? await mutator.rename(id: area.id, to: area.title) } },
          redo: { Task { try? await mutator.rename(id: area.id, to: title) } })
      }, onEnd: onEnd)
    case .project(let project, _):
      let mutator = projectsMutator
      cell.beginRename(onCommit: { [weak self] title in
        Task { try? await mutator.rename(id: project.id, to: title) }
        self?.recordStructure(
          name: String(localized: "Rename Project", comment: "SeptaskKit: undo action"),
          undo: { Task { try? await mutator.rename(id: project.id, to: project.title) } },
          redo: { Task { try? await mutator.rename(id: project.id, to: title) } })
      }, onEnd: onEnd)
    default:
      break
    }
  }

  @objc private func deleteSelected() {
    // Copy matches the SwiftUI sidebar's confirmation exactly (SidebarView) —
    // one deletion story between the two shells. A window SHEET, not an
    // app-modal alert, with Cancel as the Return default.
    switch selectedNode?.content {
    case .area(let area):
      KitPrompt.confirmDestructive(
        title: String(localized: "Delete \(area.title)?",
                      comment: "SeptaskKit: delete area confirm"),
        message: String(localized: "Projects in this area will be detached but not deleted.",
                        comment: "Delete area confirmation body"),
        in: view.window
      ) { [weak self] in
        self?.deleteArea(area)
      }
    case .project(let project, _):
      KitPrompt.confirmDestructive(
        title: String(localized: "Delete \(project.title)?",
                      comment: "SeptaskKit: delete project confirm"),
        message: String(localized: "Tasks in this project will be moved to the inbox.",
                        comment: "Delete project confirmation body"),
        in: view.window
      ) { [weak self] in
        self?.deleteProject(project)
      }
    default:
      break
    }
  }

  /// Delete is a hard delete in the store, so undo REBUILDS the area under
  /// its old id with its old fields and position. Projects and tasks keep
  /// pointing at that id, so they rejoin it as soon as it exists again.
  private func deleteArea(_ area: Area) {
    let mutator = areasMutator
    let order = StructureCache.snapshot(in: context).areas.map(\.id)
    bounceToTodayIfShowing(key: "area:\(area.id)")
    Task { try? await mutator.delete(id: area.id) }
    recordStructure(
      name: String(localized: "Delete Area", comment: "SeptaskKit: undo action"),
      undo: {
        Task {
          _ = try? await mutator.createWithExplicitID(id: area.id, title: area.title,
                                                      context: area.context)
          if area.emoji != nil { try? await mutator.setEmoji(id: area.id, emoji: area.emoji) }
          if area.attachment != nil {
            try? await mutator.setAttachment(id: area.id, attachment: area.attachment)
          }
          try? await mutator.reorder(orderedIDs: order)
        }
      },
      redo: { Task { try? await mutator.delete(id: area.id) } })
  }

  /// The project delete also detaches its tasks (the mutator's cascade), so
  /// undo rebuilds the project — every field, sidebar position included —
  /// brings its headings back, and re-files exactly the tasks that were in
  /// it. One shared inverse (`TaskUndo.recordProjectDelete`) for every
  /// surface that deletes a project.
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
  @objc private func moveSelectedProject(_ sender: NSMenuItem) {
    guard case .project(let project, _) = selectedNode?.content else { return }
    let target = sender.representedObject as? String
    guard target != project.area else { return }
    moveProject(project, toArea: target, at: nil, snapshot: StructureCache.snapshot(in: context))
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
