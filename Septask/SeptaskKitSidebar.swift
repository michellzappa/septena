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
// projects alongside. Selection drives the task list via `onSelect`.
//
// Things-style layout, deliberately un-Finder-like: NO section header rows
// ("Views" / "Areas & Projects"), NO per-level indentation — a project sits
// in the same left column as an area, distinguished only by nesting/order,
// not by an indent step. That means the built-in disclosure triangle (which
// lives IN the indentation column) has nowhere natural to draw, so it's
// suppressed and replaced with a custom chevron on the row's trailing edge,
// left of the count badge.
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
      case .filter(let filter, _, _): return "filter:\(filter.serverView)"
      case .area(let area): return "area:\(area.id)"
      case .project(let project, _): return "project:\(project.id)"
      }
    }
  }

  var onSelect: ((TaskFilter, String) -> Void)?
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

  private var context: ModelContext { LocalStore.shared.container.mainContext }

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
        MainActor.assumeIsolated { self?.rebuild(preserving: self?.selectedKey()) }
      })
    }
  }

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }

  /// Point the sidebar at a destination (Quick Find, or any other jump).
  /// Selecting the row is what drives the list, so navigation always leaves
  /// the sidebar and the content in agreement.
  func select(_ filter: TaskFilter) {
    let key: String = switch filter {
    case .area(let id): "area:\(id)"
    case .project(let id): "project:\(id)"
    default: "filter:\(filter.serverView)"
    }
    // A project inside a collapsed area has no row until the area is opened.
    outlineView.expandItem(nil, expandChildren: true)
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

  // MARK: - Tree

  private func rebuild(preserving key: String?) {
    let snapshot = StructureCache.snapshot(in: context)

    // Counts. Inbox/Today membership is view logic that must not be
    // re-derived here (drift) — those two go through the canonical filters.
    // Project/area counts come from one live-table pass.
    let inboxCount = LocalCache.tasks(in: context, filter: .triage).count
    let todayCount = LocalCache.tasks(in: context, filter: .today)
      .filter { !$0.isInTriageBand }.count
    let all = LocalCache.allTasks(in: context).filter { !$0.isHeading }
    let open = all.filter { $0.status == .open }
    let openByProject = Dictionary(grouping: open.compactMap(\.project), by: { $0 })
      .mapValues(\.count)
    // An area's count rolls up its own loose tasks plus its projects'.
    var openByArea = Dictionary(grouping: open.compactMap(\.area), by: { $0 })
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
    let doneTodayCount = LocalCache.tasks(in: context, filter: .logbook)
      .filter { ($0.completedAt ?? "").hasPrefix(SeptenaDate.today) }.count

    // Symbols come from `Route.filterIcon`; no separate Inbox row — loose
    // captures live in the triage band on top of Today (the same structure
    // the SwiftUI sidebar settled on, docs/TRIAGE_BAND_SPEC.md). The band's
    // size rides on Today's count so nothing about it is hidden.
    var views = [
      Node(.filter(.today, title: "Today", symbol: "sun.max.fill"),
           count: todayCount + inboxCount > 0 ? todayCount + inboxCount : nil),
      Node(.filter(.upcoming, title: "Upcoming", symbol: "calendar"),
           count: LocalCache.tasks(in: context, filter: .upcoming).count.nilIfZero),
      Node(.filter(.unscheduled, title: "Anytime", symbol: "rectangle.stack.fill"),
           count: LocalCache.tasks(in: context, filter: .unscheduled).count.nilIfZero),
      Node(.filter(.logbook, title: "Logbook", symbol: "checkmark"), count: doneTodayCount.nilIfZero),
    ]
    // Only shown once there's something in it — same gate the SwiftUI
    // sidebar uses, so an empty trash doesn't sit in the list forever.
    let recentlyDeletedCount = LocalCache.tasks(in: context, filter: .recentlyDeleted).count
    if recentlyDeletedCount > 0 {
      views.append(Node(.filter(.recentlyDeleted, title: "Recently Deleted", symbol: "trash"),
                        count: recentlyDeletedCount))
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
      let rollUp = (openByArea[area.id] ?? 0)
        + projects.reduce(0) { $0 + (openByProject[$1.id] ?? 0) }
      openByArea[area.id] = rollUp
      organize.append(Node(.area(area), children: children,
                           count: rollUp > 0 ? rollUp : nil))
    }

    // No group wrapper nodes — the views cluster and the areas/projects
    // cluster are just adjacent siblings at the root. `roots` is what
    // `numberOfChildrenOfItem(nil)` returns, so this list order IS the
    // top-level row order.
    roots = views + organize
    organizeStartIndex = views.count
    topLevelAreaOrProjectKeys = Set(organize.map(\.key))
    outlineView.reloadData()
    outlineView.expandItem(nil, expandChildren: true)

    if let key, let row = row(forKey: key) {
      outlineView.selectRowIndexes([row], byExtendingSelection: false)
    }
  }

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

  func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
    guard let node = item as? Node else { return roots.count }
    return node.children.count
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
      guard let node = item as? Node, dropAction(for: node) != nil else { return [] }
      // Always target the row itself, never a gap between rows.
      outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
      return .move
    }
    return validateStructureReorder(info, proposedItem: item, proposedChildIndex: index)
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
        mutator.moveToProject(id: id, project: nil)
        mutator.moveToArea(id: id, area: areaId)
      case .project(let projectId):
        mutator.moveToProject(id: id, project: projectId)
      }
    }
    // Local mutations don't broadcast on their own; both shells (and the
    // counts here) listen for this.
    NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    return true
  }

  // MARK: - Structure drag-reorder (areas / projects)
  //
  // Always compatible with the existing data: this calls the SAME
  // `reorder(orderedIDs:)` API and the SAME move-before-target math
  // (`SidebarView.reorderArea`/`reorderProject`) the SwiftUI sidebar's own
  // drag-and-drop already uses — areas reorder among themselves (a flat id
  // list), projects reorder among SAME-PARENT siblings only (loose projects
  // together, or together within one area). Cross-parent drops would be a
  // REPARENT, not a reorder, and are rejected — filing a project into a
  // different area happens via "New Project in ⟨Area⟩" or a task drop, not
  // by dragging the project row itself.

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
    // Only between-row drops reorder; dropping ON a row is the task-filing
    // gesture (handled above) or meaningless for a structure item.
    guard index != NSOutlineViewDropOnItemIndex, let dragged = draggedStructureNode(from: info)
    else { return [] }

    switch dragged.content {
    case .area:
      guard item == nil,
            areaNodeRange.contains(index) || index == areaNodeRange.upperBound
      else { return [] }
      outlineView.setDropItem(nil, dropChildIndex: index)
      return .move

    case .project(let project, _):
      if project.area == nil {
        // Loose project → root, within the loose-project prefix only (before
        // the area block begins).
        guard item == nil, index >= organizeStartIndex, index <= areaNodeRange.lowerBound
        else { return [] }
        outlineView.setDropItem(nil, dropChildIndex: index)
        return .move
      } else {
        // Project nested under an area → only back into that SAME area.
        guard let parent = item as? Node, case .area(let area) = parent.content,
              area.id == project.area
        else { return [] }
        outlineView.setDropItem(parent, dropChildIndex: index)
        return .move
      }

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
      var ids = snapshot.areas.map(\.id)
      guard let from = ids.firstIndex(of: area.id) else { return false }
      ids.remove(at: from)
      let to = min(max(0, index - areaNodeRange.lowerBound), ids.count)
      ids.insert(area.id, at: to)
      Task { try? await areasMutator.reorder(orderedIDs: ids) }
      return true

    case .project(let project, _):
      var siblings = snapshot.projects
        .filter { $0.area == project.area && $0.status == .active }
        .map(\.id)
      guard let from = siblings.firstIndex(of: project.id) else { return false }
      siblings.remove(at: from)
      // Root-relative for a loose project (needs the same offset validate
      // used); already parent-relative for a project nested under an area.
      let localIndex = project.area == nil ? index - organizeStartIndex : index
      let to = min(max(0, localIndex), siblings.count)
      siblings.insert(project.id, at: to)
      Task { try? await projectsMutator.reorder(orderedIDs: siblings) }
      return true

    case .filter:
      return false
    }
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
      cell.textField?.font = SeptaskKitTheme.taskTitle
      cell.textField?.stringValue = title
      let tint: NSColor = filter == .today
        ? SeptaskKitTheme.todayAccent
        : SeptaskKitTheme.inkSecondary
      cell.imageView?.image = KitGlyph.colored(symbol: symbol, color: tint)
    case .area(let area):
      // Bold — an area is a section, the weight that distinguishes it from
      // its own projects one level down.
      cell.textField?.font = .boldSystemFont(ofSize: SeptaskKitTheme.taskTitle.pointSize)
      cell.textField?.stringValue = area.title
      if let emoji = area.emoji {
        cell.emoji.isHidden = false
        cell.emoji.stringValue = emoji
        cell.imageView?.image = nil
      } else {
        cell.imageView?.image = KitGlyph.areaDot()
      }
    case .project(let project, let progress):
      cell.textField?.font = SeptaskKitTheme.taskTitle
      cell.textField?.stringValue = project.title
      cell.imageView?.image = KitGlyph.progress(progress)
    }
    cell.badge.stringValue = showsCounts ? (node.count.map(String.init) ?? "") : ""

    if node.children.isEmpty {
      cell.disclosure.isHidden = true
      cell.onToggleDisclosure = nil
    } else {
      cell.disclosure.isHidden = false
      cell.disclosure.image = Self.chevronImage(expanded: outlineView.isItemExpanded(node))
      cell.onToggleDisclosure = { [weak self, weak outlineView] in
        guard let outlineView else { return }
        if outlineView.isItemExpanded(node) {
          outlineView.animator().collapseItem(node)
        } else {
          outlineView.animator().expandItem(node)
        }
        self?.updateDisclosure(for: node)
      }
    }
    return cell
  }

  /// Refresh one row's chevron direction without reloading its children —
  /// called right after a click, and from the expand/collapse delegate
  /// methods below so keyboard/type-select toggles stay in sync too.
  private func updateDisclosure(for node: Node) {
    let row = outlineView.row(forItem: node)
    guard row >= 0, let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
      as? SidebarCell else { return }
    cell.disclosure.image = Self.chevronImage(expanded: outlineView.isItemExpanded(node))
  }

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
  fileprivate final class SidebarCell: NSTableCellView {
    let badge = NSTextField(labelWithString: "")
    /// An area's user glyph sits where the icon would — same slot, so titles
    /// stay aligned whether an area has an emoji or the muted dot.
    let emoji = NSTextField(labelWithString: "")
    /// Custom expand/collapse affordance — see the controller's
    /// `shouldShowOutlineCellForItem`.
    let disclosure = KitDisclosureView()
    var onToggleDisclosure: (() -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
      super.init(frame: .zero)
      self.identifier = identifier
      let text = NSTextField(labelWithString: "")
      text.translatesAutoresizingMaskIntoConstraints = false
      text.lineBreakMode = .byTruncatingTail
      text.font = SeptaskKitTheme.taskTitle
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
    guard outlineView.selectedRow >= 0,
          let node = outlineView.item(atRow: outlineView.selectedRow) as? Node else { return }
    switch node.content {
    case .filter(let filter, let title, _):
      onSelect?(filter, title)
    case .area(let area):
      onSelect?(.area(area.id), area.title)
    case .project(let project, _):
      onSelect?(.project(project.id), project.title)
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
      menu.addItem(item("New Project in \(area.title)", #selector(newProjectInSelectedArea)))
      menu.addItem(.separator())
      menu.addItem(item("Rename Area…", #selector(renameSelected)))
      menu.addItem(item("Delete Area…", #selector(deleteSelected)))
    case .project(let project, _):
      menu.addItem(item("Rename Project…", #selector(renameSelected)))
      menu.addItem(item("Delete Project…", #selector(deleteSelected)))
      _ = project
    case .filter(_, _, _), .none:
      menu.addItem(item("New Area…", #selector(newArea)))
      menu.addItem(item("New Project…", #selector(newProjectLoose)))
    }
    menu.popUp(positioning: nil, at: point, in: outlineView)
  }

  private func item(_ title: String, _ action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    return item
  }

  private var selectedNode: Node? {
    outlineView.selectedRow >= 0 ? outlineView.item(atRow: outlineView.selectedRow) as? Node : nil
  }

  @objc func newArea() {
    guard let title = KitPrompt.text(title: "New Area", placeholder: "Area name",
                                      confirmTitle: "Create") else { return }
    Task { try? await areasMutator.create(title: title) }
  }

  @objc private func newProjectLoose() { newProject(inArea: nil) }

  @objc private func newProjectInSelectedArea() {
    guard case .area(let area) = selectedNode?.content else { return }
    newProject(inArea: area.id)
  }

  @objc func newProject() { newProject(inArea: nil) }

  private func newProject(inArea areaId: String?) {
    guard let title = KitPrompt.text(title: "New Project", placeholder: "Project name",
                                      confirmTitle: "Create") else { return }
    Task { try? await projectsMutator.create(title: title, area: areaId) }
  }

  @objc private func renameSelected() {
    switch selectedNode?.content {
    case .area(let area):
      guard let title = KitPrompt.text(title: "Rename Area", placeholder: "Area name",
                                        initial: area.title, confirmTitle: "Rename")
      else { return }
      Task { try? await areasMutator.rename(id: area.id, to: title) }
    case .project(let project, _):
      guard let title = KitPrompt.text(title: "Rename Project", placeholder: "Project name",
                                        initial: project.title, confirmTitle: "Rename")
      else { return }
      Task { try? await projectsMutator.rename(id: project.id, to: title) }
    default:
      break
    }
  }

  @objc private func deleteSelected() {
    // Copy matches the SwiftUI sidebar's confirmation exactly (SidebarView) —
    // one deletion story between the two shells.
    switch selectedNode?.content {
    case .area(let area):
      guard KitPrompt.confirmDestructive(title: "Delete \(area.title)?",
                              message: "Projects in this area will be detached but not deleted.")
      else { return }
      Task { try? await areasMutator.delete(id: area.id) }
      bounceToTodayIfShowing(key: "area:\(area.id)")
    case .project(let project, _):
      guard KitPrompt.confirmDestructive(title: "Delete \(project.title)?",
                              message: "Tasks in this project will be moved to the inbox.")
      else { return }
      Task { try? await projectsMutator.delete(id: project.id) }
      bounceToTodayIfShowing(key: "project:\(project.id)")
    default:
      break
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

/// The disclosure chevron's hit area — a plain `NSButton` here would compete
/// with the ROW's own drag-recognition (the row is a drag SOURCE, for
/// structure reorder): a table/outline row view's `mouseDown` claims the
/// event for potential drag-threshold tracking before an ordinary subview's
/// click-tracking gets a turn, so the button's action could silently never
/// fire. Same fix already proven for the task checkbox
/// (`KitCheckboxView.mouseDown`) — hand-track press/release directly instead
/// of going through `NSButton`'s cell-tracking loop.
@MainActor
final class KitDisclosureView: NSView {
  private let imageView = NSImageView()
  var onTap: (() -> Void)?

  var image: NSImage? {
    get { imageView.image }
    set { imageView.image = newValue }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.contentTintColor = SeptaskKitTheme.iconMuted
    addSubview(imageView)
    NSLayoutConstraint.activate([
      imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
      imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("KitDisclosureView is code-only") }

  override func mouseDown(with event: NSEvent) {
    // Swallow — see the type comment.
  }

  override func mouseUp(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if bounds.contains(point) { onTap?() }
  }
}

/// Keyboard/right-click seam mirroring `SeptaskKitTableView` — see the
/// `onRightClick` comment in `loadView()` for why this bypasses `.menu`.
@MainActor
private final class KitSidebarOutlineView: NSOutlineView {
  var onRightClick: ((NSEvent) -> Void)?
  /// Tab / Shift-Tab — two-pane keyboard nav, list ⇄ sidebar (mirrors
  /// `SeptaskKitTableView.onFocusSidebar`).
  var onTab: (() -> Void)?

  override func rightMouseDown(with event: NSEvent) {
    onRightClick?(event)
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 48 {  // Tab / Shift-Tab — only two stops in the loop.
      onTab?()
      return
    }
    super.keyDown(with: event)
  }
}
#endif
