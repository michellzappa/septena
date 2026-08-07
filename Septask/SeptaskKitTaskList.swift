#if os(macOS)
import AppKit
import EventKit
import SwiftData

extension NSPasteboard.PasteboardType {
  /// Dragged task rows carry their stable task id — the same identity every
  /// wire and mutator speaks (docs/IDENTIFIERS.md).
  static let septaskTask = NSPasteboard.PasteboardType("com.septena.septask.task-id")
  /// Dragged SIDEBAR STRUCTURE rows (area/project reordering) — carries the
  /// node's `key` ("area:<id>" / "project:<id>"), distinct from
  /// `.septaskTask` so the sidebar's single drop handler can tell "reorder
  /// the sidebar itself" apart from "file a dragged task".
  static let septaskStructureItem = NSPasteboard.PasteboardType("com.septena.septask.structure-item")
}

/// Shared by the list (reorder/re-file drops) and the sidebar (file/schedule
/// drops).
@MainActor
enum KitDrag {
  static func ids(from info: NSDraggingInfo) -> [String] {
    (info.draggingPasteboard.pasteboardItems ?? [])
      .compactMap { $0.string(forType: .septaskTask) }
  }
}

// The spike's task list (see SeptaskKitWindow.swift for scope): a native
// NSTableView over LocalCache's ordered DTOs, writing through TaskMutator.
// Selection, arrow keys, type-select, and every shortcut below run on the
// synchronous responder chain — the feel being evaluated against SwiftUI.
//
// Structure matches the SwiftUI list: Today (setting-gated, default on) and
// Anytime group open tasks under area / project headers in sidebar order —
// loose tasks first, then each area (direct tasks, then its projects), then
// loose projects (`orderedFromGroupedOpen` in TaskListView is the reference).
// Flat Today sorts by due urgency instead, per the same setting's contract.
//
// Keyboard map — same bindings as `TaskRowShortcuts` (TaskCommands.swift),
// so the two shells never teach conflicting muscle memory:
//   ↑/↓, ⇧-arrows, type-select, Home/End — native NSTableView
//   ⌘K — toggle complete          ⌘T — toggle Today
//   ⌘N — new task in this list    ⌘, — settings
//   ⌘R, Return, double-click — rename via the field editor (Esc cancels)
//   ⌘⌫ — delete (soft; lands in Recently Deleted)
//   Space — deliberately unbound (the "Space completes the task" trap);
//           the checkbox refuses first responder for the same reason.
@MainActor
final class SeptaskKitTaskListController: NSViewController {

  /// A row's list-membership capsule ("# BFF", "📁 Admin") — shown only where
  /// the surrounding group doesn't already say where the task lives.
  struct Chip: Equatable {
    let symbol: String
    let title: String
  }

  /// The glyph a group header wears — mirrors the sidebar's vocabulary.
  enum GroupIcon: Equatable {
    case emoji(String)
    case areaDot
    case project(Double)
    case symbol(String)
  }

  /// A calendar event flattened to a value — the row diff compares rows, and
  /// EKEvent is a live reference whose identity says nothing about content.
  struct Event: Equatable {
    let id: String
    let title: String
    let time: String
  }

  /// One list line: a synthetic group header, a task row, a calendar event,
  /// the project/area page's own big title, or the "N logged items" footer.
  /// `key` is the stable identity the animated diff runs on.
  private enum Row: Equatable {
    case header(id: String, title: String, icon: GroupIcon, count: Int)
    case screenTitle(title: String, icon: GroupIcon)
    case task(SeptenaTask, chip: Chip?)
    case event(Event)
    case loggedFooter(count: Int, expanded: Bool)

    var key: String {
      switch self {
      case .header(let id, _, _, _): return "h:" + id
      case .screenTitle: return "screen-title"
      case .task(let task, _): return task.id
      case .event(let event): return "e:" + event.id
      case .loggedFooter: return "logged-footer"
      }
    }

    var task: SeptenaTask? {
      if case .task(let task, _) = self { return task }
      return nil
    }

    /// Rows that draw on a card (tasks and events), vs. headers on the page.
    var isCardRow: Bool {
      switch self {
      case .header, .screenTitle, .loggedFooter: return false
      case .task, .event: return true
      }
    }
  }

  private let tableView = SeptaskKitTableView()
  private let emptyLabel = NSTextField(labelWithString: "No Tasks")
  private var rows: [Row] = []
  private var filter: TaskFilter = .today
  private var observers: [NSObjectProtocol] = []
  /// A ⌘N row whose first title is still being typed — abandoned (empty on
  /// commit) it's purged, so escaping a fresh row leaves nothing behind.
  private var pendingNewTaskId: String?
  private var composerShowsNotes = false
  /// The row currently expanded into the inline composer, if any.
  private var composingTaskId: String?
  /// Completed rows are lingering on screen; refreshes wait (see `beginSettle`).
  private var isSettling = false
  private var settleWorkItem: DispatchWorkItem?
  /// Held so its submenu can be refreshed from the live structure on open.
  private let moveMenuItem = NSMenuItem()

  /// The inspector follows the selection; the window owns the wiring.
  var onSelectionChange: ((SeptenaTask?) -> Void)?
  /// A refresh landed — anything showing this data should re-read.
  var onStoreChanged: (() -> Void)?
  var onToggleInspector: (() -> Void)?
  var onQuickFind: (() -> Void)?
  /// A grouped Today/Anytime area or project header was clicked — drill into
  /// that list, the same destination its sidebar row goes to.
  var onNavigateToGroup: ((TaskFilter) -> Void)?
  /// Tab pressed while the list holds focus — the window owns moving focus
  /// to the sidebar (see `focusList()`'s sibling, `focusSidebar()`).
  var onFocusSidebar: (() -> Void)?

  private var context: ModelContext { LocalStore.shared.container.mainContext }

  // MARK: - Undo

  /// Owned rather than borrowed from `NSWindow` — without an `NSDocument`,
  /// `NSWindow.undoManager` is nil by default (that machinery is document
  /// -architecture-only). `NSViewController` IS an `NSResponder`, and this
  /// controller sits properly in the chain (a real child of the split view
  /// controller), so overriding `undoManager` here is what makes the
  /// standard Edit ▸ Undo/Redo menu items — and ⌘Z/⌘⇧Z — find it.
  private lazy var kitUndoManager = UndoManager()
  override var undoManager: UndoManager? { kitUndoManager }

  /// Registers `undoAction` as the inverse of a mutation just made; performing
  /// it (⌘Z) re-registers `redoAction` as ITS OWN inverse, which is what gives
  /// ⌘⇧Z (redo) for free — the standard `UndoManager` symmetric-registration
  /// idiom. Only covers the value-level mutators (complete/uncomplete,
  /// delete/restore, rename, move) — see docs/SEPTASK_APPKIT_PARITY.md for
  /// what's still unwired (dates, recurrence).
  private func recordUndo(name: String, undo undoAction: @escaping () -> Void,
                          redo redoAction: @escaping () -> Void) {
    kitUndoManager.setActionName(name)
    kitUndoManager.registerUndo(withTarget: self) { target in
      undoAction()
      target.recordUndo(name: name, undo: redoAction, redo: undoAction)
    }
  }
  private var mutator: TaskMutator { SeptenaServices.shared.taskMutator }

  override func loadView() {
    let column = NSTableColumn(identifier: .init("task"))
    tableView.addTableColumn(column)
    tableView.headerView = nil
    // Cards are drawn per row (KitCardRowView) on the page background, the
    // SwiftUI list's grouped-card look — so the table itself stays plain and
    // transparent rather than adding a second inset/background of its own.
    tableView.style = .plain
    // MUST be .custom: any other value makes AppKit impose its own row height
    // AND its own font on `NSTableCellView`s. That silently overrode the group
    // headers' larger font (the task rows escaped it only because they set an
    // `attributedStringValue`, which carries its own font attribute).
    tableView.rowSizeStyle = .custom
    tableView.backgroundColor = .clear
    tableView.intercellSpacing = NSSize(width: 0, height: 0)
    tableView.allowsMultipleSelection = true
    // The selection fill IS the focus indicator. A focus ring on top of it is
    // a second highlight language on one surface — and it draws in
    // `keyboardFocusIndicatorColor`, which follows the accent, so with this
    // app's ink accent it renders as a black box around the selected row.
    tableView.focusRingType = .none
    tableView.dataSource = self
    tableView.delegate = self
    tableView.target = self
    tableView.doubleAction = #selector(beginEditFromDoubleClick)
    tableView.onToggleComplete = { [weak self] in self?.toggleCompleteSelection() }
    tableView.onToggleToday = { [weak self] in self?.toggleTodaySelection() }
    tableView.onBeginEdit = { [weak self] in self?.beginEditSelectedRow() }
    tableView.onOpenComposer = { [weak self] in self?.beginComposingSelectedRow() }
    tableView.onDelete = { [weak self] in self?.deleteSelection() }
    tableView.onNewTask = { [weak self] in self?.createTask() }
    tableView.onToggleInspector = { [weak self] in self?.onToggleInspector?() }
    tableView.onQuickFind = { [weak self] in self?.onQuickFind?() }
    tableView.onWhen = { [weak self] in self?.presentDatePopover(kind: .when) }
    tableView.onDeadline = { [weak self] in self?.presentDatePopover(kind: .deadline) }
    tableView.onClearSchedule = { [weak self] in self?.clearScheduleSelection() }
    tableView.onDuplicate = { [weak self] in self?.duplicateSelection() }
    tableView.onMove = { [weak self] in self?.presentMoveMenu() }
    tableView.onFocusSidebar = { [weak self] in self?.onFocusSidebar?() }
    // Edit ▸ Copy targets the first responder, so implementing `copy(_:)` on
    // the table is what makes the STANDARD menu item work — better than a
    // second ⌘C item in the Task menu fighting it for the binding.
    tableView.onCopy = { [weak self] in self?.copySelection() }
    tableView.canCopy = { [weak self] in self?.hasActionableSelection ?? false }
    // NOT `tableView.menu = ...`: AppKit's automatic path for a table's
    // `.menu` property paints its own native "row targeted by a context
    // menu" highlight UNDERNEATH our custom fill — a second, uncontrollable
    // selection language on top of `KitCardRowView`'s. Popping the menu up
    // manually from `rightMouseDown` bypasses that machinery entirely.
    let contextMenu = buildContextMenu()
    let recentlyDeletedMenu = buildRecentlyDeletedMenu()
    tableView.onRightClick = { [weak self, weak tableView] event in
      guard let self, let tableView else { return }
      let point = tableView.convert(event.locationInWindow, from: nil)
      let row = tableView.row(at: point)
      guard row >= 0 else {
        // Blank space below the list, on a project page: the entry point
        // for adding a section, matching the SwiftUI page's own affordance.
        if case .project = self.filter {
          self.buildBlankSpaceMenu().popUp(positioning: nil, at: point, in: tableView)
        }
        return
      }
      if !tableView.selectedRowIndexes.contains(row) {
        tableView.selectRowIndexes([row], byExtendingSelection: false)
      }
      let menu: NSMenu
      if let task = self.rows[row].task, task.isHeading {
        menu = self.buildHeadingContextMenu()
      } else if self.filter == .recentlyDeleted {
        menu = recentlyDeletedMenu
      } else {
        menu = contextMenu
      }
      menu.popUp(positioning: nil, at: point, in: tableView)
    }
    tableView.registerForDraggedTypes([.septaskTask])
    tableView.setDraggingSourceOperationMask(.move, forLocal: true)

    let scroll = NSScrollView()
    scroll.documentView = tableView
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = true
    scroll.backgroundColor = SeptaskKitTheme.pageBackground
    // Breathing room above the first card and below the last — Things-style;
    // without it the list runs flush to the window's top and bottom edges.
    // `contentInsets` (not a spacer row) is the standard way to do this: it
    // pads the clip view rather than the document, so scroll/bounce and
    // "scroll to visible" all still measure from the real content edges.
    scroll.automaticallyAdjustsContentInsets = false
    scroll.contentInsets = NSEdgeInsets(top: 16, left: 0, bottom: 16, right: 0)
    view = scroll

    emptyLabel.font = SeptaskKitTheme.taskTitle
    emptyLabel.textColor = SeptaskKitTheme.iconMuted
    emptyLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(emptyLabel)
    NSLayoutConstraint.activate([
      emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])

    // CloudKit batches post .septenaTasksChanged; mutations made in the
    // SwiftUI window don't post anything (its views refresh themselves), so
    // window-becomes-key covers the cross-window A/B case.
    for name in [Notification.Name.septenaTasksChanged, .septenaStructureChanged,
                 .septenaDataChanged] {
      observers.append(NotificationCenter.default.addObserver(
        forName: name, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.reload() }
      })
    }
    observers.append(NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
    ) { [weak self] note in
      MainActor.assumeIsolated {
        guard let self, note.object as? NSWindow === self.view.window else { return }
        self.reload()
      }
    })
  }

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }

  /// True once `show` has run at least once — see the guard below.
  private var hasShownOnce = false

  /// THE actual fix for "linger doesn't linger": completing a task posts
  /// `.septenaTasksChanged` synchronously, which the SIDEBAR also observes to
  /// refresh its counts — and its rebuild reselects the (freshly rebuilt,
  /// so identity-different) currently-selected row, which re-fires `onSelect`
  /// → `show(sameFilter, ...)` on THIS list, synchronously, mid-settle.
  /// Reselecting the destination you're already on must be a no-op, or every
  /// settle gets cancelled the instant it starts by the very completion that
  /// triggered it. `hasShownOnce` keeps this from also swallowing the very
  /// first call at launch, when `filter` already equals the default `.today`
  /// before anything has actually loaded.
  func show(_ filter: TaskFilter, title: String) {
    if hasShownOnce, filter == self.filter { return }
    hasShownOnce = true
    cancelSettle()
    self.filter = filter
    view.window?.subtitle = title
    reload(animated: false)
    if tableView.numberOfRows > 0 {
      tableView.scrollRowToVisible(0)
    }
  }

  /// Give the task list keyboard focus. Called once the window is on screen
  /// so arrow keys drive TASKS from the start — AppKit would otherwise make
  /// the sidebar (the first view in the split) the initial first responder,
  /// which is the "arrows move the sidebar selection" trap the SwiftUI shell
  /// also had (see CLAUDE.md, "the sidebar holds focus by default").
  func focusList() {
    view.window?.makeFirstResponder(tableView)
    if tableView.selectedRow < 0, let first = rows.firstIndex(where: { $0.task != nil }) {
      tableView.selectRowIndexes([first], byExtendingSelection: false)
    }
  }

  /// Select and reveal a row by task id — how a jump (Quick Find) lands on
  /// the thing it was asked to find. No-op when the task isn't in this list.
  func select(taskId: String) {
    guard let row = rows.firstIndex(where: { $0.task?.id == taskId }) else { return }
    tableView.selectRowIndexes([row], byExtendingSelection: false)
    tableView.scrollRowToVisible(row)
    view.window?.makeFirstResponder(tableView)
  }

  // MARK: - Data

  /// True while a title field editor is live in this table — a mid-edit
  /// reloadData() would destroy the editing session (e.g. a CloudKit batch
  /// landing while the user types), so reloads defer until the edit commits.
  private var isTitleEditorActive: Bool {
    guard let editor = view.window?.firstResponder as? NSTextView,
          let field = editor.delegate as? NSTextField else { return false }
    return field.isDescendant(of: tableView)
  }

  /// Mirrors SettingsKey.todayGroupByList's contract: absent → on.
  private var todayGroupsByList: Bool {
    UserDefaults.standard.object(forKey: SettingsKey.todayGroupByList) == nil
      ? true
      : UserDefaults.standard.bool(forKey: SettingsKey.todayGroupByList)
  }

  private func reload(animated: Bool = true) {
    // Every edit funnels through commitRename, which reloads — so a skipped
    // refresh here is picked up the moment the edit ends. The settle window
    // ends in a reload of its own, so skipping here is likewise not a loss.
    if isTitleEditorActive || isSettling || composingTaskId != nil { return }

    let selected = Set(tableView.selectedRowIndexes.compactMap { row in
      rows.indices.contains(row) ? rows[row].task?.id : nil
    })

    var pool = LocalCache.tasks(in: context, filter: filter)
    // One standard title row, on every page — computed once here rather than
    // duplicated into each branch below.
    let titleRows: [Row] = screenTitleRow().map { [$0] } ?? []
    var newRows: [Row]
    switch filter {
    case .today where todayGroupsByList:
      newRows = titleRows + agenda() + triageBand() + groupedByList(withoutTriage(pool))
    case .today:
      // Flat Today: due-first ordering, per the setting's documented contract.
      newRows = titleRows + agenda() + triageBand()
        + withoutTriage(pool).sorted(by: SeptenaTask.compareNextPageOrder).map(chipped)
    case .upcoming:
      newRows = titleRows + upcomingBuckets(pool)
    case .unscheduled:
      newRows = titleRows + groupedByList(pool)
    case .project, .area:
      // Scoped reads return every live status; capture the done subset for
      // the logged footer BEFORE narrowing `pool` to open work (+ headings) —
      // finished rows don't live inline here, same as the SwiftUI page.
      var completed = pool.filter { $0.status == .done }
      if case .area = filter {
        // Area pages show only area-DIRECT work in the open list — a task
        // filed under one of the area's projects appears on that project's
        // page, not doubled here. The logged footer honors the same split.
        completed = completed.filter { $0.project == nil }
      }
      completed.sort { ($0.completedAt ?? "") > ($1.completedAt ?? "") }

      pool = pool.filter { $0.isHeading || $0.status == .open }
      newRows = titleRows + pool.map { .task($0, chip: nil) }
        + loggedFooterRows(completed: completed)
    case .logbook:
      // Already most-recent-first from LocalCache; cap what one screen needs.
      newRows = titleRows + pool.prefix(200).map(chipped)
    default:
      newRows = titleRows + pool.map(chipped)
    }

    apply(newRows, animated: animated)
    emptyLabel.isHidden = !rows.isEmpty
    onStoreChanged?()

    if !selected.isEmpty {
      let indexes = IndexSet(rows.indices.filter {
        guard let id = rows[$0].task?.id else { return false }
        return selected.contains(id)
      })
      tableView.selectRowIndexes(indexes, byExtendingSelection: false)
    }
  }

  /// Gated on the setting AND on access already being granted — this shell
  /// never triggers the permission prompt itself; Settings ▸ Integrations
  /// owns that, same as `agenda()`/`upcomingBuckets()` below.
  private var showsCalendarEvents: Bool {
    let enabled = UserDefaults.standard.object(forKey: SettingsKey.tasksShowCalendarEvents) == nil
      ? true
      : UserDefaults.standard.bool(forKey: SettingsKey.tasksShowCalendarEvents)
    return enabled && CalendarBridge.shared.access == .granted
  }

  /// TODAY's calendar agenda, woven above the tasks the way the SwiftUI list
  /// weaves it (`TaskListModel.refreshCalendarEvents`) — what's still ahead
  /// today. Upcoming uses `upcomingBuckets()` instead, which weaves events
  /// per-day rather than as one block at the top.
  private func agenda() -> [Row] {
    guard showsCalendarEvents else { return [] }
    let events = CalendarBridge.shared.remainingTodayEvents()
    guard !events.isEmpty else { return [] }

    let rows = events.map { event in
      Row.event(Event(id: event.eventIdentifier ?? UUID().uuidString,
                      title: event.title ?? "",
                      time: KitDayFormat.eventTime(event, on: filter)))
    }
    return [.header(id: "agenda", title: "Agenda", icon: .symbol("calendar"),
                    count: events.count)] + rows
  }

  /// Upcoming grouped by day — matches `TaskListView.upcomingBuckets()`
  /// exactly: bucket key is the EARLIEST FUTURE of a task's scheduled/deadline
  /// date (so a past-scheduled, future-deadline task buckets on the deadline,
  /// never under a stale header), days are the UNION of task-days and
  /// event-days (an all-day-event-only day still gets a row), sorted
  /// ascending, with `SeptenaDate.scheduleHeaderLabel` giving each day's
  /// title ("Today"/"Tomorrow"/weekday/"EEE, MMM d" — the exact same
  /// function, not a reimplementation).
  private func upcomingBuckets(_ pool: [SeptenaTask]) -> [Row] {
    let today = SeptenaDate.today
    var tasksByDay: [String: [SeptenaTask]] = [:]
    for task in pool {
      let key = [task.scheduled, task.deadline]
        .compactMap { $0 }
        .filter { $0 > today }
        .min()
      guard let key else { continue }
      tasksByDay[key, default: []].append(task)
    }

    var eventsByDay: [String: [EKEvent]] = [:]
    if showsCalendarEvents {
      for event in CalendarBridge.shared.upcomingEvents(days: 30) {
        for key in upcomingDayKeys(for: event) {
          eventsByDay[key, default: []].append(event)
        }
      }
    }

    let days = Set(tasksByDay.keys).union(eventsByDay.keys).sorted()
    var rows: [Row] = []
    for key in days {
      let label = SeptenaDate.parse(key).map(SeptenaDate.scheduleHeaderLabel) ?? key
      let dayTasks = tasksByDay[key] ?? []
      let dayEvents = eventsByDay[key] ?? []
      rows.append(.header(id: "day-\(key)", title: label, icon: .symbol("calendar"),
                         count: dayTasks.count))
      rows.append(contentsOf: dayEvents.map { event in
        .event(Event(id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? "",
                    time: KitDayFormat.eventTime(event, on: filter)))
      })
      rows.append(contentsOf: dayTasks.map(chipped))
    }
    return rows
  }

  /// Every day an event covers within the 30-day window — a multi-day
  /// all-day event (e.g. a long weekend) shows on each day it spans, not
  /// just its start day. Mirrors `TaskListView.upcomingDayKeys(for:)`.
  private func upcomingDayKeys(for event: EKEvent) -> [String] {
    let cal = Calendar.current
    guard let today = SeptenaDate.startOfDay(for: SeptenaDate.today),
          let start = event.startDate,
          let windowEnd = cal.date(byAdding: .day, value: 30, to: today)
    else { return [] }
    var endRef = event.endDate ?? start
    if event.isAllDay, endRef == cal.startOfDay(for: endRef) {
      endRef = endRef.addingTimeInterval(-1)
    }
    var day = max(cal.startOfDay(for: start), today)
    let lastDay = min(cal.startOfDay(for: endRef), windowEnd)
    var keys: [String] = []
    while day <= lastDay {
      if let key = SeptenaDate.format(day) { keys.append(key) }
      guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
      day = next
    }
    return keys
  }

  /// The unratified band that rides on top of Today — loose captures and
  /// agent proposals (docs/TRIAGE_BAND_SPEC.md). This is why the sidebar has
  /// no separate Inbox row: the band IS the inbox, and it lives here, exactly
  /// as the SwiftUI Today renders it.
  private func triageBand() -> [Row] {
    let band = LocalCache.tasks(in: context, filter: .triage)
    guard !band.isEmpty else { return [] }
    return [.header(id: "inbox", title: "Inbox", icon: .symbol("tray"), count: band.count)]
      + band.map(chipped)
  }

  /// An MCP-authored row can satisfy both the triage band and Today (the band
  /// keys off the agent cue, not the date fields), so Today's own rows drop
  /// anything already shown in the band above.
  private func withoutTriage(_ pool: [SeptenaTask]) -> [SeptenaTask] {
    pool.filter { !$0.isInTriageBand }
  }

  /// A task row carrying its list-membership chip, for surfaces where the
  /// group doesn't already say where the task lives. Agent-authored triage
  /// rows are exactly why loose lists still need this — they can carry a
  /// project while sitting in the band.
  private func chipped(_ task: SeptenaTask) -> Row {
    .task(task, chip: chip(for: task))
  }

  private func chip(for task: SeptenaTask) -> Chip? {
    let snapshot = StructureCache.snapshot(in: context)
    if let projectId = task.project,
       let project = snapshot.projects.first(where: { $0.id == projectId }) {
      return Chip(symbol: "number", title: project.title)
    }
    if let areaId = task.area,
       let area = snapshot.areas.first(where: { $0.id == areaId }) {
      return Chip(symbol: "folder", title: area.title)
    }
    return nil
  }

  /// The grouped open list — reference implementation is TaskListView's
  /// `orderedFromGroupedOpen`: loose tasks, then each area (direct tasks,
  /// then its projects), then loose projects. Sidebar order throughout
  /// (StructureCache). Headers only appear above non-empty groups, and carry
  /// the same glyph + count as their sidebar row.
  // MARK: - Project/area page chrome (screen title, logged footer)

  /// The current project/area's id, when the list is scoped to one — the
  /// same value both the title row and the logged-footer state key key off.
  private var scopeId: String? {
    switch filter {
    case .project(let id), .area(let id): return id
    default: return nil
    }
  }

  /// The page's own big title — an area's emoji/dot or a project's
  /// completion ring, plus its name at a larger rung than an in-list group
  /// header. macOS windows have no automatic "large title" the way an iOS
  /// nav bar does, so this is what stands in for it, same as the SwiftUI
  /// destination screens.
  /// One standard component on EVERY page, not just project/area — the
  /// smart lists use the same symbols the sidebar rows do
  /// (`NavigationState.filterIcon`), so a page's title always matches the
  /// icon you clicked in the sidebar to get there.
  private func screenTitleRow() -> Row? {
    let snapshot = StructureCache.snapshot(in: context)
    switch filter {
    case .today: return .screenTitle(title: "Today", icon: .symbol("sun.max.fill"))
    case .triage: return .screenTitle(title: "Inbox", icon: .symbol("tray"))
    case .upcoming: return .screenTitle(title: "Upcoming", icon: .symbol("calendar"))
    case .unscheduled: return .screenTitle(title: "Anytime", icon: .symbol("rectangle.stack.fill"))
    case .logbook: return .screenTitle(title: "Logbook", icon: .symbol("checkmark"))
    case .recentlyDeleted: return .screenTitle(title: "Recently Deleted", icon: .symbol("trash"))
    case .project(let id):
      guard let project = snapshot.projects.first(where: { $0.id == id }) else { return nil }
      let progress = projectProgress()[id] ?? 0
      return .screenTitle(title: project.title, icon: .project(progress))
    case .area(let id):
      guard let area = snapshot.areas.first(where: { $0.id == id }) else { return nil }
      return .screenTitle(title: area.title, icon: area.emoji.map(GroupIcon.emoji) ?? .areaDot)
    }
  }

  /// Same UserDefaults key AND encoding `TaskListView`'s
  /// `scopeLoggedExpandedData` (`@AppStorage`-backed `Data` holding a
  /// JSON `Set<String>` of expanded project/area ids) uses — sharing it
  /// means expand/collapse state agrees between this shell and the classic
  /// SwiftUI window instead of drifting into two independent trackers.
  private static let loggedExpandedKey = "septena.tasks.projectLoggedExpanded"

  private func loggedExpandedIds() -> Set<String> {
    guard let data = UserDefaults.standard.data(forKey: Self.loggedExpandedKey) else { return [] }
    return (try? JSONDecoder().decode(Set<String>.self, from: data)) ?? []
  }

  /// Things-style footer: "Show N logged items" / collapsed by default,
  /// expanding into the completed tasks for this page. Matches
  /// `TaskListView.scopeLoggedSection` exactly (same copy, same sort —
  /// newest-completed-first).
  private func loggedFooterRows(completed: [SeptenaTask]) -> [Row] {
    guard let scopeId, !completed.isEmpty else { return [] }
    let expanded = loggedExpandedIds().contains(scopeId)
    var rows: [Row] = [.loggedFooter(count: completed.count, expanded: expanded)]
    if expanded {
      rows.append(contentsOf: completed.map { .task($0, chip: nil) })
    }
    return rows
  }

  func toggleLoggedExpanded() {
    guard let scopeId else { return }
    var ids = loggedExpandedIds()
    if ids.contains(scopeId) { ids.remove(scopeId) } else { ids.insert(scopeId) }
    UserDefaults.standard.set((try? JSONEncoder().encode(ids)) ?? Data(),
                              forKey: Self.loggedExpandedKey)
    // Hard reload, not the diffed animated path: this can insert/remove a
    // whole BLOCK of rows below the footer in one go, and an instant
    // reveal/collapse reads as correct disclosure behavior on its own —
    // no need to fight the diff machinery for what's an infrequent toggle.
    reload(animated: false)
  }

  private func groupedByList(_ pool: [SeptenaTask]) -> [Row] {
    let snapshot = StructureCache.snapshot(in: context)
    let byProject = Dictionary(grouping: pool.filter { $0.project != nil },
                               by: { $0.project! })
    let byArea = Dictionary(grouping: pool.filter { $0.project == nil && $0.area != nil },
                            by: { $0.area! })
    let loose = pool.filter { $0.project == nil && $0.area == nil }
    let progress = projectProgress()

    // Loose rows keep their chips: an agent proposal can name a project while
    // still sitting in the ungrouped band.
    var result: [Row] = loose.map(chipped)
    func appendProject(_ project: Project) {
      guard let tasks = byProject[project.id], !tasks.isEmpty else { return }
      result.append(.header(id: "p-\(project.id)", title: project.title,
                            icon: .project(progress[project.id] ?? 0),
                            count: tasks.count))
      result.append(contentsOf: tasks.map { .task($0, chip: nil) })
    }
    for area in snapshot.areas {
      if let direct = byArea[area.id], !direct.isEmpty {
        result.append(.header(id: "a-\(area.id)", title: area.title,
                              icon: area.emoji.map(GroupIcon.emoji) ?? .areaDot,
                              count: direct.count))
        result.append(contentsOf: direct.map { .task($0, chip: nil) })
      }
      for project in snapshot.projects where project.area == area.id {
        appendProject(project)
      }
    }
    for project in snapshot.projects where project.area == nil {
      appendProject(project)
    }
    return result
  }

  /// Completion ratio per project — done / (done + open), matching the
  /// sidebar's ring. Cancelled rows don't count either way.
  private func projectProgress() -> [String: Double] {
    var done: [String: Int] = [:]
    var open: [String: Int] = [:]
    for task in LocalCache.allTasks(in: context) where !task.isHeading {
      guard let project = task.project else { continue }
      switch task.status {
      case .done: done[project, default: 0] += 1
      case .open: open[project, default: 0] += 1
      case .cancelled: break
      }
    }
    var result: [String: Double] = [:]
    for (project, doneCount) in done {
      let total = doneCount + (open[project] ?? 0)
      result[project] = total > 0 ? Double(doneCount) / Double(total) : 0
    }
    for project in open.keys where result[project] == nil {
      result[project] = 0
    }
    return result
  }

  /// Animated structural diff: rows keep identity by `key`, so completes fade
  /// out where they sit, arrivals slide in, and everything else stays put.
  /// Falls back to a hard reload for filter switches / first population, and
  /// collapses to an instant swap under Reduce Motion.
  private func apply(_ new: [Row], animated: Bool) {
    let old = rows
    rows = new

    guard animated, !old.isEmpty, !KitMotion.reduce else {
      tableView.reloadData()
      return
    }

    let oldKeys = old.map(\.key)
    let newKeys = new.map(\.key)
    if oldKeys == newKeys {
      var changed = IndexSet()
      for index in new.indices where new[index] != old[index] { changed.insert(index) }
      if !changed.isEmpty {
        tableView.reloadData(forRowIndexes: changed, columnIndexes: [0])
      }
      return
    }

    let diff = newKeys.difference(from: oldKeys).inferringMoves()
    tableView.beginUpdates()
    for change in diff {
      switch change {
      case .remove(let offset, _, let association):
        if association == nil {
          tableView.removeRows(at: [offset], withAnimation: KitMotion.removeRows)
        }
      case .insert(let offset, _, let association):
        if let from = association {
          tableView.moveRow(at: from, to: offset)
        } else {
          tableView.insertRows(at: [offset], withAnimation: KitMotion.insertRows)
        }
      }
    }
    tableView.endUpdates()

    // Surviving rows whose content changed (rename, date, today flag).
    let oldByKey = Dictionary(old.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    var changed = IndexSet()
    for index in new.indices {
      if let previous = oldByKey[new[index].key], previous != new[index] {
        changed.insert(index)
      }
    }
    if !changed.isEmpty {
      tableView.reloadData(forRowIndexes: changed, columnIndexes: [0])
    }
  }

  /// Whether a row command has anything to act on — drives menu enablement.
  var hasActionableSelection: Bool { !actionableSelection.isEmpty }

  /// Copy the selection's titles — one per line. Reached through Edit ▸ Copy
  /// (the table implements `copy(_:)`, so the standard menu item finds it on
  /// the responder chain) as well as the row menus.
  func copySelection() {
    let titles = actionableSelection.map(\.title)
    guard !titles.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(titles.joined(separator: "\n"), forType: .string)
  }

  func duplicateSelection() {
    for task in actionableSelection {
      _ = mutator.duplicate(task)
    }
    reload()
  }

  /// File the selection. `nil` area+project is the loose "No List" case.
  func move(to destination: KitMoveMenu.Destination) {
    let selection = actionableSelection
    guard !selection.isEmpty else { return }
    // Captured before mutating, so undo can restore each task's EXACT prior
    // (project, area) pair — not just "the previous list", since a batch move
    // can start from several different lists at once.
    let previous = selection.map { (id: $0.id, project: $0.project, area: $0.area) }

    func apply(_ destination: KitMoveMenu.Destination, project: String?, area: String?, id: String) {
      switch destination {
      case .none:
        mutator.moveToProject(id: id, project: nil)
        mutator.moveToArea(id: id, area: nil)
      case .area(let areaId):
        mutator.moveToProject(id: id, project: nil)
        mutator.moveToArea(id: id, area: areaId)
      case .project(let projectId):
        mutator.moveToProject(id: id, project: projectId)
      }
    }

    recordUndo(name: "Move Task",
              undo: { [weak self] in
                guard let self else { return }
                for entry in previous {
                  self.mutator.moveToProject(id: entry.id, project: entry.project)
                  self.mutator.moveToArea(id: entry.id, area: entry.area)
                }
                self.reload()
                self.onStoreChanged?()
              },
              redo: { [weak self] in
                guard let self else { return }
                for entry in previous {
                  apply(destination, project: entry.project, area: entry.area, id: entry.id)
                }
                self.reload()
                self.onStoreChanged?()
              })

    for entry in previous {
      apply(destination, project: entry.project, area: entry.area, id: entry.id)
    }
    reload()
    onStoreChanged?()
  }

  /// ⌘⇧M — pop the move menu at the selected row. A menu (not a bespoke
  /// picker) so it gets arrow keys and type-select for free.
  func presentMoveMenu() {
    guard !actionableSelection.isEmpty, tableView.selectedRow >= 0 else { return }
    let snapshot = StructureCache.snapshot(in: context)
    let menu = KitMoveMenu.build(areas: snapshot.areas, projects: snapshot.projects,
                                 target: self, action: #selector(menuMoveTo(_:)))
    let rect = tableView.rect(ofRow: tableView.selectedRow)
    menu.popUp(positioning: nil,
               at: NSPoint(x: rect.minX + 40, y: rect.maxY),
               in: tableView)
  }

  /// Apply a repeat rule to the selection (menu bar + context menu).
  func setRecurrence(_ rule: Recurrence?) {
    for task in actionableSelection {
      mutator.setRecurrence(id: task.id, recurrence: rule)
    }
    reload()
    onStoreChanged?()
  }

  /// The rows a command applies to (headings excluded — they only rename).
  private var actionableSelection: [SeptenaTask] {
    tableView.selectedRowIndexes.compactMap { row in
      guard rows.indices.contains(row), let task = rows[row].task else { return nil }
      return task.isHeading ? nil : task
    }
  }

  // MARK: - Mutations

  func toggleCompleteSelection() {
    // Mark-complete has no meaning in the trash — checkbox tap and ⌘K both
    // route to restore there (see `toggle(id:)`).
    guard filter != .recentlyDeleted else {
      restoreTasks(actionableSelection.map(\.id))
      return
    }
    let selection = actionableSelection
    guard !selection.isEmpty else { return }
    apply(completing: selection.filter { $0.status == .open },
         reopening: selection.filter { $0.status != .open })
  }

  private func toggle(id: String) {
    // In the trash, a checkbox tap means "bring this back" — mark-complete
    // has no meaning for an already-deleted row.
    guard filter != .recentlyDeleted else {
      restoreTasks([id])
      return
    }
    guard let task = rows.compactMap(\.task).first(where: { $0.id == id }) else { return }
    if task.status == .open {
      apply(completing: [task], reopening: [])
    } else {
      apply(completing: [], reopening: [task])
    }
  }

  // MARK: - Recently Deleted (restore / purge)

  private func restoreTasks(_ ids: [String]) {
    guard !ids.isEmpty else { return }
    recordUndo(name: "Restore Task",
              undo: { [weak self] in
                for id in ids { self?.mutator.delete(id: id) }
                self?.reload()
              },
              redo: { [weak self] in
                for id in ids { self?.mutator.restore(id: id) }
                self?.reload()
              })
    for id in ids { mutator.restore(id: id) }
    reload()
  }

  private func purgeTasks(_ ids: [String]) {
    // No undo: purge is a real SwiftData delete, not a tombstone — there is
    // no state left to restore from.
    for id in ids { mutator.purge(id: id) }
    reload()
  }

  /// Complete/reopen a batch. Completed rows in drop-done lists get the
  /// settle beat — restyled checked in place, then removed after a beat by
  /// the diffed reload's fade. Views that keep completed rows (Logbook) and
  /// pure reopens refresh immediately.
  ///
  /// Restyling and `isSettling = true` happen BEFORE any `mutator` call —
  /// `TaskMutator.complete`/`uncomplete` post `.septenaTasksChanged`
  /// SYNCHRONOUSLY (`commitAndPush` → `TaskChange.post`, on the calling
  /// thread, before the call returns). `reload()`'s only defense against that
  /// racing ahead of the restyle is the `isSettling` flag, so it has to
  /// already be true by the time the first mutator call fires — setting it
  /// afterward is a no-op, the notification's reload already ran and wiped
  /// the row before the linger ever started. This IS why the linger
  /// previously didn't linger.
  private func apply(completing: [SeptenaTask], reopening: [SeptenaTask]) {
    if !completing.isEmpty || !reopening.isEmpty {
      let completingIds = completing.map(\.id)
      let reopeningIds = reopening.map(\.id)
      recordUndo(name: completingIds.isEmpty ? "Reopen Task" : "Complete Task",
                undo: { [weak self] in
                  for id in completingIds { self?.mutator.uncomplete(id: id) }
                  for id in reopeningIds { self?.mutator.complete(id: id) }
                  self?.reload()
                },
                redo: { [weak self] in
                  for id in completingIds { self?.mutator.complete(id: id) }
                  for id in reopeningIds { self?.mutator.uncomplete(id: id) }
                  self?.reload()
                })
    }
    guard !completing.isEmpty else {
      for task in reopening { mutator.uncomplete(id: task.id) }
      reload()
      return
    }

    let dropsCompleted: Bool
    switch filter {
    case .logbook, .recentlyDeleted: dropsCompleted = false
    default: dropsCompleted = true
    }
    guard dropsCompleted else {
      for task in completing { mutator.complete(id: task.id) }
      for task in reopening { mutator.uncomplete(id: task.id) }
      reload()
      return
    }

    isSettling = true
    // The row stays where it is, restyled as completed, for the settle window
    // — you see what you just did before it leaves.
    let ids = Set(completing.map(\.id))
    var restyled = IndexSet()
    for index in rows.indices {
      if case .task(var task, let chip) = rows[index], ids.contains(task.id) {
        task.status = .done
        rows[index] = .task(task, chip: chip)
        restyled.insert(index)
      }
    }
    tableView.reloadData(forRowIndexes: restyled, columnIndexes: [0])

    for task in completing { mutator.complete(id: task.id) }
    for task in reopening { mutator.uncomplete(id: task.id) }
    beginSettle()
  }

  /// Hold the list still for the settle window, then let the completed rows
  /// fade out on the next diffed reload.
  ///
  /// Reloads are suppressed meanwhile rather than merely delayed: completing a
  /// task queues a CloudKit change, and the batch's `.septenaTasksChanged`
  /// would otherwise land mid-linger and yank the row out early — which is
  /// exactly the "row vanishes the instant you check it" feel this removes.
  private func beginSettle() {
    settleWorkItem?.cancel()
    isSettling = true
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.isSettling = false
      self.settleWorkItem = nil
      self.reload()
    }
    settleWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + KitMotion.settleDelay, execute: work)
  }

  /// End the linger immediately — used when the list itself changes out from
  /// under it (a different filter), where holding stale rows makes no sense.
  private func cancelSettle() {
    settleWorkItem?.cancel()
    settleWorkItem = nil
    isSettling = false
  }

  // MARK: - Dates (⌘S When, ⌘⇧D Deadline, ⌘⇧. Clear)

  /// Anchor a date popover to the focused row and apply the choice to the
  /// whole actionable selection.
  func presentDatePopover(kind: SeptaskKitDatePopover.Kind) {
    let selection = actionableSelection
    guard !selection.isEmpty, tableView.selectedRow >= 0 else { return }

    let anchor = tableView.rect(ofRow: tableView.selectedRow)
    let initial: Date? = switch kind {
    case .when: KitDayFormat.date(fromWire: selection.first?.scheduled)
    case .deadline: KitDayFormat.date(fromWire: selection.first?.deadline)
    }

    SeptaskKitDatePopover.present(kind: kind, initial: initial,
                                  relativeTo: anchor, of: tableView) { [weak self] date, today in
      guard let self else { return }
      for task in selection {
        switch kind {
        case .when:
          if today {
            self.mutator.moveToToday(id: task.id)
          } else {
            self.mutator.schedule(id: task.id, date: date)
            self.mutator.removeFromToday(id: task.id)
          }
        case .deadline:
          self.mutator.setDeadline(id: task.id, date: date)
        }
      }
      self.reload()
    }
  }

  /// ⌘⇧. — drop both the schedule and the Today pin, leaving the task in
  /// Anytime. Matches `TaskRowShortcuts.clearSchedule`.
  func clearScheduleSelection() {
    for task in actionableSelection {
      mutator.schedule(id: task.id, date: nil)
      mutator.removeFromToday(id: task.id)
    }
    reload()
  }

  func toggleTodaySelection() {
    for task in actionableSelection {
      if task.today {
        mutator.removeFromToday(id: task.id)
      } else {
        mutator.moveToToday(id: task.id)
      }
    }
    reload()
  }

  func deleteSelection() {
    let victims = actionableSelection
    guard !victims.isEmpty else { return }
    let anchor = tableView.selectedRowIndexes.first ?? 0
    if filter == .recentlyDeleted {
      // ⌘⌫ already means "delete" everywhere else; in the trash itself that
      // naturally reads as the final, permanent delete.
      purgeTasks(victims.map(\.id))
    } else {
      let ids = victims.map(\.id)
      recordUndo(name: "Delete Task",
                undo: { [weak self] in
                  for id in ids { self?.mutator.restore(id: id) }
                  self?.reload()
                },
                redo: { [weak self] in
                  for id in ids { self?.mutator.delete(id: id) }
                  self?.reload()
                })
      for task in victims {
        mutator.delete(id: task.id)
      }
      reload()
    }
    // Standard list behavior: selection moves to the nearest surviving row.
    if !rows.isEmpty {
      tableView.selectRowIndexes([min(anchor, rows.count - 1)],
                                 byExtendingSelection: false)
    }
  }

  private func commitRename(id: String, title: String) {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let isAbandonedNewTask = (id == pendingNewTaskId) && trimmed.isEmpty
    pendingNewTaskId = nil
    if isAbandonedNewTask {
      // The ⌘N row was escaped/committed empty — it never really existed for
      // the user, so remove it entirely rather than soft-deleting to trash.
      mutator.purge(id: id)
    } else if let task = rows.compactMap(\.task).first(where: { $0.id == id }),
              !trimmed.isEmpty, trimmed != task.title {
      let previousTitle = task.title
      recordUndo(name: "Rename Task",
                undo: { [weak self] in
                  self?.mutator.update(id: id, title: previousTitle)
                  self?.reload()
                },
                redo: { [weak self] in
                  self?.mutator.update(id: id, title: trimmed)
                  self?.reload()
                })
      mutator.update(id: id, title: trimmed)
    }
    reload()
    view.window?.makeFirstResponder(tableView)
  }

  // MARK: - Creation (⌘N)

  /// Create in the context being looked at — Today lands on Today, a project/
  /// area list files there, Upcoming schedules tomorrow (the minimal date that
  /// keeps the row visible in that list). The new row appears at the top of
  /// its group (TaskOrder's insert-at-top), selected, with the title editor
  /// open.
  func createTask() {
    if isTitleEditorActive {
      // Commit the in-flight edit first; commitRename runs synchronously.
      view.window?.makeFirstResponder(tableView)
    }
    if composingTaskId != nil {
      // A composer left open would otherwise silently swallow the reload
      // below (reload() no-ops while `composingTaskId` is set) — the new
      // task would be created but never actually show up. Closing it first
      // gives ⌘N a clean slate no matter what was being edited before.
      collapseComposer(commit: true)
    }

    var area: String?
    var project: String?
    var today = false
    var scheduled: Date?
    switch filter {
    case .today: today = true
    case .project(let pid): project = pid
    case .area(let aid): area = aid
    case .upcoming: scheduled = KitDayFormat.tomorrow()
    case .unscheduled, .triage: break
    case .logbook, .recentlyDeleted:
      NSSound.beep()
      return
    }

    let task = mutator.create(title: "", area: area, project: project,
                              scheduled: scheduled, today: today)
    pendingNewTaskId = task.id
    reload(animated: false)
    guard let row = rows.firstIndex(where: { $0.task?.id == task.id }) else { return }
    tableView.selectRowIndexes([row], byExtendingSelection: false)
    tableView.scrollRowToVisible(row)
    beginEditingRow(row)
  }

  // MARK: - Editing entry points

  /// ⌘R only — a fast bare-title rename via the field editor, distinct from
  /// the full composer (Return / double-click). Some edits really are just
  /// fixing a typo.
  func beginEditSelectedRow() {
    let row = tableView.selectedRow
    guard row >= 0 else { return }
    beginEditingRow(row)
  }

  /// Standard AppKit way to act on a row synchronously right after inserting
  /// it: `makeIfNecessary: true` forces the cell into existence instead of
  /// hoping it's already been dequeued (a bare `reloadData()` doesn't
  /// guarantee that timing, so `false` here could silently no-op — the
  /// exact way ⌘N could create a task and NOT actually enter edit mode,
  /// leaving the title un-editable until the user clicked it themselves).
  /// One retry on the next runloop turn as a backstop, so a fresh task is
  /// reliably ready to type into immediately.
  private func beginEditingRow(_ row: Int) {
    if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
      as? SeptaskKitTaskCell {
      cell.beginEditing()
      return
    }
    DispatchQueue.main.async { [weak self] in
      guard let self, self.rows.indices.contains(row) else { return }
      if let cell = self.tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
        as? SeptaskKitTaskCell {
        cell.beginEditing()
      }
    }
  }

  /// Return / double-click — expands the selected row into the inline
  /// composer (title + elective pill rail + notes), the AppKit counterpart of
  /// `TaskComposerCard` in `.inline` mode. Matches the SwiftUI shell, whose
  /// Return already opens the rich editor rather than a bare rename.
  func beginComposingSelectedRow() {
    // Nothing about a deleted task is editable — Return/double-click there
    // restores it instead (matching the checkbox), rather than opening dead
    // controls.
    guard filter != .recentlyDeleted else {
      restoreTasks(actionableSelection.map(\.id))
      return
    }
    let row = tableView.selectedRow
    guard row >= 0, let task = rows[row].task else { return }
    // A section heading has no pills/notes to open a full composer for —
    // same as the SwiftUI project page, renaming it is a bare title edit.
    guard !task.isHeading else {
      beginEditingRow(row)
      return
    }
    beginComposing(id: task.id)
  }

  @objc private func beginEditFromDoubleClick() {
    guard tableView.clickedRow >= 0, rows[tableView.clickedRow].task != nil else { return }
    tableView.selectRowIndexes([tableView.clickedRow], byExtendingSelection: false)
    beginComposingSelectedRow()
  }

  // MARK: - Inline composer (title + elective pills + notes)

  func beginComposing(id: String) {
    guard composingTaskId != id else { return }
    if composingTaskId != nil { collapseComposer(commit: true) }
    composingTaskId = id
    guard let row = rows.firstIndex(where: { $0.task?.id == id }) else {
      composingTaskId = nil
      return
    }
    tableView.selectRowIndexes([row], byExtendingSelection: false)
    // Force this ONE row to re-dequeue as the composer cell and pick up its
    // taller height — the diffed path in `reload()` wouldn't do this on its
    // own, since the row's underlying `Row` VALUE hasn't changed (composing
    // state lives outside it, in `composingTaskId`).
    tableView.reloadData(forRowIndexes: [row], columnIndexes: [0])
    tableView.noteHeightOfRows(withIndexesChanged: [row])
    tableView.scrollRowToVisible(row)
    DispatchQueue.main.async { [weak self] in
      guard let self, self.composingTaskId == id,
            let freshRow = self.rows.firstIndex(where: { $0.task?.id == id }),
            let cell = self.tableView.view(atColumn: 0, row: freshRow, makeIfNecessary: false)
              as? KitComposerCell
      else { return }
      cell.focusTitle()
    }
  }

  /// Fold the composing row back to a normal row. `commit` is false when the
  /// cell already committed itself (Return/Esc inside the title/notes field —
  /// see `KitComposerCell.control(_:doCommandBy:)`), true for every other path
  /// (switching to a different row, selecting elsewhere) so nothing typed is
  /// silently dropped.
  private func collapseComposer(commit: Bool) {
    guard let taskId = composingTaskId else { return }
    if commit, let row = rows.firstIndex(where: { $0.task?.id == taskId }),
       let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
         as? KitComposerCell {
      cell.commit()
    }
    composingTaskId = nil
    reload()
    // Belt and braces: force the row's cell back to normal even when nothing
    // actually changed (composer opened and closed with no edits) — the
    // diffed reload above only re-dequeues rows whose CONTENT differs, and
    // cell TYPE isn't part of that diff.
    if let row = rows.firstIndex(where: { $0.task?.id == taskId }) {
      tableView.reloadData(forRowIndexes: [row], columnIndexes: [0])
      tableView.noteHeightOfRows(withIndexesChanged: [row])
    }
    view.window?.makeFirstResponder(tableView)
  }

  /// Re-read the task from the store and refresh the composer cell's PILLS —
  /// used after a pill's popover/menu writes through the mutator. Deliberately
  /// does NOT call `wireComposer`/`cell.configure`: that would re-run
  /// `titleField.stringValue = task.title` and silently discard whatever
  /// title the user has typed but not yet committed (the same bug class as
  /// `SeptaskKitInspectorController.show(_:)`'s same-id guard exists for —
  /// this is the composer's version of it). Still re-binds the action
  /// closures via `bindComposerActions`, since those close over `task` by
  /// value and would otherwise keep acting on a stale pre-edit snapshot.
  private func refreshComposerRow(taskId: String) {
    guard composingTaskId == taskId,
          let fresh = LocalCache.allTasks(in: context).first(where: { $0.id == taskId }),
          let row = rows.firstIndex(where: { $0.task?.id == taskId }),
          let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
            as? KitComposerCell
    else { return }
    cell.refreshPills(with: fresh, listName: listName(for: fresh))
    bindComposerActions(cell, task: fresh)
  }

  /// A header id built by `groupedByList`'s "p-"/"a-" prefix has a real
  /// area/project to drill into; "inbox"/"agenda" don't. ONE place this is
  /// decided — `heightOfRow`'s extra margin and `viewFor:`'s click/cursor
  /// wiring both call this rather than each re-deriving it, which is exactly
  /// the kind of duplicated logic that let them drift apart before.
  private func isNavigableHeaderId(_ id: String) -> Bool {
    id.hasPrefix("p-") || id.hasPrefix("a-")
  }

  private func navigationTarget(forHeaderId id: String) -> TaskFilter? {
    if id.hasPrefix("p-") { return .project(String(id.dropFirst(2))) }
    if id.hasPrefix("a-") { return .area(String(id.dropFirst(2))) }
    return nil
  }

  private func listName(for task: SeptenaTask) -> String? {
    let snapshot = StructureCache.snapshot(in: context)
    if let id = task.project, let project = snapshot.projects.first(where: { $0.id == id }) {
      return project.title
    }
    if let id = task.area, let area = snapshot.areas.first(where: { $0.id == id }) {
      return area.title
    }
    return nil
  }

  /// Populate a composer cell — title, notes, pills — and wire its actions.
  /// Called ONLY when the cell is first dequeued for a task (`viewFor:`).
  /// Never call this on a refresh; see `refreshComposerRow`.
  private func wireComposer(_ cell: KitComposerCell, task: SeptenaTask) {
    cell.configure(with: task, listName: listName(for: task))
    composerShowsNotes = cell.showsNotes
    bindComposerActions(cell, task: task)
  }

  /// The pill/checkbox action closures, all closing over `task` by value —
  /// shared by the initial wire-up and every post-pill refresh, so a stale
  /// closure never lingers after the task actually changes underneath it.
  private func bindComposerActions(_ cell: KitComposerCell, task: SeptenaTask) {
    cell.onNotesVisibilityChanged = { [weak self, weak cell] in
      guard let self, let cell,
            let row = self.rows.firstIndex(where: { $0.task?.id == task.id }) else { return }
      self.composerShowsNotes = cell.showsNotes
      self.tableView.noteHeightOfRows(withIndexesChanged: [row])
    }

    cell.onCommit = { [weak self] title, notes in
      guard let self else { return }
      let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty, trimmed != task.title {
        self.mutator.update(id: task.id, title: trimmed)
      }
      if notes != task.notes {
        self.mutator.update(id: task.id, notes: notes)
      }
    }
    cell.onCollapse = { [weak self] in self?.collapseComposer(commit: false) }

    cell.onAction = { [weak self] action in
      guard let self else { return }
      switch action {
      case .toggleComplete:
        let wasOpen = task.status == .open
        self.recordUndo(name: wasOpen ? "Complete Task" : "Reopen Task",
                        undo: { [weak self] in
                          if wasOpen { self?.mutator.uncomplete(id: task.id) }
                          else { self?.mutator.complete(id: task.id) }
                          self?.reload()
                        },
                        redo: { [weak self] in
                          if wasOpen { self?.mutator.complete(id: task.id) }
                          else { self?.mutator.uncomplete(id: task.id) }
                          self?.reload()
                        })
        if wasOpen {
          self.mutator.complete(id: task.id)
        } else {
          self.mutator.uncomplete(id: task.id)
        }
        self.collapseComposer(commit: true)

      case .toggleToday:
        if task.today {
          self.mutator.removeFromToday(id: task.id)
        } else {
          self.mutator.moveToToday(id: task.id)
        }
        self.refreshComposerRow(taskId: task.id)

      case .when(let anchor):
        SeptaskKitDatePopover.present(kind: .when,
                                      initial: KitDayFormat.date(fromWire: task.scheduled),
                                      relativeTo: anchor.bounds, of: anchor) { [weak self] date, today in
          guard let self else { return }
          if today {
            self.mutator.moveToToday(id: task.id)
          } else {
            self.mutator.schedule(id: task.id, date: date)
            self.mutator.removeFromToday(id: task.id)
          }
          self.refreshComposerRow(taskId: task.id)
        }

      case .deadline(let anchor):
        SeptaskKitDatePopover.present(kind: .deadline,
                                      initial: KitDayFormat.date(fromWire: task.deadline),
                                      relativeTo: anchor.bounds, of: anchor) { [weak self] date, _ in
          self?.mutator.setDeadline(id: task.id, date: date)
          self?.refreshComposerRow(taskId: task.id)
        }

      case .list:
        // Reuses the exact "Move to" menu the context menu and ⌘⇧M pop up —
        // one destination list, not a second picker to keep in sync. It acts
        // on the current selection, which is this row (selecting it is how
        // compose mode began).
        self.presentMoveMenu()
        self.refreshComposerRow(taskId: task.id)

      case .repeatRule(let anchor):
        let menu = KitRecurrenceMenu.build(target: self, action: #selector(self.menuSetRecurrence(_:)))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height), in: anchor)
        self.refreshComposerRow(taskId: task.id)
      }
    }
  }

  // MARK: - Context menu (same commands + equivalents as the Task menu)

  /// Same commands, same order, same bindings as the menu bar's Task menu and
  /// as `TaskRowCommands` in the SwiftUI shell — one vocabulary everywhere.
  private func buildContextMenu() -> NSMenu {
    let menu = NSMenu()
    menu.delegate = self
    menu.addItem(item("Rename", #selector(menuRename), "r", [.command]))
    menu.addItem(item("Show Info", #selector(menuInspector), "i", [.command, .option]))
    menu.addItem(item("Copy", #selector(menuCopy), "c", [.command]))
    menu.addItem(item("Duplicate", #selector(menuDuplicate), "d", [.command]))
    menu.addItem(.separator())
    menu.addItem(item("Mark as Complete", #selector(menuToggleComplete), "k", [.command]))
    menu.addItem(item("Toggle Today", #selector(menuToggleToday), "t", [.command]))
    menu.addItem(item("When…", #selector(menuWhen), "s", [.command]))
    menu.addItem(item("Deadline…", #selector(menuDeadline), "d", [.command, .shift]))
    menu.addItem(item("Clear Schedule", #selector(menuClearSchedule), ".", [.command, .shift]))

    // Move and Repeat are closed sets, so they're submenus rather than more
    // popovers — the standard AppKit shape for "pick one of a few". The move
    // submenu is rebuilt on open (menuNeedsUpdate) so it can't serve a stale
    // project list.
    moveMenuItem.title = "Move to"
    moveMenuItem.keyEquivalent = "m"
    moveMenuItem.keyEquivalentModifierMask = [.command, .shift]
    menu.addItem(moveMenuItem)

    let repeatItem = NSMenuItem(title: "Repeat", action: nil, keyEquivalent: "")
    repeatItem.submenu = KitRecurrenceMenu.build(target: self,
                                                 action: #selector(menuSetRecurrence(_:)))
    menu.addItem(repeatItem)

    menu.addItem(.separator())
    menu.addItem(item("Delete", #selector(menuDelete), "\u{8}", [.command]))
    return menu
  }

  /// The trash's own vocabulary — nothing else on the normal menu (rename,
  /// complete, dates…) means anything for an already-deleted row.
  private func buildRecentlyDeletedMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(item("Restore", #selector(menuRestore), "", []))
    menu.addItem(.separator())
    menu.addItem(item("Delete Permanently", #selector(menuDelete), "\u{8}", [.command]))
    return menu
  }

  @objc private func menuRestore() { restoreTasks(actionableSelection.map(\.id)) }

  // MARK: - Headings (project sections)
  //
  // A heading is a real task (`isHeading`, `kind == "heading"`) — creating,
  // renaming, and deleting one call the SAME `TaskMutator` methods and use
  // the SAME confirmation copy the SwiftUI project page does
  // (`TaskListView.commitHeadingCreate`/`commitHeadingRename`, and the
  // "Delete this section?" dialog), so a section behaves identically in
  // either shell. NOT yet implemented: filing a task under a heading by
  // dragging it there (SwiftUI's `handleHeadingDrop`) — tracked in
  // docs/SEPTASK_APPKIT_PARITY.md rather than rushed here.

  /// Right-click on blank list space, project pages only — where "New
  /// Section" lives since there's no heading row to right-click yet.
  private func buildBlankSpaceMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(item("New Section", #selector(menuNewSection), "", []))
    return menu
  }

  /// Right-click on a heading row: rename (same field-editor path as any
  /// task) and delete — nothing else on the normal task menu applies to a
  /// section divider.
  private func buildHeadingContextMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(item("Rename", #selector(menuRename), "r", [.command]))
    menu.addItem(.separator())
    menu.addItem(item("Delete Section", #selector(menuDeleteHeading), "", []))
    return menu
  }

  @objc private func menuNewSection() {
    guard case .project(let projectId) = filter,
          let title = KitPrompt.text(title: "New Section", placeholder: "Section name",
                                     confirmTitle: "Create")
    else { return }
    _ = mutator.createHeading(title: title, project: projectId)
    reload()
  }

  @objc private func menuDeleteHeading() {
    let row = tableView.selectedRow
    guard row >= 0, let heading = rows[row].task, heading.isHeading else { return }
    // Exact copy from TaskListView's confirmationDialog — same story either shell.
    guard KitPrompt.confirmDestructive(
      title: "Delete this section?",
      message: "Its tasks stay in the project.",
      confirmTitle: "Delete Section"
    ) else { return }
    mutator.delete(id: heading.id)
    reload()
  }

  private func item(_ title: String, _ action: Selector, _ key: String,
                    _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    item.target = self
    return item
  }

  @objc private func menuToggleComplete() { toggleCompleteSelection() }
  @objc private func menuToggleToday() { toggleTodaySelection() }
  @objc private func menuRename() { beginEditSelectedRow() }
  @objc private func menuInspector() { onToggleInspector?() }
  @objc private func menuCopy() { copySelection() }
  @objc private func menuDuplicate() { duplicateSelection() }

  @objc private func menuMoveTo(_ sender: NSMenuItem) {
    let snapshot = StructureCache.snapshot(in: context)
    guard let destination = KitMoveMenu.destination(for: sender,
                                                    areas: snapshot.areas,
                                                    projects: snapshot.projects)
    else { return }
    move(to: destination)
  }
  @objc private func menuWhen() { presentDatePopover(kind: .when) }
  @objc private func menuDeadline() { presentDatePopover(kind: .deadline) }
  @objc private func menuClearSchedule() { clearScheduleSelection() }

  @objc private func menuSetRecurrence(_ sender: NSMenuItem) {
    setRecurrence(KitRecurrenceMenu.recurrence(for: sender))
  }
  @objc private func menuDelete() { deleteSelection() }
}

// MARK: - Context menu freshness

extension SeptaskKitTaskListController: NSMenuDelegate {
  /// Rebuild the move destinations each time the menu opens — areas and
  /// projects change while the window is open, and a submenu built once at
  /// construction would quietly go stale.
  func menuNeedsUpdate(_ menu: NSMenu) {
    let snapshot = StructureCache.snapshot(in: context)
    moveMenuItem.submenu = KitMoveMenu.build(areas: snapshot.areas,
                                             projects: snapshot.projects,
                                             target: self,
                                             action: #selector(menuMoveTo(_:)))
  }
}

// MARK: - Table data source / delegate

extension SeptaskKitTaskListController: NSTableViewDataSource, NSTableViewDelegate {
  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

  /// Always false, deliberately — NOT `if case .header = rows[row] { true }`.
  /// A `.header` row already gets full custom appearance from `KitCardRowView`
  /// + `KitGroupHeaderCell` (the same mechanism `.screenTitle` uses, which
  /// DOES render at its intended size). Marking it a group row on top of that
  /// let AppKit's own system "section header" text style — small, secondary
  /// color, semibold — fight the cell's own font, and it wins: that's why
  /// `KitGroupHeaderCell`'s font bumps kept visually not-landing no matter
  /// how large `Self.font` was set. `shouldSelectRow` already excludes
  /// headers from selection on its own (`rows[row].task != nil`), so nothing
  /// downstream actually needed `isGroupRow` to be true.
  func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { false }

  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
    rows[row].task != nil
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    // Selecting a different row while composing has to fold the open row
    // shut first — otherwise clicking elsewhere leaves an orphaned composer
    // (and any typed edits unsaved).
    if let composingId = composingTaskId,
       !(rows.indices.contains(tableView.selectedRow)
         && rows[tableView.selectedRow].task?.id == composingId) {
      collapseComposer(commit: true)
    }
    // The inspector shows a single row; a multi-selection has no one subject.
    let selection = actionableSelection
    onSelectionChange?(selection.count == 1 ? selection.first : nil)
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    switch rows[row] {
    // Headers carry the air between cards, so they're taller than their text.
    // Area/project headers get EXTRA margin above them (matching the
    // sidebar's per-top-level-area treatment) — they start a new list
    // section; "Inbox"/"Agenda" are sub-groups within Today's own flow and
    // don't need the same visual break.
    case .header(let id, _, _, _):
      // Kept in sync with `KitGroupHeaderCell.font` (17pt).
      let base = 17 * FontScale.shared.factor + 26
      return isNavigableHeaderId(id) ? base + 10 : base
    // The page's own title — noticeably taller than an in-list header, the
    // same visual weight a big navigation title would carry.
    case .screenTitle: return SeptenaTypeScale.size(.title2) + 40
    case .task(let task, _):
      if task.id == composingTaskId {
        return KitComposerCell.height(showsNotes: composerShowsNotes)
      }
      return SeptaskKitTheme.rowHeight
    case .event: return SeptaskKitTheme.rowHeight
    case .loggedFooter: return SeptenaTypeScale.size(.footnote) + 24
    }
  }

  /// Card geometry: a run of task rows between headers draws as one card,
  /// rounded only at its ends (KitCardRowView). Headers sit on the page.
  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    let identifier = NSUserInterfaceItemIdentifier("cardRow")
    let rowView = tableView.makeView(withIdentifier: identifier, owner: nil) as? KitCardRowView
      ?? {
        let fresh = KitCardRowView()
        fresh.identifier = identifier
        return fresh
      }()

    if rows[row].isCardRow {
      rowView.isCard = true
      let previousOnCard = row > 0 && rows[row - 1].isCardRow
      let nextOnCard = row + 1 < rows.count && rows[row + 1].isCardRow
      rowView.isFirstInGroup = !previousOnCard
      rowView.isLastInGroup = !nextOnCard
    } else {
      rowView.isCard = false
    }
    rowView.needsDisplay = true
    return rowView
  }

  // MARK: Drag & drop (reorder + re-file)

  /// Manual reorder applies wherever manual order is what's shown; archives
  /// don't reorder.
  private var allowsReorder: Bool {
    switch filter {
    case .logbook, .recentlyDeleted: return false
    default: return true
    }
  }

  func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int)
    -> NSPasteboardWriting? {
    guard let task = rows[row].task, !task.isHeading else { return nil }
    let item = NSPasteboardItem()
    item.setString(task.id, forType: .septaskTask)
    return item
  }

  func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                 proposedRow row: Int,
                 proposedDropOperation operation: NSTableView.DropOperation)
    -> NSDragOperation {
    guard allowsReorder, !KitDrag.ids(from: info).isEmpty else { return [] }
    if operation == .on {
      tableView.setDropRow(row, dropOperation: .above)
    }
    return .move
  }

  func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                 row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
    let ids = KitDrag.ids(from: info)
    guard !ids.isEmpty else { return false }
    let dragged = Set(ids)

    // Neighbor order keys around the insertion gap, skipping headers and the
    // rows being moved. TaskOrder.positions spaces the drop between them.
    // (The midpoint-exhaustion renumber pass is TaskListView's; a spike-level
    // collision just lands adjacent, which the next drag resolves.)
    var aboveKey: Double?
    for index in stride(from: row - 1, through: 0, by: -1) {
      if let task = rows[index].task, !task.isHeading, !dragged.contains(task.id) {
        aboveKey = TaskOrder.key(position: task.position, createdAt: task.createdAt)
        break
      }
    }
    var belowKey: Double?
    for index in row..<rows.count {
      if let task = rows[index].task, !task.isHeading, !dragged.contains(task.id) {
        belowKey = TaskOrder.key(position: task.position, createdAt: task.createdAt)
        break
      }
    }

    let positions = TaskOrder.positions(count: ids.count, above: aboveKey, below: belowKey)
    for (id, position) in zip(ids, positions) {
      mutator.reorder(id: id, toPosition: position)
    }
    refileIfGroupedDrop(ids: ids, at: row, dragged: dragged)
    reload()
    return true
  }

  /// In the grouped views, a drop inside another area/project group also
  /// re-files the task there (Things behavior): the receiving group is the
  /// nearest header above the insertion gap; none means the loose zone.
  private func refileIfGroupedDrop(ids: [String], at row: Int, dragged: Set<String>) {
    let grouped: Bool
    switch filter {
    case .today: grouped = todayGroupsByList
    case .unscheduled: grouped = true
    default: grouped = false
    }
    guard grouped else { return }

    var targetProject: String?
    var targetArea: String?
    for index in stride(from: row - 1, through: 0, by: -1) {
      if case .header(let id, _, _, _) = rows[index] {
        if id.hasPrefix("p-") { targetProject = String(id.dropFirst(2)) }
        if id.hasPrefix("a-") { targetArea = String(id.dropFirst(2)) }
        break
      }
    }

    let byId = Dictionary(rows.compactMap(\.task).map { ($0.id, $0) },
                          uniquingKeysWith: { a, _ in a })
    for id in ids {
      guard let task = byId[id] else { continue }
      if task.project != targetProject {
        mutator.moveToProject(id: id, project: targetProject)
      }
      // Area only matters outside a project group (a project implies its area).
      if targetProject == nil, task.area != targetArea {
        mutator.moveToArea(id: id, area: targetArea)
      }
    }
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                 row: Int) -> NSView? {
    switch rows[row] {
    case .header(let id, let title, let icon, let count):
      let identifier = NSUserInterfaceItemIdentifier("headerCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? KitGroupHeaderCell
        ?? KitGroupHeaderCell(identifier: identifier)
      // Only area/project headers have a leaf to drill into — "Inbox" and
      // "Agenda" aren't destinations of their own.
      let target = navigationTarget(forHeaderId: id)
      cell.configure(title: title, icon: icon, count: count, isNavigable: target != nil)
      cell.onTap = target.map { filter in { [weak self] in self?.onNavigateToGroup?(filter) } }
      return cell

    case .screenTitle(let title, let icon):
      let identifier = NSUserInterfaceItemIdentifier("screenTitleCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? KitScreenTitleCell
        ?? KitScreenTitleCell(identifier: identifier)
      cell.configure(title: title, icon: icon)
      return cell

    case .loggedFooter(let count, let expanded):
      let identifier = NSUserInterfaceItemIdentifier("loggedFooterCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? KitLoggedFooterCell
        ?? KitLoggedFooterCell(identifier: identifier)
      cell.configure(count: count, expanded: expanded)
      cell.onTap = { [weak self] in self?.toggleLoggedExpanded() }
      return cell

    case .task(let task, let chip):
      if task.id == composingTaskId {
        let identifier = NSUserInterfaceItemIdentifier("composerCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? KitComposerCell
          ?? KitComposerCell(identifier: identifier)
        wireComposer(cell, task: task)
        return cell
      }
      let identifier = NSUserInterfaceItemIdentifier("taskCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? SeptaskKitTaskCell
        ?? SeptaskKitTaskCell(identifier: identifier)
      cell.configure(with: task, filter: filter, chip: chip)
      cell.onToggle = { [weak self] id in self?.toggle(id: id) }
      // Deferred one runloop tick — same reentrancy hazard as the composer's
      // `deferCommitAndCollapse` (see its doc comment): `onRename` fires from
      // `controlTextDidEndEditing`, itself mid-resign-first-responder, and
      // `commitRename`'s mutator write posts synchronously, which can cascade
      // back into `makeFirstResponder` (via the sidebar's reselect) before
      // this call has even returned. Running the commit on a fresh tick keeps
      // that reentrant call off an in-progress first-responder transition —
      // the "Esc/click-away doesn't close the row" bug.
      cell.onRename = { [weak self] id, title in
        DispatchQueue.main.async { self?.commitRename(id: id, title: title) }
      }
      return cell

    case .event(let event):
      let identifier = NSUserInterfaceItemIdentifier("eventCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? KitEventCell
        ?? KitEventCell(identifier: identifier)
      cell.configure(with: event)
      return cell
    }
  }
}

// MARK: - Motion

/// AppKit mirror of the SwiftUI a11y gate (`A11yMotion`): every row animation
/// resolves through here so Reduce Motion collapses it to an instant change.
@MainActor
private enum KitMotion {
  static var reduce: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }
  static var insertRows: NSTableView.AnimationOptions { [.effectFade, .slideDown] }
  static var removeRows: NSTableView.AnimationOptions { [.effectFade, .slideUp] }
  /// How long a checked row keeps its place, visibly completed, before it
  /// leaves the list. Long enough to read as "yes, that one" and to undo by
  /// eye; the pause itself isn't motion, so it survives Reduce Motion and only
  /// the fade afterwards collapses.
  static let settleDelay: TimeInterval = 2.5
}

// MARK: - Row cell

/// Checkbox + title + trailing meta (deadline / scheduled / repeat), on the
/// shared type ladder via SeptaskKitTheme. The title field is non-editable at
/// rest and becomes the field editor only through `beginEditing()` — the
/// native answer to the SwiftUI Text→TextField swap that corrupts List
/// selection (CLAUDE.md trap).
@MainActor
final class SeptaskKitTaskCell: NSTableCellView, NSTextFieldDelegate {
  var onToggle: ((String) -> Void)?
  var onRename: ((String, String) -> Void)?

  private let checkbox = KitCheckboxView()
  private let title = NSTextField(labelWithString: "")
  private let notesGlyph = NSImageView()
  private let chip = KitChipView()
  private let detail = NSTextField(labelWithString: "")
  private var taskId = ""
  private var plainTitle = ""
  private var editing = false
  // Content floats in a centered, max-width column (Things-style) rather than
  // stretching edge-to-edge — see `layout()`.
  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    checkbox.translatesAutoresizingMaskIntoConstraints = false
    checkbox.onToggle = { [weak self] in
      guard let self else { return }
      self.onToggle?(self.taskId)
    }

    // Single-line, truncate with ellipsis — denser list rhythm; full title
    // is on the tooltip / inspector / composer.
    title.maximumNumberOfLines = 1
    title.cell?.wraps = false
    title.cell?.truncatesLastVisibleLine = true
    title.lineBreakMode = .byTruncatingTail
    title.isEditable = false
    title.isSelectable = false
    title.delegate = self
    title.translatesAutoresizingMaskIntoConstraints = false
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    notesGlyph.translatesAutoresizingMaskIntoConstraints = false
    notesGlyph.contentTintColor = SeptaskKitTheme.iconMuted
    notesGlyph.image = NSImage(systemSymbolName: "text.alignleft",
                               accessibilityDescription: "Has notes")?
      .withSymbolConfiguration(.init(pointSize: 9, weight: .regular))

    detail.lineBreakMode = .byClipping
    detail.isEditable = false
    detail.isSelectable = false
    detail.setContentHuggingPriority(.required, for: .horizontal)
    detail.setContentCompressionResistancePriority(.required, for: .horizontal)

    // Trailing cluster: notes marker, list chip, date — in that reading order,
    // each hidden when it has nothing to say.
    let trailing = NSStackView(views: [notesGlyph, chip, detail])
    trailing.orientation = .horizontal
    trailing.spacing = 6
    trailing.translatesAutoresizingMaskIntoConstraints = false
    trailing.setHuggingPriority(.required, for: .horizontal)

    addSubview(checkbox)
    addSubview(title)
    addSubview(trailing)
    textField = title
    leadingConstraint = checkbox.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: KitCardRowView.horizontalInset + 6)
    trailingConstraint = trailing.trailingAnchor.constraint(
      equalTo: trailingAnchor, constant: -(KitCardRowView.horizontalInset + 8))
    NSLayoutConstraint.activate([
      leadingConstraint,
      checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
      checkbox.widthAnchor.constraint(equalToConstant: 20),
      checkbox.heightAnchor.constraint(equalToConstant: 20),
      title.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 7),
      title.centerYAnchor.constraint(equalTo: centerYAnchor),
      trailing.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
      trailingConstraint,
      trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("SeptaskKitTaskCell is code-only") }

  /// Recompute the centered-column inset for the row's current width — called
  /// on every resize (AppKit's normal layout pass), same margin the card
  /// background (`KitCardRowView.cardPath`) draws to.
  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + 6
    trailingConstraint.constant = -(inset + 8)
    super.layout()
  }

  func configure(with task: SeptenaTask, filter: TaskFilter,
                 chip chipValue: SeptaskKitTaskListController.Chip?) {
    taskId = task.id
    plainTitle = task.title
    editing = false
    title.isEditable = false

    if task.isHeading {
      checkbox.isHidden = true
      notesGlyph.isHidden = true
      chip.isHidden = true
      detail.stringValue = ""
      title.toolTip = task.title
      title.attributedStringValue = NSAttributedString(
        string: task.title,
        attributes: [
          .font: SeptaskKitTheme.heading,
          .foregroundColor: SeptaskKitTheme.inkSecondary,
        ])
      return
    }

    checkbox.isHidden = false
    title.toolTip = task.title
    let done = task.status != .open
    checkbox.isDone = done
    // The box carries readiness and Today the same way TaskCheckbox does:
    // dashed = unratified proposal, gold = promoted to Today.
    let isProposal = task.isInTriageBand && task.source == TaskSource.mcp
    checkbox.isDashed = !done && isProposal
    // Matches `TaskCheckboxModel.isToday = task.isOnToday && showsTodayIndicator`
    // exactly: the solid pinned badge is suppressed ON the Today screen
    // itself (redundant there — everything on screen is already "on Today"),
    // where the tenure fade below carries the cue instead. Elsewhere (moved
    // in via a scheduled/deadline date counts too, not just the pinned flag —
    // `isOnToday`, not the raw `today` field) it shows solid.
    checkbox.isToday = task.isOnToday && filter != .today
    // The remaining cue vocabulary, matching `TaskCheckboxModel`: gold tenure
    // dial for days carried on Today, corner dot for unread agent context on a
    // committed row (proposals are excluded — they already read as dashed),
    // and the cue ring while an agent row is fresh and unengaged.
    checkbox.tenureFill = done ? nil : task.todayTenureFill()
    checkbox.cornerDot = !done && !isProposal && task.conversation.hasStarted
    checkbox.agentCue = !done && task.showsAgentCue()

    var titleAttributes: [NSAttributedString.Key: Any] = [
      .font: SeptaskKitTheme.taskTitle,
      .foregroundColor: NSColor.labelColor,
    ]
    if done {
      titleAttributes[.foregroundColor] = SeptaskKitTheme.inkSecondary
      titleAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
    }
    title.attributedStringValue = NSAttributedString(string: task.title,
                                                     attributes: titleAttributes)

    notesGlyph.isHidden = (task.notes ?? "").isEmpty
    if let chipValue {
      chip.isHidden = false
      chip.configure(symbol: chipValue.symbol, title: chipValue.title)
    } else {
      chip.isHidden = true
    }

    configureDetail(with: task, filter: filter, done: done)
  }

  /// Trailing meta: the deadline when one exists (red once it's due),
  /// otherwise the scheduled date where that's the list's point (Upcoming),
  /// plus a repeat marker. Quiet by design — most rows show nothing.
  private func configureDetail(with task: SeptenaTask, filter: TaskFilter, done: Bool) {
    var parts: [String] = []
    var color = SeptaskKitTheme.iconMuted

    if let deadline = task.deadline, !done {
      parts.append(KitDayFormat.display(deadline))
      if deadline <= SeptenaDate.today {
        color = SeptaskKitTheme.overdueRed
      }
    } else if case .upcoming = filter, let scheduled = task.scheduled {
      parts.append(KitDayFormat.display(scheduled))
    }
    if task.recurrence != nil {
      parts.append("↻")
    }

    detail.font = SeptaskKitTheme.meta
    detail.textColor = color
    detail.stringValue = parts.joined(separator: "  ")
    detail.isHidden = parts.isEmpty
  }

  // MARK: - Field-editor rename

  func beginEditing() {
    guard !editing else { return }
    editing = true
    title.isEditable = true
    title.stringValue = plainTitle
    window?.makeFirstResponder(title)
    title.currentEditor()?.selectAll(nil)
  }

  func controlTextDidEndEditing(_ obj: Notification) {
    guard editing else { return }
    editing = false
    title.isEditable = false
    onRename?(taskId, title.stringValue)
  }

  func control(_ control: NSControl, textView: NSTextView,
               doCommandBy commandSelector: Selector) -> Bool {
    // Escape cancels: restore the original title, then let editing end —
    // controlTextDidEndEditing sees an unchanged string and commits nothing.
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      title.stringValue = plainTitle
      window?.makeFirstResponder(nil)
      return true
    }
    return false
  }
}

// MARK: - Calendar event cell

/// A calendar event woven into the agenda: a tinted dot where the checkbox
/// would be (nothing here is completable), the event's title, and its time.
@MainActor
final class KitEventCell: NSTableCellView {
  private let dot = NSImageView()
  private let title = NSTextField(labelWithString: "")
  private let time = NSTextField(labelWithString: "")
  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    dot.translatesAutoresizingMaskIntoConstraints = false
    dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 6, weight: .regular))
    dot.contentTintColor = SeptaskKitTheme.iconMuted

    title.translatesAutoresizingMaskIntoConstraints = false
    title.font = SeptaskKitTheme.taskTitle
    title.textColor = SeptaskKitTheme.inkSecondary
    title.lineBreakMode = .byTruncatingTail
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    time.translatesAutoresizingMaskIntoConstraints = false
    time.font = SeptaskKitTheme.meta
    time.textColor = SeptaskKitTheme.iconMuted
    time.setContentHuggingPriority(.required, for: .horizontal)
    time.setContentCompressionResistancePriority(.required, for: .horizontal)

    addSubview(dot)
    addSubview(title)
    addSubview(time)
    textField = title
    leadingConstraint = dot.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: KitCardRowView.horizontalInset + 6)
    trailingConstraint = time.trailingAnchor.constraint(
      equalTo: trailingAnchor, constant: -(KitCardRowView.horizontalInset + 8))
    NSLayoutConstraint.activate([
      leadingConstraint,
      dot.centerYAnchor.constraint(equalTo: centerYAnchor),
      dot.widthAnchor.constraint(equalToConstant: 20),
      title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 7),
      title.centerYAnchor.constraint(equalTo: centerYAnchor),
      time.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
      trailingConstraint,
      time.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("KitEventCell is code-only") }

  /// Same centered-column margin as `SeptaskKitTaskCell` — see its `layout()`.
  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + 6
    trailingConstraint.constant = -(inset + 8)
    super.layout()
  }

  func configure(with event: SeptaskKitTaskListController.Event) {
    title.stringValue = event.title
    time.stringValue = event.time
  }
}

// MARK: - Project/area screen title

/// The page's own big title — an area's emoji/dot or a project's completion
/// ring, plus its name at a larger rung than an in-list group header. Not
/// clickable (you're already here) and carries no count, unlike
/// `KitGroupHeaderCell`, which is why this is its own small type rather than
/// a third mode bolted onto that one.
@MainActor
final class KitScreenTitleCell: NSTableCellView {
  private let icon = NSImageView()
  private let emoji = NSTextField(labelWithString: "")
  private let title = NSTextField(labelWithString: "")
  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!

  private static let font: NSFont = .systemFont(ofSize: SeptenaTypeScale.size(.title2), weight: .bold)

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    icon.translatesAutoresizingMaskIntoConstraints = false
    emoji.translatesAutoresizingMaskIntoConstraints = false
    emoji.font = .systemFont(ofSize: SeptenaTypeScale.size(.title3))
    title.translatesAutoresizingMaskIntoConstraints = false
    title.font = Self.font
    title.textColor = .labelColor
    title.lineBreakMode = .byTruncatingTail

    addSubview(icon)
    addSubview(emoji)
    addSubview(title)
    textField = title
    leadingConstraint = icon.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: KitCardRowView.horizontalInset + 4)
    trailingConstraint = title.trailingAnchor.constraint(
      lessThanOrEqualTo: trailingAnchor, constant: -(KitCardRowView.horizontalInset + 8))
    NSLayoutConstraint.activate([
      leadingConstraint,
      icon.centerYAnchor.constraint(equalTo: title.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 18),
      emoji.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
      emoji.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
      title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
      title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
      trailingConstraint,
    ])
  }

  required init?(coder: NSCoder) { fatalError("KitScreenTitleCell is code-only") }

  /// Same width-dependent centered-column margin as every other row.
  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + 4
    trailingConstraint.constant = -(inset + 8)
    super.layout()
  }

  func configure(title titleText: String, icon iconKind: SeptaskKitTaskListController.GroupIcon) {
    title.stringValue = titleText
    emoji.isHidden = true
    icon.isHidden = false
    switch iconKind {
    case .emoji(let glyph):
      emoji.isHidden = false
      emoji.stringValue = glyph
      icon.isHidden = true
    case .areaDot:
      icon.image = KitGlyph.areaDot()
    case .project(let progress):
      icon.image = KitGlyph.progress(progress)
    case .symbol(let name):
      icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
      icon.contentTintColor = SeptaskKitTheme.inkSecondary
    }
  }
}

// MARK: - Logged footer ("Show N logged items")

/// Things-style footer on project/area pages — a quiet link that expands
/// completed tasks for that page. Matches `TaskListView.scopeLoggedToggleRow`
/// exactly: same copy, meta font, secondary ink, left-aligned on the content
/// column (not the wider page gutter).
@MainActor
final class KitLoggedFooterCell: NSTableCellView {
  private let label = NSTextField(labelWithString: "")
  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!
  var onTap: (() -> Void)?

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = SeptaskKitTheme.meta
    label.textColor = SeptaskKitTheme.inkSecondary

    let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
    addGestureRecognizer(click)

    addSubview(label)
    textField = label
    leadingConstraint = label.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: KitCardRowView.horizontalInset + 6)
    trailingConstraint = label.trailingAnchor.constraint(
      lessThanOrEqualTo: trailingAnchor, constant: -(KitCardRowView.horizontalInset + 8))
    NSLayoutConstraint.activate([
      leadingConstraint,
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      trailingConstraint,
    ])
  }

  required init?(coder: NSCoder) { fatalError("KitLoggedFooterCell is code-only") }

  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + 6
    trailingConstraint.constant = -(inset + 8)
    super.layout()
  }

  func configure(count: Int, expanded: Bool) {
    label.stringValue = expanded ? "Hide \(count) logged items" : "Show \(count) logged items"
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }

  @objc private func handleClick() { onTap?() }
}

// MARK: - Group header cell

/// The header above a run of rows: the group's glyph, its name, and its count
/// — the same trio the sidebar row shows, so a group reads as the sidebar
/// entry it came from.
@MainActor
final class KitGroupHeaderCell: NSTableCellView {
  private let icon = NSImageView()
  private let emoji = NSTextField(labelWithString: "")
  private let title = NSTextField(labelWithString: "")
  private let count = NSTextField(labelWithString: "")
  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!
  /// Set only for area/project headers (see `configure`) — clicking drills
  /// into that list, the same destination its sidebar row goes to. Whether a
  /// header is clickable is entirely a matter of this being non-nil
  /// (`resetCursorRects` below) — NOT a font distinction; every header in
  /// the list reads at ONE size, "Inbox" and "Agenda" included, so a glance
  /// down the list shows one consistent rung of section title.
  var onTap: (() -> Void)?

  /// Matches SwiftUI's ACTUAL group header exactly —
  /// `sectionGroupHeaderTitleStyle()` (`Theme.groupHeaderFontSize` = 17 on
  /// macOS, `.semibold`) — rather than another guessed offset off
  /// `.headline`. Every earlier pass here (`+9`, `+14`, `+10`, `.bold`) was
  /// tuning a number disconnected from the real target, which is why each
  /// round kept reading "wrong" no matter which way it was nudged. A `var`,
  /// not `let`: `FontScale.shared.factor` can change at runtime (Settings ▸
  /// Text Size), and SwiftUI's `scaledFont` reacts live — this should too.
  private static var font: NSFont {
    .systemFont(ofSize: 17 * FontScale.shared.factor, weight: .semibold)
  }
  /// The icon COLUMN width — same as a task row's checkbox column
  /// (`Theme.checkboxTap` = 22 on macOS) — so header glyphs and row
  /// checkboxes sit at one X. NOT the glyph's own size: SwiftUI sizes each
  /// icon KIND differently within this column (`TaskListView.groupHeaderBody`
  /// — `AreaIcon(diameter: 21)`, `ProjectProgressIcon(diameter: 14)`, a
  /// system symbol at `.scaledFont(size: 16)`), so `configure` matches those
  /// per case rather than forcing one shared diameter.
  private static let iconColumnWidth: CGFloat = 22

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    for field in [emoji, title, count] {
      field.translatesAutoresizingMaskIntoConstraints = false
    }
    icon.translatesAutoresizingMaskIntoConstraints = false
    title.font = SeptaskKitTheme.groupTitle
    title.textColor = .labelColor
    title.lineBreakMode = .byTruncatingTail
    // Sized to roughly fill the 21pt area-icon slot (matches `AreaIcon`'s
    // emoji sizing), not the title's own font. Dialed down 2pt after visual
    // review — 16 read a touch heavy next to the 17pt title.
    emoji.font = .systemFont(ofSize: 14 * FontScale.shared.factor)
    count.font = SeptaskKitTheme.meta

    let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
    addGestureRecognizer(click)
    count.textColor = SeptaskKitTheme.iconMuted

    addSubview(icon)
    addSubview(emoji)
    addSubview(title)
    addSubview(count)
    textField = title
    leadingConstraint = icon.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: KitCardRowView.horizontalInset + 4)
    trailingConstraint = count.trailingAnchor.constraint(
      lessThanOrEqualTo: trailingAnchor, constant: -(KitCardRowView.horizontalInset + 8))
    NSLayoutConstraint.activate([
      leadingConstraint,
      icon.centerYAnchor.constraint(equalTo: title.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: Self.iconColumnWidth),
      emoji.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
      emoji.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
      title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
      // Bottom-aligned: the header's air belongs above it, separating cards.
      // -5 (was -4) — 1pt more breathing room below the title before the
      // list underneath starts.
      title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
      count.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
      count.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
      trailingConstraint,
    ])
  }

  required init?(coder: NSCoder) { fatalError("KitGroupHeaderCell is code-only") }

  /// Same centered-column margin as the row cells, so the header's left/right
  /// edges line up with the cards below it.
  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + 4
    trailingConstraint.constant = -(inset + 8)
    super.layout()
  }

  func configure(title titleText: String,
                 icon iconKind: SeptaskKitTaskListController.GroupIcon,
                 count countValue: Int,
                 isNavigable: Bool) {
    // Attributed, not `stringValue` + `.font`: a bare font assignment on an
    // NSTableCellView's textField is what AppKit overrides for any
    // `rowSizeStyle` other than `.custom` — belt and braces alongside setting
    // that, since this font carrying is the whole point of the row.
    title.attributedStringValue = NSAttributedString(
      string: titleText,
      attributes: [.font: Self.font, .foregroundColor: NSColor.labelColor])
    // No trailing count on any header, by request — the field stays in the
    // view for layout stability but is never populated.
    count.stringValue = ""
    _ = countValue

    emoji.isHidden = true
    icon.isHidden = false
    switch iconKind {
    case .emoji(let glyph):
      emoji.isHidden = false
      emoji.stringValue = glyph
      icon.isHidden = true
    case .areaDot:
      // 21 — matches `AreaIcon(diameter: 21)` in `TaskListView.groupHeaderBody`.
      icon.image = KitGlyph.areaDot(diameter: 21)
    case .project(let progress):
      // 13 — SwiftUI's own `ProjectProgressIcon(diameter: 14)`, dialed down
      // 1pt after visual review to sit better against the 17pt title.
      icon.image = KitGlyph.progress(progress, diameter: 13)
    case .symbol(let name):
      icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
      icon.contentTintColor = SeptaskKitTheme.inkSecondary
    }
    // Reused cells carry a stale cursor rect otherwise — a scrolled-in
    // non-navigable header could keep the pointing-hand from whatever row
    // used to occupy this recycled view.
    window?.invalidateCursorRects(for: self)
  }

  @objc private func handleClick() { onTap?() }

  /// The pointing-hand cursor is the platform's "this text is a link/button"
  /// signal — it's what makes "clickable" discoverable without a hover state
  /// to lean on in an `NSTableCellView`.
  override func resetCursorRects() {
    guard onTap != nil else { return }
    addCursorRect(bounds, cursor: .pointingHand)
  }
}

/// "YYYY-MM-DD" wire dates → short localized display ("Jun 12").
@MainActor
enum KitDayFormat {
  private static let parse: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
  }()

  private static let render: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMMd")
    return formatter
  }()

  static func display(_ isoDay: String) -> String {
    guard let date = parse.date(from: isoDay) else { return isoDay }
    return render.string(from: date)
  }

  /// The app's today (SeptenaDate.today, honoring time-travel), not the wall
  /// clock — per the DayClock invariant.
  static func todayDate() -> Date? {
    parse.date(from: SeptenaDate.today)
  }

  /// `offset` days from the app's today.
  static func day(offset: Int) -> Date? {
    guard let today = todayDate() else { return nil }
    return Calendar.current.date(byAdding: .day, value: offset, to: today)
  }

  static func tomorrow() -> Date? { day(offset: 1) }

  private static let clock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    formatter.dateStyle = .none
    return formatter
  }()

  private static let dayAndClock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMMd jm")
    return formatter
  }()

  /// An event's time as the row shows it: the clock alone on Today (the day
  /// is implied), day + time on Upcoming.
  static func eventTime(_ event: EKEvent, on filter: TaskFilter) -> String {
    guard let start = event.startDate else { return "" }
    if event.isAllDay {
      return filter == .today ? "All day" : dayOnly.string(from: start)
    }
    return filter == .today ? clock.string(from: start) : dayAndClock.string(from: start)
  }

  private static let dayOnly: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMMd")
    return formatter
  }()

  /// Wire form ("YYYY-MM-DD") of a picked date, for reading a task's current
  /// value back into a picker.
  static func date(fromWire wire: String?) -> Date? {
    guard let wire else { return nil }
    return parse.date(from: wire)
  }
}

// MARK: - Table subclass (keyboard)

/// Keyboard seam: the `TaskRowShortcuts` equivalents intercept on the
/// responder chain ahead of the menu bar (whose SwiftUI items are disabled in
/// this window anyway — no focused task-list publisher), Return opens the
/// rename field editor. Everything else — arrows, type-select, ⇧-extension —
/// is stock NSTableView.
@MainActor
final class SeptaskKitTableView: NSTableView {
  var onToggleComplete: (() -> Void)?
  var onToggleToday: (() -> Void)?
  /// ⌘R — bare-title rename.
  var onBeginEdit: (() -> Void)?
  /// Return / double-click — the full inline composer.
  var onOpenComposer: (() -> Void)?
  var onDelete: (() -> Void)?
  var onNewTask: (() -> Void)?
  var onWhen: (() -> Void)?
  var onDeadline: (() -> Void)?
  var onClearSchedule: (() -> Void)?
  var onToggleInspector: (() -> Void)?
  var onQuickFind: (() -> Void)?
  var onDuplicate: (() -> Void)?
  var onMove: (() -> Void)?
  var onCopy: (() -> Void)?
  var canCopy: (() -> Bool)?
  /// Tab / Shift-Tab — two-pane keyboard nav, sidebar ⇄ list (mirrors the
  /// sidebar's own `onTab` in `KitSidebarOutlineView`).
  var onFocusSidebar: (() -> Void)?

  /// Standard responder-chain copy, so Edit ▸ Copy (and its ⌘C) reaches the
  /// task list without a competing menu item.
  @objc func copy(_ sender: Any?) { onCopy?() }

  override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(copy(_:)) { return canCopy?() ?? false }
    return super.validateUserInterfaceItem(item)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

    // ⌥⌘I — the platform's inspector toggle.
    if flags == [.command, .option],
       event.charactersIgnoringModifiers?.lowercased() == "i" {
      onToggleInspector?()
      return true
    }

    // ⌘⇧D / ⌘⇧. — deliberately the shifted forms (bare ⌘. is the system
    // Cancel equivalent), matching TaskRowShortcuts. ⌘⇧F is Quick Find, the
    // same binding the SwiftUI window uses.
    if flags == [.command, .shift] {
      switch event.charactersIgnoringModifiers?.lowercased() {
      case "d": onDeadline?(); return true
      case ".": onClearSchedule?(); return true
      case "f": onQuickFind?(); return true
      case "m": onMove?(); return true
      default: return super.performKeyEquivalent(with: event)
      }
    }

    guard flags == .command else {
      return super.performKeyEquivalent(with: event)
    }
    switch event.charactersIgnoringModifiers {
    case "k": onToggleComplete?(); return true
    case "t": onToggleToday?(); return true
    case "r": onBeginEdit?(); return true
    case "n": onNewTask?(); return true
    case "s": onWhen?(); return true
    case "d": onDuplicate?(); return true
    case ",": SeptaskKitSettingsWindow.show(); return true
    case "\u{7F}": onDelete?(); return true   // ⌘⌫, matching TaskRowShortcuts.delete
    default: return super.performKeyEquivalent(with: event)
    }
  }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 36, 76:  // Return / keypad Enter — opens the composer, not a bare rename.
      onOpenComposer?()
    case 48:  // Tab / Shift-Tab — only two stops in the loop, so either
      // direction just crosses to the sidebar (no field editor is live here;
      // one is first responder instead and eats Tab before this fires).
      onFocusSidebar?()
    default:
      super.keyDown(with: event)
    }
  }

  /// Finder-standard context-menu targeting: right-click inside the selection
  /// acts on the selection; outside it, the clicked row becomes the selection.
  var onRightClick: ((NSEvent) -> Void)?

  /// Deliberately does NOT call super — see the comment where `onRightClick`
  /// is wired up. `NSTableView`'s default secondary-click handling is what
  /// paints the native row highlight we're avoiding, so this replaces it
  /// entirely rather than adding to it.
  override func rightMouseDown(with event: NSEvent) {
    onRightClick?(event)
  }
}
#endif
